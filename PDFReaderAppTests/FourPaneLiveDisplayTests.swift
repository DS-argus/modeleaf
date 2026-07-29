import AppKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Four pane live display")
@MainActor
struct FourPaneLiveDisplayTests {
    @Test("growing both outer-band orientations to 2x2 through the display cycle keeps every inner divider at half")
    func fourPaneGrowthKeepsDividerHalves() throws {
        for (outerOrientation, actions) in [
            (PaneOrientation.sideBySide, [ActionID.paneSplitRight, .paneSplitDown, .paneFocusLeft, .paneSplitDown]),
            (.stacked, [.paneSplitDown, .paneSplitRight, .paneFocusUp, .paneSplitRight]),
        ] {
            try withLiveFixture { url, controller, window, pump in
                #expect(controller.openDocument(at: url))
                pump()
                for action in actions {
                    controller.dispatch(action)
                    pump()
                }

                let root = controller.mainWindowController.rootView
                let outer = try container("paneContainer", in: root)
                #expect(outer.isVertical == (outerOrientation == .sideBySide))
                let outerAvailable = (outer.isVertical ? outer.bounds.width : outer.bounds.height) - outer.dividerThickness
                #expect(abs(outer.currentDividerPosition - outerAvailable / 2) < 1)
                for identifier in ["paneContainer.leadingBand", "paneContainer.trailingBand"] {
                    let inner = try container(identifier, in: root)
                    #expect(inner.isVertical == (outerOrientation == .stacked))
                    let available = (inner.isVertical ? inner.bounds.width : inner.bounds.height) - inner.dividerThickness
                    #expect(abs(inner.currentDividerPosition - available / 2) < 1, "\(identifier) must sit at half, not the minimum-thickness clamp")
                    #expect(inner.subviews.allSatisfy {
                        (inner.isVertical ? $0.frame.width : $0.frame.height) >= WindowVisualMetrics.minimumPaneThickness
                    })
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
    }

    private func withLiveFixture(_ body: (URL, ApplicationController, NSWindow, () -> Void) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try PDFFixtureFactory.makePerformancePDF(.F, in: directory)
        let controller = ApplicationController(
            configService: ConfigService(source: ConfigFileSource(url: directory.appendingPathComponent("missing.toml"))),
            sessionStore: ReaderSessionStore(),
            themeStore: ThemeSelectionStore(fileURL: directory.appendingPathComponent("theme-state.json")),
            recentFilesStore: RecentFilesStore(fileURL: directory.appendingPathComponent("recent-state.json")),
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
        func pump() {
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        try body(url, controller, window, pump)
    }

    private func container(_ identifier: String, in root: NSView) throws -> PaneContainerView {
        func walk(_ view: NSView) -> PaneContainerView? {
            if let container = view as? PaneContainerView, container.accessibilityIdentifier() == identifier { return container }
            for subview in view.subviews {
                if let found = walk(subview) { return found }
            }
            return nil
        }
        return try #require(walk(root), "missing container \(identifier)")
    }
}
