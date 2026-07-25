import AppKit

@MainActor
final class ReaderWindow: NSWindow {
    var keyEventHandler: ((NSEvent) -> Bool)?
    var mouseDownHandler: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            mouseDownHandler?(event)
        }
        if event.type == .keyDown, keyEventHandler?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}
