import AppKit
import PDFReaderCore

@MainActor
final class ReaderRootView: NSView {
    let tabBar = TabBarView()
    let emptyState = EmptyStateView()
    let statusBar = StatusBarView()
    let promptOverlay = PromptOverlayView()
    private let contentHost = NSView()
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private weak var presentedContentView: NSView?
    private var currentStatus = StatusBarPresentation.empty
    private var readerInputContext: InputContext?
    private var renderedSessionSnapshot: ReaderSessionStoreSnapshot?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("readerRoot")

        for view in [tabBar, contentHost, statusBar, promptOverlay] {
            view.prepareForAutoLayout()
            addSubview(view)
        }
        emptyState.prepareForAutoLayout()
        contentHost.addSubview(emptyState)

        tabBarHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBarHeightConstraint,

            contentHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            emptyState.topAnchor.constraint(equalTo: contentHost.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),

            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.statusBarHeight),

            promptOverlay.centerXAnchor.constraint(equalTo: contentHost.centerXAnchor),
            promptOverlay.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -16),
            promptOverlay.heightAnchor.constraint(equalToConstant: WindowVisualMetrics.promptHeight),
            promptOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: WindowVisualMetrics.promptMaximumWidth),
            promptOverlay.widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            promptOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: contentHost.leadingAnchor, constant: 40),
            promptOverlay.trailingAnchor.constraint(lessThanOrEqualTo: contentHost.trailingAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(theme: AppKitTheme) {
        layer?.backgroundColor = theme[.background].cgColor
        contentHost.wantsLayer = true
        contentHost.layer?.backgroundColor = theme[.background].cgColor
        tabBar.apply(theme: theme)
        emptyState.apply(theme: theme)
        statusBar.apply(theme: theme)
        promptOverlay.apply(theme: theme)
    }

    func render(
        snapshot: ReaderSessionStoreSnapshot,
        activeContentView: NSView?,
        sessionStatus: ReaderStatusSnapshot?
    ) {
        let hasTabs = !snapshot.tabs.isEmpty
        if renderedSessionSnapshot != snapshot {
            tabBar.render(snapshot)
            tabBarHeightConstraint.constant = hasTabs ? WindowVisualMetrics.tabBarHeight : 0
            tabBar.isHidden = !hasTabs
            emptyState.isHidden = hasTabs
            renderedSessionSnapshot = snapshot
        }
        setPresentedContentView(activeContentView)

        if let sessionStatus {
            currentStatus.context = readerInputContext.map(Self.statusLabel(for:)) ?? sessionStatus.context
            currentStatus.page = sessionStatus.page
            currentStatus.zoom = sessionStatus.zoom
            currentStatus.detail = sessionStatus.detail
            currentStatus.expandedDetail = nil
            currentStatus.tone = .normal
        } else if currentStatus.tone != .error {
            currentStatus = .empty
        }
        statusBar.render(currentStatus)
    }

    func setInputContext(_ context: InputContext) {
        readerInputContext = context
        currentStatus.context = Self.statusLabel(for: context)
        statusBar.render(currentStatus)
    }

    func showDiagnostic(_ message: String, expandedDetail: String? = nil, isError: Bool = true) {
        currentStatus.detail = message
        currentStatus.expandedDetail = expandedDetail
        currentStatus.tone = isError ? .error : .normal
        statusBar.render(currentStatus)
    }

    func clearDiagnostic() {
        currentStatus.detail = ReaderStatusSnapshot.empty.detail
        currentStatus.expandedDetail = nil
        currentStatus.tone = .normal
        statusBar.render(currentStatus)
    }

    func setPendingPrefix(_ prefix: String) {
        currentStatus.pendingPrefix = prefix
        statusBar.render(currentStatus)
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

    private static func statusLabel(for context: InputContext) -> String {
        switch context {
        case .navigation: "NORMAL"
        case .pagePrompt: "PAGE"
        case .searchPrompt, .searchResults: "SEARCH"
        }
    }
}
