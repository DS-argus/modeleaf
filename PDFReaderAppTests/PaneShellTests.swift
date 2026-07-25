import AppKit
import PDFReaderTestSupport
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
            // Tab bars carry no perimeter border in any state (user review
            // 3-6); the single active indicator is the accessibility value
            // plus the active pane's hairline canvas focus ring.
            #expect(leading.tabBar.layer?.borderWidth == 0)
            #expect(trailing.tabBar.layer?.borderWidth == 0)
        }
        #expect(controller.window?.title == "Duplicate.pdf — Modeleaf")
        #expect(controller.rootView.statusBar.presentation.page == "7 / 10")

        #expect(fixture.coordinator.activatePane(fixture.leading))
        #expect(controller.window?.title == "Origin.pdf — Modeleaf")
        #expect(controller.rootView.statusBar.presentation.page == "2 / 10")
        #expect(controller.window?.firstResponder === fixture.origin.focusView)
    }
    @Test("split orientation exposes pane and tab-bar accessibility labels")
    func splitOrientationAccessibilityLabels() throws {
        for (orientation, leadingLabel, trailingLabel) in [
            (PaneOrientation.sideBySide, "Left", "Right"),
            (.stacked, "Top", "Bottom"),
        ] {
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

            let leading = try #require(controller.rootView.paneViewForTesting(leadingID))
            let trailing = try #require(controller.rootView.paneViewForTesting(trailingID))
            #expect(leading.accessibilityLabel() == "\(leadingLabel) pane")
            #expect(trailing.accessibilityLabel() == "\(trailingLabel) pane")
            #expect(leading.tabBar.accessibilityLabel() == "\(leadingLabel) pane document tabs")
            #expect(trailing.tabBar.accessibilityLabel() == "\(trailingLabel) pane document tabs")
            #expect([leading, trailing].filter { $0.accessibilityValue() as? String == "active" }.count == 1)
        }
    }
    @Test("stacked single-column layouts use pane chrome and stacked key-loop controls")
    func stackedSingleColumnChromeAndKeyLoop() throws {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        let duplicate = StubReaderSession(id: TabID(), title: "Duplicate.pdf")
        coordinator.configureDuplication { _ in duplicate }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let bottom = try #require(coordinator.split(direction: .stacked))
        let top = try #require(coordinator.snapshot.panes.keys.first { $0 != bottom })
        let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(configuration: BuiltInDefaults.config.theme), actionHandler: { _ in })
        defer { controller.close() }

        #expect(coordinator.snapshot.layout == .single(.two(top: top, bottom: bottom)))
        #expect(controller.rootView.tabBar.isHidden)
        #expect(controller.rootView.paneViewForTesting(bottom)?.tabBar.isHidden == false)
        #expect(duplicate.focusView.nextKeyView === controller.rootView.paneViewForTesting(bottom)?.orderedKeyViews.first)
        #expect(coordinator.focus(.up))
        #expect(coordinator.activePaneID == top)
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
        #expect(fixture.coordinator.snapshot.layout == .single(.one(fixture.leading)))
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
        #expect(fixture.coordinator.snapshot.layout == .single(.one(fixture.leading)))
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

    @Test("active prompt remains focused through global unsplit staging then dismisses on settle")
    func activePromptDismissesAfterGlobalUnsplitSettlement() throws {
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        controller.showWindow(nil)
        controller.presentPrompt(PromptPresentation(kind: .search, text: "needle", validationMessage: nil))
        let promptResponder = controller.rootView.promptOverlay.textField.currentEditor()
        #expect(controller.window?.firstResponder === promptResponder)
        #expect(fixture.coordinator.unsplit())
        #expect(controller.rootView.promptOverlay.isHidden)
        #expect(controller.window?.firstResponder === fixture.duplicate.focusView)
        #expect(fixture.coordinator.snapshot.layout == .single(.one(fixture.trailing)))
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
        #expect(coordinator.snapshot.layout == .single(.one(trailing)))
        let newTrailing = try #require(coordinator.split(direction: .sideBySide))
        let leading = try #require(coordinator.snapshot.panes.keys.first { $0 != newTrailing })
        let leadingPane = try #require(controller.rootView.paneViewForTesting(leading))
        let trailingPane = try #require(controller.rootView.paneViewForTesting(newTrailing))
        #expect(leading == trailing)
        #expect(leadingPane.tabBar.trafficLightInset == WindowVisualMetrics.trafficLightInset)
        #expect(trailingPane.tabBar.trafficLightInset == 0)
    }

    @Test("committed unsplit releases the retired pane view and resplit builds a fresh labeled pane")
    func committedUnsplitPrunesRetiredPaneViews() throws {
        let coordinator = PaneCoordinator()
        let firstDuplicate = StubReaderSession(id: TabID(), title: "First duplicate.pdf")
        let secondDuplicate = StubReaderSession(id: TabID(), title: "Second duplicate.pdf")
        var duplicates = [firstDuplicate, secondDuplicate]
        coordinator.configureDuplication { _ in duplicates.removeFirst() }
        let trailing = try splitWithFreshOrigin(coordinator)
        let leading = try #require(coordinator.snapshot.panes.keys.first { $0 != trailing })
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }

        let retiredPane = try #require(controller.rootView.paneViewForTesting(leading))

        #expect(coordinator.unsplit())
        controller.rootView.layoutSubtreeIfNeeded()
        // Durable pruning contract: the cache entry is gone, the retired pane
        // is fully detached from the window hierarchy, and its callbacks are
        // released. NSView deallocation timing itself is AppKit-owned and
        // nondeterministic (tracking areas, event caches), so object identity
        // and detachment — not weak-nil — are the asserted guarantees.
        #expect(controller.rootView.paneViewForTesting(leading) == nil)
        #expect(retiredPane.superview == nil)
        #expect(retiredPane.window == nil)
        #expect(retiredPane.onActivate == nil && retiredPane.onSelect == nil)

        let newTrailing = try #require(coordinator.split(direction: .sideBySide))
        let resplitLeading = try #require(coordinator.snapshot.panes.keys.first { $0 != newTrailing })
        let leadingPane = try #require(controller.rootView.paneViewForTesting(resplitLeading))
        let trailingPane = try #require(controller.rootView.paneViewForTesting(newTrailing))
        #expect(newTrailing != leading)
        #expect(leadingPane !== retiredPane)
        #expect(trailingPane !== retiredPane)
        #expect(leadingPane.accessibilityLabel() == "Left pane")
        #expect(leadingPane.tabBar.trafficLightInset == WindowVisualMetrics.trafficLightInset)
        #expect(trailingPane.accessibilityLabel() == "Right pane")
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
        let dispatcher = ActionDispatcher(
            coordinator: coordinator,
            navigation: BuiltInDefaults.config.navigation
        )
        let controller = MainWindowController(
            coordinator: coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { dispatcher.dispatch($0) }
        )
        defer { controller.close() }
        let readerWindow = try #require(controller.window as? ReaderWindow)
        readerWindow.setContentSize(WindowVisualMetrics.initialSize)
        // A window device is required for AppKit to deliver mouse events through
        // sendEvent; orderFrontRegardless attaches one without app activation.
        readerWindow.orderFrontRegardless()
        readerWindow.makeKey()
        readerWindow.layoutIfNeeded()
        controller.rootView.frame = NSRect(origin: .zero, size: WindowVisualMetrics.initialSize)
        controller.rootView.needsLayout = true
        controller.rootView.layoutSubtreeIfNeeded()
        let container = try #require(firstDescendant(of: controller.rootView, as: PaneContainerView.self))
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        container.setPosition(container.bounds.width / 2, ofDividerAt: 0)
        container.adjustSubviews()
        let pane = try #require(controller.rootView.paneViewForTesting(trailingID))
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()

        secondTrailingTab.canvas.onMouseDown = {
            secondTrailingTab.canvas.activeWhenHandled = coordinator.activePaneID == trailingID
        }
        sendClick(to: secondTrailingTab.canvas, in: readerWindow)
        #expect(secondTrailingTab.canvas.activeWhenHandled)
        #expect(coordinator.activePaneID == trailingID)

        #expect(coordinator.activatePane(leadingID))
        let originalSelect = pane.onSelect
        var activeWhenTabHandled = false
        pane.onSelect = { tabID in
            activeWhenTabHandled = coordinator.activePaneID == trailingID
            originalSelect?(tabID)
        }
        pane.tabBar.needsLayout = true
        pane.tabBar.layoutSubtreeIfNeeded()
        readerWindow.layoutIfNeeded()
        let tab = try #require(firstDescendant(of: controller.rootView, identifier: "tab.\(trailing.id.rawValue.uuidString.lowercased())"))
        // Real event delivery: the production window handler must activate the
        // pane for a click anywhere in its tab bar. The click lands on the tab
        // bar background (not a button) because headless NSButton tracking
        // blocks in its mouse-tracking loop; the button selection chain itself
        // is exercised through AppKit's action path below.
        let barPoint = NSPoint(x: pane.tabBar.bounds.maxX - 40, y: pane.tabBar.bounds.midY)
        sendMouseDown(to: pane.tabBar, at: barPoint, in: readerWindow)
        #expect(coordinator.activePaneID == trailingID)

        #expect(coordinator.activatePane(leadingID))
        let tabButton = try #require(tab as? NSButton)
        tabButton.performClick(nil)
        #expect(activeWhenTabHandled)
        #expect(coordinator.activePaneID == trailingID)
        #expect(coordinator.store(for: trailingID)?.snapshot.activeID == trailing.id)
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

    @Test("first-mouse click-through is scoped to tab controls and the PDF canvas only")
    func firstMouseScope() throws {
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        let pane = try #require(controller.rootView.paneViewForTesting(fixture.trailing))

        let tabSelect = try #require(firstDescendant(
            of: pane,
            identifier: "tab.\(fixture.duplicate.id.rawValue.uuidString.lowercased())"
        ) as? NSButton)
        let tabClose = try #require(firstDescendant(
            of: pane,
            identifier: "tab.close.\(fixture.duplicate.id.rawValue.uuidString.lowercased())"
        ) as? NSButton)
        #expect(tabSelect.acceptsFirstMouse(for: nil))
        #expect(tabClose.acceptsFirstMouse(for: nil))
        #expect(pane.tabBar.newTabButton.acceptsFirstMouse(for: nil))
        #expect(ReaderPDFView(frame: .zero).acceptsFirstMouse(for: nil))

        #expect(!controller.rootView.promptOverlay.commitButton.acceptsFirstMouse(for: nil))
        #expect(!controller.rootView.promptOverlay.cancelButton.acceptsFirstMouse(for: nil))
        #expect(!controller.rootView.emptyState.openButton.acceptsFirstMouse(for: nil))
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

    private func sendClick(to view: NSView, at point: NSPoint? = nil, in window: ReaderWindow) {
        let point = point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let location = view.convert(point, to: nil)
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

    private func sendMouseDown(to view: NSView, at point: NSPoint, in window: ReaderWindow) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
        window.sendEvent(event)
    }

    @Test("split mode collapses the window tab bar so pane tab bars reach the window top")
    func splitCollapsesWindowTabBar() throws {
        // User review 2-2: the leading pane's tab bar sat below the traffic
        // lights because the hidden window-level tab bar kept its 34pt height.
        let fixture = splitFixture()
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        let root = controller.rootView
        root.frame = NSRect(origin: .zero, size: WindowVisualMetrics.initialSize)
        root.layoutSubtreeIfNeeded()

        #expect(root.tabBar.isHidden)
        #expect(root.tabBar.frame.height == 0)
        let leadingPane = try #require(root.paneViewForTesting(fixture.leading))
        // Top-aligned with the window: the pane's top edge equals the root's
        // top edge (AppKit bottom-left origin => maxY comparison).
        #expect(abs(leadingPane.convert(NSPoint(x: 0, y: leadingPane.bounds.maxY), to: root).y - root.bounds.maxY) < 0.5)

        // Returning to a single pane restores the window tab bar height.
        #expect(fixture.coordinator.unsplit())
        root.layoutSubtreeIfNeeded()
        #expect(!root.tabBar.isHidden)
        #expect(root.tabBar.frame.height == WindowVisualMetrics.tabBarHeight)
    }

    @Test("exactly one hairline canvas ring survives split and pane switches")
    func canvasRingFollowsActivePane() throws {
        // User review 3-5: right after a split both canvases kept a focus
        // ring because PDFView moves first responder to an internal view and
        // the origin ring went stale.
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 2)
            let service = PDFOpenService()
            let origin = try service.open(url: url)
            let coordinator = PaneCoordinator()
            coordinator.configureDuplication { snapshot in try? service.open(url: snapshot.sourceURL) }
            #expect(coordinator.insert(origin, into: .createIfEmpty))
            let controller = MainWindowController(
                coordinator: coordinator,
                theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
                actionHandler: { _ in }
            )
            defer {
                while coordinator.closeActiveTab() {}
                controller.close()
            }
            let trailingID = try #require(coordinator.split(direction: .sideBySide))
            let leadingID = try #require(coordinator.snapshot.panes.keys.first { $0 != trailingID })
            controller.rootView.layoutSubtreeIfNeeded()

            @MainActor func ringWidths() throws -> [PaneID: CGFloat] {
                let snapshot = coordinator.snapshot
                var widths: [PaneID: CGFloat] = [:]
                for (id, view) in snapshot.paneFocusViews {
                    let canvas = try #require(view as? ReaderPDFView)
                    canvas.refreshFocusAppearance()
                    widths[id] = canvas.layer?.borderWidth ?? -1
                }
                return widths
            }

            var widths = try ringWidths()
            #expect(widths[trailingID] == WindowVisualMetrics.canvasFocusRingWidth)
            #expect(widths[leadingID] == 0)

            #expect(coordinator.activatePane(leadingID))
            widths = try ringWidths()
            #expect(widths[leadingID] == WindowVisualMetrics.canvasFocusRingWidth)
            #expect(widths[trailingID] == 0)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-pane-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
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
    private func weakPane(in rootView: ReaderRootView, with id: PaneID) -> WeakPaneReference {
        WeakPaneReference(rootView.paneViewForTesting(id))
    }
    private func splitWithFreshOrigin(_ coordinator: PaneCoordinator) throws -> PaneID {
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        return try #require(coordinator.split(direction: .sideBySide))
    }

    @Test("asymmetric three-pane rendering nests only the stacked column")
    func asymmetricNestedPaneRendering() throws {
        let coordinator = PaneCoordinator()
        var duplicates = [
            StubReaderSession(id: TabID(), title: "Right top.pdf"),
            StubReaderSession(id: TabID(), title: "Right bottom.pdf"),
        ]
        coordinator.configureDuplication { _ in duplicates.removeFirst() }
        #expect(coordinator.insert(StubReaderSession(id: TabID(), title: "Left.pdf"), into: .createIfEmpty))
        #expect(coordinator.split(direction: .sideBySide) != nil)
        #expect(coordinator.split(direction: .stacked) != nil)
        let controller = MainWindowController(coordinator: coordinator, theme: AppKitTheme(configuration: BuiltInDefaults.config.theme), actionHandler: { _ in })
        defer { controller.close() }

        let layout = coordinator.snapshot.layout
        guard case let .split(leading: .one(left), trailing: .two(top: rightTop, bottom: rightBottom)) = layout else {
            Issue.record("Expected one-plus-two split layout")
            return
        }
        let outer = try #require(firstDescendant(of: controller.rootView, as: PaneContainerView.self))
        #expect(outer.isVertical)
        #expect(outer.subviews.count == 2)
        #expect(controller.rootView.paneViewForTesting(left)?.tabBar.trafficLightInset == WindowVisualMetrics.trafficLightInset)
        #expect(controller.rootView.paneViewForTesting(rightTop)?.accessibilityLabel() == "Right Top pane")
        #expect(controller.rootView.paneViewForTesting(rightBottom)?.accessibilityLabel() == "Right Bottom pane")
        #expect(controller.rootView.paneViewForTesting(rightTop)?.tabBar.trafficLightInset == 0)
        #expect(controller.rootView.paneViewForTesting(rightBottom)?.tabBar.trafficLightInset == 0)
    }
}

private final class WeakPaneReference {
    weak var value: PaneView?

    init(_ value: PaneView?) {
        self.value = value
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }
}
