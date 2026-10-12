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
final class ScratchBridge: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {

    /// 单例：iOS 13 无 @StateObject，用单例保证实例稳定、状态不丢失。
    static let shared = ScratchBridge()

    // MARK: - 对外状态（驱动 SwiftUI 弹窗）

    @Published var savedMessage: String?
    @Published var showError = false
    @Published var errorMessage = ""

    // MARK: - 私有资源路径

    let configuration: WKWebViewConfiguration
    private(set) var indexURL: URL!
    private(set) var scratchDir: URL!
    private weak var webView: WKWebView?

    // MARK: - 初始化

    override private init() {
        let bundle = Bundle.main
        // 用递归查找避免 Tuist 打包后目录结构差异；scratchgui 资源目录内必有 index.html
        let htmlPaths = bundle.paths(forResourcesOfType: "html", inDirectory: nil)
        guard let index = htmlPaths.first(where: { $0.contains("scratchgui") && $0.hasSuffix("index.html") }) else {
            fatalError("未找到 scratchgui/index.html，请确认已将 scratch-gui 构建产物复制到 SwiftUIStarter/scratchgui")
        }
        let dir = URL(fileURLWithPath: index).deletingLastPathComponent()
        indexURL = URL(fileURLWithPath: index)
        scratchDir = dir

        configuration = WKWebViewConfiguration()
        super.init()

        // 注入桥接脚本：拦截 blob 下载并上报原生
        let script = WKUserScript(
            source: ScratchBridge.bridgeJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(self, name: "scratchSave")
        configuration.preferences.javaScriptEnabled = true
    }

    // MARK: - WebView 创建与加载

    func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        self.webView = webView
        webView.loadFileURL(indexURL, allowingReadAccessTo: scratchDir)
        return webView
    }

    // MARK: - 原生打开 .sb3

    /// 由文件选择器调用：读入 .sb3 数据，包成 data: URL 后经 project_url 参数载入编辑器。
    /// scratch-gui 的编辑器仅从 URL 读取 project_url（支持 http/https/data 三种 scheme），
    /// 因此用 `data:application/octet-stream;base64,<内容>` 直接传入，无需本地 HTTP server。
    func openProject(data: Data) {
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
        // 初始加载已在 makeUIView 中触发，此处无需处理
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
