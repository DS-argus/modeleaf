import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("ReaderSessionStore ownership and isolation")
@MainActor
struct ReaderSessionStoreTests {
    @Test("U-TAB-03 session state remains isolated while the active tab changes")
    func sessionStateIsIsolated() throws {
        let store = ReaderSessionStore()
        let first = StubReaderSession(id: fixedID(1), title: "First.pdf", page: 2, zoom: 1.25)
        let second = StubReaderSession(id: fixedID(2), title: "Second.pdf", page: 8, zoom: 0.90)

        #expect(store.insert(first))
        #expect(store.insert(second))
        #expect(store.activeSession?.id == second.id)

        #expect(store.activate(first.id))
        first.page = 7
        first.zoom = 1.50
        first.searchQuery = "alpha"
        store.sessionDidChange(first.id)

        #expect(store.activeSession?.id == first.id)
        #expect(first.page == 7)
        #expect(first.zoom == 1.50)
        #expect(first.searchQuery == "alpha")
        #expect(second.page == 8)
        #expect(second.zoom == 0.90)
        #expect(second.searchQuery.isEmpty)
    }

    @Test("U-TAB-04 snapshots derive titles, order, and active state from owned sessions plus TabStore")
    func snapshotsAreFirstClassTabState() {
        let store = ReaderSessionStore()
        let first = StubReaderSession(id: fixedID(1), title: "Reference.pdf")
        let second = StubReaderSession(id: fixedID(2), title: "Notes.pdf")
        var snapshots: [ReaderSessionStoreSnapshot] = []
        store.onChange = { snapshots.append($0) }

        #expect(store.insert(first))
        #expect(store.insert(second))
        #expect(store.activate(first.id))

        let snapshot = store.snapshot
        #expect(snapshot.tabs == [
            ReaderTabSnapshot(id: first.id, title: "Reference.pdf"),
            ReaderTabSnapshot(id: second.id, title: "Notes.pdf"),
        ])
        #expect(snapshot.activeID == first.id)
        #expect(snapshots.last == snapshot)
    }

    @Test("one-based tab ordinals activate existing tabs and ignore missing ordinals")
    func activatesTabOrdinal() {
        let store = ReaderSessionStore()
        let first = StubReaderSession(id: fixedID(1), title: "First.pdf")
        let second = StubReaderSession(id: fixedID(2), title: "Second.pdf")
        let third = StubReaderSession(id: fixedID(3), title: "Third.pdf")
        #expect(store.insert(first))
        #expect(store.insert(second))
        #expect(store.insert(third))

        #expect(store.activateTab(atOneBasedOrdinal: 1))
        #expect(store.activeSession?.id == first.id)
        #expect(!store.activateTab(atOneBasedOrdinal: 1))
        #expect(!store.activateTab(atOneBasedOrdinal: 0))
        #expect(!store.activateTab(atOneBasedOrdinal: 4))
        #expect(store.activeSession?.id == first.id)
    }

    @Test("closing calls ordered teardown once and final close returns the store to empty")
    func closeOrdersTeardownAndReturnsEmpty() {
        let store = ReaderSessionStore()
        let first = StubReaderSession(id: fixedID(1), title: "First.pdf")
        let second = StubReaderSession(id: fixedID(2), title: "Second.pdf")
        #expect(store.insert(first))
        #expect(store.insert(second))

        #expect(store.close(second.id))
        #expect(second.prepareForCloseCount == 1)
        #expect(store.activeSession?.id == first.id)
        #expect(store.closeActive())
        #expect(first.prepareForCloseCount == 1)
        #expect(store.snapshot.isEmpty)
        #expect(store.activeSession == nil)
        #expect(!store.closeActive())
    }

    @Test("the presentation layer can release a closed session because the store is its lifetime owner")
    func closedSessionCanDeallocate() {
        let store = ReaderSessionStore()
        var session: StubReaderSession? = StubReaderSession(id: fixedID(1), title: "Ephemeral.pdf")
        let weakBox = WeakBox(session)
        #expect(store.insert(session!))

        #expect(store.close(session!.id))
        session = nil

        #expect(weakBox.value == nil)
    }

    private func fixedID(_ value: Int) -> TabID {
        TabID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
    }
}

@MainActor
final class StubReaderSession: ReaderSessionPresenting {
    let id: TabID
    let title: String
    let contentView: NSView
    var page: Int
    var zoom: Double
    var searchQuery = ""
    private(set) var prepareForCloseCount = 0
    private var presentationChangeHandler: (() -> Void)?

    init(id: TabID, title: String, page: Int = 1, zoom: Double = 1.0) {
        self.id = id
        self.title = title
        self.page = page
        self.zoom = zoom
        self.contentView = StoreFocusableTestView()
        contentView.setAccessibilityIdentifier("pdfCanvas")
    }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(
            context: searchQuery.isEmpty ? "NORMAL" : "SEARCH",
            page: "\(page) / 10",
            zoom: "\(Int((zoom * 100).rounded()))%",
            detail: searchQuery.isEmpty ? title : "search: \(searchQuery)"
        )
    }

    func setPresentationChangeHandler(_ handler: (() -> Void)?) {
        presentationChangeHandler = handler
    }

    func publishPresentationChange() {
        presentationChangeHandler?()
    }

    func prepareForClose() {
        prepareForCloseCount += 1
    }
}

@MainActor
final class StoreFocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
