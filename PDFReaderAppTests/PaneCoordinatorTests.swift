import AppKit
import Foundation
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp
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
        #expect(coordinator.snapshot.layout == .split(leading: .one(coordinator.snapshot.panes.keys.first(where: { $0 != destination })!), trailing: .one(destination)))
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
                case (.singleOne, _), (.singleTwo, .sideBySide), (.splitOneOne, .stacked), (.splitOneTwo, .stacked): true
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
            snapshot.layout == .single(.one(survivor)) && snapshot.activeID == origin.id
        })
        #expect(coordinator.snapshot.layout == .single(.one(survivor)))
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
                    #expect(coordinator.snapshot.layout == .split(leading: .two(top: leadingTop, bottom: leadingBottom), trailing: .two(top: trailingTop, bottom: trailingBottom)))

                    let removed: [WeakSessionObjects]
                    switch path {
                    case .rowCollapse:
                        #expect(coordinator.closeActiveTab())
                        removed = [references[trailingBottom]!]
                        #expect(coordinator.snapshot.layout == .split(leading: .two(top: leadingTop, bottom: leadingBottom), trailing: .one(trailingTop)))
                        #expect(coordinator.store(for: trailingTop)?.activeSession != nil)
                    case .columnCollapse:
                        #expect(coordinator.closeActiveTab())
                        #expect(coordinator.activatePane(trailingTop))
                        #expect(coordinator.closeActiveTab())
                        removed = [references[trailingBottom]!, references[trailingTop]!]
                        #expect(coordinator.snapshot.layout == .single(.two(top: leadingTop, bottom: leadingBottom)))
                        #expect(coordinator.store(for: leadingTop)?.activeSession != nil)
                    case .globalUnsplit:
                        #expect(coordinator.activatePane(leadingTop))
                        #expect(coordinator.unsplit())
                        removed = [references[trailingTop]!, references[leadingBottom]!, references[trailingBottom]!]
                        #expect(coordinator.snapshot.layout == .single(.one(leadingTop)))
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

    @Test("cross-column focus remembers each column row while vertical focus stays column-internal")
    func rememberedFocusRows() throws {
        let coordinator = PaneCoordinator()
        var duplicates = (1...3).map { StubReaderSession(id: TabID(), title: "Duplicate \($0).pdf") }
        coordinator.configureDuplication { _ in duplicates.removeFirst() }
        #expect(coordinator.insert(StubReaderSession(id: TabID(), title: "Origin.pdf"), into: .createIfEmpty))
        let trailingTop = try #require(coordinator.split(direction: .sideBySide))
        let leadingTop = try #require(coordinator.snapshot.layout.paneIDs.first { $0 != trailingTop })
        #expect(coordinator.activatePane(leadingTop))
        let leadingBottom = try #require(coordinator.split(direction: .stacked))
        #expect(coordinator.focus(.right))
        let trailingBottom = try #require(coordinator.split(direction: .stacked))
        #expect(coordinator.focus(.left))
        #expect(coordinator.activePaneID == leadingBottom)
        #expect(coordinator.focus(.up))
        #expect(coordinator.activePaneID == leadingTop)
        #expect(coordinator.focus(.right))
        #expect(coordinator.activePaneID == trailingBottom)
        #expect(!coordinator.focus(.right))
        #expect(coordinator.focus(.left))
        #expect(coordinator.activePaneID == leadingTop)
        #expect(!coordinator.focus(.up))
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
            PaneLayout.split(leading: .two(top: leadingTop, bottom: leadingBottom), trailing: .two(top: trailingTop, bottom: trailingBottom)),
            .split(leading: .two(top: leadingTop, bottom: leadingBottom), trailing: .one(trailingTop)),
            .single(.two(top: leadingTop, bottom: leadingBottom)),
            .single(.one(leadingTop)),
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
        #expect(carried.coordinator.snapshot.layout == .single(.two(top: carried.trailingTop, bottom: carried.trailingBottom)))
        let newTrailing = try #require(carried.coordinator.split(direction: .sideBySide))
        #expect(carried.coordinator.focus(.left))
        #expect(carried.coordinator.activePaneID == carried.trailingBottom)
        #expect(carried.coordinator.focus(.right))
        #expect(carried.coordinator.activePaneID == newTrailing)

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
