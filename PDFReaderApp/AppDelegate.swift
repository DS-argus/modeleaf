import AppKit
import PDFReaderCore

@MainActor
protocol AppRuntimeApplication: AnyObject {
    var delegate: (any NSApplicationDelegate)? { get set }

    func setActivationPolicy(_ activationPolicy: NSApplication.ActivationPolicy) -> Bool
    func run()
}

extension NSApplication: AppRuntimeApplication {}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var applicationController: ApplicationController?
    private var pendingOpenURLs: [URL] = []

    static func main() {
        runApplication()
    }

    static func runApplication(
        application: any AppRuntimeApplication = NSApplication.shared,
        delegate: AppDelegate = AppDelegate()
    ) {
        application.delegate = delegate
        _ = application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let application = notification.object as? NSApplication ?? .shared
        application.applicationIconImage = ApplicationIcon.load()
        let controller = ApplicationController(application: application)
        controller.start()
        applicationController = controller
        if !pendingOpenURLs.isEmpty {
            controller.openExternalDocuments(pendingOpenURLs)
            pendingOpenURLs.removeAll()
        }
        application.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let applicationController {
            applicationController.openExternalDocuments(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
