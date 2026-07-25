import AppKit
import Testing
@testable import PDFReaderApp
import PDFReaderCore

@Suite("Pane focus, routing, and shared chrome")
@MainActor
struct PaneShellTests {
    @Test("pointer activation precedes canvas and tab-bar operations")
    func pointerActivationOrdering() {
        let pane = PaneView(id: PaneID(), trafficLightInset: 0)
        var events: [String] = []
        pane.onActivate = { events.append("activate") }
        pane.onNewTab = { events.append("new-tab") }

        pane.activateForPointerEvent()
        events.append("canvas")
        #expect(events == ["activate", "canvas"])

        events.removeAll()
        pane.tabBar.onNewTab?()
        #expect(events == ["activate", "new-tab"])

        events.removeAll()
        let tabID = TabID()
        pane.onSelect = { _ in events.append("select") }
        pane.onClose = { _ in events.append("close") }
        pane.tabBar.onSelect?(tabID)
        #expect(events == ["activate", "select"])
        events.removeAll()
        pane.tabBar.onClose?(tabID)
        #expect(events == ["activate", "close"])
    }

    @Test("splitting immediately focuses the newly active pane")
    func splitFocusesNewPane() throws {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        let duplicate = StubReaderSession(id: TabID(), title: "Duplicate.pdf")
        coordinator.configureDuplication { _ in duplicate }
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let newPane = try #require(coordinator.split(direction: .sideBySide))
        #expect(coordinator.activePaneID == newPane)
        #expect(controller.window?.firstResponder === duplicate.focusView)
    }

    @Test("directional focus follows split geometry, moves the responder, and no-ops at boundaries")
    func directionalFocusMovesResponder() throws {
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        #expect(fixture.coordinator.activePaneID == fixture.trailing)
        #expect(controller.window?.firstResponder === fixture.duplicate.focusView)
        #expect(!fixture.coordinator.focus(.up))
        #expect(fixture.coordinator.activePaneID == fixture.trailing)
        #expect(fixture.coordinator.focus(.left))
        #expect(fixture.coordinator.activePaneID == fixture.leading)
        #expect(controller.window?.firstResponder === fixture.origin.focusView)
        #expect(!fixture.coordinator.focus(.left))
        #expect(fixture.coordinator.activePaneID == fixture.leading)
    }

    @Test("dispatcher tab actions remain isolated to the active pane")
    func activePaneActionIsolation() throws {
        let fixture = splitFixture()
        let extra = StubReaderSession(id: TabID(), title: "Origin extra.pdf")
        #expect(fixture.coordinator.insert(extra, into: .existing(fixture.leading)))
        #expect(fixture.coordinator.activatePane(fixture.trailing))
        let dispatcher = ActionDispatcher(
            coordinator: fixture.coordinator,
            navigation: BuiltInDefaults.config.navigation
        )

        dispatcher.dispatch(.tabPrevious)

        #expect(fixture.coordinator.store(for: fixture.trailing)?.snapshot.activeID == fixture.duplicate.id)
        #expect(fixture.coordinator.store(for: fixture.leading)?.snapshot.activeID == extra.id)
    }

    @Test("split panes expose exactly one active indicator and synchronously update shared chrome")
    func activeIndicatorAndChromeStaySynchronized() throws {
        let fixture = splitFixture(originPage: 2, duplicatePage: 7)
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        for themeID in ThemeID.allCases {
            controller.apply(theme: AppKitTheme(configuration: ThemeConfiguration(builtIn: themeID)))
            let leading = try #require(controller.rootView.paneViewForTesting(fixture.leading))
            let trailing = try #require(controller.rootView.paneViewForTesting(fixture.trailing))
            #expect([leading, trailing].filter { $0.accessibilityValue() as? String == "active" }.count == 1)
            #expect(trailing.accessibilityValue() as? String == "active")
            #expect(leading.tabBar.layer?.borderWidth == 0)
            #expect(trailing.tabBar.layer?.borderWidth == WindowVisualMetrics.focusIndicatorWidth)
        }
        #expect(controller.window?.title == "Duplicate.pdf — Modeleaf")
        #expect(controller.rootView.statusBar.presentation.page == "7 / 10")

        #expect(fixture.coordinator.activatePane(fixture.leading))
        #expect(controller.window?.title == "Origin.pdf — Modeleaf")
        #expect(controller.rootView.statusBar.presentation.page == "2 / 10")
        #expect(controller.window?.firstResponder === fixture.origin.focusView)
    }
    @Test("collapse stages the survivor responder and clears the removed pane from the key loop")
    func collapseStagesResponderAndKeyLoop() throws {
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        let removedFocus = fixture.duplicate.focusView
        #expect(fixture.coordinator.closeActiveTab())
        #expect(controller.window?.firstResponder === fixture.origin.focusView)
        #expect(removedFocus.nextKeyView == nil)
        #expect(fixture.coordinator.snapshot.layout == .single(fixture.leading))
    }

    @Test("dismissed prompt collapse stages the survivor focus and removes the closed pane key loop")
    func dismissedPromptCollapseRestoresSurvivorFocus() throws {
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        let removedFocus = fixture.duplicate.focusView

        controller.presentPrompt(PromptPresentation(kind: .page, text: "2", validationMessage: nil))
        controller.dismissPromptAndRestoreFocus()
        #expect(controller.window?.firstResponder === fixture.duplicate.focusView)

        #expect(fixture.coordinator.closeActiveTab())
        #expect(controller.window?.firstResponder === fixture.origin.focusView)
        #expect(removedFocus.nextKeyView == nil)
        #expect(fixture.coordinator.snapshot.layout == .single(fixture.leading))
    }

    @Test("active prompt owns focus through close staging before post-commit refresh")
    func activePromptPreventsResponderMigrationDuringCloseStaging() throws {
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        controller.presentPrompt(PromptPresentation(kind: .search, text: "needle", validationMessage: nil))
        let promptResponder = controller.rootView.promptOverlay.textField.currentEditor()
        #expect(controller.window?.firstResponder === promptResponder)

        var responderStayedWithPrompt = false
        let closed = fixture.coordinator.closeActiveTab { _ in
            responderStayedWithPrompt = controller.window?.firstResponder === promptResponder
            return true
        }
        #expect(closed)
        #expect(responderStayedWithPrompt)
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.window?.firstResponder === fixture.origin.focusView)
    }


    @Test("collapse and unsplit reattach the survivor beneath the visible root host")
    func survivorContentMovesOutOfHiddenPaneContainer() throws {
        for collapseWithClose in [true, false] {
            let fixture = splitFixture()
            let controller = MainWindowController(
                coordinator: fixture.coordinator,
                theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
                actionHandler: { _ in }
            )
            defer { controller.close() }
            let container = try #require(firstDescendant(of: controller.rootView, as: PaneContainerView.self))

            if collapseWithClose {
                #expect(fixture.coordinator.closeActiveTab())
            } else {
                #expect(fixture.coordinator.unsplit())
            }

            let survivor = collapseWithClose ? fixture.origin : fixture.duplicate
            #expect(container.isHidden)
            #expect(survivor.contentView.window === controller.window)
            #expect(!isDescendant(survivor.contentView, of: container))
            #expect(isDescendant(survivor.contentView, of: controller.rootView))
        }
    }

    @Test("status and focus renders preserve a custom split divider ratio")
    func snapshotRendersPreserveCustomDividerRatio() throws {
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        let container = try #require(firstDescendant(of: controller.rootView, as: PaneContainerView.self))
        controller.rootView.layoutSubtreeIfNeeded()
        container.setPosition(280, ofDividerAt: 0)
        controller.rootView.layoutSubtreeIfNeeded()
        let initialRatio = container.subviews[0].frame.width / (container.bounds.width - container.dividerThickness)

        fixture.origin.page = 6
        fixture.origin.publishPresentationChange()
        #expect(fixture.coordinator.focus(.left))
        #expect(fixture.coordinator.focus(.right))
        controller.rootView.layoutSubtreeIfNeeded()

        let renderedRatio = container.subviews[0].frame.width / (container.bounds.width - container.dividerThickness)
        #expect(abs(renderedRatio - initialRatio) < 0.001)
    }

    @Test("resplitting a trailing survivor gives it the leading traffic-light inset")
    func resplitPromotesTrailingSurvivorToLeadingInset() throws {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        let firstDuplicate = StubReaderSession(id: TabID(), title: "First duplicate.pdf")
        let secondDuplicate = StubReaderSession(id: TabID(), title: "Second duplicate.pdf")
        var duplicates = [firstDuplicate, secondDuplicate]
        coordinator.configureDuplication { _ in duplicates.removeFirst() }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let trailing = try #require(coordinator.split(direction: .sideBySide))
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        #expect(coordinator.unsplit())
        #expect(coordinator.snapshot.layout == .single(trailing))
        let newTrailing = try #require(coordinator.split(direction: .sideBySide))
        let leading = try #require(coordinator.snapshot.panes.keys.first { $0 != newTrailing })
        let leadingPane = try #require(controller.rootView.paneViewForTesting(leading))
        let trailingPane = try #require(controller.rootView.paneViewForTesting(newTrailing))
        #expect(leading == trailing)
        #expect(leadingPane.tabBar.trafficLightInset == WindowVisualMetrics.trafficLightInset)
        #expect(trailingPane.tabBar.trafficLightInset == 0)
    }

    @Test("window mouse events activate an inactive pane before canvas and tab selection handlers")
    func realPointerActivationOrdering() throws {
        let coordinator = PaneCoordinator()
        let leading = EventRecordingSession(id: TabID(), title: "Leading.pdf")
        let trailing = EventRecordingSession(id: TabID(), title: "Trailing.pdf")
        let secondTrailingTab = EventRecordingSession(id: TabID(), title: "Trailing second.pdf")
        coordinator.configureDuplication { _ in trailing }
        #expect(coordinator.insert(leading, into: .createIfEmpty))
        let trailingID = try #require(coordinator.split(direction: .sideBySide))
        let leadingID = try #require(coordinator.snapshot.panes.keys.first { $0 != trailingID })
        #expect(coordinator.insert(secondTrailingTab, into: .existing(trailingID)))
        #expect(coordinator.activatePane(leadingID))
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        let window = try #require(controller.window)
        let readerWindow = try #require(window as? ReaderWindow)
        readerWindow.mouseDownHandler = { _ in
            _ = coordinator.activatePane(trailingID)
        }
        controller.rootView.layoutSubtreeIfNeeded()

        trailing.canvas.onMouseDown = { trailing.canvas.activeWhenHandled = coordinator.activePaneID == trailingID }
        sendClick(to: trailing.canvas, in: window)
        trailing.canvas.mouseDown(with: mouseDownEvent(at: trailing.canvas, in: window))
        #expect(trailing.canvas.activeWhenHandled)
        #expect(coordinator.activePaneID == trailingID)

        #expect(coordinator.activatePane(leadingID))
        let tab = try #require(firstDescendant(of: controller.rootView, identifier: "tab.\(secondTrailingTab.id.rawValue.uuidString.lowercased())"))
        let tabItem = try #require(tab.superview)
        sendClick(to: tabItem, at: NSPoint(x: tabItem.bounds.midX, y: 1), in: window)
        tabItem.mouseDown(with: mouseDownEvent(at: tabItem, in: window))
        #expect(coordinator.activePaneID == trailingID)
        #expect(coordinator.store(for: trailingID)?.snapshot.activeID == secondTrailingTab.id)
    }

    @Test("480 by 360 split panes preserve reachable controls at both divider limits")
    func minimumWindowSplitLayout() throws {
        for orientation in [PaneOrientation.sideBySide, .stacked] {
            let coordinator = PaneCoordinator()
            let leadingSession = StubReaderSession(id: TabID(), title: "Leading.pdf")
            let trailingSession = StubReaderSession(id: TabID(), title: "Trailing.pdf")
            coordinator.configureDuplication { _ in trailingSession }
            #expect(coordinator.insert(leadingSession, into: .createIfEmpty))
            let trailingID = try #require(coordinator.split(direction: orientation))
            let leadingID = try #require(coordinator.snapshot.panes.keys.first { $0 != trailingID })
            let controller = MainWindowController(
                coordinator: coordinator,
                theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
                actionHandler: { _ in }
            )
            defer { controller.close() }
            let window = try #require(controller.window)
            window.setContentSize(WindowVisualMetrics.minimumSize)
            controller.rootView.layoutSubtreeIfNeeded()

            let container = try #require(firstDescendant(of: controller.rootView, as: PaneContainerView.self))
            let leading = try #require(controller.rootView.paneViewForTesting(leadingID))
            let trailing = try #require(controller.rootView.paneViewForTesting(trailingID))
            #expect(leading.tabBar.trafficLightInset == WindowVisualMetrics.trafficLightInset)
            #expect(trailing.tabBar.trafficLightInset == 0)

            let totalThickness = orientation == .sideBySide ? container.bounds.width : container.bounds.height
            let defaultLeadingThickness = orientation == .sideBySide ? leading.frame.width : leading.frame.height
            #expect(abs(defaultLeadingThickness - (totalThickness - container.dividerThickness) / 2) < 1)

            for requestedDivider in [-1_000 as CGFloat, 1_000 as CGFloat] {
                container.setPosition(requestedDivider, ofDividerAt: 0)
                controller.rootView.layoutSubtreeIfNeeded()
                let leadingThickness = orientation == .sideBySide ? leading.frame.width : leading.frame.height
                let trailingThickness = orientation == .sideBySide ? trailing.frame.width : trailing.frame.height
                #expect(leadingThickness >= 160)
                #expect(trailingThickness >= 160)

                let activePane = try #require(controller.rootView.paneViewForTesting(trailingID))
                let closeID = "tab.close.\(trailingSession.id.rawValue.uuidString.lowercased())"
                let close = try #require(firstDescendant(of: activePane, identifier: closeID))
                assertReachable(close, in: controller.rootView)
                assertReachable(activePane.tabBar.newTabButton, in: controller.rootView)
                assertReachable(trailingSession.contentView, in: controller.rootView)
                assertReachable(controller.rootView.statusBar, in: controller.rootView)
                assertNoAmbiguousLayout(in: controller.rootView)
            }
        }
    }

    private func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let matched = view as? T { return matched }
        for subview in view.subviews {
            if let matched = firstDescendant(of: subview, as: type) { return matched }
        }
        return nil
    }

    private func firstDescendant(of view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for subview in view.subviews {
            if let matched = firstDescendant(of: subview, identifier: identifier) { return matched }
        }
        return nil
    }

    private func assertReachable(_ view: NSView, in root: NSView) {
        #expect(view.window != nil)
        #expect(!view.isHidden)
        #expect(!view.bounds.isEmpty)
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: root)
        let hit = root.hitTest(point)
        #expect(hit.map { isDescendant($0, of: view) } == true, "unreachable \(view.accessibilityIdentifier()) frame=\(view.frame) hit=\(String(describing: hit))")
    }

    private func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current === ancestor { return true }
            candidate = current.superview
        }
        return false
    }

    private func assertNoAmbiguousLayout(in view: NSView) {
        #expect(!view.hasAmbiguousLayout, "ambiguous \(type(of: view)) id=\(view.accessibilityIdentifier()) frame=\(view.frame)")
        guard !(view is NSScrollView) else { return }
        for subview in view.subviews { assertNoAmbiguousLayout(in: subview) }
    }


    private func sendClick(to view: NSView, at point: NSPoint? = nil, in window: NSWindow) {
        let point = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let location = view.convert(point, to: window.contentView)
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private func mouseDownEvent(at view: NSView, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: window.contentView),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
    private func splitFixture(originPage: Int = 1, duplicatePage: Int = 1) -> (
        coordinator: PaneCoordinator,
        leading: PaneID,
        trailing: PaneID,
        origin: StubReaderSession,
        duplicate: StubReaderSession
    ) {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf", page: originPage)
        let duplicate = StubReaderSession(id: TabID(), title: "Duplicate.pdf", page: duplicatePage)
        coordinator.configureDuplication { _ in duplicate }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let trailing = try! #require(coordinator.split(direction: .sideBySide))
        let leading = try! #require(coordinator.snapshot.panes.keys.first { $0 != trailing })
        return (coordinator, leading, trailing, origin, duplicate)
    }
}


@MainActor
private final class EventRecordingSession: ReaderSessionPresenting, ReaderDuplicationSnapshotProviding {
    let id: TabID
    let title: String
    let canvas = EventRecordingCanvas()
    var contentView: NSView { canvas }

    init(id: TabID, title: String) {
        self.id = id
        self.title = title
        canvas.setAccessibilityIdentifier("pdfCanvas")
    }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title)
    }


    func prepareForClose() {}
    var duplicationSnapshot: ReaderDuplicationSnapshot {
        ReaderDuplicationSnapshot(
            sourceURL: URL(fileURLWithPath: "/tmp/\(title)"),
            oneBasedPage: 1,
            viewMode: .manual,

            scaleFactor: 1
        )
    }
}

@MainActor
private final class EventRecordingCanvas: NSView {
    var onMouseDown: (() -> Void)?
    var activeWhenHandled = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}
