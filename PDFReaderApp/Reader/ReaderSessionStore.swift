import AppKit
import PDFReaderCore

struct ReaderStatusSnapshot: Equatable {
    var context: String
    var page: String
    var zoom: String
    var detail: String
    var mode: String = ""
    static let empty = ReaderStatusSnapshot(context: "NORMAL", page: "— / —", zoom: "100%", detail: "Ready")
}

@MainActor
protocol ReaderDuplicateValidating: AnyObject {
    func configureDuplicateValidation(_ handler: @escaping (Bool) -> Void)
}
@MainActor
protocol ReaderSessionPresenting: ReaderNavigationHistoryPresenting {
    var id: TabID { get }
    var title: String { get }
    var sourceURL: URL { get }
    var contentView: NSView { get }
    var focusView: NSView { get }
    var statusSnapshot: ReaderStatusSnapshot { get }
    var pageCount: Int { get }
    var searchSnapshot: ReaderSearchSnapshot { get }
    var preferredInputContext: InputContext { get }

    var outlineSnapshot: ReaderOutlineSnapshot { get }
    @discardableResult func activateOutlineRow(id: ReaderOutlineRowID) -> NavigationTransactionOutcome
    func setPresentationChangeHandler(_ handler: (() -> Void)?)
    func applyTheme(_ theme: AppKitTheme)
    func applyLinkDestinationIndicatorSettings(_ configuration: LinkDestinationIndicatorSettings)
    func scrollBy(xPoints: Double, yPoints: Double)
    func scrollVerticallyByViewportFraction(_ fraction: Double)
    func moveHorizontally(byPoints points: Double)
    func moveVertically(byPoints points: Double)
    func moveVertically(byViewportFraction fraction: Double)
    @discardableResult func goToPage(_ oneBasedPage: Int) -> Bool
    @discardableResult func goToNextPage() -> Bool
    @discardableResult func goToPreviousPage() -> Bool
    @discardableResult func goToFirstPage() -> Bool
    @discardableResult func goToLastPage() -> Bool
    func zoom(by factor: Double)
    func resetZoom()
    func fitWidth()
    func fitPage()
    func rotateLeft()
    func rotateRight()
    @discardableResult func printDocument() -> Bool
    func beginSearch(_ query: String)
    @discardableResult func selectNextSearchResult() -> Bool
    @discardableResult func selectPreviousSearchResult() -> Bool
    func clearSearch()
    func prepareForClose()
}

extension ReaderSessionPresenting {
    var focusView: NSView { contentView }
    var pageCount: Int { 0 }
    func scrollBy(xPoints: Double, yPoints: Double) {}
    func zoom(by factor: Double) {}
    var searchSnapshot: ReaderSearchSnapshot { .empty }
    var outlineSnapshot: ReaderOutlineSnapshot { .empty }
    func activateOutlineRow(id: ReaderOutlineRowID) -> NavigationTransactionOutcome { .preflightRejected }
    var preferredInputContext: InputContext { searchSnapshot.isActive ? .searchResults : .navigation }
    func setPresentationChangeHandler(_ handler: (() -> Void)?) {}
    func resetZoom() {}
    func applyLinkDestinationIndicatorSettings(_ configuration: LinkDestinationIndicatorSettings) {}
    func fitWidth() {}
    func fitPage() {}
    func rotateLeft() {}
    func rotateRight() {}
    func printDocument() -> Bool { false }
    func scrollVerticallyByViewportFraction(_ fraction: Double) {}
    func moveHorizontally(byPoints points: Double) { scrollBy(xPoints: points, yPoints: 0) }
    func moveVertically(byPoints points: Double) { scrollBy(xPoints: 0, yPoints: points) }
    func moveVertically(byViewportFraction fraction: Double) { scrollVerticallyByViewportFraction(fraction) }
    func goToPage(_ oneBasedPage: Int) -> Bool { false }
    func beginSearch(_ query: String) {}
    func selectNextSearchResult() -> Bool { false }
    func selectPreviousSearchResult() -> Bool { false }
    func clearSearch() {}
    func prepareForClose() {}
    func goToNextPage() -> Bool { false }
    func goToPreviousPage() -> Bool { false }
    func goToFirstPage() -> Bool { false }
    func goToLastPage() -> Bool { false }
}

@MainActor
protocol ReaderNavigationHistoryPresenting: AnyObject {
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var isNavigationHistoryHealthy: Bool { get }
    var navigationAvailabilityDetail: String { get }
    @discardableResult func goBack() -> NavigationTransactionOutcome
    @discardableResult func goForward() -> NavigationTransactionOutcome
    func setNavigationOutcomeHandler(_ handler: ((NavigationTransactionOutcome) -> Void)?)
}

@MainActor
extension ReaderNavigationHistoryPresenting {
    func setNavigationOutcomeHandler(_ handler: ((NavigationTransactionOutcome) -> Void)?) {}
}


struct ReaderTabSnapshot: Equatable { let id: TabID; let title: String }; struct ReaderSessionStoreSnapshot: Equatable { let tabs: [ReaderTabSnapshot]; let activeID: TabID?; var isEmpty: Bool { tabs.isEmpty } }; struct PreparedTabClose: Equatable { let closingTab: TabID; let closingIndex: Int; let priorSelection: TabID?; let projectedSelection: TabID? }
@MainActor final class ReaderSessionStore { private var tabStore = TabStore(); private var sessionsByID: [TabID: any ReaderSessionPresenting] = [:]; private var changeHandler: ((ReaderSessionStoreSnapshot) -> Void)?
    var onChange: ((ReaderSessionStoreSnapshot) -> Void)? { get { changeHandler } set { precondition(changeHandler == nil || newValue == nil, "ReaderSessionStore change handler is coordinator-owned"); changeHandler = newValue } }; func registerChangeHandler(_ handler: @escaping (ReaderSessionStoreSnapshot) -> Void) { precondition(changeHandler == nil, "ReaderSessionStore change handler is coordinator-owned"); changeHandler = handler }
    var snapshot: ReaderSessionStoreSnapshot { ReaderSessionStoreSnapshot(tabs: tabStore.orderedIDs.compactMap { sessionsByID[$0].map { ReaderTabSnapshot(id: $0.id, title: $0.title) } }, activeID: tabStore.activeID) }; var activeSession: (any ReaderSessionPresenting)? { tabStore.activeID.flatMap { sessionsByID[$0] } }; var sessionCount: Int { tabStore.orderedIDs.count }
    var activeOutlineSnapshot: ReaderOutlineSnapshot? { activeSession?.outlineSnapshot }
    @discardableResult func activateOutlineRow(id: ReaderOutlineRowID) -> NavigationTransactionOutcome { activeSession?.activateOutlineRow(id: id) ?? .unavailable }
    @discardableResult func insert(_ session: any ReaderSessionPresenting) -> Bool { guard sessionsByID[session.id] == nil, tabStore.insert(session.id) else { return false }; sessionsByID[session.id] = session; session.setPresentationChangeHandler { [weak self, id = session.id] in self?.sessionDidChange(id) }; publishChange(); return true }; func session(for id: TabID) -> (any ReaderSessionPresenting)? { sessionsByID[id] }
    func applyTheme(_ theme: AppKitTheme) { sessionsByID.values.forEach { $0.applyTheme(theme) } }
    func applyLinkDestinationIndicatorSettings(_ configuration: LinkDestinationIndicatorSettings) { sessionsByID.values.forEach { $0.applyLinkDestinationIndicatorSettings(configuration) } }
    @discardableResult func activate(_ id: TabID) -> Bool { guard tabStore.activate(id) else { return false }; publishChange(); return true }; @discardableResult func activateTab(atOneBasedOrdinal ordinal: Int) -> Bool { guard ordinal > 0, tabStore.activate(at: ordinal - 1) else { return false }; publishChange(); return true }; @discardableResult func activateNext() -> TabID? { let previous = tabStore.activeID; let active = tabStore.activateNext(); if active != previous { publishChange() }; return active }; @discardableResult func activatePrevious() -> TabID? { let previous = tabStore.activeID; let active = tabStore.activatePrevious(); if active != previous { publishChange() }; return active }; @discardableResult func closeActive() -> Bool { guard let activeID = tabStore.activeID else { return false }; return close(activeID) }
    @discardableResult func beginClose(_ id: TabID) -> PreparedTabClose? { guard sessionsByID[id] != nil, let closingIndex = tabStore.orderedIDs.firstIndex(of: id) else { return nil }; let priorSelection = tabStore.activeID; var projectedStore = tabStore; guard projectedStore.close(id) else { preconditionFailure("ReaderSessionStore and TabStore diverged for \(id)") }; let token = PreparedTabClose(closingTab: id, closingIndex: closingIndex, priorSelection: priorSelection, projectedSelection: projectedStore.activeID); tabStore = projectedStore; return token }
    @discardableResult func commitClose(_ token: PreparedTabClose) -> Bool { guard let session = sessionsByID[token.closingTab] else { return false }; session.setPresentationChangeHandler(nil); session.prepareForClose(); sessionsByID.removeValue(forKey: token.closingTab); publishChange(); return true }
    func rollbackClose(_ token: PreparedTabClose) { guard sessionsByID[token.closingTab] != nil else { return }; guard tabStore.insert(token.closingTab, at: token.closingIndex) else { preconditionFailure("ReaderSessionStore cannot restore a pending close") }; if let priorSelection = token.priorSelection { guard tabStore.activate(priorSelection) else { preconditionFailure("ReaderSessionStore cannot restore prior selection") } } }
    @discardableResult func close(_ id: TabID) -> Bool { guard let token = beginClose(id) else { return false }; return commitClose(token) }; func sessionDidChange(_ id: TabID) { guard sessionsByID[id] != nil else { return }; publishChange() }; private func publishChange() { changeHandler?(snapshot) }
}
