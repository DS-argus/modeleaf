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


    @Test("split creates and activates a duplicate pane, then enforces the two-pane limit")
    func splitAndLimit() {
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

    @Test("collapse and unsplit release closed PDFKit sessions and search owners")
    func projectedPaneTeardownReleasesAllOwnedObjects() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            for path in [ClosePath.collapse, .unsplit] {
                var weakSession: WeakObject<ReaderSession>?
                var weakView: WeakObject<PDFView>?
                var weakDocument: WeakObject<PDFDocument>?
                var weakSearch: WeakObject<PaneSearchLifecycleSpy>?
                autoreleasepool {
                    let coordinator = PaneCoordinator()
                    #expect(coordinator.insert(try! PDFOpenService().open(url: url), into: .createIfEmpty))
                    coordinator.configureDuplication { _ in
                        let document = PDFDocument(url: url)!
                        let search = PaneSearchLifecycleSpy()
                        let session = ReaderSession(sourceURL: url, document: document, searchLifecycle: search)
                        weakSession = WeakObject(session)
                        weakView = WeakObject(descendantPDFViews(in: session.contentView).only!)
                        weakDocument = WeakObject(document)
                        weakSearch = WeakObject(search)
                        return session
                    }
                    #expect(coordinator.split(direction: .sideBySide) != nil)

                    switch path {
                    case .collapse:
                        #expect(coordinator.closeActiveTab())
                    case .unsplit:
                        #expect(coordinator.focus(.left))
                        #expect(coordinator.unsplit())
                    }
                    while coordinator.closeActiveTab() {}
                }
                drainPDFKit()
                #expect(weakSession?.value == nil)
                #expect(weakView?.value == nil)
                #expect(weakDocument?.value == nil)
                #expect(weakSearch?.value == nil)
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

private enum ClosePath {
    case collapse
    case unsplit
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
