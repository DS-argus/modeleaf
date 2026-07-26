import AppKit
import Foundation
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp
@MainActor private func withStackedOuterBands(_ value: Bool, _ body: () throws -> Void) rethrows {
    let original = PaneFeatureFlags.stackedOuterBands
    PaneFeatureFlags.stackedOuterBands = value
    defer { PaneFeatureFlags.stackedOuterBands = original }
    try body()
}
@Suite("Single-pane coordinator")
@MainActor
struct PaneCoordinatorTests {
    @Test("createIfEmpty creates one active pane and passes through tab state")
    func insertAndPassthrough() {
        let coordinator = PaneCoordinator()
        let session = StubReaderSession(id: TabID(), title: "One.pdf")
        #expect(coordinator.insert(session, into: .createIfEmpty))
        let snapshot = coordinator.snapshot
        #expect(snapshot.panes.count == 1)
        #expect(snapshot.activeID == session.id)
        snapshot.assertCardinality()
        #expect(coordinator.activeSession?.id == session.id)
    }

    @Test("each logical mutation emits one settled snapshot")
    func emissionCount() {
        let coordinator = PaneCoordinator()
        var snapshots: [PaneCoordinatorSnapshot] = []
        coordinator.onSnapshot = { snapshots.append($0) }
        let first = StubReaderSession(id: TabID(), title: "One.pdf")
        let second = StubReaderSession(id: TabID(), title: "Two.pdf")
        #expect(coordinator.insert(first, into: .createIfEmpty))
        #expect(coordinator.insert(second, into: .createIfEmpty))
        #expect(snapshots.count == 2)
    }

    @Test("settled pane mutations emit one snapshot and rejected mutations emit none")
    func settledMutationEmissionMatrix() throws {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        let duplicate = StubReaderSession(id: TabID(), title: "Duplicate.pdf")
        coordinator.configureDuplication { _ in duplicate }
        var emissions: [PaneCoordinatorSnapshot] = []
        coordinator.onSnapshot = { snapshot in
            snapshot.assertCardinality()
            emissions.append(snapshot)
        }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        #expect(emissions.count == 1)
        #expect(!coordinator.insert(origin, into: .existing(PaneID())))
        #expect(emissions.count == 1)
        let trailing = try #require(coordinator.split(direction: .sideBySide))
        #expect(emissions.count == 2)
        #expect(coordinator.focus(.left))
        #expect(emissions.count == 3)
        #expect(coordinator.activatePane(trailing))
        #expect(emissions.count == 4)
        #expect(!coordinator.closeActiveTab { _ in false })
        #expect(emissions.count == 5) // restoration after rejected staged close
        let successor = StubReaderSession(id: TabID(), title: "Successor.pdf")
        #expect(coordinator.insert(successor, into: .existing(trailing)))
        #expect(emissions.count == 6)
        #expect(coordinator.closeActiveTab())
        #expect(emissions.count == 7)
        #expect(coordinator.store(for: trailing)?.snapshot.activeID == duplicate.id)
        #expect(coordinator.focus(.left))
        #expect(emissions.count == 8)
        #expect(coordinator.unsplit())
        #expect(emissions.count == 9)
    }

    @Test("projected close commits only after staging succeeds")
    func projectedClose() {
        let coordinator = PaneCoordinator()
        let first = StubReaderSession(id: TabID(), title: "One.pdf")
        let second = StubReaderSession(id: TabID(), title: "Two.pdf")
        #expect(coordinator.insert(first, into: .createIfEmpty))
        #expect(coordinator.insert(second, into: .createIfEmpty))
        #expect(coordinator.closeActiveTab { $0.activeID == first.id })
        #expect(second.prepareForCloseCount == 1)
        #expect(coordinator.activeSession?.id == first.id)
    }

    @Test("failed staging rolls selection back without teardown")
    func rollbackClose() {
        let coordinator = PaneCoordinator()
        let first = StubReaderSession(id: TabID(), title: "One.pdf")
        let second = StubReaderSession(id: TabID(), title: "Two.pdf")
        #expect(coordinator.insert(first, into: .createIfEmpty))
        #expect(coordinator.insert(second, into: .createIfEmpty))
        #expect(!coordinator.closeActiveTab { _ in false })
        #expect(second.prepareForCloseCount == 0)
        #expect(coordinator.activeSession?.id == second.id)
    }

    @Test("closing the final tab returns to empty")
    func finalClose() {
        let coordinator = PaneCoordinator()
        let session = StubReaderSession(id: TabID(), title: "One.pdf")
        #expect(coordinator.insert(session, into: .createIfEmpty))
        #expect(coordinator.closeActiveTab { $0.layout == .empty })
        #expect(coordinator.snapshot.layout == .empty)
        #expect(session.prepareForCloseCount == 1)
    }


    @Test("split creates and activates a duplicate pane and permits growth toward the four-pane ceiling")
    func splitCreatesAndActivatesDuplicate() {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf", page: 4, zoom: 1.5)
        let duplicate = StubReaderSession(id: TabID(), title: "Origin.pdf", page: 4, zoom: 1.5)
        coordinator.configureDuplication { snapshot in
            #expect(snapshot.oneBasedPage == 4)
            #expect(snapshot.viewMode == .manual)
            #expect(snapshot.scaleFactor == 1.5)
            return duplicate
        }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let destination = try! #require(coordinator.split(direction: .sideBySide))
        #expect(coordinator.snapshot.layout == .split(orientation: .sideBySide, leading: .one(coordinator.snapshot.panes.keys.first(where: { $0 != destination })!), trailing: .one(destination)))
        #expect(coordinator.activePaneID == destination)
        #expect(coordinator.store(for: destination)?.snapshot.tabs.map(\.id) == [duplicate.id])
        #expect(coordinator.split(direction: .stacked) != nil)
    }

    @Test("split target matrix supports both axes through four panes")
    func splitTargetMatrix() throws {
        enum Topology: CaseIterable { case singleOne, singleTwo, splitOneOne, splitTwoOne, splitOneTwo, splitTwoTwo }
        for topology in Topology.allCases {
            for direction in [PaneOrientation.sideBySide, .stacked] {
                let coordinator = PaneCoordinator()
                var duplicationCalls = 0
                coordinator.configureDuplication { _ in
                    duplicationCalls += 1
                    return StubReaderSession(id: TabID(), title: "Duplicate \(duplicationCalls).pdf")
                }
                var completionCalls = 0
                var emissions = 0
                coordinator.configureDuplicationCompletion { _, _ in completionCalls += 1 }
                coordinator.onSnapshot = { _ in emissions += 1 }
                #expect(coordinator.insert(StubReaderSession(id: TabID(), title: "Origin.pdf"), into: .createIfEmpty))
                switch topology {
                case .singleOne:
                    break
                case .singleTwo:
                    #expect(coordinator.split(direction: .stacked) != nil)
                case .splitOneOne:
                    #expect(coordinator.split(direction: .sideBySide) != nil)
                case .splitTwoOne:
                    #expect(coordinator.split(direction: .sideBySide) != nil)
                    #expect(coordinator.activatePane(coordinator.snapshot.layout.paneIDs.first!))
                    #expect(coordinator.split(direction: .stacked) != nil)
                case .splitOneTwo:
                    #expect(coordinator.split(direction: .sideBySide) != nil)
                    #expect(coordinator.split(direction: .stacked) != nil)
                    #expect(coordinator.activatePane(coordinator.snapshot.layout.paneIDs.first!))
                case .splitTwoTwo:
                    #expect(coordinator.split(direction: .sideBySide) != nil)
                    #expect(coordinator.split(direction: .stacked) != nil)
                    #expect(coordinator.activatePane(coordinator.snapshot.layout.paneIDs.first!))
                    #expect(coordinator.split(direction: .stacked) != nil)
                }

                let before = coordinator.snapshot
                let callsBefore = duplicationCalls
                let completionCallsBefore = completionCalls
                let emissionsBefore = emissions
                let result = coordinator.split(direction: direction)
                let expectedSuccess = switch (topology, direction) {
                case (.singleOne, _), (.splitOneOne, .stacked), (.splitOneTwo, .stacked): true
                default: false
                }
                #expect((result != nil) == expectedSuccess, "\(topology) / \(direction)")
                #expect(duplicationCalls == callsBefore + (expectedSuccess ? 1 : 0))
                #expect(completionCalls == completionCallsBefore + (expectedSuccess ? 1 : 0))
                #expect(emissions == emissionsBefore + (expectedSuccess ? 1 : 0))
                #expect(coordinator.snapshot.layout.paneIDs.count == before.layout.paneIDs.count + (expectedSuccess ? 1 : 0))
                if expectedSuccess {
                    #expect(coordinator.activePaneID == result)
                    #expect(coordinator.snapshot.layout.contains(result!))
                } else {
                    #expect(coordinator.snapshot.layout == before.layout)
                    #expect(coordinator.activePaneID == before.activePaneID)
                }
            }
        }
    }
    @Test("stacked outer two-band splits are gated strict no-ops")
    func stackedOuterBandGate() throws {
        #expect(PaneFeatureFlags.stackedOuterBands == false)
        let coordinator = PaneCoordinator()
        var duplications = 0, completions = 0, emissions = 0
        coordinator.configureDuplication { _ in duplications += 1; return StubReaderSession(id: TabID(), title: "Duplicate.pdf") }
        coordinator.configureDuplicationCompletion { _, _ in completions += 1 }
        coordinator.onSnapshot = { _ in emissions += 1 }
        #expect(coordinator.insert(StubReaderSession(id: TabID(), title: "Origin.pdf"), into: .createIfEmpty))
        let bottom = try #require(coordinator.split(direction: .stacked))
        let before = coordinator.snapshot
        let counts = (duplications, completions, emissions)
        #expect(coordinator.split(direction: .sideBySide) == nil)
        #expect((duplications, completions, emissions) == counts)
        #expect(coordinator.snapshot.layout == before.layout)
        #expect(coordinator.activePaneID == bottom)
        withStackedOuterBands(true) {
            let destination = try! #require(coordinator.split(direction: .sideBySide))
            #expect(coordinator.snapshot.layout == .split(orientation: .stacked, leading: .one(before.layout.paneIDs[0]), trailing: .two(first: bottom, second: destination)))
        }
    }
    @Test("S1 layout reshape preserves legacy split outcomes and coordinator side effects")
    func s1LegacySplitOracle() throws {
        enum LegacyPaneStack: Equatable {
            case one(PaneID)
            case two(top: PaneID, bottom: PaneID)

            var paneIDs: [PaneID] {
                switch self {
                case let .one(id): [id]
                case let .two(top, bottom): [top, bottom]
                }
            }
        }
        enum LegacyPaneLayout: Equatable {
            case empty
            case single(LegacyPaneStack)
            case split(leading: LegacyPaneStack, trailing: LegacyPaneStack)

            var paneIDs: [PaneID] {
                switch self {
                case .empty: []
                case let .single(stack): stack.paneIDs
                case let .split(leading, trailing): leading.paneIDs + trailing.paneIDs
                }
            }

            func applyingSplit(_ orientation: PaneOrientation, to activePaneID: PaneID, inserting destination: PaneID) -> LegacyPaneLayout? {
                switch (orientation, self) {
                case let (.sideBySide, .single(stack)):
                    return .split(leading: stack, trailing: .one(destination))
                case let (.stacked, .single(.one(origin))) where origin == activePaneID:
                    return .single(.two(top: origin, bottom: destination))
                case let (.stacked, .split(leading, trailing)):
                    if case let .one(origin) = leading, origin == activePaneID {
                        return .split(leading: .two(top: origin, bottom: destination), trailing: trailing)
                    }
                    if case let .one(origin) = trailing, origin == activePaneID {
                        return .split(leading: leading, trailing: .two(top: origin, bottom: destination))
                    }
                    return nil
                default:
                    return nil
                }
            }
        }
        func canonicalize(_ stack: LegacyPaneStack) -> PaneStack {
            switch stack {
            case let .one(id): .one(id)
            case let .two(top, bottom): .two(first: top, second: bottom)
            }
        }
        func canonicalize(_ layout: LegacyPaneLayout?) -> PaneLayout? {
            guard let layout else { return nil }
            return switch layout {
            case .empty: .empty
            case let .single(.one(id)): .single(id)
            case let .single(.two(top, bottom)): .split(orientation: .stacked, leading: .one(top), trailing: .one(bottom))
            case let .split(leading, trailing): .split(orientation: .sideBySide, leading: canonicalize(leading), trailing: canonicalize(trailing))
            }
        }

        let a = PaneID(), b = PaneID(), c = PaneID(), d = PaneID()
        let families: [(String, LegacyPaneLayout)] = [
            ("single.one", .single(.one(a))),
            ("single.two", .single(.two(top: a, bottom: b))),
            ("sideBySide one/one", .split(leading: .one(a), trailing: .one(b))),
            ("sideBySide two/one", .split(leading: .two(top: a, bottom: b), trailing: .one(c))),
            ("sideBySide one/two", .split(leading: .one(a), trailing: .two(top: b, bottom: c))),
            ("sideBySide two/two", .split(leading: .two(top: a, bottom: b), trailing: .two(top: c, bottom: d))),
        ]
        var oracleCells = 0
        for (name, legacy) in families {
            for active in legacy.paneIDs {
                for direction in [PaneOrientation.sideBySide, .stacked] {
                    let destination = PaneID()
                    let expected = canonicalize(legacy.applyingSplit(direction, to: active, inserting: destination))
                    let layout = canonicalize(legacy)!
                    let actual = layout.applyingSplit(direction, to: active, inserting: destination)
                    if case let .split(.stacked, leading, trailing) = actual,
                       [leading, trailing].contains(where: { if case .two = $0 { true } else { false } }) {
                        #expect(actual != expected, "\(name), active=\(active), direction=\(direction)")
                    } else {
                        #expect(actual == expected, "\(name), active=\(active), direction=\(direction)")
                    }
                    oracleCells += 1
                }
            }
        }
        #expect(oracleCells == 30)

        enum Family { case singleOne, singleTwo, oneOne, twoOne, oneTwo, twoTwo }
        func makeCoordinator(_ family: Family) throws -> PaneCoordinator {
            let coordinator = PaneCoordinator()
            var duplicateNumber = 0
            coordinator.configureDuplication { _ in
                duplicateNumber += 1
                return StubReaderSession(id: TabID(), title: "Duplicate \(duplicateNumber).pdf")
            }
            #expect(coordinator.insert(StubReaderSession(id: TabID(), title: "Origin.pdf"), into: .createIfEmpty))
            switch family {
            case .singleOne:
                break
            case .singleTwo:
                #expect(coordinator.split(direction: .stacked) != nil)
            case .oneOne:
                #expect(coordinator.split(direction: .sideBySide) != nil)
            case .twoOne:
                let trailing = try #require(coordinator.split(direction: .sideBySide))
                let leading = try #require(coordinator.snapshot.layout.paneIDs.first { $0 != trailing })
                #expect(coordinator.activatePane(leading))
                #expect(coordinator.split(direction: .stacked) != nil)
            case .oneTwo:
                #expect(coordinator.split(direction: .sideBySide) != nil)
                #expect(coordinator.split(direction: .stacked) != nil)
            case .twoTwo:
                let trailing = try #require(coordinator.split(direction: .sideBySide))
                let leading = try #require(coordinator.snapshot.layout.paneIDs.first { $0 != trailing })
                #expect(coordinator.activatePane(leading))
                #expect(coordinator.split(direction: .stacked) != nil)
                #expect(coordinator.activatePane(trailing))
                #expect(coordinator.split(direction: .stacked) != nil)
            }
            return coordinator
        }
        for family in [Family.singleOne, .singleTwo, .oneOne, .twoOne, .oneTwo, .twoTwo] {
            let coordinator = try makeCoordinator(family)
            var duplications = 0, completions = 0, emissions = 0
            coordinator.configureDuplication { _ in
                duplications += 1
                return StubReaderSession(id: TabID(), title: "Probe \(duplications).pdf")
            }
            coordinator.configureDuplicationCompletion { _, success in if success { completions += 1 } }
            coordinator.onSnapshot = { _ in emissions += 1 }
            let before = coordinator.snapshot
            let successDirection: PaneOrientation? = [.sideBySide, .stacked].first {
                guard let projected = before.layout.applyingSplit($0, to: before.activePaneID!, inserting: PaneID()) else { return false }
                if case let .split(.stacked, leading, trailing) = projected, [leading, trailing].contains(where: { if case .two = $0 { true } else { false } }) { return false }
                return true
            }
            if let successDirection {
                #expect(coordinator.split(direction: successDirection) != nil)
                #expect(duplications == 1)
                #expect(completions == 1)
                #expect(emissions == 1)
            }

            let reject = try makeCoordinator(family)
            var rejectedDuplications = 0, rejectedCompletions = 0, rejectedEmissions = 0
            reject.configureDuplication { _ in rejectedDuplications += 1; return StubReaderSession(id: TabID(), title: "Rejected.pdf") }
            reject.configureDuplicationCompletion { _, _ in rejectedCompletions += 1 }
            reject.onSnapshot = { _ in rejectedEmissions += 1 }
            let rejectedBefore = reject.snapshot
            if let rejectDirection = [PaneOrientation.sideBySide, .stacked].first(where: { rejectedBefore.layout.applyingSplit($0, to: rejectedBefore.activePaneID!, inserting: PaneID()) == nil }) {
                #expect(reject.split(direction: rejectDirection) == nil)
                #expect(rejectedDuplications == 0)
                #expect(rejectedCompletions == 0)
                #expect(rejectedEmissions == 0)
                #expect(reject.snapshot.layout == rejectedBefore.layout)
                #expect(reject.activePaneID == rejectedBefore.activePaneID)
            }
        }
        let memoryCoordinator = try makeCoordinator(.oneTwo)
        let rememberedPane = try #require(memoryCoordinator.activePaneID)
        #expect(memoryCoordinator.split(direction: .sideBySide) == nil)
        #expect(memoryCoordinator.focus(.left))
        #expect(memoryCoordinator.focus(.right))
        #expect(memoryCoordinator.activePaneID == rememberedPane, "rejected split preserves band-slot memory")
    }
    @Test("geometric focus and unsplit retain the active pane")
    func focusAndUnsplit() {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        let duplicate = StubReaderSession(id: TabID(), title: "Duplicate.pdf")
        coordinator.configureDuplication { _ in duplicate }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let destination = try! #require(coordinator.split(direction: .sideBySide))
        #expect(coordinator.focus(.left))
        #expect(coordinator.activePaneID != destination)
        #expect(!coordinator.focus(.up))
        #expect(coordinator.unsplit())
        #expect(duplicate.prepareForCloseCount == 1)
}
    @Test("closing a pane's last tab collapses onto the survivor without changing its active tab")
    func collapseKeepsSurvivorSelection() throws {
        let coordinator = PaneCoordinator()
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        let extra = StubReaderSession(id: TabID(), title: "Extra.pdf")
        let duplicate = StubReaderSession(id: TabID(), title: "Duplicate.pdf")
        coordinator.configureDuplication { _ in duplicate }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        #expect(coordinator.insert(extra, into: .createIfEmpty))
        let closingPane = try #require(coordinator.split(direction: .sideBySide))
        let survivor = try #require(coordinator.snapshot.panes.keys.first { $0 != closingPane })
        #expect(coordinator.activatePane(survivor))
        #expect(coordinator.store(for: survivor)?.activate(origin.id) == true)
        #expect(coordinator.activatePane(closingPane))

        #expect(coordinator.closeActiveTab { snapshot in
            snapshot.layout == .single(survivor) && snapshot.activeID == origin.id
        })
        #expect(coordinator.snapshot.layout == .single(survivor))
        #expect(coordinator.activePaneID == survivor)
        #expect(coordinator.activeSession?.id == origin.id)
    }

    @Test("empty terminal state recreates its first pane through createIfEmpty")
    func emptyReopens() {
        let coordinator = PaneCoordinator()
        let first = StubReaderSession(id: TabID(), title: "First.pdf")
        let reopened = StubReaderSession(id: TabID(), title: "Reopened.pdf")
        #expect(coordinator.insert(first, into: .createIfEmpty))
        #expect(coordinator.closeActiveTab { $0.layout == .empty })
        #expect(coordinator.insert(reopened, into: .createIfEmpty))
        #expect(coordinator.snapshot.layout != .empty)
        #expect(coordinator.activeSession?.id == reopened.id)
    }

    @Test("four-pane teardown releases each collapsed tier and all globally unsplit PDFKit ownership")
    func fourPaneTeardownReleasesAllOwnedObjects() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            for path in [FourPaneClosePath.rowCollapse, .columnCollapse, .globalUnsplit] {
                let removedReferences = try autoreleasepool { () throws -> [WeakSessionObjects] in
                    let coordinator = PaneCoordinator()
                    var references: [PaneID: WeakSessionObjects] = [:]
                    var pendingReferences: WeakSessionObjects?
                    let original = try PDFOpenService().open(url: url)
                    #expect(coordinator.insert(original, into: .createIfEmpty))
                    coordinator.configureDuplication { _ in
                        let document = PDFDocument(url: url)!
                        let search = PaneSearchLifecycleSpy()
                        let session = ReaderSession(sourceURL: url, document: document, searchLifecycle: search)
                        pendingReferences = WeakSessionObjects(session: session, view: descendantPDFViews(in: session.contentView).only!, document: document, search: search)
                        return session
                    }

                    let trailingTop = try #require(coordinator.split(direction: .sideBySide))
                    references[trailingTop] = pendingReferences!
                    let leadingTop = try #require(coordinator.snapshot.layout.paneIDs.first { $0 != trailingTop })
                    #expect(coordinator.activatePane(leadingTop))
                    let leadingBottom = try #require(coordinator.split(direction: .stacked))
                    references[leadingBottom] = pendingReferences!
                    #expect(coordinator.activatePane(trailingTop))
                    let trailingBottom = try #require(coordinator.split(direction: .stacked))
                    references[trailingBottom] = pendingReferences!
                    #expect(coordinator.snapshot.layout == .split(orientation: .sideBySide, leading: .two(first: leadingTop, second: leadingBottom), trailing: .two(first: trailingTop, second: trailingBottom)))

                    let removed: [WeakSessionObjects]
                    switch path {
                    case .rowCollapse:
                        #expect(coordinator.closeActiveTab())
                        removed = [references[trailingBottom]!]
                        #expect(coordinator.snapshot.layout == .split(orientation: .sideBySide, leading: .two(first: leadingTop, second: leadingBottom), trailing: .one(trailingTop)))
                        #expect(coordinator.store(for: trailingTop)?.activeSession != nil)
                    case .columnCollapse:
                        #expect(coordinator.closeActiveTab())
                        #expect(coordinator.activatePane(trailingTop))
                        #expect(coordinator.closeActiveTab())
                        removed = [references[trailingBottom]!, references[trailingTop]!]
                        #expect(coordinator.snapshot.layout == .split(orientation: .stacked, leading: .one(leadingTop), trailing: .one(leadingBottom)))
                        #expect(coordinator.store(for: leadingTop)?.activeSession != nil)
                    case .globalUnsplit:
                        #expect(coordinator.activatePane(leadingTop))
                        #expect(coordinator.unsplit())
                        removed = [references[trailingTop]!, references[leadingBottom]!, references[trailingBottom]!]
                        #expect(coordinator.snapshot.layout == .single(leadingTop))
                        #expect(coordinator.activeSession === original)
                    }
                    coordinator.snapshot.assertCardinality()
                    while coordinator.closeActiveTab() {}
                    return removed
                }
                drainPDFKit()
                removedReferences.forEach(assertReleased)
            }
        }
    }

    @Test("cross-column focus preserves the row in 2x2 and uses memory only from a full-height source")
    func crossColumnFocusRowSemantics() throws {
        // tmux semantics (verified against tmux 3.6a): with both columns
        // split, crossing lands in the SAME row — the source row overlaps
        // exactly one destination pane, so the move is geometric, not
        // memory-driven. Memory applies only when the source column is a
        // full-height .one pane overlapping both destination rows.
        let coordinator = PaneCoordinator()
        var duplicates = (1...3).map { StubReaderSession(id: TabID(), title: "Duplicate \($0).pdf") }
        coordinator.configureDuplication { _ in duplicates.removeFirst() }
        #expect(coordinator.insert(StubReaderSession(id: TabID(), title: "Origin.pdf"), into: .createIfEmpty))
        let trailingTop = try #require(coordinator.split(direction: .sideBySide))
        let leadingTop = try #require(coordinator.snapshot.layout.paneIDs.first { $0 != trailingTop })

        // 1+2: leading full-height, trailing split. Ambiguous crossing uses
        // the trailing column's remembered row.
        let trailingBottom = try #require(coordinator.split(direction: .stacked))
        #expect(coordinator.activePaneID == trailingBottom)
        #expect(coordinator.focus(.left))
        #expect(coordinator.activePaneID == leadingTop)
        #expect(coordinator.focus(.right))
        #expect(coordinator.activePaneID == trailingBottom, "full-height source lands on remembered row")
        #expect(coordinator.focus(.up))
        #expect(coordinator.focus(.left))
        #expect(coordinator.focus(.right))
        #expect(coordinator.activePaneID == trailingTop, "memory tracks the most recently focused row")

        // 2x2: crossing preserves the row regardless of memory.
        #expect(coordinator.activatePane(leadingTop))
        let leadingBottom = try #require(coordinator.split(direction: .stacked))
        #expect(coordinator.activatePane(trailingBottom))   // trailing memory = bottom
        #expect(coordinator.activatePane(leadingTop))
        #expect(coordinator.focus(.right))
        #expect(coordinator.activePaneID == trailingTop, "2x2 top row crosses to top row, ignoring bottom memory")
        #expect(coordinator.focus(.left))
        #expect(coordinator.activePaneID == leadingTop)
        #expect(coordinator.focus(.down))
        #expect(coordinator.activePaneID == leadingBottom)
        #expect(coordinator.focus(.right))
        #expect(coordinator.activePaneID == trailingBottom, "2x2 bottom row crosses to bottom row")
        #expect(!coordinator.focus(.right))
        #expect(!coordinator.focus(.down))
    }
    @Test("four-pane close cascade projects each tier once and rollback preserves every tier")
    func fourPaneCloseCascadeAndRollback() throws {
        let coordinator = PaneCoordinator()
        var duplicates = (1...3).map { StubReaderSession(id: TabID(), title: "Duplicate \($0).pdf") }
        coordinator.configureDuplication { _ in duplicates.removeFirst() }
        let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
        var emissions = 0
        coordinator.onSnapshot = { _ in emissions += 1 }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let trailingTop = try #require(coordinator.split(direction: .sideBySide))
        let leadingTop = try #require(coordinator.snapshot.layout.paneIDs.first { $0 != trailingTop })
        #expect(coordinator.activatePane(leadingTop))
        let leadingBottom = try #require(coordinator.split(direction: .stacked))
        #expect(coordinator.activatePane(trailingTop))
        let trailingBottom = try #require(coordinator.split(direction: .stacked))

        let expected = [
            PaneLayout.split(orientation: .sideBySide, leading: .two(first: leadingTop, second: leadingBottom), trailing: .two(first: trailingTop, second: trailingBottom)),
            .split(orientation: .sideBySide, leading: .two(first: leadingTop, second: leadingBottom), trailing: .one(trailingTop)),
            .split(orientation: .stacked, leading: .one(leadingTop), trailing: .one(leadingBottom)),
            .single(leadingTop),
            .empty,
        ]
        for index in 0..<4 {
            #expect(coordinator.snapshot.layout == expected[index])
            let before = emissions
            #expect(!coordinator.closeActiveTab { _ in false })
            #expect(coordinator.snapshot.layout == expected[index])
            #expect(emissions == before + 1)
            #expect(coordinator.closeActiveTab())
            #expect(coordinator.snapshot.layout == expected[index + 1])
            #expect(emissions == before + 2)
            coordinator.snapshot.assertCardinality()
        }
    }


    @Test("focus memory carries, falls back, and survives deferred pane activation")
    func focusMemoryMatrix() throws {
        // A trailing remembered bottom survives removal of the entire leading
        // column, becomes the leading column on resplit, and remains the h/l target.
        let carried = fourPaneCoordinator()
        #expect(carried.coordinator.activatePane(carried.trailingBottom))
        #expect(carried.coordinator.activatePane(carried.leadingBottom))
        #expect(carried.coordinator.closeActiveTab())
        #expect(carried.coordinator.activatePane(carried.leadingTop))
        #expect(carried.coordinator.closeActiveTab())
        #expect(carried.coordinator.snapshot.layout == .split(orientation: .stacked, leading: .one(carried.trailingTop), trailing: .one(carried.trailingBottom)))
        var newTrailing: PaneID?
        withStackedOuterBands(true) {
            newTrailing = carried.coordinator.split(direction: .sideBySide)
        }
        let resolvedNewTrailing = try #require(newTrailing)
        #expect(carried.coordinator.focus(.left))
        #expect(carried.coordinator.activePaneID == carried.trailingBottom)
        #expect(carried.coordinator.focus(.right))
        #expect(carried.coordinator.activePaneID == resolvedNewTrailing)

        // Removing the remembered row collapses to the top survivor; crossing
        // into that column therefore has the top fallback rather than stale bottom.
        let fallback = fourPaneCoordinator()
        #expect(fallback.coordinator.activatePane(fallback.trailingBottom))
        #expect(fallback.coordinator.closeActiveTab())
        #expect(fallback.coordinator.activatePane(fallback.leadingTop))
        #expect(fallback.coordinator.focus(.right))
        #expect(fallback.coordinator.activePaneID == fallback.trailingTop)

        // Both direct existing insertion and a delayed successful insertion
        // activate their target pane, updating that column's remembered row.
        let insertion = fourPaneCoordinator()
        #expect(insertion.coordinator.activatePane(insertion.leadingTop))
        #expect(insertion.coordinator.insert(StubReaderSession(id: TabID(), title: "Existing.pdf"), into: .existing(insertion.trailingBottom)))
        #expect(insertion.coordinator.focus(.left))
        #expect(insertion.coordinator.focus(.right))
        #expect(insertion.coordinator.activePaneID == insertion.trailingBottom)
        #expect(insertion.coordinator.activatePane(insertion.leadingTop))
        let deferredTarget = insertion.trailingBottom
        #expect(insertion.coordinator.insert(StubReaderSession(id: TabID(), title: "Deferred success.pdf"), into: .existing(deferredTarget)))
        #expect(insertion.coordinator.focus(.left))
        #expect(insertion.coordinator.focus(.right))
        #expect(insertion.coordinator.activePaneID == deferredTarget)
    }

    @Test("rejected row, column, and unsplit projections preserve focus memory verbatim")
    func rejectedProjectionFocusMemoryMatrix() throws {
        enum Rejection { case row, column, unsplit }
        for rejection in [Rejection.row, .column, .unsplit] {
            let fixture = fourPaneCoordinator()
            #expect(fixture.coordinator.activatePane(fixture.leadingBottom))
            #expect(fixture.coordinator.activatePane(fixture.trailingBottom))
            let expectedLeft: PaneID
            switch rejection {
            case .row:
                #expect(!fixture.coordinator.closeActiveTab { _ in false })
                expectedLeft = fixture.leadingBottom
            case .column:
                #expect(fixture.coordinator.activatePane(fixture.leadingBottom))
                #expect(fixture.coordinator.closeActiveTab())
                #expect(!fixture.coordinator.closeActiveTab { _ in false })
                expectedLeft = fixture.leadingTop
            case .unsplit:
                #expect(!fixture.coordinator.unsplit { _ in false })
                expectedLeft = fixture.leadingBottom
            }
            if expectedLeft == fixture.leadingTop {
                // Rejected column projection keeps the leading survivor
                // active; crossing right must land on the trailing column's
                // remembered row, and returning honors the carried memory.
                #expect(fixture.coordinator.activePaneID == fixture.leadingTop, "\(rejection)")
                #expect(fixture.coordinator.focus(.right), "\(rejection)")
                #expect(fixture.coordinator.activePaneID == fixture.trailingBottom, "\(rejection)")
                #expect(fixture.coordinator.focus(.left), "\(rejection)")
                #expect(fixture.coordinator.activePaneID == expectedLeft, "\(rejection)")
            } else {
                // Rejection preserves trailingBottom active; both columns'
                // memories survive the rejected projection verbatim.
                #expect(fixture.coordinator.activePaneID == fixture.trailingBottom, "\(rejection)")
                #expect(fixture.coordinator.focus(.left), "\(rejection)")
                #expect(fixture.coordinator.activePaneID == expectedLeft, "\(rejection)")
                #expect(fixture.coordinator.focus(.right), "\(rejection)")
                #expect(fixture.coordinator.activePaneID == fixture.trailingBottom, "\(rejection)")
                #expect(fixture.coordinator.focus(.left), "\(rejection)")
                #expect(fixture.coordinator.activePaneID == expectedLeft, "\(rejection)")
            }
        }
    }

    @Test("staging-time session notifications never publish mid-transaction state")
    func stagingReentrancyIsSuppressed() throws {
        // Regression for a real-app SIGTRAP: closing the last tab of a pane
        // begins the close (store already mutated), then the staging handler
        // renders the projection, which unmounts/reflows PDF views and fires
        // PDFKit presentation notifications. Those must not publish: the
        // layout still contains the closing pane while its store has no
        // active session, so strict makeSnapshot preconditions trap.
        enum Tier { case rowCollapse, windowEmpty, unsplit }
        for tier in [Tier.rowCollapse, .windowEmpty, .unsplit] {
            for commit in [false, true] {
                let coordinator = PaneCoordinator()
                let origin = StubReaderSession(id: TabID(), title: "Origin.pdf")
                let duplicate = StubReaderSession(id: TabID(), title: "Duplicate.pdf")
                coordinator.configureDuplication { _ in duplicate }
                #expect(coordinator.insert(origin, into: .createIfEmpty))
                if tier != .windowEmpty { #expect(coordinator.split(direction: .sideBySide) != nil) }
                var emissions = 0
                coordinator.onSnapshot = { snapshot in
                    snapshot.assertCardinality()
                    emissions += 1
                }
                let fire = {
                    // Both the closing and the surviving session may notify
                    // while the projection render moves views around.
                    origin.publishPresentationChange()
                    duplicate.publishPresentationChange()
                }
                let result: Bool
                switch tier {
                case .rowCollapse, .windowEmpty:
                    result = coordinator.closeActiveTab { _ in fire(); return commit }
                case .unsplit:
                    result = coordinator.unsplit { _ in fire(); return commit }
                }
                #expect(result == commit, "\(tier) commit=\(commit)")
                // Exactly one settled emission per attempt: the commit or the
                // rollback restoration. Staging-time notifications add none.
                #expect(emissions == 1, "\(tier) commit=\(commit) emissions=\(emissions)")
                coordinator.snapshot.assertCardinality()
                // Post-transaction notifications publish normally again.
                if !commit {
                    origin.publishPresentationChange()
                    #expect(emissions == 2, "\(tier) post-transaction emission")
                }
            }
        }
    }

    private func fourPaneCoordinator() -> (coordinator: PaneCoordinator, leadingTop: PaneID, leadingBottom: PaneID, trailingTop: PaneID, trailingBottom: PaneID) {
        let coordinator = PaneCoordinator()
        var duplicates = (1...5).map { StubReaderSession(id: TabID(), title: "Duplicate \($0).pdf") }
        coordinator.configureDuplication { _ in duplicates.removeFirst() }
        #expect(coordinator.insert(StubReaderSession(id: TabID(), title: "Origin.pdf"), into: .createIfEmpty))
        let trailingTop = try! #require(coordinator.split(direction: .sideBySide))
        let leadingTop = try! #require(coordinator.snapshot.layout.paneIDs.first { $0 != trailingTop })
        #expect(coordinator.activatePane(leadingTop))
        let leadingBottom = try! #require(coordinator.split(direction: .stacked))
        #expect(coordinator.activatePane(trailingTop))
        let trailingBottom = try! #require(coordinator.split(direction: .stacked))
        return (coordinator, leadingTop, leadingBottom, trailingTop, trailingBottom)
    }
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-pane-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func descendantPDFViews(in view: NSView) -> [PDFView] {
        let own = (view as? PDFView).map { [$0] } ?? []
        return own + view.subviews.flatMap(descendantPDFViews(in:))
    }

    private func drainPDFKit() {
        autoreleasepool {}
        for _ in 0..<3 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func assertReleased(_ references: WeakSessionObjects) {
        #expect(references.session.value == nil)
        #expect(references.view.value == nil)
        #expect(references.document.value == nil)
        #expect(references.search.value == nil)
    }
}



extension StubReaderSession: ReaderDuplicationSnapshotProviding {
    var duplicationSnapshot: ReaderDuplicationSnapshot {
        ReaderDuplicationSnapshot(
            sourceURL: URL(fileURLWithPath: "/tmp/\(title)"),
            oneBasedPage: page,
            viewMode: .manual,
            scaleFactor: zoom
        )
    }
}


private final class WeakObject<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

@MainActor
private final class PaneSearchLifecycleSpy: ReaderSearchLifecycle {
    func requestCancellation() {}
    func detachCallbacks() {}
    func clearHighlights() {}
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private enum FourPaneClosePath {
    case rowCollapse
    case columnCollapse
    case globalUnsplit
}

private struct WeakSessionObjects {
    let session: WeakObject<ReaderSession>
    let view: WeakObject<PDFView>
    let document: WeakObject<PDFDocument>
    let search: WeakObject<PaneSearchLifecycleSpy>

    init(session: ReaderSession, view: PDFView, document: PDFDocument, search: PaneSearchLifecycleSpy) {
        self.session = WeakObject(session)
        self.view = WeakObject(view)
        self.document = WeakObject(document)
        self.search = WeakObject(search)
    }
}
