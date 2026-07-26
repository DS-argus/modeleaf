import AppKit
import Foundation
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Pane MVP red-team")
@MainActor
struct PaneRedTeamTests {
    @Test("adversarial pane state-machine matrix")
    func adversarialStateMachineMatrix() throws {
        var caseOutcomes: [String: Bool] = [:]
        // Every recorded condition folds into its case outcome so the durable
        // artifact can never report a case PASS while any of its expectations
        // failed. `check` both records the expectation and accumulates it.
        var casePassed = true
        func check(_ condition: Bool, _ comment: Comment? = nil) {
            #expect(condition, comment)
            casePassed = casePassed && condition
        }
        func beginCase() { casePassed = true }

        beginCase()
        for orientation in [PaneOrientation.sideBySide, .stacked] {
            let fixture = makeFixture(orientation: orientation)
            let perpendicular = orientation.perpendicular
            check(fixture.coordinator.split(direction: orientation) == nil)
            check(fixture.coordinator.split(direction: perpendicular) != nil)
            let settledLayout = fixture.coordinator.snapshot.layout
            check(fixture.coordinator.snapshot.panes.count == 3)
            for _ in 0..<20 {
                check(fixture.coordinator.split(direction: .sideBySide) == nil)
                check(fixture.coordinator.split(direction: .stacked) == nil)
            }
            check(fixture.coordinator.snapshot.layout == settledLayout)
        }
        caseOutcomes["AC-2 split ceiling both directions / rapid repeat"] = casePassed

        beginCase()
        for outerOrientation in [PaneOrientation.sideBySide, .stacked] {
            let coordinator = PaneCoordinator()
            var duplicationCalls = 0
            var completionCalls = 0
            var emissions = 0
            coordinator.configureDuplication { _ in
                duplicationCalls += 1
                return RedTeamSession(title: "Duplicate \(duplicationCalls).pdf", page: duplicationCalls, color: .systemOrange)
            }
            coordinator.configureDuplicationCompletion { _, _ in completionCalls += 1 }
            coordinator.onSnapshot = { _ in emissions += 1 }
            check(coordinator.insert(RedTeamSession(title: "Origin.pdf", page: 1, color: .systemBlue), into: .createIfEmpty))
            check(coordinator.split(direction: outerOrientation) != nil)
            let perpendicular = outerOrientation.perpendicular
            check(coordinator.split(direction: perpendicular) != nil)
            let remainingOuterPane = try! #require(coordinator.snapshot.layout.paneIDs.first { coordinator.snapshot.layout.side(of: $0) == .leading })
            check(coordinator.activatePane(remainingOuterPane))
            check(coordinator.split(direction: perpendicular) != nil)
            check(coordinator.snapshot.layout.paneIDs.count == 4)

            for paneID in coordinator.snapshot.layout.paneIDs {
                check(coordinator.activatePane(paneID))
                let settled = coordinator.snapshot
                let sideEffects = (duplicationCalls, completionCalls, emissions)
                check(coordinator.split(direction: .sideBySide) == nil)
                check(coordinator.split(direction: .stacked) == nil)
                check(coordinator.snapshot.layout == settled.layout)
                check(coordinator.snapshot.activePaneID == settled.activePaneID)
                check((duplicationCalls, completionCalls, emissions) == sideEffects)
            }
        }
        caseOutcomes["Constrained-tree max-four-pane ceiling"] = casePassed
        beginCase()
        for paneCount in [3, 4] {
            let coordinator = PaneCoordinator()
            var duplicationCalls = 0
            var emissions = 0
            coordinator.configureDuplication { _ in
                duplicationCalls += 1
                return RedTeamSession(title: "Duplicate \(duplicationCalls).pdf", page: duplicationCalls, color: .systemOrange)
            }
            coordinator.onSnapshot = { _ in emissions += 1 }
            check(coordinator.insert(RedTeamSession(title: "Origin.pdf", page: 1, color: .systemBlue), into: .createIfEmpty))
            check(coordinator.split(direction: .stacked) != nil)
            check(coordinator.split(direction: .sideBySide) != nil)
            if paneCount == 4 {
                let top = coordinator.snapshot.layout.paneIDs[0]
                check(coordinator.activatePane(top))
                check(coordinator.split(direction: .sideBySide) != nil)
            }
            let settled = coordinator.snapshot
            let counts = (duplicationCalls, emissions)
            for _ in 0..<20 {
                check(coordinator.split(direction: .sideBySide) == nil)
                check(coordinator.split(direction: .stacked) == nil)
            }
            check(coordinator.snapshot.layout == settled.layout)
            check(coordinator.snapshot.activePaneID == settled.activePaneID)
            check((duplicationCalls, emissions) == counts)
        }
        caseOutcomes["Stacked-outer three/four-pane split-ceiling spam has zero side effects"] = casePassed

        beginCase()
        let stackedLifecycle = makeFixture(orientation: .stacked)
        check(stackedLifecycle.coordinator.split(direction: .sideBySide) != nil)
        check(stackedLifecycle.coordinator.closeActiveTab())
        check(stackedLifecycle.coordinator.closeActiveTab())
        check(stackedLifecycle.coordinator.closeActiveTab())
        check(stackedLifecycle.coordinator.snapshot.layout == .empty)
        let reopened = RedTeamSession(title: "Reopened stacked.pdf", page: 9, color: .systemGreen)
        check(stackedLifecycle.coordinator.insert(reopened, into: .createIfEmpty))
        stackedLifecycle.coordinator.configureDuplication { _ in RedTeamSession(title: "Reopened stacked duplicate.pdf", page: 9, color: .systemPurple) }
        check(stackedLifecycle.coordinator.split(direction: .stacked) != nil)
        check(stackedLifecycle.coordinator.split(direction: .sideBySide) != nil)
        check(stackedLifecycle.coordinator.snapshot.layout.paneIDs.count == 3)
        caseOutcomes["Stacked-outer close-collapse-empty-reopen-resplit"] = casePassed

        beginCase()
        for _ in 0..<2 {
            let fixture = makeFixture(orientation: .sideBySide)
            check(fixture.coordinator.closeActiveTab())
            check(fixture.coordinator.snapshot.layout == .single(fixture.leading))
            check(fixture.coordinator.snapshot.panes.count == 1)
            check(fixture.coordinator.closeActiveTab())
            check(fixture.coordinator.snapshot.layout == .empty)
            check(fixture.coordinator.snapshot.panes.isEmpty)
            let reopened = RedTeamSession(title: "Reopened.pdf", page: 9, color: .systemGreen)
            check(fixture.coordinator.insert(reopened, into: .createIfEmpty))
            let replacement = RedTeamSession(title: "Reopened duplicate.pdf", page: 9, color: .systemPurple)
            fixture.coordinator.configureDuplication { _ in replacement }
            check(fixture.coordinator.split(direction: .sideBySide) != nil)
            check(fixture.coordinator.snapshot.panes.count == 2)
        }
        caseOutcomes["EF4 AC-6 close-collapse-empty-reopen-resplit twice"] = casePassed

        beginCase()
        let rollback = makeFixture(orientation: .sideBySide)
        let extra = RedTeamSession(title: "Opposite extra.pdf", page: 3, color: .brown)
        check(rollback.coordinator.insert(extra, into: .existing(rollback.leading)))
        let originalLeading = rollback.coordinator.store(for: rollback.leading)!.snapshot
        check(!rollback.coordinator.unsplit(stage: { _ in false }))
        check(rollback.coordinator.activatePane(rollback.trailing))
        check(rollback.coordinator.snapshot.panes[rollback.leading] == originalLeading)
        check(extra.prepareForCloseCount == 0)
        check(rollback.coordinator.unsplit(stage: { $0.layout == .single(rollback.trailing) }))
        check(rollback.coordinator.snapshot.layout == .single(rollback.trailing))
        check(rollback.origin.prepareForCloseCount == 1)
        check(extra.prepareForCloseCount == 1)
        caseOutcomes["AC-7 unsplit rollback then commit with multi-tab opposite pane"] = casePassed

        beginCase()
        let stale = makeFixture(orientation: .sideBySide)
        check(stale.coordinator.activatePane(stale.leading))
        let vanishedPane = stale.trailing
        check(stale.coordinator.unsplit())
        let delayed = RedTeamSession(title: "Delayed.pdf", page: 4, color: .magenta)
        check(!stale.coordinator.insert(delayed, into: .existing(vanishedPane)))
        check(delayed.prepareForCloseCount == 0)
        check(stale.coordinator.closeActiveTab())
        let fresh = RedTeamSession(title: "Fresh.pdf", page: 5, color: .cyan)
        check(stale.coordinator.insert(fresh, into: .createIfEmpty))
        check(stale.coordinator.snapshot.layout != .empty)
        caseOutcomes["AC-8 stale pane completion reject and empty createIfEmpty"] = casePassed

        beginCase()
        for orientation in [PaneOrientation.sideBySide, .stacked] {
            let fixture = makeFixture(orientation: orientation)
            for direction in [PaneFocusDirection.left, .down, .up, .right] {
                for _ in 0..<10 { _ = fixture.coordinator.focus(direction) }
            }
            fixture.coordinator.snapshot.assertCardinality()
            check(fixture.coordinator.unsplit())
            for direction in [PaneFocusDirection.left, .down, .up, .right] { check(!fixture.coordinator.focus(direction)) }
            check(fixture.coordinator.closeActiveTab())
            for direction in [PaneFocusDirection.left, .down, .up, .right] { check(!fixture.coordinator.focus(direction)) }
            check(fixture.coordinator.snapshot.layout == .empty)
            check(fixture.coordinator.snapshot.panes.isEmpty)
        }
        caseOutcomes["AC-4 boundary focus spam in both geometries and terminal layouts"] = casePassed

        beginCase()
        let isolation = makeFixture(orientation: .sideBySide)
        for step in 1...30 {
            isolation.origin.page = step
            isolation.origin.zoom = Double(step) / 10
            isolation.origin.searchQuery = "origin-\(step)"
            isolation.origin.publishPresentationChange()
            isolation.duplicate.page = 100 - step
            isolation.duplicate.zoom = Double(100 - step) / 10
            isolation.duplicate.searchQuery = "duplicate-\(step)"
            isolation.duplicate.publishPresentationChange()
            check(isolation.origin.page == step)
            check(isolation.duplicate.page == 100 - step)
            check(isolation.origin.searchQuery != isolation.duplicate.searchQuery)
        }
        caseOutcomes["AC-3 interleaved page zoom search isolation"] = casePassed

        beginCase()
        let cleanDuplicate = RedTeamSession(title: "Clean.pdf", page: 1, color: .gray)
        isolation.coordinator.configureDuplication { _ in cleanDuplicate }
        check(isolation.coordinator.unsplit())
        check(isolation.coordinator.split(direction: .sideBySide) != nil)
        check(cleanDuplicate.searchQuery.isEmpty)
        check(cleanDuplicate.selection == nil)
        caseOutcomes["EF8 duplicate search and selection exclusion"] = casePassed
        try writeArtifacts(caseOutcomes: caseOutcomes)
    }

    @Test("dispatched stacked-outer anchor renders with labels and default dividers")
    func dispatchedStackedOuterAnchor() throws {
        try withTemporaryDirectory { fixtures in
            let url = try PDFFixtureFactory.makePerformancePDF(.F, in: fixtures)
            @MainActor func makeController() throws -> ApplicationController {
                let controller = ApplicationController(
                    configService: ConfigService(source: ConfigFileSource(url: fixtures.appendingPathComponent("missing-config.toml"))),
                    sessionStore: ReaderSessionStore(),
                    terminationHandler: {}
                )
                _ = controller.mainWindowController
                let window = try #require(controller.mainWindowController.window)
                window.setContentSize(NSSize(width: 900, height: 640))
                window.orderFrontRegardless()
                #expect(controller.openDocument(at: url))
                return controller
            }
            @MainActor func container(_ identifier: String, in root: NSView) throws -> PaneContainerView {
                func walk(_ view: NSView) -> PaneContainerView? {
                    if let container = view as? PaneContainerView, container.accessibilityIdentifier() == identifier { return container }
                    for subview in view.subviews { if let found = walk(subview) { return found } }
                    return nil
                }
                return try #require(walk(root), "missing container \(identifier)")
            }

            let controller = try makeController()
            defer { while controller.coordinator.closeActiveTab() {}; controller.mainWindowController.close() }
            let top = try #require(controller.coordinator.activePaneID)
            controller.dispatch(.paneSplitDown)
            let bottom = try #require(controller.coordinator.activePaneID)
            controller.dispatch(.paneSplitRight)
            let bottomRight = try #require(controller.coordinator.activePaneID)
            #expect(controller.coordinator.snapshot.layout == .split(orientation: .stacked, leading: .one(top), trailing: .two(first: bottom, second: bottomRight)))
            let root = controller.mainWindowController.rootView
            root.needsLayout = true; root.layoutSubtreeIfNeeded()
            let topPane = try #require(root.paneViewForTesting(top))
            let bottomLeftPane = try #require(root.paneViewForTesting(bottom))
            let bottomRightPane = try #require(root.paneViewForTesting(bottomRight))
            #expect(topPane.accessibilityLabel() == "Top pane")
            #expect(bottomLeftPane.accessibilityLabel() == "Bottom Left pane")
            #expect(bottomRightPane.accessibilityLabel() == "Bottom Right pane")
            #expect(bottomRightPane.accessibilityValue() as? String == "active")
            let outer = try container("paneContainer", in: root)
            let inner = try container("paneContainer.trailingBand", in: root)
            #expect(!outer.isVertical && inner.isVertical)
            #expect(abs(outer.currentDividerPosition - (outer.bounds.height - outer.dividerThickness) / 2) < 1)
            #expect(abs(inner.currentDividerPosition - (inner.bounds.width - inner.dividerThickness) / 2) < 1)
            #expect(controller.coordinator.snapshot.paneContentViews[bottomRight]?.window === controller.mainWindowController.window)

            let topSlotController = try makeController()
            defer { while topSlotController.coordinator.closeActiveTab() {}; topSlotController.mainWindowController.close() }
            let topSlot = try #require(topSlotController.coordinator.activePaneID)
            topSlotController.dispatch(.paneSplitDown)
            let lowerSlot = try #require(topSlotController.coordinator.activePaneID)
            topSlotController.dispatch(.paneFocusUp)
            topSlotController.dispatch(.paneSplitRight)
            let topRight = try #require(topSlotController.coordinator.activePaneID)
            #expect(topSlotController.coordinator.snapshot.layout == .split(orientation: .stacked, leading: .two(first: topSlot, second: topRight), trailing: .one(lowerSlot)))
        }
    }
    @Test("prompt focus is not stolen during rejected pane mutations")
    func promptFocusOwnership() throws {
        let fixture = makeFixture(orientation: .sideBySide)
        let controller = MainWindowController(
            coordinator: fixture.coordinator,
            theme: AppKitTheme(configuration: BuiltInDefaults.config.theme),
            actionHandler: { _ in }
        )
        defer { controller.close() }
        controller.presentPrompt(PromptPresentation(kind: .search, text: "needle", validationMessage: nil))
        let responder = controller.rootView.promptOverlay.textField.currentEditor()
        #expect(controller.window?.firstResponder === responder)
        #expect(!fixture.coordinator.unsplit(stage: { _ in controller.window?.firstResponder === responder ? false : true }))
        #expect(controller.window?.firstResponder === responder)
        #expect(!fixture.coordinator.closeActiveTab(stage: { _ in controller.window?.firstResponder === responder ? false : true }))
        #expect(controller.window?.firstResponder === responder)
    }

    private func makeFixture(orientation: PaneOrientation) -> (coordinator: PaneCoordinator, leading: PaneID, trailing: PaneID, origin: RedTeamSession, duplicate: RedTeamSession) {
        let coordinator = PaneCoordinator()
        let origin = RedTeamSession(title: "Origin.pdf", page: 2, color: .systemBlue)
        let duplicate = RedTeamSession(title: "Duplicate.pdf", page: 7, color: .systemOrange)
        coordinator.configureDuplication { _ in duplicate }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let trailing = try! #require(coordinator.split(direction: orientation))
        let leading = try! #require(coordinator.snapshot.panes.keys.first { $0 != trailing })
        return (coordinator, leading, trailing, origin, duplicate)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-red-team-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func writeArtifacts(caseOutcomes: [String: Bool]) throws {
        guard let directory = ProcessInfo.processInfo.environment["PDF_READER_SNAPSHOT_DIR"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Evidence renders use the REAL application pipeline: real fixture
        // PDFs opened through PDFOpenService, split via dispatched pane
        // actions, and PDFKit-rendered page content in both panes.
        for (actions, name) in [([ActionID.paneSplitRight], "side-by-side.png"), ([.paneSplitDown], "stacked.png"), ([.paneSplitDown, .paneSplitRight], "stacked-outer-anchor.png")] {
            try withTemporaryDirectory { fixtures in
                let url = try PDFFixtureFactory.makePerformancePDF(.F, in: fixtures)
                let controller = ApplicationController(
                    configService: ConfigService(source: ConfigFileSource(url: fixtures.appendingPathComponent("missing-config.toml"))),
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
                #expect(controller.openDocument(at: url))
                (controller.coordinator.activeSession as? ReaderSession)?.fitWidth()
                for action in actions { controller.dispatch(action) }
                let layout = controller.coordinator.snapshot.layout
                let committed: Bool
                switch (actions, layout) {
                case ([.paneSplitRight], .split): committed = true
                case ([.paneSplitDown], .split(orientation: .stacked, leading: .one, trailing: .one)): committed = true
                case ([.paneSplitDown, .paneSplitRight], .split(orientation: .stacked, leading: .one, trailing: .two)): committed = true
                default: committed = false
                }
                guard committed else {
                    Issue.record("Expected a committed split for \(name), got \(layout)")
                    return
                }
                #expect((controller.coordinator.activeSession as? ReaderSession)?.goToPage(7) == true)
                (controller.coordinator.activeSession as? ReaderSession)?.fitWidth()
                let root = controller.mainWindowController.rootView
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
                // PDFKit tiles asynchronously; capture only after every pane's
                // content region contains the fixture's non-uniform page pixels.
                let contentFrames = try controller.coordinator.snapshot.layout.paneIDs.map { paneID in
                    let surface = try #require(controller.coordinator.snapshot.paneContentViews[paneID])
                    return surface.convert(surface.bounds, to: root)
                }
                var representation: NSBitmapImageRep?
                for _ in 0..<25 {
                    window.displayIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    root.needsDisplay = true
                    let candidate = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                    root.cacheDisplay(in: root.bounds, to: candidate)
                    if contentFrames.allSatisfy({ hasFixtureRasterPixels(in: $0, representation: candidate, rootBounds: root.bounds) }) {
                        representation = candidate
                        break
                    }
                }
                let settledRepresentation = try #require(representation, "Timed out waiting for non-uniform PDF pixels in every pane for \(name)")
                let png = try #require(settledRepresentation.representation(using: .png, properties: [:]))
                #expect(png.count > 50_000)
                try png.write(to: output.appendingPathComponent(name))
            }
        }
        let cases = caseOutcomes.keys.sorted().map { name in
            [
                "case": name,
                "verdict": caseOutcomes[name]! ? "passed" : "failed",
                "evidence": "PaneRedTeamTests.adversarialStateMachineMatrix",
            ]
        }
        let passed = caseOutcomes.values.allSatisfy { $0 }
        let report: [String: Any] = [
            "kind": "adversarial test-report",
            "suite": "PaneRedTeamTests",
            "verdict": passed ? "passed" : "failed",
            "cases": cases,
            "artifacts": ["side-by-side.png", "stacked.png", "stacked-outer-anchor.png"],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("adversarial-test-report.json"), options: .atomic)
    }

    /// Fixture-specific raster proof: the `.F` fixture is high-entropy random
    /// noise, so a rendered interior page region must contain MANY distinct
    /// quantized colors. A blank page shell (white page + canvas + shadow)
    /// yields only a handful of distinct quantized colors and fails. This is
    /// what makes the published PNG evidence prove "fixture pixels rendered in
    /// every pane" rather than "something varied somewhere".
    private func hasFixtureRasterPixels(in frame: NSRect, representation: NSBitmapImageRep, rootBounds: NSRect) -> Bool {
        distinctQuantizedColorCount(in: frame, representation: representation, rootBounds: rootBounds) >= 12
    }

    func distinctQuantizedColorCount(in frame: NSRect, representation: NSBitmapImageRep, rootBounds: NSRect) -> Int {
        let scaleX = CGFloat(representation.pixelsWide) / rootBounds.width
        let scaleY = CGFloat(representation.pixelsHigh) / rootBounds.height
        // Sample the interior third of the pane so chrome, page edges, and
        // shadows are excluded; only page-content pixels count.
        let sampledFrame = frame.insetBy(dx: frame.width / 3, dy: frame.height / 3)
        let minX = max(0, Int((sampledFrame.minX - rootBounds.minX) * scaleX))
        let maxX = min(representation.pixelsWide - 1, Int((sampledFrame.maxX - rootBounds.minX) * scaleX))
        let minY = max(0, Int((sampledFrame.minY - rootBounds.minY) * scaleY))
        let maxY = min(representation.pixelsHigh - 1, Int((sampledFrame.maxY - rootBounds.minY) * scaleY))
        guard minX < maxX, minY < maxY else { return 0 }
        var quantized = Set<UInt32>()
        let strideX = max(1, (maxX - minX) / 16)
        let strideY = max(1, (maxY - minY) / 16)
        for y in stride(from: minY, through: maxY, by: strideY) {
            for x in stride(from: minX, through: maxX, by: strideX) {
                guard let color = representation.colorAt(x: x, y: y) else { continue }
                let rgb = color.usingColorSpace(.deviceRGB) ?? color
                // 4-bit-per-channel quantization: tolerant of AA/color-space
                // jitter while keeping the noise fixture's diversity visible.
                let r = UInt32((rgb.redComponent * 15).rounded())
                let g = UInt32((rgb.greenComponent * 15).rounded())
                let b = UInt32((rgb.blueComponent * 15).rounded())
                quantized.insert(r << 8 | g << 4 | b)
            }
        }
        return quantized.count
    }

    @Test("fixture raster predicate rejects blank and uniform surfaces")
    func fixtureRasterPredicateNegativeCase() throws {
        // Negative proof for the render-evidence gate: a blank page shell
        // (white page rectangle on a dark canvas — non-uniform but not
        // fixture content) and a fully uniform fill must both FAIL the
        // fixture predicate, while synthetic high-entropy noise passes.
        let bounds = NSRect(x: 0, y: 0, width: 120, height: 120)
        func bitmap(_ draw: (NSRect) -> Void) throws -> NSBitmapImageRep {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw(bounds)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        let uniform = try bitmap { rect in NSColor.white.setFill(); rect.fill() }
        #expect(!hasFixtureRasterPixels(in: bounds, representation: uniform, rootBounds: bounds))
        let blankShell = try bitmap { rect in
            NSColor.black.setFill(); rect.fill()
            NSColor.white.setFill(); rect.insetBy(dx: 20, dy: 20).fill()
        }
        #expect(!hasFixtureRasterPixels(in: bounds, representation: blankShell, rootBounds: bounds))
        // Deterministic high-entropy pattern: a simple integer hash drives the
        // channel values, so the positive control is replayable byte-for-byte.
        let noise = try bitmap { rect in
            for x in stride(from: 0, to: Int(rect.width), by: 4) {
                for y in stride(from: 0, to: Int(rect.height), by: 4) {
                    let h = UInt32(truncatingIfNeeded: (x &* 73_856_093) ^ (y &* 19_349_663) ^ 0x9E37)
                    NSColor(
                        red: CGFloat(h & 0xFF) / 255,
                        green: CGFloat((h >> 8) & 0xFF) / 255,
                        blue: CGFloat((h >> 16) & 0xFF) / 255,
                        alpha: 1
                    ).setFill()
                    NSRect(x: x, y: y, width: 4, height: 4).fill()
                }
            }
        }
        #expect(hasFixtureRasterPixels(in: bounds, representation: noise, rootBounds: bounds))
    }
}

@MainActor
private final class RedTeamSession: ReaderSessionPresenting, ReaderDuplicationSnapshotProviding {
    let id = TabID()
    let title: String
    let canvas: RedTeamCanvas
    var contentView: NSView { canvas }
    var page: Int
    var zoom = 1.0
    var searchQuery = ""
    var selection: String?
    private(set) var prepareForCloseCount = 0
    private var onPresentationChange: (() -> Void)?

    init(title: String, page: Int, color: NSColor) {
        self.title = title
        self.page = page
        canvas = RedTeamCanvas(color: color, label: title)
    }

    var statusSnapshot: ReaderStatusSnapshot { ReaderStatusSnapshot(context: searchQuery.isEmpty ? "NORMAL" : "SEARCH", page: "\(page) / 100", zoom: "\(Int(zoom * 100))%", detail: title) }
    var duplicationSnapshot: ReaderDuplicationSnapshot { ReaderDuplicationSnapshot(sourceURL: URL(fileURLWithPath: "/tmp/\(title)"), oneBasedPage: page, viewMode: .manual, scaleFactor: zoom) }
    func setPresentationChangeHandler(_ handler: (() -> Void)?) { onPresentationChange = handler }
    func publishPresentationChange() { onPresentationChange?() }
    func prepareForClose() { prepareForCloseCount += 1 }
}

@MainActor
private final class RedTeamCanvas: NSView {
    let color: NSColor
    let label: String
    init(color: NSColor, label: String) { self.color = color; self.label = label; super.init(frame: .zero); wantsLayer = true; setAccessibilityIdentifier("pdfCanvas") }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.88).setFill(); dirtyRect.fill()
        let text = NSString(string: label)
        text.draw(at: NSPoint(x: 28, y: bounds.midY), withAttributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white])
    }
}
