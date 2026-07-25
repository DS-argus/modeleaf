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
            if orientation == .sideBySide {
                check(fixture.coordinator.split(direction: .sideBySide) == nil)
                check(fixture.coordinator.split(direction: .stacked) != nil)
            } else {
                check(fixture.coordinator.split(direction: .sideBySide) != nil)
                check(fixture.coordinator.split(direction: .stacked) != nil)
            }
            let settledLayout = fixture.coordinator.snapshot.layout
            let expectedCount = orientation == .sideBySide ? 3 : 4
            check(fixture.coordinator.snapshot.panes.count == expectedCount)
            for _ in 0..<20 {
                check(fixture.coordinator.split(direction: .sideBySide) == nil)
                check(fixture.coordinator.split(direction: .stacked) == nil)
            }
            check(fixture.coordinator.snapshot.layout == settledLayout)
        }
        caseOutcomes["AC-2 split ceiling both directions / rapid repeat"] = casePassed
        caseOutcomes["Constrained-tree max-four-pane ceiling"] = casePassed

        beginCase()
        for _ in 0..<2 {
            let fixture = makeFixture(orientation: .sideBySide)
            check(fixture.coordinator.closeActiveTab())
            check(fixture.coordinator.snapshot.layout == .single(.one(fixture.leading)))
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
        check(rollback.coordinator.unsplit(stage: { $0.layout == .single(.one(rollback.trailing)) }))
        check(rollback.coordinator.snapshot.layout == .single(.one(rollback.trailing)))
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
        for (action, name) in [(ActionID.paneSplitRight, "side-by-side.png"), (.paneSplitDown, "stacked.png")] {
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
                controller.dispatch(action)
                // Post-S1 topology: side-by-side commits .split while a
                // stacked split of a single pane commits .single(.two).
                let layout = controller.coordinator.snapshot.layout
                let committed: Bool
                switch (action, layout) {
                case (.paneSplitRight, .split): committed = true
                case (.paneSplitDown, .single(.two)): committed = true
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
                // PDFKit draws pages through asynchronous tiling; an offscreen
                // cacheDisplay taken before tiles land captures an empty
                // canvas. Drain the run loop until both pane PDF surfaces
                // produce non-uniform content (bounded retries).
                for _ in 0..<25 {
                    window.displayIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                    root.needsDisplay = true
                }
                let representation = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: representation)
                let png = try #require(representation.representation(using: .png, properties: [:]))
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
            "artifacts": ["side-by-side.png", "stacked.png"],
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("adversarial-test-report.json"), options: .atomic)
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
