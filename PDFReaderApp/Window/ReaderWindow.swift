import AppKit

@MainActor
final class ReaderWindow: NSWindow {
    var keyEventHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyEventHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}
