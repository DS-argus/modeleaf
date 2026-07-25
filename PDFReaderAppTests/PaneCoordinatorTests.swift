import Testing
import Foundation
@testable import PDFReaderApp
import PDFReaderCore

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
        let duplicate = StubReaderSession(id: TabID(), title: "Origin.pdf", page: 1, zoom: 1)
        coordinator.configureDuplication { snapshot in
            #expect(snapshot.oneBasedPage == 4)
            #expect(snapshot.viewMode == .manual)
            #expect(snapshot.scaleFactor == 1.5)
            return duplicate
        }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        let destination = try! #require(coordinator.split(direction: .sideBySide))
        #expect(coordinator.snapshot.layout == .split(orientation: .sideBySide, leadingOrTop: coordinator.snapshot.panes.keys.first(where: { $0 != destination })!, trailingOrBottom: destination))
        #expect(coordinator.activePaneID == destination)
        #expect(coordinator.store(for: destination)?.snapshot.tabs.map(\.id) == [duplicate.id])
        #expect(coordinator.split(direction: .stacked) == nil)
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
