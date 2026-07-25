import AppKit
import PDFReaderCore

@MainActor
final class PaneView: NSView {
    let id: PaneID
    let tabBar = TabBarView()
    private let contentHost = NSView()
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

    func activateForPointerEvent() {
        onActivate?()
    }

    func render(snapshot: ReaderSessionStoreSnapshot, contentView: NSView?) {
        tabBar.render(snapshot)
        tabBarHeightConstraint.constant = snapshot.isEmpty ? 0 : WindowVisualMetrics.tabBarHeight
        tabBar.isHidden = snapshot.isEmpty
        setPresentedContentView(contentView)
    }

    private func activateThen(_ operation: () -> Void) {
        onActivate?()
        operation()
    }

    private func setPresentedContentView(_ view: NSView?) {
        guard presentedContentView !== view else { return }
        presentedContentView?.removeFromSuperview()
        presentedContentView = view
        guard let view else { return }
        view.prepareForAutoLayout()
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
    }
}
