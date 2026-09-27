import AppKit
import PDFReaderCore

@MainActor
final class ShortcutRecordingSession {
    enum Outcome: Equatable {
        case recorded(String)
        case cancelled
        case invalid(String)
    }

    private weak var window: NSWindow?
    private weak var returnResponder: NSResponder?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var buffer: ShortcutRecordingBuffer
    private let onChange: (String, String?) -> Void
    private let onFinish: (Outcome) -> Void
    private var finished = false
    private var lastConsumedEvent: NSEvent?
    private let acceptsEvent: (NSWindow, NSEvent) -> Bool

    init(
        window: NSWindow,
        target: ShortcutRecordingTarget,
        acceptsEvent: @escaping (NSWindow, NSEvent) -> Bool = { $0.isKeyWindow && $1.window === $0 },
        onChange: @escaping (String, String?) -> Void,
        onFinish: @escaping (Outcome) -> Void
    ) {
        self.window = window
        returnResponder = window.firstResponder
        buffer = ShortcutRecordingBuffer(target: target)
        self.onChange = onChange
        self.onFinish = onFinish
        self.acceptsEvent = acceptsEvent
    }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        guard monitor == nil, !finished else { return }
        // If recording was entered from a key command, the same event may still
        // be offered through another AppKit dispatch path. Consume, don't record it.
        if let trigger = NSApp.currentEvent, trigger.type == .keyDown, trigger.window === window {
            lastConsumedEvent = trigger
        }
        (window as? ReaderWindow)?.shortcutRecorder = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consume(event) ?? false }
            return consumed ? nil : event
        }
        for (name, object) in [
            (NSWindow.didResignKeyNotification, window as AnyObject?),
            (NSWindow.willCloseNotification, window as AnyObject?),
            (NSApplication.didResignActiveNotification, NSApplication.shared as AnyObject?),
        ] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        onChange("Press keys…", nil)
    }

    func cancel() { finish(.cancelled) }

    /// Shared by local monitoring, window dispatch and key-equivalent dispatch.
    func consume(_ event: NSEvent) -> Bool {
        guard !finished, let window, acceptsEvent(window, event),
              [.keyDown, .keyUp, .flagsChanged].contains(event.type) else { return false }
        if lastConsumedEvent === event { return true }
        lastConsumedEvent = event
        if event.type == .keyDown { receive(event) }
        return true
    }

    private func receive(_ event: NSEvent) {
        let token = AppKitKeyEventAdapter.recordingToken(for: event) ?? .imeComposition
        let physicalModifiers = Self.physicalModifiers(from: event.modifierFlags)
        switch buffer.receive(token, physicalModifiers: physicalModifiers, isRepeat: event.isARepeat) {
        case let .completed(source): finish(.recorded(source))
        case .cancelled: finish(.cancelled)
        case let .invalid(message): finish(.invalid(message))
        case .recorded, .rejected:
            let source = KeySequence(tokens: buffer.tokens).description
            let label = ShortcutKeyDisplay.text(for: source)
            let text = ShortcutKeyDisplay.inputDescription(for: source).map { "\(label)  (\($0))" } ?? label
            onChange(text.isEmpty ? "Press keys…" : text, buffer.error)
        case .ignoredRepeat: break
        }
    }

    private static func physicalModifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        if let reader = window as? ReaderWindow, reader.shortcutRecorder === self { reader.shortcutRecorder = nil }
        lastConsumedEvent = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let window, let returnResponder { window.makeFirstResponder(returnResponder) }
        onFinish(outcome)
    }
}
