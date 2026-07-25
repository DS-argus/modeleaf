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
        var splitCeilingPassed = true
        for orientation in [PaneOrientation.sideBySide, .stacked] {
            let fixture = makeFixture(orientation: orientation)
            if orientation == .sideBySide {
                #expect(fixture.coordinator.split(direction: .sideBySide) == nil)
                #expect(fixture.coordinator.split(direction: .stacked) != nil)
            } else {
                #expect(fixture.coordinator.split(direction: .sideBySide) != nil)
                #expect(fixture.coordinator.split(direction: .stacked) != nil)
            }
            let settledLayout = fixture.coordinator.snapshot.layout
            let expectedCount = orientation == .sideBySide ? 3 : 4
            #expect(fixture.coordinator.snapshot.panes.count == expectedCount)
            for _ in 0..<20 {
                #expect(fixture.coordinator.split(direction: .sideBySide) == nil)
                #expect(fixture.coordinator.split(direction: .stacked) == nil)
            }
            #expect(fixture.coordinator.snapshot.layout == settledLayout)
            splitCeilingPassed = splitCeilingPassed && fixture.coordinator.snapshot.layout == settledLayout && fixture.coordinator.snapshot.panes.count == expectedCount
        }
        caseOutcomes["AC-2 split ceiling both directions / rapid repeat"] = splitCeilingPassed
        caseOutcomes["Constrained-tree max-four-pane ceiling"] = splitCeilingPassed

        var lifecyclePassed = true
        for _ in 0..<2 {
            let fixture = makeFixture(orientation: .sideBySide)
            #expect(fixture.coordinator.closeActiveTab())
            #expect(fixture.coordinator.snapshot.layout == .single(.one(fixture.leading)))
            #expect(fixture.coordinator.snapshot.panes.count == 1)
            #expect(fixture.coordinator.closeActiveTab())
            #expect(fixture.coordinator.snapshot.layout == .empty)
            #expect(fixture.coordinator.snapshot.panes.isEmpty)
            let reopened = RedTeamSession(title: "Reopened.pdf", page: 9, color: .systemGreen)
            #expect(fixture.coordinator.insert(reopened, into: .createIfEmpty))
            let replacement = RedTeamSession(title: "Reopened duplicate.pdf", page: 9, color: .systemPurple)
            fixture.coordinator.configureDuplication { _ in replacement }
            #expect(fixture.coordinator.split(direction: .sideBySide) != nil)
            #expect(fixture.coordinator.snapshot.panes.count == 2)
            lifecyclePassed = lifecyclePassed && fixture.coordinator.snapshot.panes.count == 2
        }
        caseOutcomes["EF4 AC-6 close-collapse-empty-reopen-resplit twice"] = lifecyclePassed

        let rollback = makeFixture(orientation: .sideBySide)
        let extra = RedTeamSession(title: "Opposite extra.pdf", page: 3, color: .brown)
        #expect(rollback.coordinator.insert(extra, into: .existing(rollback.leading)))
        let originalLeading = rollback.coordinator.store(for: rollback.leading)!.snapshot
        #expect(!rollback.coordinator.unsplit(stage: { _ in false }))
        #expect(rollback.coordinator.activatePane(rollback.trailing))
        #expect(rollback.coordinator.snapshot.panes[rollback.leading] == originalLeading)
        #expect(extra.prepareForCloseCount == 0)
        #expect(rollback.coordinator.unsplit(stage: { $0.layout == .single(.one(rollback.trailing)) }))
        #expect(rollback.coordinator.snapshot.layout == .single(.one(rollback.trailing)))
        #expect(rollback.origin.prepareForCloseCount == 1)
        #expect(extra.prepareForCloseCount == 1)
        caseOutcomes["AC-7 unsplit rollback then commit with multi-tab opposite pane"] = rollback.coordinator.snapshot.layout == .single(.one(rollback.trailing)) && rollback.origin.prepareForCloseCount == 1 && extra.prepareForCloseCount == 1

        let stale = makeFixture(orientation: .sideBySide)
        #expect(stale.coordinator.activatePane(stale.leading))
        let vanishedPane = stale.trailing
        #expect(stale.coordinator.unsplit())
        let delayed = RedTeamSession(title: "Delayed.pdf", page: 4, color: .magenta)
        #expect(!stale.coordinator.insert(delayed, into: .existing(vanishedPane)))
        #expect(delayed.prepareForCloseCount == 0)
        #expect(stale.coordinator.closeActiveTab())
        let fresh = RedTeamSession(title: "Fresh.pdf", page: 5, color: .cyan)
        #expect(stale.coordinator.insert(fresh, into: .createIfEmpty))
        caseOutcomes["AC-8 stale pane completion reject and empty createIfEmpty"] = delayed.prepareForCloseCount == 0 && stale.coordinator.snapshot.layout != .empty

        var focusSpamPassed = true
        for orientation in [PaneOrientation.sideBySide, .stacked] {
            let fixture = makeFixture(orientation: orientation)
            for direction in [PaneFocusDirection.left, .down, .up, .right] {
                for _ in 0..<10 { _ = fixture.coordinator.focus(direction) }
            }
            fixture.coordinator.snapshot.assertCardinality()
            #expect(fixture.coordinator.unsplit())
            for direction in [PaneFocusDirection.left, .down, .up, .right] { #expect(!fixture.coordinator.focus(direction)) }
            #expect(fixture.coordinator.closeActiveTab())
            for direction in [PaneFocusDirection.left, .down, .up, .right] { #expect(!fixture.coordinator.focus(direction)) }
            focusSpamPassed = focusSpamPassed && fixture.coordinator.snapshot.layout == .empty && fixture.coordinator.snapshot.panes.isEmpty
        }
        caseOutcomes["AC-4 boundary focus spam in both geometries and terminal layouts"] = focusSpamPassed

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
            #expect(isolation.origin.page == step)
            #expect(isolation.duplicate.page == 100 - step)
            #expect(isolation.origin.searchQuery != isolation.duplicate.searchQuery)
        }
        let cleanDuplicate = RedTeamSession(title: "Clean.pdf", page: 1, color: .gray)
        isolation.coordinator.configureDuplication { _ in cleanDuplicate }
        #expect(isolation.coordinator.unsplit())
        #expect(isolation.coordinator.split(direction: .sideBySide) != nil)
        #expect(cleanDuplicate.searchQuery.isEmpty)
        #expect(cleanDuplicate.selection == nil)
        caseOutcomes["AC-3 interleaved page zoom search isolation"] = isolation.origin.page == 30 && isolation.duplicate.page == 70 && isolation.origin.searchQuery == "origin-30" && isolation.duplicate.searchQuery == "duplicate-30"
        caseOutcomes["EF8 duplicate search and selection exclusion"] = cleanDuplicate.searchQuery.isEmpty && cleanDuplicate.selection == nil
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

    private func makeFixture(orientation: PaneOrientation) -> (coordinator: PaneCoordinator, leading: PaneID, trailing: PaneID, origin: RedTeamSession, duplicate: RedTeamSession, emissions: [PaneCoordinatorSnapshot]) {
        let coordinator = PaneCoordinator()
        let origin = RedTeamSession(title: "Origin.pdf", page: 2, color: .systemBlue)
        let duplicate = RedTeamSession(title: "Duplicate.pdf", page: 7, color: .systemOrange)
        coordinator.configureDuplication { _ in duplicate }
        var emissions: [PaneCoordinatorSnapshot] = []
        coordinator.onSnapshot = { emissions.append($0) }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let trailing = try! #require(coordinator.split(direction: orientation))
        let leading = try! #require(coordinator.snapshot.panes.keys.first { $0 != trailing })
        return (coordinator, leading, trailing, origin, duplicate, emissions)
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
                #expect(controller.openDocument(at: url))
                (controller.coordinator.activeSession as? ReaderSession)?.fitWidth()
                controller.dispatch(action)
                guard case .split = controller.coordinator.snapshot.layout else {
                    Issue.record("Expected a committed split for \(name)")
                    return
                }
                #expect((controller.coordinator.activeSession as? ReaderSession)?.goToPage(7) == true)
                (controller.coordinator.activeSession as? ReaderSession)?.fitWidth()
                let root = controller.mainWindowController.rootView
                root.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
                root.needsLayout = true
                root.layoutSubtreeIfNeeded()
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
