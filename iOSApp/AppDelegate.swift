import UIKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        NSLog("[PBL][APP] didFinishLaunching bundle=%@", Bundle.main.bundleIdentifier ?? "unknown")
        return true
    }
}
