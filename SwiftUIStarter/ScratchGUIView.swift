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
        configuration.userContentController.add(self, name: "scratchSave")

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
        guard message.name == "scratchSave",
              let body = message.body as? [String: Any],
              let name = body["name"] as? String,
              let base64 = body["data"] as? String else {
            return
        }
        saveProject(name: name, base64: base64)
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
    @available(iOS 15.0, *)
    func webView(_ webView: WKWebView, decidePolicyFor captureType: WKMediaCaptureType, decisionHandler: @escaping (WKMediaCapturePermissionDecision) -> Void) {
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

    // MARK: - 桥接脚本（注入到页面）

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
