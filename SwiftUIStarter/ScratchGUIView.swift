import SwiftUI
import WebKit
import UIKit

/// 桥接 scratch-gui（Web 编辑器）与 iOS 原生层。
/// - 保存：拦截编辑器“保存到电脑”的 blob 下载，写入 App Documents/ScratchProjects。
/// - 打开：底层 openProject(data:) 可将 .sb3 经 project_url(data:) 参数载入编辑器
///   （由编辑器自身 UI 触发，不再使用额外原生浮层按钮）。
/// - 相机/麦克风：实现 WKUIDelegate 媒体捕获授权，拦截网页 getUserMedia 请求并直接授予，
///   使 Scratch 的视频侦测 / 声音扩展可直接使用设备（系统首次硬件弹窗仍由用户确认一次）。
///
/// 为兼容 iOS 13：以单例持有实例（避免 @StateObject 不可用导致反复重建）。
///
/// 关键稳定性修正（针对 iPhone 7 / 老设备启动闪退）：
/// - WKWebView 仅创建一次，避免复用 WKWebViewConfiguration 引发异常崩溃。
/// - index.html 查找多重回退，失败不再 fatalError，而是弹错误提示。
/// - 非持久化 websiteDataStore，降低内存/磁盘占用。
final class ScratchBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

    /// 单例：iOS 13 无 @StateObject，用单例保证实例稳定、状态不丢失。
    static let shared = ScratchBridge()

    // MARK: - 对外状态（驱动 SwiftUI 顶部 Toast）

    /// 顶部 Toast 提示：toastMessage 为空则不显示；toastIsError 决定绿（成功）/红（错误）。
    @Published var toastMessage: String?
    @Published var toastIsError = false

    // MARK: - 私有资源路径

    private(set) var webView: WKWebView?
    private var indexURL: URL?
    private var scratchDir: URL?

    // MARK: - 初始化

    override private init() {
        super.init()
        // 资源解析与 WKWebView 创建延迟到 makeWebView()（首次由 SwiftUI 触发），
        // 避免单例构造阶段做任何可能失败的重操作。
    }

    // MARK: - Toast 显示

    /// 显示顶部 Toast：成功（绿）/错误（红），展示后自动消失。
    /// - 成功提示展示 1.5 秒；错误提示文本较长，展示 2.5 秒以便阅读。
    private func showToast(_ message: String, isError: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.toastMessage = message
            self?.toastIsError = isError
            let duration: TimeInterval = isError ? 2.5 : 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                // 仅当仍是本条提示时才清除，避免覆盖更新的提示。
                if self?.toastMessage == message {
                    self?.toastMessage = nil
                }
            }
        }
    }

    // MARK: - WebView 创建与加载

    /// 返回唯一的 WKWebView 实例：首次调用时创建并加载，后续调用直接复用，
    /// 从根本上杜绝“同一 WKWebViewConfiguration 被多次初始化 WKWebView”导致的崩溃。
    func makeWebView() -> WKWebView {
        if let existing = webView { return existing }

        guard let indexURL = ScratchBridge.resolveIndexURL() else {
            let msg = "未在 App 资源中找到 scratch-gui 的 index.html，请确认构建已包含 scratchgui 目录（Tuist 资源未正确打包）。"
            showToast(msg, isError: true)
            let fallback = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            webView = fallback
            return fallback
        }

        self.indexURL = indexURL
        self.scratchDir = indexURL.deletingLastPathComponent()

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptEnabled = true
        // 非持久化数据仓储：减少磁盘与内存占用，对 2GB 内存的老设备（iPhone 7）更友好。
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ScratchBridge.bridgeJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
        )
        // 预置离线资产（document start）：在页面任何脚本执行前把 bundle 内资产写入
        // window.__scratchBundledAssets，offline-assets.js 模块加载时同步消费，
        // 保证 VM 加载作品时 storage.load 必命中缓存（无 hydrate 竞态）。
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: ScratchBridge.bundledAssetsJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        configuration.userContentController.add(self, name: "scratchSave")
        // 资源离线包：网页把待下载资产清单上报到此，由原生 URLSession 下载（规避 CORS）
        // 写入 Documents 沙盒并回推 hydrate；启动时再回推离线状态。
        configuration.userContentController.add(self, name: "offlineDownload")
        configuration.userContentController.add(self, name: "offlineGetAsset")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        self.webView = webView
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        return webView
    }

    /// 健壮查找 scratch-gui 的 index.html：
    /// 1) 优先按子目录 scratchgui 直接定位；
    /// 2) 否则扫描所有 index.html，挑选父目录含 scratch 标志性文件（player.html/editor.html/static 等）的那个；
    /// 3) 仍无则取首个 index.html。
    private static func resolveIndexURL() -> URL? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: "scratchgui") {
            return url
        }
        let candidates = (bundle.urls(forResourcesWithExtension: "html", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent == "index.html" }
        let markers = ["player.html", "editor.html", "static", "addons.html", "credits.html", "sa.html"]
        for marker in markers {
            if let found = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().appendingPathComponent(marker).path)
            }) {
                return found
            }
        }
        return candidates.first
    }

    // MARK: - 原生打开 .sb3

    /// 由文件选择器调用：读入 .sb3 数据，包成 data: URL 后经 project_url 参数载入编辑器。
    /// scratch-gui 的编辑器仅从 URL 读取 project_url（支持 http/https/data 三种 scheme），
    /// 因此用 `data:application/octet-stream;base64,<内容>` 直接传入，无需本地 HTTP server。
    func openProject(data: Data) {
        guard let indexURL = indexURL, let scratchDir = scratchDir else { return }
        let base64 = data.base64EncodedString()
        let dataURL = "data:application/octet-stream;base64," + base64
        guard var components = URLComponents(url: indexURL, resolvingAgainstBaseURL: false) else { return }
        components.queryItems = [URLQueryItem(name: "project_url", value: dataURL)]
        if let url = components.url {
            webView?.loadFileURL(url, allowingReadAccessTo: scratchDir)
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body as? [String: Any]
        switch message.name {
        case "scratchSave":
            guard let name = body?["name"] as? String,
                  let base64 = body?["data"] as? String else {
                return
            }
            saveProject(name: name, base64: base64)
        case "offlineDownload":
            // 网页上报待下载资产清单：[{md5ext, url}, ...]
            // 由原生 URLSession 下载（无 CORS 限制），校验后写盘并回推 hydrate。
            guard let assets = body?["assets"] as? [[String: Any]] else { return }
            handleOfflineDownload(assets: assets)
        case "offlineGetAsset":
            guard let md5ext = body?["md5ext"] as? String else { return }
            pushOfflineAsset(md5ext: md5ext)
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate（加载完成回推离线状态）

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushOfflineState(to: webView)
    }

    // MARK: - WKNavigationDelegate（加载错误兜底）

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadError(error)
    }

    /// 网页内容进程被系统终止（老设备 2GB 内存跑重型编辑器时常因内存压力被 jetsam 杀掉）。
    /// 捕获后给出明确提示，便于区分“内存不足”与“加载失败”两类问题。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showToast("网页内容进程已终止：很可能是 iPhone 7 内存（2GB）不足以运行完整编辑器。请关闭其他后台 App 后重试；若仍失败，需要我出“精简版/播放器版”以大幅降低内存占用。", isError: true)
    }

    private func reportLoadError(_ error: Error) {
        showToast("页面加载失败：\(error.localizedDescription)", isError: true)
    }

    // MARK: - WKUIDelegate（媒体捕获授权：摄像头/麦克风）

    /// 拦截网页对摄像头/麦克风的 getUserMedia 请求，并直接授予（.grant），
    /// 使 scratch-gui 的视频侦测、声音扩展可无缝使用设备。
    /// 注意：该代理方法自 iOS 15 起可用；iPhone 7 最高可升 iOS 15，故覆盖目标设备。
    /// 系统级「App 是否允许访问相机/麦克风」的首次弹窗仍由用户确认一次，无法绕过（Apple 隐私策略）。
    /// iOS 26 SDK 起 API 改名：决策类型 WKMediaCapturePermissionDecision → WKPermissionDecision，
    /// 方法 decidePolicyFor:captureType: → requestMediaCapturePermissionFor:initiatedByFrame:type:。
    @available(iOS 15.0, *)
    @MainActor
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type captureType: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    // MARK: - 保存文件到本地（应用沙盒 Documents/ScratchProjects）

    /// 网页“保存到电脑”触发后，由 JS 桥接把 .sb3 的 base64 上报到这里，
    /// 通过 FileManager（系统文件 API）写入应用沙盒的 Documents/ScratchProjects 目录。
    /// 该目录已开启 UIFileSharingEnabled，可在系统「文件」App 中查看。
    private func saveProject(name: String, base64: String) {
        let fileName = ScratchBridge.sanitizedFileName(name)
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), !data.isEmpty else {
            showToast("保存失败：无法解码保存的数据（内容为空或格式错误）", isError: true)
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("ScratchProjects", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileURL = folder.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: .atomic)
            // 成功提示：左上角绿色 Toast，1.5 秒后自动消失。
            showToast("保存成功！作品已保存至文件/Gudaocode/ScratchProjects/里", isError: false)
        } catch {
            showToast("保存失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// 清洗文件名：去掉路径分隔符等非法字符，并确保以 .sb3 结尾。
    private static func sanitizedFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        var cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        if cleaned.isEmpty { cleaned = "project" }
        if !cleaned.lowercased().hasSuffix(".sb3") { cleaned += ".sb3" }
        return cleaned
    }

    // MARK: - 资源离线包（Documents/OfflineAssets 持久化 + 启动 hydrate）

    /// 离线资产目录：Documents/OfflineAssets（随 App 沙盒持久化，跨启动有效）。
    private var offlineAssetsDir: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("OfflineAssets", isDirectory: true)
    }

    /// 预置离线资产目录：.app bundle 根下 OfflineAssets（copy-scratchgui.sh 构建期拷入，随 App 分发）。
    /// 存放 default project 的素材（backdrop + costume），启动 hydrate 即可用，免用户手动下载。
    private var bundledAssetsDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("OfflineAssets", isDirectory: true)
    }

    /// 清洗资产文件名（md5ext，如 "1a2b3c.svg"）：去掉路径分隔符，仅保留末段。
    private static func sanitizedAssetName(_ name: String) -> String {
        let base = name.components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? name
        let illegal = CharacterSet(charactersIn: "?%*|\"<>:")
        let cleaned = base.components(separatedBy: illegal).joined(separator: "_")
        return cleaned.isEmpty ? "asset.bin" : cleaned
    }

    /// 下载整个离线资源包（原生 URLSession 并发执行）。
    ///
    /// 为何由原生层下载：
    ///   - 非 wav 资源走 cdn.coding321.com/assets（阿里云 OSS，无 CORS 头）；原生层 URLSession 无视 CORS，
    ///     且可写 Documents 沙盒并跨启动持久化；wav 仍走 openblockcc（带 CORS `*`）。
    ///   - 缺失资产返回正常 404（coding321 为 404 + XML），需按 HTTP 状态判定跳过，并以魔数校验兜底；
    ///   - WKWebView 为 nonPersistent，网页存储不持久，故持久化统一走原生 Documents。
    ///
    /// 流程：去重 → 并发下载（上限 4）→ HTTP 状态/魔数校验 → 写盘 → 回推资产字节给网页 builtinHelper
    ///       → 逐条回推进度 → 全部结束后回推完成。
    /// - Parameter assets: 网页上报的资产清单 [{md5ext, url}]。
    private func handleOfflineDownload(assets: [[String: Any]]) {
        // 去重（按 md5ext 保序）；每个资产带一组候选源 URL（按优先级，原生层顺序回退）。
        var seen = Set<String>()
        var list: [(md5ext: String, urls: [URL])] = []
        for item in assets {
            guard let md5ext = item["md5ext"] as? String else { continue }
            if seen.contains(md5ext) { continue }
            var urlStrings: [String] = []
            if let urls = item["urls"] as? [String] {
                urlStrings = urls
            } else if let single = item["url"] as? String {
                urlStrings = [single]
            }
            let urls = urlStrings.compactMap { URL(string: $0) }
            if urls.isEmpty { continue }
            seen.insert(md5ext)
            list.append((md5ext, urls))
        }
        let total = list.count
        guard total > 0 else {
            pushOfflineComplete(downloaded: 0, skipped: 0, total: 0, notFound: 0)
            return
        }

        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: 4) // 限流：老设备/弱网下避免并发过高
        let stateQueue = DispatchQueue(label: "offline-download-state")
        var done = 0
        var downloaded = 0
        var notFound = 0

        let workQueue = DispatchQueue(label: "offline-download", attributes: .concurrent)
        for entry in list {
            group.enter()
            workQueue.async { [weak self] in
                semaphore.wait()
                defer {
                    semaphore.signal()
                    group.leave()
                }
                // 顺序尝试各候选源，取第一个 HTTP 200 且通过魔数校验的；全部失败视为“未找到”。
                var ok = false
                if let self = self {
                    // 本地已有（随包预置或此前下载过）则直接回推，不再走网络
                    if let existing = self.readOfflineAsset(md5ext: entry.md5ext) {
                        self.pushOfflineAssetData(md5ext: entry.md5ext, data: existing)
                        ok = true
                    } else if let data = self.downloadFirstValid(md5ext: entry.md5ext, urls: entry.urls),
                        self.writeOfflineAsset(md5ext: entry.md5ext, data: data) {
                        // 回推字节给网页：写入 storage.builtinHelper，当前会话立即可用。
                        self.pushOfflineAssetData(md5ext: entry.md5ext, data: data)
                        ok = true
                    }
                }
                stateQueue.async {
                    done += 1
                    if ok { downloaded += 1 } else { notFound += 1 }
                    let progress = (done, downloaded, notFound)
                    self?.pushOfflineProgress(done: progress.0, total: total, skipped: progress.2)
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            stateQueue.sync {
                self?.pushOfflineComplete(downloaded: downloaded, skipped: notFound, total: total, notFound: notFound)
            }
        }
    }

    /// 顺序尝试各候选源，返回第一个 HTTP 200 且通过魔数校验的字节；全部失败返回 nil。
    private func downloadFirstValid(md5ext: String, urls: [URL]) -> Data? {
        for url in urls {
            let (httpOK, data) = downloadSync(url: url)
            if httpOK, let data = data, isValidAsset(md5ext: md5ext, data: data) {
                NSLog("[offline] %@ OK <- %@", md5ext, url.absoluteString)
                return data
            }
        }
        NSLog("[offline] %@ NOT FOUND on all sources", md5ext)
        return nil
    }

    /// 同步下载单个 URL（用于在一个 work item 内顺序回退候选源）。
    private func downloadSync(url: URL) -> (httpOK: Bool, data: Data?) {
        let sem = DispatchSemaphore(value: 0)
        var httpOK = false
        var outData: Data?
        URLSession.shared.dataTask(with: url) { data, response, error in
            httpOK = (response as? HTTPURLResponse)?.statusCode == 200
            outData = (error == nil) ? data : nil
            sem.signal()
        }.resume()
        sem.wait()
        return (httpOK, outData)
    }

    /// 魔数 / 内容校验：拒绝 XML/HTML 错误体（404 等）与类型不符的数据。
    /// - coding321 对缺失资源返回 404 + XML 错误体（约 400 字节）；虽已被上方 HTTP 状态判断拦下，
    ///   此处魔数校验作为第二道防线，并防御其他异常响应。
    private func isValidAsset(md5ext: String, data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let ext = (md5ext as NSString).pathExtension.lowercased()
        let head = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // 显式拒绝 HTML 兜底页（<!doctype / <html / <head / <body）。
        if head.hasPrefix("<!doctype") || head.hasPrefix("<html")
            || head.hasPrefix("<head") || head.hasPrefix("<body") {
            return false
        }
        switch ext {
        case "svg":
            return head.hasPrefix("<svg") || head.hasPrefix("<?xml")
        case "png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47]) // \x89PNG
        case "jpg", "jpeg":
            return data.starts(with: [0xFF, 0xD8, 0xFF])
        case "wav":
            return data.starts(with: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        case "mp3":
            return data.starts(with: [0x49, 0x44, 0x33]) || data.starts(with: [0xFF, 0xFB]) // "ID3" 或帧同步
        default:
            return false
        }
    }

    /// 写盘：Documents/OfflineAssets/{md5ext}。单个失败不阻断整体下载。
    @discardableResult
    private func writeOfflineAsset(md5ext: String, data: Data) -> Bool {
        let fileURL = offlineAssetsDir.appendingPathComponent(ScratchBridge.sanitizedAssetName(md5ext))
        do {
            try FileManager.default.createDirectory(at: offlineAssetsDir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 回推单个资产字节（base64）给网页：window.__scratchOfflineAsset。
    private func pushOfflineAssetData(md5ext: String, data: Data) {
        guard let webView = webView else { return }
        let payload: [String: Any] = ["md5ext": md5ext, "data": data.base64EncodedString()]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let js = "window.__scratchOfflineAsset && window.__scratchOfflineAsset(\(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 回推下载进度：window.__scratchOfflineProgress({done, total, skipped})。
    private func pushOfflineProgress(done: Int, total: Int, skipped: Int) {
        guard let webView = webView else { return }
        let payload: [String: Any] = ["done": done, "total": total, "skipped": skipped]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let js = "window.__scratchOfflineProgress && window.__scratchOfflineProgress(\(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// 回推下载完成：window.__scratchOfflineComplete({downloaded, skipped, total, notFound})。
    private func pushOfflineComplete(downloaded: Int, skipped: Int, total: Int, notFound: Int) {
        guard let webView = webView else { return }
        let payload: [String: Any] = ["downloaded": downloaded, "skipped": skipped, "total": total, "notFound": notFound]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let js = "window.__scratchOfflineComplete && window.__scratchOfflineComplete(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 是否已启用离线包：OfflineAssets 目录存在且至少有一个资产文件。
    /// 合并用户下载的（Documents/OfflineAssets）与随包预置的（bundle OfflineAssets）资产。
    private func offlineAssetsList() -> [String] {
        let allowed = Set(["svg", "png", "jpg", "jpeg", "wav", "mp3"])
        var names = Set<String>()
        let documents = try? FileManager.default.contentsOfDirectory(atPath: offlineAssetsDir.path)
        for name in (documents ?? []) where allowed.contains((name as NSString).pathExtension.lowercased())
            && !name.hasPrefix(".") {
            names.insert(name)
        }
        if let bundled = bundledAssetsDir,
           let files = try? FileManager.default.contentsOfDirectory(atPath: bundled.path) {
            for name in files where allowed.contains((name as NSString).pathExtension.lowercased())
                && !name.hasPrefix(".") {
                names.insert(name)
            }
        }
        return names.sorted()
    }

    /// 读取离线资产字节：先用户下载目录（Documents/OfflineAssets），再随包预置目录（bundle OfflineAssets）。
    private func readOfflineAsset(md5ext: String) -> Data? {
        let name = ScratchBridge.sanitizedAssetName(md5ext)
        let userFile = offlineAssetsDir.appendingPathComponent(name)
        if let data = FileManager.default.contents(atPath: userFile.path) {
            return data
        }
        if let bundledFile = bundledAssetsDir?.appendingPathComponent(name),
           let data = FileManager.default.contents(atPath: bundledFile.path) {
            return data
        }
        return nil
    }

    /// 启动时把离线状态与资产清单回推给网页（window.__scratchOfflineInit）。
    private func pushOfflineState(to webView: WKWebView) {
        let assets = offlineAssetsList()
        let payload: [String: Any] = ["enabled": !assets.isEmpty, "assets": assets]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let js = "window.__scratchOfflineInit && window.__scratchOfflineInit(\(json));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// 网页请求单个离线资产字节：读盘（用户目录优先、预置兜底）→ base64 → 回推 window.__scratchOfflineAsset。
    private func pushOfflineAsset(md5ext: String) {
        guard let webView = webView else { return }
        guard let data = readOfflineAsset(md5ext: md5ext) else { return }
        let payload: [String: Any] = ["md5ext": md5ext, "data": data.base64EncodedString()]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        let js = "window.__scratchOfflineAsset && window.__scratchOfflineAsset(\(json));"
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    // MARK: - 桥接脚本（注入到页面）

    /// 预置资产注入脚本（document start 执行）：读取 bundle 内 OfflineAssets 目录
    /// （copy-scratchgui.sh 构建期拷入，存放 default project 素材），以 base64 写入
    /// window.__scratchBundledAssets。网页侧 offline-assets.js 在模块加载时同步消费，
    /// 早于 VM 加载作品 → storage.load 必命中 builtinHelper 缓存，无竞态、离线可用。
    private static var bundledAssetsJS: String {
        let allowed = Set(["svg", "png", "jpg", "jpeg", "wav", "mp3"])
        var map: [String: String] = [:]
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("OfflineAssets", isDirectory: true),
           let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for name in files where allowed.contains((name as NSString).pathExtension.lowercased()) {
                if let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) {
                    map[name] = data.base64EncodedString()
                }
            }
        }
        let json = ((try? JSONSerialization.data(withJSONObject: map))
            .flatMap { String(data: $0, encoding: .utf8) }) ?? "{}"
        return "window.__scratchBundledAssets = \(json);"
    }

    /// 重写 HTMLAnchorElement.click：当编辑器“保存到电脑”创建 blob: 链接并点击时，
    /// 读取其内容为 base64，通过 messageHandlers 上报原生层保存，阻止浏览器默认下载。
    private static let bridgeJS = """
    (function () {
      if (window.__scratchBridgeInstalled) return;
      window.__scratchBridgeInstalled = true;

      var origClick = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        if (this.download && typeof this.href === 'string' && this.href.indexOf('blob:') === 0) {
          var name = this.download || 'project.sb3';
          if (name.toLowerCase().indexOf('.sb3') === -1) name += '.sb3';
          fetch(this.href)
            .then(function (r) { return r.blob(); })
            .then(function (blob) {
              var reader = new FileReader();
              reader.onloadend = function () {
                var b64 = (reader.result || '').split(',')[1] || '';
                if (window.webkit &&
                    window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.scratchSave) {
                  window.webkit.messageHandlers.scratchSave.postMessage({ name: name, data: b64 });
                }
              };
              reader.readAsDataURL(blob);
            });
          return;
        }
        return origClick.apply(this, arguments);
      };
    })();
    """
}

// MARK: - UIViewRepresentable 包装 WKWebView

struct ScratchWebView: UIViewRepresentable {
    let bridge: ScratchBridge

    func makeUIView(context: Context) -> WKWebView {
        bridge.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // WKWebView 由单例唯一持有，初始加载已在 makeUIView 中触发，此处无需处理。
    }
}

// MARK: - SwiftUI 入口视图（iOS 13 兼容）

struct ScratchGUIView: View {
    @ObservedObject private var bridge = ScratchBridge.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScratchWebView(bridge: bridge)
                .edgesIgnoringSafeArea(.all)

            // 左上角 Toast：成功（绿）/错误（红），由 bridge.toastMessage 驱动，自动消失。
            if let message = bridge.toastMessage {
                HStack(spacing: 6) {
                    Image(systemName: bridge.toastIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((bridge.toastIsError ? Color.red : Color.green).opacity(0.92))
                .foregroundColor(.white)
                .cornerRadius(10)
                .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
                .frame(maxWidth: 300, alignment: .leading)
                .padding(.top, 12)
                .padding(.leading, 12)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: bridge.toastMessage)
            }
        }
    }
}
