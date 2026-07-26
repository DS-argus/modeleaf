import AppKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

/// Live-display regression for the user-reported 2x2 distortion: growing
/// 3-pane (1+2) to 2x2 through dispatched actions with real PDFs and a
/// displayed window pinned the previously split column's divider to the
/// minimum-thickness clamp (160) because the outer re-install redistributed
/// columns through zero-height transients and nothing re-asserted the inner
/// positions afterwards.
@Suite("Four pane live display")
@MainActor
struct FourPaneLiveDisplayTests {
    @Test("growing to 2x2 through the display cycle keeps every divider at half")
    func fourPaneGrowthKeepsDividerHalves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try PDFFixtureFactory.makePerformancePDF(.F, in: dir)
        let controller = ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))),
            sessionStore: ReaderSessionStore(),
            terminationHandler: {}
        )
        defer {
            while controller.coordinator.closeActiveTab() {}
            controller.mainWindowController.close()
        }
        _ = controller.mainWindowController
        let window = try #require(controller.mainWindowController.window)
        window.setContentSize(NSSize(width: 900, height: 640))
        window.orderFrontRegardless()
        func pump() { window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

        #expect(controller.openDocument(at: url)); pump()
        controller.dispatch(.paneSplitRight); pump()
        controller.dispatch(.paneSplitDown); pump()   // splits the active trailing column first
        controller.dispatch(.paneFocusLeft); pump()
        controller.dispatch(.paneSplitDown); pump()   // leading column -> 2x2

        let root = controller.mainWindowController.rootView
        func container(_ id: String) throws -> PaneContainerView {
            func walk(_ view: NSView) -> PaneContainerView? {
                if let c = view as? PaneContainerView, c.accessibilityIdentifier() == id { return c }
                for sub in view.subviews { if let found = walk(sub) { return found } }
                return nil
            }
            return try #require(walk(root), "missing container \(id)")
        }
        let outer = try container("paneContainer")
        let outerAvailable = outer.bounds.width - outer.dividerThickness
        #expect(abs(outer.currentDividerPosition - outerAvailable / 2) < 1)
        for id in ["paneContainer.leadingBand", "paneContainer.trailingBand"] {
            let stack = try container(id)
            let available = stack.bounds.height - stack.dividerThickness
            #expect(abs(stack.currentDividerPosition - available / 2) < 1, "\(id) must sit at half, not the minimum-thickness clamp")
            #expect(stack.subviews.allSatisfy { $0.frame.height >= WindowVisualMetrics.minimumPaneThickness })
        }
    }

    @Test("growing stacked outer bands to 2x2 through the display cycle keeps every divider at half")
    func stackedOuterFourPaneGrowthKeepsDividerHalves() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("live4-stacked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try PDFFixtureFactory.makePerformancePDF(.F, in: dir)
        let controller = ApplicationController(configService: ConfigService(source: ConfigFileSource(url: dir.appendingPathComponent("missing.toml"))), sessionStore: ReaderSessionStore(), terminationHandler: {})
        defer { while controller.coordinator.closeActiveTab() {}; controller.mainWindowController.close() }
        _ = controller.mainWindowController
        let window = try #require(controller.mainWindowController.window)
        window.setContentSize(NSSize(width: 900, height: 640))
        window.orderFrontRegardless()
        func pump() { window.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

            #expect(controller.openDocument(at: url)); pump()
            controller.dispatch(.paneSplitDown); pump()
            controller.dispatch(.paneSplitRight); pump()
            controller.dispatch(.paneFocusUp); pump()
            controller.dispatch(.paneSplitRight); pump()

        let root = controller.mainWindowController.rootView
        func container(_ id: String) throws -> PaneContainerView {
            func walk(_ view: NSView) -> PaneContainerView? {
                if let c = view as? PaneContainerView, c.accessibilityIdentifier() == id { return c }
                for sub in view.subviews { if let found = walk(sub) { return found } }
                return nil
            }
            return try #require(walk(root), "missing container \(id)")
        }
        let outer = try container("paneContainer")
        #expect(!outer.isVertical)
        #expect(abs(outer.currentDividerPosition - (outer.bounds.height - outer.dividerThickness) / 2) < 1)
        for id in ["paneContainer.leadingBand", "paneContainer.trailingBand"] {
            let pair = try container(id)
            #expect(pair.isVertical)
            #expect(abs(pair.currentDividerPosition - (pair.bounds.width - pair.dividerThickness) / 2) < 1)
            #expect(pair.subviews.allSatisfy { $0.frame.width >= WindowVisualMetrics.minimumPaneThickness })
        }
        for paneID in controller.coordinator.snapshot.layout.paneIDs {
            let pane = try #require(root.paneViewForTesting(paneID))
            #expect(pane.window === window)
            #expect(!pane.isHidden)
            let surface = try #require(controller.coordinator.snapshot.paneContentViews[paneID])
            #expect(surface.window === window)
            #expect(!surface.bounds.isEmpty)
        }
    }
}
