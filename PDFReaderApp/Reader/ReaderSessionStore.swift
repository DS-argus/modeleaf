import AppKit
import PDFReaderCore

struct ReaderStatusSnapshot: Equatable {
    var context: String
    var page: String
    var zoom: String
    var detail: String

    static let empty = ReaderStatusSnapshot(
        context: "NORMAL",
        page: "— / —",
        zoom: "100%",
        detail: "Ready"
    )
}

@MainActor
protocol ReaderSessionPresenting: AnyObject {
    var id: TabID { get }
    var title: String { get }
    var contentView: NSView { get }
    var focusView: NSView { get }
    var statusSnapshot: ReaderStatusSnapshot { get }
    var pageCount: Int { get }
    var searchSnapshot: ReaderSearchSnapshot { get }
    var preferredInputContext: InputContext { get }

    func setPresentationChangeHandler(_ handler: (() -> Void)?)
    func scrollBy(xPoints: Double, yPoints: Double)
    func scrollVerticallyByViewportFraction(_ fraction: Double)
    @discardableResult func goToPage(_ oneBasedPage: Int) -> Bool
    @discardableResult func goToNextPage() -> Bool
    @discardableResult func goToPreviousPage() -> Bool
    @discardableResult func goToFirstPage() -> Bool
    @discardableResult func goToLastPage() -> Bool
    func zoom(by factor: Double)
    func resetZoom()
    func fitWidth()
    func fitPage()
    func beginSearch(_ query: String)
    @discardableResult func selectNextSearchResult() -> Bool
    @discardableResult func selectPreviousSearchResult() -> Bool
    func clearSearch()
    func prepareForClose()
}

extension ReaderSessionPresenting {
    var focusView: NSView { contentView }
    var pageCount: Int { 0 }
    var searchSnapshot: ReaderSearchSnapshot { .empty }
    var preferredInputContext: InputContext { searchSnapshot.isActive ? .searchResults : .navigation }

    func setPresentationChangeHandler(_ handler: (() -> Void)?) {}
    func scrollBy(xPoints: Double, yPoints: Double) {}
    func scrollVerticallyByViewportFraction(_ fraction: Double) {}
    func goToPage(_ oneBasedPage: Int) -> Bool { false }
    func goToNextPage() -> Bool { false }
    func goToPreviousPage() -> Bool { false }
    func goToFirstPage() -> Bool { false }
    func goToLastPage() -> Bool { false }
    func zoom(by factor: Double) {}
    func resetZoom() {}
    func fitWidth() {}
    func fitPage() {}
    func beginSearch(_ query: String) {}
    func selectNextSearchResult() -> Bool { false }
    func selectPreviousSearchResult() -> Bool { false }
    func clearSearch() {}
}

struct ReaderTabSnapshot: Equatable {
    let id: TabID
    let title: String
}

struct ReaderSessionStoreSnapshot: Equatable {
    let tabs: [ReaderTabSnapshot]
    let activeID: TabID?

    var isEmpty: Bool { tabs.isEmpty }
}

@MainActor
final class ReaderSessionStore {
    private var tabStore = TabStore()
    private var sessionsByID: [TabID: any ReaderSessionPresenting] = [:]

    var onChange: ((ReaderSessionStoreSnapshot) -> Void)?

    var snapshot: ReaderSessionStoreSnapshot {
        ReaderSessionStoreSnapshot(
            tabs: tabStore.orderedIDs.compactMap { id in
                sessionsByID[id].map { ReaderTabSnapshot(id: id, title: $0.title) }
            },
            activeID: tabStore.activeID
        )
    }

    var activeSession: (any ReaderSessionPresenting)? {
        tabStore.activeID.flatMap { sessionsByID[$0] }
    }

    var sessionCount: Int { tabStore.orderedIDs.count }

    @discardableResult
    func insert(_ session: any ReaderSessionPresenting) -> Bool {
        guard sessionsByID[session.id] == nil, tabStore.insert(session.id) else { return false }
        sessionsByID[session.id] = session
        session.setPresentationChangeHandler { [weak self, id = session.id] in
            self?.sessionDidChange(id)
        }
        publishChange()
        return true
    }

    func session(for id: TabID) -> (any ReaderSessionPresenting)? {
        sessionsByID[id]
    }

    @discardableResult
    func activate(_ id: TabID) -> Bool {
        guard tabStore.activate(id) else { return false }
        publishChange()
        return true
    }

    @discardableResult
    func activateNext() -> TabID? {
        let previous = tabStore.activeID
        let active = tabStore.activateNext()
        if active != previous { publishChange() }
        return active
    }

    @discardableResult
    func activatePrevious() -> TabID? {
        let previous = tabStore.activeID
        let active = tabStore.activatePrevious()
        if active != previous { publishChange() }
        return active
    }

    @discardableResult
    func closeActive() -> Bool {
        guard let activeID = tabStore.activeID else { return false }
        return close(activeID)
    }

    @discardableResult
    func close(_ id: TabID) -> Bool {
        guard let session = sessionsByID[id] else { return false }
        session.setPresentationChangeHandler(nil)
        session.prepareForClose()
        guard tabStore.close(id) else {
            preconditionFailure("ReaderSessionStore and TabStore diverged for \(id)")
        }
        sessionsByID.removeValue(forKey: id)
        publishChange()
        return true
    }

    func sessionDidChange(_ id: TabID) {
        guard sessionsByID[id] != nil else { return }
        publishChange()
    }

    private func publishChange() {
        onChange?(snapshot)
    }
}
