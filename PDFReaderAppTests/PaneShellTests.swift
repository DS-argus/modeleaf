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
