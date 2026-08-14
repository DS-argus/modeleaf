import AppKit
import PDFReaderCore

@MainActor
final class PaneView: NSView {
    let id: PaneID
    let tabBar = TabBarView()
    let contentHost = NSView()
    private weak var presentedContentView: NSView?
    private var tabBarHeightConstraint: NSLayoutConstraint!

    var onActivate: (() -> Void)?
    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onNewTab: (() -> Void)?
    var orderedKeyViews: [NSView] { tabBar.orderedKeyViews }

    init(id: PaneID, trafficLightInset: CGFloat) {
        self.id = id
        super.init(frame: .zero)
        setAccessibilityIdentifier("pane.\(id.rawValue.uuidString.lowercased())")
        setAccessibilityRole(.group)
        tabBar.accessibilityScope = "pane.\(id.rawValue.uuidString.lowercased())"
        tabBar.trafficLightInset = trafficLightInset
        tabBar.onSelect = { [weak self] tabID in
            self?.activateThen { self?.onSelect?(tabID) }
        }
        tabBar.onClose = { [weak self] tabID in
            self?.activateThen { self?.onClose?(tabID) }
        }
        tabBar.onNewTab = { [weak self] in
            self?.activateThen { self?.onNewTab?() }
        }
        for view in [tabBar, contentHost] {
            view.prepareForAutoLayout()
            addSubview(view)
        }
        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.tabBarHeight)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBarHeightConstraint,
            contentHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func apply(theme: AppKitTheme) {
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = theme[.background].cgColor
        tabBar.apply(theme: theme)
    }

    func setActive(_ active: Bool) {
        setAccessibilityValue(active ? "active" : "inactive")
        tabBar.setPaneActive(active)
    }

    func setPositionLabel(_ label: String) {
        setAccessibilityLabel("\(label) pane")
        tabBar.setAccessibilityLabel("\(label) pane document tabs")
    }

    func setTrafficLightInset(_ inset: CGFloat) {
        tabBar.trafficLightInset = inset
    }

    func activateForPointerEvent() {
        onActivate?()
    }

    func render(snapshot: ReaderSessionStoreSnapshot, contentView: NSView?) {
        tabBar.render(snapshot)
        tabBarHeightConstraint.constant = snapshot.isEmpty ? 0 : WindowVisualMetrics.tabBarHeight
        tabBar.isHidden = snapshot.isEmpty
        setPresentedContentView(contentView)
    }

    func retire() {
        presentedContentView?.removeFromSuperview()
        presentedContentView = nil
        onActivate = nil
        onSelect = nil
        onClose = nil
        onNewTab = nil
        for view in subviews { view.removeFromSuperview() }
        removeFromSuperview()
    }

    private func activateThen(_ operation: () -> Void) {
        onActivate?()
        operation()
    }

    private func setPresentedContentView(_ view: NSView?) {
        if presentedContentView !== view { presentedContentView?.removeFromSuperview() }
        presentedContentView = view
        attachContentView(view, to: contentHost)
    }
}

@MainActor
func attachContentView(_ view: NSView?, to host: NSView) {
    guard let view, view.superview !== host else { return }
    view.removeFromSuperview()
    view.prepareForAutoLayout()
    host.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: host.topAnchor),
        view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
}
