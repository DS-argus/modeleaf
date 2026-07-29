import AppKit

@MainActor
final class ReaderWindow: NSWindow {
    var keyEventHandler: ((NSEvent) -> Bool)?
    var mouseDownHandler: ((NSEvent) -> Void)?
    var geometryEventHandler: (() -> Void)?
    var geometryEventObserverForTesting: ((NSEvent.EventType) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let geometryType = [.scrollWheel, .magnify, .smartMagnify, .swipe, .rotate].contains(event.type) ? event.type : nil
        if let geometryType {
            handleGeometryEvent(geometryType)
        }
        if event.type == .leftMouseDown {
            mouseDownHandler?(event)
        }
        if event.type == .keyDown, keyEventHandler?(event) == true {
            return
        }
        super.sendEvent(event)
        if let geometryType {
            geometryEventObserverForTesting?(geometryType)
        }
    }

    func sendGeometryEventForTesting(_ type: NSEvent.EventType) {
        guard [.scrollWheel, .magnify, .smartMagnify, .swipe, .rotate].contains(type) else { return }
        handleGeometryEvent(type)
    }

    private func handleGeometryEvent(_ type: NSEvent.EventType) {
        geometryEventHandler?()
    }
}
