import AppKit

enum WindowVisualMetrics {
    static let initialSize = NSSize(width: 1_040, height: 760)
    static let minimumSize = NSSize(width: 720, height: 480)
    static let tabBarHeight: CGFloat = 34
    static let tabHeight: CGFloat = 26
    static let statusBarHeight: CGFloat = 26
    static let trafficLightInset: CGFloat = 78
    static let promptMaximumWidth: CGFloat = 520
    static let promptHeight: CGFloat = 42
    static let cornerRadius: CGFloat = 8
    static let compactCornerRadius: CGFloat = 6
    static let focusIndicatorWidth: CGFloat = 2
}

@MainActor
final class ClosureButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    var handler: (() -> Void)? {
        didSet {
            target = self
            action = #selector(invokeHandler)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(invokeHandler)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func invokeHandler() {
        handler?()
    }
}

extension NSView {
    func prepareForAutoLayout() {
        translatesAutoresizingMaskIntoConstraints = false
    }
}
