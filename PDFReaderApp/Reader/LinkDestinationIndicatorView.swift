import AppKit
import PDFReaderCore
import QuartzCore

@MainActor
final class LinkDestinationIndicatorView: NSView {
    private let primaryLayer = CAShapeLayer()
    private let backdropLayer = CAShapeLayer()
    private let dotLayer = CAShapeLayer()

    private var configuration = LinkDestinationIndicatorSettings.standard
    private var accentColor = NSColor.controlAccentColor
    private var backgroundColor = NSColor.white

    private(set) var isVisible = false
    private(set) var indicatorCenter: CGPoint?
    private(set) var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)

        for shapeLayer in [backdropLayer, primaryLayer, dotLayer] {
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.opacity = 0
            layer?.addSublayer(shapeLayer)
        }
        applyConfiguration()
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        _ configuration: LinkDestinationIndicatorSettings,
        accentColor: NSColor? = nil,
        backgroundColor: NSColor? = nil
    ) {
        cancel()
        self.configuration = configuration
        if let accentColor { self.accentColor = accentColor }
        if let backgroundColor { self.backgroundColor = backgroundColor }
        applyConfiguration()
    }

    func applyAppearance(accentColor: NSColor, backgroundColor: NSColor) {
        self.accentColor = accentColor
        self.backgroundColor = backgroundColor
        applyColors()
    }

    func present(at center: CGPoint) {
        generation += 1
        let presentationGeneration = generation
        indicatorCenter = center
        isVisible = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAnimations()
        for shapeLayer in [backdropLayer, primaryLayer, dotLayer] {
            shapeLayer.position = center
            shapeLayer.opacity = 0
        }
        CATransaction.commit()

        let primaryAnimation = makePrimaryAnimation()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == presentationGeneration else { return }
                self.isVisible = false
                self.indicatorCenter = nil
            }
        }
        primaryLayer.add(primaryAnimation, forKey: "linkDestinationPulse")
        if usesBackdrop, let backdropAnimation = primaryAnimation.copy() as? CAAnimationGroup {
            backdropLayer.add(backdropAnimation, forKey: "linkDestinationPulse")
        }
        if let dotAnimation = makeDotAnimation() {
            dotLayer.add(dotAnimation, forKey: "linkDestinationDot")
        }
        CATransaction.commit()
    }

    func cancel() {
        generation += 1
        removeAnimations()
        for shapeLayer in [backdropLayer, primaryLayer, dotLayer] {
            shapeLayer.opacity = 0
        }
        isVisible = false
        indicatorCenter = nil
    }

    var activeAnimationForTesting: CAAnimationGroup? {
        primaryLayer.animation(forKey: "linkDestinationPulse") as? CAAnimationGroup
    }
    var activeDotAnimationForTesting: CAAnimationGroup? {
        dotLayer.animation(forKey: "linkDestinationDot") as? CAAnimationGroup
    }
    var lineWidthForTesting: CGFloat { primaryLayer.lineWidth }
    var strokeColorForTesting: CGColor? { primaryLayer.strokeColor }
    var backdropVisibleForTesting: Bool { usesBackdrop }
    var settingsForTesting: LinkDestinationIndicatorSettings { configuration }

    private var size: CGFloat { CGFloat(configuration.size) }
    private var totalDuration: CFTimeInterval { Double(configuration.durationMilliseconds) / 1_000 }
    private var usesBackdrop: Bool { configuration.color == .preset(.highContrast) }

    private func applyConfiguration() {
        let shapeBounds = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        for shapeLayer in [backdropLayer, primaryLayer, dotLayer] {
            shapeLayer.bounds = shapeBounds
        }
        backdropLayer.lineWidth = 5
        primaryLayer.lineWidth = 2
        dotLayer.lineWidth = 0
        primaryLayer.path = finalPrimaryPath()
        backdropLayer.path = finalPrimaryPath()
        dotLayer.path = dotPath()
        applyColors()
    }

    private func applyColors() {
        let colors = resolvedColors()
        primaryLayer.strokeColor = colors.primary.cgColor
        primaryLayer.fillColor = NSColor.clear.cgColor
        dotLayer.strokeColor = colors.primary.cgColor
        dotLayer.fillColor = colors.primary.cgColor
        backdropLayer.strokeColor = colors.backdrop?.cgColor
        backdropLayer.fillColor = NSColor.clear.cgColor
    }

    private func resolvedColors() -> (primary: NSColor, backdrop: NSColor?) {
        switch configuration.color {
        case .preset(.red):
            return (.systemRed, nil)
        case .preset(.amber):
            return (.systemOrange, nil)
        case .preset(.cyan):
            return (.systemCyan, nil)
        case .preset(.green):
            return (.systemGreen, nil)
        case .preset(.purple):
            return (.systemPurple, nil)
        case .preset(.accent):
            return (accentColor, nil)
        case .preset(.autoContrast):
            return (backgroundLuminance > 0.5 ? .black : .white, nil)
        case .preset(.highContrast):
            return (.white, .black)
        case let .customHex(value):
            return (Self.color(fromHex: value) ?? .systemRed, nil)
        }
    }

    private var backgroundLuminance: CGFloat {
        guard let color = backgroundColor.usingColorSpace(.deviceRGB) else { return 1 }
        return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
    }

    private func makePrimaryAnimation() -> CAAnimationGroup {
        let group = CAAnimationGroup()
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = configuration.style == .beacon ? 0.75 : 0.95
        opacity.toValue = 0

        switch configuration.style {
        case .pulseRing:
            group.animations = [pathAnimation(from: ringPath(diameter: size * 0.36), to: ringPath(diameter: size)), opacity]
            group.duration = totalDuration / 2
            group.repeatCount = 2
        case .target:
            group.animations = [opacity]
            group.duration = totalDuration
        case .beacon:
            group.animations = [pathAnimation(from: ringPath(diameter: size * 0.28), to: ringPath(diameter: size)), opacity]
            group.duration = totalDuration
        case .staticRing:
            group.animations = [opacity]
            group.duration = totalDuration
        case .diamondPulse:
            group.animations = [pathAnimation(from: diamondPath(diameter: size * 0.36), to: diamondPath(diameter: size)), opacity]
            group.duration = totalDuration / 2
            group.repeatCount = 2
        }
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }

    private func makeDotAnimation() -> CAAnimationGroup? {
        guard configuration.style == .beacon else { return nil }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [opacity]
        group.duration = totalDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }

    private func pathAnimation(from: CGPath, to: CGPath) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    private func finalPrimaryPath() -> CGPath {
        switch configuration.style {
        case .pulseRing, .beacon, .staticRing:
            return ringPath(diameter: size)
        case .target:
            return targetPath()
        case .diamondPulse:
            return diamondPath(diameter: size)
        }
    }

    private func ringPath(diameter: CGFloat) -> CGPath {
        let inset = (size - diameter) / 2 + primaryLayer.lineWidth / 2
        return CGPath(ellipseIn: primaryLayer.bounds.insetBy(dx: inset, dy: inset), transform: nil)
    }

    private func diamondPath(diameter: CGFloat) -> CGPath {
        let center = CGPoint(x: primaryLayer.bounds.midX, y: primaryLayer.bounds.midY)
        let radius = max(0, diameter / 2 - primaryLayer.lineWidth / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.closeSubpath()
        return path
    }

    private func targetPath() -> CGPath {
        let path = CGMutablePath()
        path.addPath(ringPath(diameter: size * 0.62))
        let center = CGPoint(x: primaryLayer.bounds.midX, y: primaryLayer.bounds.midY)
        let edgeInset = primaryLayer.lineWidth / 2
        let innerGap = size * 0.18
        path.move(to: CGPoint(x: edgeInset, y: center.y))
        path.addLine(to: CGPoint(x: center.x - innerGap, y: center.y))
        path.move(to: CGPoint(x: center.x + innerGap, y: center.y))
        path.addLine(to: CGPoint(x: size - edgeInset, y: center.y))
        path.move(to: CGPoint(x: center.x, y: edgeInset))
        path.addLine(to: CGPoint(x: center.x, y: center.y - innerGap))
        path.move(to: CGPoint(x: center.x, y: center.y + innerGap))
        path.addLine(to: CGPoint(x: center.x, y: size - edgeInset))
        return path
    }

    private func dotPath() -> CGPath {
        let dotSize = max(4, size * 0.18)
        let rect = CGRect(
            x: primaryLayer.bounds.midX - dotSize / 2,
            y: primaryLayer.bounds.midY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )
        return CGPath(ellipseIn: rect, transform: nil)
    }

    private func removeAnimations() {
        primaryLayer.removeAllAnimations()
        backdropLayer.removeAllAnimations()
        dotLayer.removeAllAnimations()
    }

    private static func color(fromHex value: String) -> NSColor? {
        guard value.count == 7, value.first == "#", let raw = UInt64(value.dropFirst(), radix: 16) else { return nil }
        return NSColor(
            calibratedRed: CGFloat((raw >> 16) & 0xff) / 255,
            green: CGFloat((raw >> 8) & 0xff) / 255,
            blue: CGFloat(raw & 0xff) / 255,
            alpha: 1
        )
    }
}
