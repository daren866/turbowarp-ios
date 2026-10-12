import UIKit
import SwiftUI

/// iOS 13 兼容入口：UIKit AppDelegate + UIHostingController 承载 SwiftUI 编辑器。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: ScratchGUIView())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
