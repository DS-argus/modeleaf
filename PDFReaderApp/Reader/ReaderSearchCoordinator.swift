import AppKit
import PDFKit

enum ReaderSearchCoordinatorState: Equatable, Sendable { case idle; case running(query: String, generation: UInt64); case cancelling(query: String, generation: UInt64, pendingLatest: String?) }
struct ReaderSearchSnapshot: Equatable, Sendable { var query: String; var matchCount: Int; var activeMatchIndex: Int?; var isRunning: Bool; var emptyResult: ReaderSearchEmptyResult? = nil; static let empty = ReaderSearchSnapshot(query: "", matchCount: 0, activeMatchIndex: nil, isRunning: false); var isActive: Bool { !query.isEmpty }; var activeMatchNumber: Int? { activeMatchIndex.map { $0 + 1 } } }
enum ReaderSearchEmptyResult: Equatable, Sendable { case noMatch; case noSearchableText }
enum ReaderSearchResultDisplayOutcome: Equatable, Sendable { case displayedDistinct; case displayedSame; case failed }
struct SearchHighlightPalette { var allResults: NSColor; var activeResult: NSColor; static let `default` = SearchHighlightPalette(allResults: .systemYellow.withAlphaComponent(0.58), activeResult: .systemOrange.withAlphaComponent(0.88)) }
@MainActor protocol ReaderSearchDriverSink: AnyObject { func searchDriverDidBegin(generation: UInt64); func searchDriverDidMatch(_ selection: PDFSelection, generation: UInt64); func searchDriverDidEnd(generation: UInt64) }
@MainActor protocol ReaderSearchDriving: AnyObject { var sink: (any ReaderSearchDriverSink)? { get set }; func begin(query: String, generation: UInt64); func cancel(generation: UInt64); func detach() }
@MainActor protocol ReaderSearchResultPresenting: AnyObject { @discardableResult func presentSearchResults(_ selections: [PDFSelection], activeIndex: Int?) -> ReaderSearchResultDisplayOutcome; @discardableResult func activateSearchResult(at index: Int) -> ReaderSearchResultDisplayOutcome; func clearSearchResults() }
@MainActor protocol ReaderSearchReplacementScheduling: AnyObject { func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) }
@MainActor private final class MainQueueSearchReplacementScheduler: ReaderSearchReplacementScheduling { func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) { DispatchQueue.main.async(execute: operation) } }
@MainActor protocol ReaderSearchControlling: ReaderSearchLifecycle { var snapshot: ReaderSearchSnapshot { get }; func setChangeHandler(_ handler: (() -> Void)?); func request(_ query: String); @discardableResult func selectNext() -> Bool; @discardableResult func selectPrevious() -> Bool; func clear() }

@MainActor final class ReaderSearchCoordinator: ReaderSearchControlling, ReaderSearchDriverSink {
    private let driver: any ReaderSearchDriving
    private let presenter: any ReaderSearchResultPresenting
    private let scheduler: any ReaderSearchReplacementScheduling
    private var changeHandler: (() -> Void)?
    private var activateNavigation: ((Int) -> SearchNavigationActivationOutcome)?
    private var recordNavigationLanding: ((Int) -> SearchNavigationActivationOutcome)?
    private var resultGeneration: UInt64?
    private var nextGeneration: UInt64 = 0
    private var transitionToken: UInt64 = 0
    private var matches: [PDFSelection] = []
    private var isDetached = false
    private(set) var state: ReaderSearchCoordinatorState = .idle
    private(set) var snapshot: ReaderSearchSnapshot = .empty
    private(set) var ignoredCallbackCount = 0

    init(driver: any ReaderSearchDriving, presenter: any ReaderSearchResultPresenting, scheduler: any ReaderSearchReplacementScheduling = MainQueueSearchReplacementScheduler()) { self.driver = driver; self.presenter = presenter; self.scheduler = scheduler; driver.sink = self }
    func configureNavigation(activate: @escaping (Int) -> SearchNavigationActivationOutcome, recordLanding: @escaping (Int) -> SearchNavigationActivationOutcome) { activateNavigation = activate; recordNavigationLanding = recordLanding }
    func setChangeHandler(_ handler: (() -> Void)?) { changeHandler = handler }
    func request(_ query: String) { guard !isDetached else { return }; transitionToken &+= 1; resultGeneration = nil; snapshot.query = query; snapshot.matchCount = 0; snapshot.activeMatchIndex = nil; snapshot.isRunning = true; snapshot.emptyResult = nil; matches.removeAll(keepingCapacity: true); presenter.clearSearchResults(); publishChange(); switch state { case .idle: start(query); case .running, .cancelling: transitionToCancellation(pendingLatest: query) } }
    @discardableResult func selectNext() -> Bool { select(offset: 1) }
    @discardableResult func selectPrevious() -> Bool { select(offset: -1) }
    func clear() { guard !isDetached else { return }; transitionToken &+= 1; resultGeneration = nil; snapshot = .empty; matches.removeAll(keepingCapacity: false); presenter.clearSearchResults(); transitionToCancellation(pendingLatest: nil); publishChange() }
    func requestCancellation() { guard !isDetached else { return }; transitionToken &+= 1; resultGeneration = nil; snapshot.isRunning = false; transitionToCancellation(pendingLatest: nil) }
    func detachCallbacks() { guard !isDetached else { return }; transitionToken &+= 1; isDetached = true; resultGeneration = nil; driver.sink = nil; driver.detach(); state = .idle; changeHandler = nil }
    func clearHighlights() { resultGeneration = nil; snapshot = .empty; matches.removeAll(keepingCapacity: false); presenter.clearSearchResults() }
    func searchDriverDidBegin(generation: UInt64) { if !accepts(generation) { ignoredCallbackCount += 1 } }
    func searchDriverDidMatch(_ selection: PDFSelection, generation: UInt64) { guard case let .running(_, active) = state, active == generation, !isDetached else { ignoredCallbackCount += 1; return }; matches.append(selection); snapshot.matchCount = matches.count; snapshot.emptyResult = nil }
    func searchDriverDidEnd(generation: UInt64) {
        guard !isDetached else { ignoredCallbackCount += 1; return }
        switch state {
        case let .running(_, active) where active == generation:
            state = .idle; snapshot.isRunning = false
            guard !matches.isEmpty else { publishChange(); return }
            resultGeneration = generation
            if presentInitialResult(generation: generation) != .failed { snapshot.activeMatchIndex = 0 }
            publishChange()
        case let .cancelling(_, active, pending) where active == generation:
            state = .idle; guard let pending else { snapshot.isRunning = false; publishChange(); return }; let token = transitionToken; scheduler.schedule { [weak self] in self?.startPendingIfCurrent(pending, token: token) }
        default: ignoredCallbackCount += 1
        }
    }
    private func accepts(_ generation: UInt64) -> Bool { guard !isDetached else { return false }; switch state { case let .running(_, active), let .cancelling(_, active, _): return active == generation; case .idle: return false } }
    private func start(_ query: String) { nextGeneration &+= 1; let generation = nextGeneration; state = .running(query: query, generation: generation); snapshot.query = query; snapshot.isRunning = true; driver.begin(query: query, generation: generation) }
    private func startPendingIfCurrent(_ query: String, token: UInt64) { guard !isDetached, transitionToken == token, state == .idle, snapshot.query == query else { return }; start(query) }
    private func transitionToCancellation(pendingLatest: String?) { switch state { case .idle: break; case let .running(query, generation): state = .cancelling(query: query, generation: generation, pendingLatest: pendingLatest); driver.cancel(generation: generation); case let .cancelling(query, generation, _): state = .cancelling(query: query, generation: generation, pendingLatest: pendingLatest) } }
    private func historyRecordingIsArmed(for generation: UInt64) -> Bool { guard let activateNavigation else { return true }; switch activateNavigation(Int(generation)) { case .armed, .retagged: return true; default: return false } }
    private func recordDistinctLanding(for generation: UInt64, isArmed: Bool, outcome: ReaderSearchResultDisplayOutcome) { guard isArmed, outcome == .displayedDistinct else { return }; _ = recordNavigationLanding?(Int(generation)) }
    private func presentInitialResult(generation: UInt64) -> ReaderSearchResultDisplayOutcome {
        let isArmed = historyRecordingIsArmed(for: generation)
        let outcome = presenter.presentSearchResults(matches, activeIndex: 0)
        recordDistinctLanding(for: generation, isArmed: isArmed, outcome: outcome)
        return outcome
    }
    private func select(offset: Int) -> Bool {
        guard !matches.isEmpty, let generation = resultGeneration else { return false }
        let current = snapshot.activeMatchIndex ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + matches.count) % matches.count
        let isArmed = historyRecordingIsArmed(for: generation)
        let outcome = presenter.activateSearchResult(at: next)
        guard outcome != .failed else { return false }
        snapshot.activeMatchIndex = next
        recordDistinctLanding(for: generation, isArmed: isArmed, outcome: outcome)
        publishChange()
        return true
    }
    private func publishChange() { changeHandler?() }
}

@MainActor final class PDFKitSearchDriver: NSObject, ReaderSearchDriving, @preconcurrency PDFDocumentDelegate {
    weak var sink: (any ReaderSearchDriverSink)?; private let document: PDFDocument; private var activeGeneration: UInt64?
    init(document: PDFDocument) { self.document = document; super.init(); document.delegate = self }
    func begin(query: String, generation: UInt64) { guard activeGeneration == nil else { preconditionFailure("PDFKit searches must be serialized across end callbacks") }; activeGeneration = generation; document.beginFindString(query, withOptions: [.caseInsensitive, .literal]) }
    func cancel(generation: UInt64) { guard activeGeneration == generation else { return }; document.cancelFindString() }
    func detach() { if document.delegate === self { document.delegate = nil }; activeGeneration = nil; sink = nil }
    func documentDidBeginDocumentFind(_ notification: Notification) { if let activeGeneration { sink?.searchDriverDidBegin(generation: activeGeneration) } }
    func didMatchString(_ instance: PDFSelection) { if let activeGeneration { sink?.searchDriverDidMatch(instance, generation: activeGeneration) } }
    func documentDidEndDocumentFind(_ notification: Notification) { guard let generation = activeGeneration else { return }; activeGeneration = nil; sink?.searchDriverDidEnd(generation: generation) }
}
