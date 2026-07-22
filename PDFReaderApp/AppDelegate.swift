import AppKit
import PDFReaderCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var applicationController: ApplicationController?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ApplicationController()
        controller.start()
        applicationController = controller
        if !pendingOpenURLs.isEmpty {
            controller.openExternalDocuments(pendingOpenURLs)
            pendingOpenURLs.removeAll()
        }
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
