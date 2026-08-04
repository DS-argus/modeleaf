import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Pane topology generalization red-team QA")
@MainActor
struct TopoGenRedTeamQATests {
    @Test("dispatch anchor order-independence and 2x2 growth")
    func anchorOrderIndependence() {
        for flow in Flow.allCases {
            let fixture = makeFixture()
            let origin = fixture.coordinator.activePaneID!
            fixture.dispatcher.dispatch(.paneSplitDown)
            let down = fixture.coordinator.activePaneID!
            switch flow {
            case .downThenRightBottom:
                fixture.dispatcher.dispatch(.paneSplitRight)
                let right = fixture.coordinator.activePaneID!
                #expect(fixture.coordinator.snapshot.layout == .split(orientation: .stacked, leading: .one(origin), trailing: .two(first: down, second: right)))
                fixture.dispatcher.dispatch(.paneFocusUp); fixture.dispatcher.dispatch(.paneSplitRight)
            case .downThenRightTop:
                fixture.dispatcher.dispatch(.paneFocusUp); fixture.dispatcher.dispatch(.paneSplitRight)
                let right = fixture.coordinator.activePaneID!
                #expect(fixture.coordinator.snapshot.layout == .split(orientation: .stacked, leading: .two(first: origin, second: right), trailing: .one(down)))
                fixture.dispatcher.dispatch(.paneFocusDown); fixture.dispatcher.dispatch(.paneSplitRight)
            case .rightThenDownRight:
                // Rebuild with right-first; this branch deliberately does not reuse the down-first setup.
                let rightFirst = makeFixture()
                let left = rightFirst.coordinator.activePaneID!
                rightFirst.dispatcher.dispatch(.paneSplitRight)
                let right = rightFirst.coordinator.activePaneID!
                rightFirst.dispatcher.dispatch(.paneSplitDown)
                let bottom = rightFirst.coordinator.activePaneID!
                #expect(rightFirst.coordinator.snapshot.layout == .split(orientation: .sideBySide, leading: .one(left), trailing: .two(first: right, second: bottom)))
                rightFirst.dispatcher.dispatch(.paneFocusLeft); rightFirst.dispatcher.dispatch(.paneSplitDown)
                assertTwoByTwo(rightFirst.coordinator, outer: .sideBySide)
                continue
            case .rightThenDownLeft:
                let rightFirst = makeFixture()
                let left = rightFirst.coordinator.activePaneID!
                rightFirst.dispatcher.dispatch(.paneSplitRight)
                let right = rightFirst.coordinator.activePaneID!
                rightFirst.dispatcher.dispatch(.paneFocusLeft); rightFirst.dispatcher.dispatch(.paneSplitDown)
                let bottom = rightFirst.coordinator.activePaneID!
                #expect(rightFirst.coordinator.snapshot.layout == .split(orientation: .sideBySide, leading: .two(first: left, second: bottom), trailing: .one(right)))
                rightFirst.dispatcher.dispatch(.paneFocusRight); rightFirst.dispatcher.dispatch(.paneSplitDown)
                assertTwoByTwo(rightFirst.coordinator, outer: .sideBySide)
                continue
            }
            assertTwoByTwo(fixture.coordinator, outer: .stacked)
        }
    }

    @Test("dispatch ceiling spam is side-effect-free at three and four panes")
    func ceilingSpam() {
        for outer in [PaneOrientation.sideBySide, .stacked] {
            for pairSide in [PaneBandSide.leading, .trailing] {
                for count in [3, 4] {
                    let fixture = makeFixture()
                    fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitRight : .paneSplitDown)
                    if pairSide == .leading {
                        fixture.dispatcher.dispatch(outer == .sideBySide ? .paneFocusLeft : .paneFocusUp)
                    }
                    fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitDown : .paneSplitRight)
                    if count == 4 {
                        fixture.dispatcher.dispatch(outer == .sideBySide ? .paneFocusRight : .paneFocusDown)
                        fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitDown : .paneSplitRight)
                    }
                    var emissions = 0
                    fixture.coordinator.onSnapshot = { _ in emissions += 1 }
                    let before = fixture.coordinator.snapshot
                    for _ in 0..<10 {
                        fixture.dispatcher.dispatch(.paneSplitRight)
                        fixture.dispatcher.dispatch(.paneSplitDown)
                    }
                    let after = fixture.coordinator.snapshot
                    #expect(after.layout == before.layout, "\(outer) / \(pairSide) / \(count)-pane layout changed")
                    #expect(after.activePaneID == before.activePaneID, "\(outer) / \(pairSide) / \(count)-pane focus changed")
                    #expect(emissions == 0, "\(outer) / \(pairSide) / \(count)-pane rejected splits emitted")
                }
            }
        }
    }

    @Test("200 dispatched focus moves match independent no-wrap 2x2 model")
    func focusTorture() {
        for outer in [PaneOrientation.sideBySide, .stacked] {
            let fixture = makeFixture()
            let ids = growTwoByTwo(fixture, outer: outer)
            var model = FocusModel(outer: outer, leadingFirst: ids.0, leadingSecond: ids.1, trailingFirst: ids.2, trailingSecond: ids.3, active: fixture.coordinator.activePaneID!)
            var seed: UInt64 = outer == .sideBySide ? 0xC0FFEE : 0xBADC0DE
            for step in 0..<200 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let direction = [PaneFocusDirection.left, .down, .up, .right][Int(seed >> 62)]
                fixture.dispatcher.dispatch(action(for: direction))
                model.move(direction)
                #expect(fixture.coordinator.activePaneID == model.active, "\(outer) step \(step) / \(direction)")
            }
        }
    }

    @Test("close reopen churn reaches empty and resplits repeatedly")
    func closeReopenChurn() {
        for outer in [PaneOrientation.sideBySide, .stacked] {
            let fixture = makeFixture()
            for round in 0..<3 {
                _ = growTwoByTwo(fixture, outer: outer)
                var ids = fixture.coordinator.snapshot.layout.paneIDs
                // Deterministic Fisher-Yates order, intentionally not layout order.
                for index in stride(from: ids.count - 1, through: 1, by: -1) { ids.swapAt(index, (index * 17 + round * 7) % (index + 1)) }
                for id in ids {
                    #expect(fixture.coordinator.activatePane(id))
                    fixture.dispatcher.dispatch(.documentClose)
                    fixture.coordinator.snapshot.assertCardinality()
                }
                #expect(fixture.coordinator.snapshot.layout == .empty)
                #expect(fixture.coordinator.insert(QASession(title: "reopen \(outer) \(round)"), into: .createIfEmpty))
            }
        }
    }

    @Test("real render promotion transfers custom inner divider for every axis and singleton side")
    func promotionEdge() throws {
        for outer in [PaneOrientation.sideBySide, .stacked] {
            for singletonSide in [PaneBandSide.leading, .trailing] {
                let fixture = makeFixture()
                let controller = MainWindowController(coordinator: fixture.coordinator, theme: AppKitTheme(themeID: .tokyoNight), actionHandler: fixture.dispatcher.dispatch)
                defer { controller.close() }
                controller.window?.orderFrontRegardless()
                fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitRight : .paneSplitDown)
                let singleton: PaneID
                if singletonSide == .leading {
                    singleton = fixture.coordinator.snapshot.layout.paneIDs[0]
                    fixture.dispatcher.dispatch(outer == .sideBySide ? .paneFocusRight : .paneFocusDown)
                } else {
                    singleton = fixture.coordinator.activePaneID!
                    fixture.dispatcher.dispatch(outer == .sideBySide ? .paneFocusLeft : .paneFocusUp)
                }
                fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitDown : .paneSplitRight)
                let pair = fixture.coordinator.snapshot.layout.paneIDs.filter { $0 != singleton }
                let pairContainer = try #require(container("paneContainer.\(singletonSide == .leading ? "trailingBand" : "leadingBand")", in: controller.rootView))
                controller.rootView.layoutSubtreeIfNeeded()
                pairContainer.setPosition(175, ofDividerAt: 0)
                pairContainer.onDividerMoved?(pairContainer.currentDividerPosition)
                let saved = pairContainer.currentDividerPosition
                #expect(fixture.coordinator.activatePane(singleton))
                fixture.dispatcher.dispatch(.documentClose)
                #expect(fixture.coordinator.snapshot.layout == .split(orientation: outer.perpendicular, leading: .one(pair[0]), trailing: .one(pair[1])))
                let promoted = try #require(container("paneContainer", in: controller.rootView))
                controller.rootView.layoutSubtreeIfNeeded()
                #expect(promoted.isVertical == (outer.perpendicular == .sideBySide))
                #expect(abs(promoted.currentDividerPosition - saved) < 0.5)
                try capture(controller.rootView, named: "promotion-\(outer)-\(singletonSide).png")
            }
        }
    }

    @Test("dispatch unsplit closes others from every pane in both 2x2 shapes")
    func unsplitEveryPane() {
        for outer in [PaneOrientation.sideBySide, .stacked] {
            for index in 0..<4 {
                let fixture = makeFixture()
                _ = growTwoByTwo(fixture, outer: outer)
                let survivor = fixture.coordinator.snapshot.layout.paneIDs[index]
                #expect(fixture.coordinator.activatePane(survivor))
                fixture.dispatcher.dispatch(.paneUnsplit)
                #expect(fixture.coordinator.snapshot.layout == .single(survivor))
                #expect(fixture.coordinator.activePaneID == survivor)
            }
        }
    }

    private enum Flow: CaseIterable { case downThenRightBottom, downThenRightTop, rightThenDownRight, rightThenDownLeft }

    private func makeFixture() -> (coordinator: PaneCoordinator, dispatcher: ActionDispatcher) {
        let coordinator = PaneCoordinator()
        var next = 0
        coordinator.configureDuplication { _ in next += 1; return QASession(title: "duplicate \(next)") }
        #expect(coordinator.insert(QASession(title: "origin"), into: .createIfEmpty))
        return (coordinator, ActionDispatcher(coordinator: coordinator, navigation: BuiltInDefaults.config.navigation))
    }

    private func growTwoByTwo(_ fixture: (coordinator: PaneCoordinator, dispatcher: ActionDispatcher), outer: PaneOrientation) -> (PaneID, PaneID, PaneID, PaneID) {
        fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitRight : .paneSplitDown)
        let trailingFirst = fixture.coordinator.activePaneID!
        let leadingFirst = fixture.coordinator.snapshot.layout.paneIDs.first!
        fixture.dispatcher.dispatch(outer == .sideBySide ? .paneFocusLeft : .paneFocusUp)
        fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitDown : .paneSplitRight)
        let leadingSecond = fixture.coordinator.activePaneID!
        #expect(fixture.coordinator.activatePane(trailingFirst))
        fixture.dispatcher.dispatch(outer == .sideBySide ? .paneSplitDown : .paneSplitRight)
        let trailingSecond = fixture.coordinator.activePaneID!
        return (leadingFirst, leadingSecond, trailingFirst, trailingSecond)
    }

    private func assertTwoByTwo(_ coordinator: PaneCoordinator, outer: PaneOrientation) {
        guard case let .split(actual, leading, trailing) = coordinator.snapshot.layout else { Issue.record("expected 2x2 split"); return }
        #expect(actual == outer)
        if case .two = leading {} else { Issue.record("leading band did not grow") }
        if case .two = trailing {} else { Issue.record("trailing band did not grow") }
        #expect(coordinator.snapshot.layout.paneIDs.count == 4)
        #expect(coordinator.activePaneID != nil)
    }

    private func action(for direction: PaneFocusDirection) -> ActionID {
        switch direction { case .left: .paneFocusLeft; case .down: .paneFocusDown; case .up: .paneFocusUp; case .right: .paneFocusRight }
    }

    private func container(_ identifier: String, in root: NSView) -> PaneContainerView? {
        if let pane = root as? PaneContainerView, pane.accessibilityIdentifier() == identifier { return pane }
        for child in root.subviews { if let found = container(identifier, in: child) { return found } }
        return nil
    }

    private func capture(_ root: NSView, named name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/topo-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: image)
        try #require(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name))
    }
}

private struct FocusModel {
    let outer: PaneOrientation
    let leadingFirst: PaneID, leadingSecond: PaneID, trailingFirst: PaneID, trailingSecond: PaneID
    var active: PaneID

    mutating func move(_ direction: PaneFocusDirection) {
        let cross = outer == .sideBySide ? (direction == .left || direction == .right) : (direction == .up || direction == .down)
        let leading = active == leadingFirst || active == leadingSecond
        if cross {
            if outer == .sideBySide && ((direction == .left && leading) || (direction == .right && !leading)) { return }
            if outer == .stacked && ((direction == .up && leading) || (direction == .down && !leading)) { return }
            let firstSlot = active == leadingFirst || active == trailingFirst
            active = leading ? (firstSlot ? trailingFirst : trailingSecond) : (firstSlot ? leadingFirst : leadingSecond)
            return
        }
        let towardSecond = outer == .sideBySide ? direction == .down : direction == .right
        let first = leading ? leadingFirst : trailingFirst
        let second = leading ? leadingSecond : trailingSecond
        if towardSecond && active == first { active = second }
        if !towardSecond && active == second { active = first }
    }
}

@MainActor
private final class QASession: ReaderSessionPresenting, ReaderDuplicationSnapshotProviding {
    func applyTheme(_ theme: AppKitTheme) {}
    let id = TabID()
    let title: String
    let contentView: NSView = QAFocusView()
    private var handler: (() -> Void)?
    init(title: String) { self.title = title; contentView.setAccessibilityIdentifier("qaCanvas") }
    var statusSnapshot: ReaderStatusSnapshot { ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title) }
    var duplicationSnapshot: ReaderDuplicationSnapshot? { ReaderDuplicationSnapshot(sourceURL: URL(fileURLWithPath: "/tmp/\(title).pdf"), navigation: NavigationSnapshot(pageIndex: 0, pageSpacePoint: .zero)!) }
    func setPresentationChangeHandler(_ handler: (() -> Void)?) { self.handler = handler }
    func prepareForClose() {}
}

@MainActor
private final class QAFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
