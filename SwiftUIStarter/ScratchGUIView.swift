import SwiftUI
import WebKit
import UIKit
import MobileCoreServices

/// 桥接 scratch-gui（Web 编辑器）与 iOS 原生层。
/// - 保存：拦截编辑器“保存到设备”的 blob 下载，写入 App Documents/ScratchProjects。
/// - 打开：提供原生文件选择器，读入 .sb3 后经 project_url(data:) 参数载入编辑器。
///
/// 为兼容 iOS 13：以单例持有实例（避免 @StateObject 不可用导致反复重建），
/// 文件选择使用 UIDocumentPickerViewController（UIViewControllerRepresentable 包装）。
///
/// 关键稳定性修正（针对 iPhone 7 / 老设备启动闪退）：
/// - WKWebView 仅创建一次，避免复用 WKWebViewConfiguration 引发异常崩溃。
/// - index.html 查找多重回退，失败不再 fatalError，而是弹错误提示。
/// - 非持久化 websiteDataStore，降低内存/磁盘占用。
final class ScratchBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    /// 单例：iOS 13 无 @StateObject，用单例保证实例稳定、状态不丢失。
    static let shared = ScratchBridge()

    // MARK: - 对外状态（驱动 SwiftUI 弹窗）

    @Published var savedMessage: String?
    @Published var showError = false
    @Published var errorMessage = ""

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

    // MARK: - WebView 创建与加载

    /// 返回唯一的 WKWebView 实例：首次调用时创建并加载，后续调用直接复用，
    /// 从根本上杜绝“同一 WKWebViewConfiguration 被多次初始化 WKWebView”导致的崩溃。
    func makeWebView() -> WKWebView {
        if let existing = webView { return existing }

        guard let indexURL = ScratchBridge.resolveIndexURL() else {
            let msg = "未在 App 资源中找到 scratch-gui 的 index.html，请确认构建已包含 scratchgui 目录（Tuist 资源未正确打包）。"
            DispatchQueue.main.async { [weak self] in
                self?.errorMessage = msg
                self?.showError = true
            }
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
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "网页内容进程已终止：很可能是 iPhone 7 内存（2GB）不足以运行完整编辑器。请关闭其他后台 App 后重试；若仍失败，需要我出“精简版/播放器版”以大幅降低内存占用。"
            self?.showError = true
        }
    }

    private func reportLoadError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = "页面加载失败：\(error.localizedDescription)"
            self?.showError = true
        }
    }

    // MARK: - 保存文件到本地

    private func saveProject(name: String, base64: String) {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            errorMessage = "无法解码保存的数据"
            showError = true
            return
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("ScratchProjects", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let fileURL = folder.appendingPathComponent(name)
            try data.write(to: fileURL, options: .atomic)
            savedMessage = "已保存到「文件」App：ScratchProjects/\(name)"
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    // MARK: - 桥接脚本（注入到页面）

    /// 重写 HTMLAnchorElement.click：当编辑器“保存到设备”创建 blob: 链接并点击时，
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

// MARK: - UIDocumentPickerViewController 包装（iOS 13 可用的文件选择器）

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // kUTTypeData 允许选择任意数据文件（含 .sb3）
        let picker = UIDocumentPickerViewController(documentTypes: [kUTTypeData as String], in: .open)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
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
    @State private var showPicker = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScratchWebView(bridge: bridge)
                .edgesIgnoringSafeArea(.all)

            // 浮动“打开”按钮：避免 iOS 13 无 .toolbar 时无法放置原生入口，
            // 同时不与 scratch 自带顶部菜单栏（导航栏）层叠。
            Button(action: { showPicker = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("打开")
                }
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55))
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .padding(.top, 6)
            .padding(.trailing, 8)
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker { url in
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) {
                    bridge.openProject(data: data)
                }
            }
        }
        .alert(
            isPresented: Binding(
                get: { bridge.savedMessage != nil },
                set: { if !$0 { bridge.savedMessage = nil } }
            )
        ) {
            Alert(
                title: Text("已保存"),
                message: Text(bridge.savedMessage ?? ""),
                dismissButton: .default(Text("好"))
            )
        }
        .alert(isPresented: $bridge.showError) {
            Alert(
                title: Text("错误"),
                message: Text(bridge.errorMessage),
                dismissButton: .default(Text("好"))
            )
        }
    }
}
