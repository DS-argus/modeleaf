import PDFKit
import Testing
@testable import PDFReaderApp

@Suite("Serialized per-session search coordinator")
@MainActor
struct ReaderSearchCoordinatorTests {
    @Test("I-SEARCH-01 replacement waits for end, latest wins, and stale generations are ignored")
    func serializedLatestReplacement() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let scheduler = DeterministicSearchScheduler()
        let coordinator = ReaderSearchCoordinator(
            driver: driver,
            presenter: presenter,
            scheduler: scheduler
        )

        coordinator.request("alpha")
        let firstGeneration = try #require(driver.generations.first)
        coordinator.request("beta")
        coordinator.request("gamma")

        #expect(driver.queries == ["alpha"])
        #expect(driver.cancelledGenerations == [firstGeneration])
        #expect(coordinator.state == .cancelling(
            query: "alpha",
            generation: firstGeneration,
            pendingLatest: "gamma"
        ))

        driver.emitMatch(selection(), generation: firstGeneration)
        #expect(coordinator.snapshot.matchCount == 0)
        driver.emitEnd(generation: firstGeneration)
        #expect(driver.queries == ["alpha"])
        #expect(scheduler.pendingCount == 1)

        scheduler.runNext()
        let secondGeneration = try #require(driver.generations.last)
        #expect(secondGeneration != firstGeneration)
        #expect(driver.queries == ["alpha", "gamma"])

        driver.emitMatch(selection(), generation: firstGeneration)
        driver.emitMatch(selection(), generation: secondGeneration)
        driver.emitEnd(generation: secondGeneration)

        #expect(coordinator.ignoredCallbackCount == 2)
        #expect(coordinator.snapshot == ReaderSearchSnapshot(
            query: "gamma",
            matchCount: 1,
            activeMatchIndex: 0,
            isRunning: false
        ))
        #expect(coordinator.state == .idle)
    }

    @Test("I-SEARCH-02 clear invalidates a replacement already deferred past the end callback")
    func clearInvalidatesDeferredReplacement() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let scheduler = DeterministicSearchScheduler()
        let coordinator = ReaderSearchCoordinator(
            driver: driver,
            presenter: presenter,
            scheduler: scheduler
        )

        coordinator.request("alpha")
        let generation = try #require(driver.generations.first)
        coordinator.request("beta")
        driver.emitEnd(generation: generation)
        #expect(scheduler.pendingCount == 1)

        coordinator.clear()
        scheduler.runNext()

        #expect(driver.queries == ["alpha"])
        #expect(coordinator.state == .idle)
        #expect(coordinator.snapshot == .empty)
        #expect(presenter.clearCount >= 3)
    }

    @Test("I-SEARCH-03 next and previous wrap across one active and all highlighted results")
    func resultNavigationWraps() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)

        coordinator.request("needle")
        let generation = try #require(driver.generations.first)
        driver.emitMatch(selection(), generation: generation)
        driver.emitMatch(selection(), generation: generation)
        driver.emitMatch(selection(), generation: generation)
        #expect(presenter.presentations.isEmpty)
        driver.emitEnd(generation: generation)

        #expect(coordinator.snapshot.activeMatchIndex == 0)
        #expect(presenter.presentations == [SearchPresentationRecord(count: 3, activeIndex: 0)])
        #expect(coordinator.selectNext())
        #expect(coordinator.snapshot.activeMatchIndex == 1)
        #expect(coordinator.selectNext())
        #expect(coordinator.snapshot.activeMatchIndex == 2)
        #expect(coordinator.selectNext())
        #expect(coordinator.snapshot.activeMatchIndex == 0)
        #expect(coordinator.selectPrevious())
        #expect(coordinator.snapshot.activeMatchIndex == 2)
        #expect(presenter.activations.last == 2)

        coordinator.clear()
        #expect(!coordinator.selectNext())
        #expect(coordinator.snapshot == .empty)
    }

    @Test("I-SEARCH-04 close cancellation detaches callbacks and clears result presentation")
    func closeLifecycleDetaches() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)

        coordinator.request("needle")
        let generation = try #require(driver.generations.first)
        coordinator.requestCancellation()
        coordinator.detachCallbacks()
        coordinator.clearHighlights()

        let ignoredBeforeLateCallbacks = coordinator.ignoredCallbackCount
        coordinator.searchDriverDidMatch(selection(), generation: generation)
        coordinator.searchDriverDidEnd(generation: generation)

        #expect(driver.cancelledGenerations == [generation])
        #expect(driver.detachCount == 1)
        #expect(driver.sink == nil)
        #expect(coordinator.state == .idle)
        #expect(coordinator.snapshot == .empty)
        #expect(presenter.presentations.isEmpty)
        #expect(presenter.activations.isEmpty)
        #expect(presenter.clearCount == 2)
        #expect(coordinator.ignoredCallbackCount == ignoredBeforeLateCallbacks + 2)
    }

    @Test("search results are accumulated and rendered once instead of quadratically")
    func resultPresentationIsBatched() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)

        coordinator.request("needle")
        let generation = try #require(driver.generations.first)
        for _ in 0..<300 {
            driver.emitMatch(selection(), generation: generation)
        }

        #expect(coordinator.snapshot.matchCount == 300)
        #expect(presenter.presentations.isEmpty)
        driver.emitEnd(generation: generation)
        #expect(presenter.presentations == [SearchPresentationRecord(count: 300, activeIndex: 0)])
    }
    @Test("current generation arms before first visible selection and coalesces subsequent landings")
    func navigationCallbacksAreGenerationScoped() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)
        var activations: [Int] = []
        var landings: [Int] = []
        coordinator.configureNavigation(
            activate: { generation in activations.append(generation); return .armed },
            recordLanding: { generation in landings.append(generation); return landings.count == 1 ? .firstCommitted : .coalesced }
        )
        coordinator.request("needle")
        let generation = try #require(driver.generations.first)
        driver.emitMatch(selection(), generation: generation)
        driver.emitMatch(selection(), generation: generation)
        driver.emitEnd(generation: generation)
        #expect(activations == [Int(generation)])
        #expect(landings == [Int(generation)])
        #expect(coordinator.selectNext())
        #expect(landings == [Int(generation), Int(generation)])
    }
    @Test("replacement retags navigation and stale callbacks never land")
    func replacementRetagsNavigationAndIgnoresStaleLanding() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let scheduler = DeterministicSearchScheduler()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter, scheduler: scheduler)
        var activated: [Int] = []
        var landed: [Int] = []
        coordinator.configureNavigation(
            activate: { generation in activated.append(generation); return activated.count == 1 ? .armed : .retagged },
            recordLanding: { generation in landed.append(generation); return .firstCommitted }
        )
        coordinator.request("alpha")
        let first = try #require(driver.generations.first)
        coordinator.request("beta")
        driver.emitEnd(generation: first)
        scheduler.runNext()
        let second = try #require(driver.generations.last)
        driver.emitMatch(selection(), generation: first)
        driver.emitEnd(generation: first)
        driver.emitMatch(selection(), generation: second)
        driver.emitEnd(generation: second)
        #expect(activated == [Int(second)])
        #expect(landed == [Int(second)])
        #expect(coordinator.ignoredCallbackCount >= 2)
    }

    @Test("no result and cancellation before first result never record navigation")
    func noResultAndCancelledSearchDoNotLand() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)
        var landings = 0
        var activations = 0
        coordinator.configureNavigation(activate: { _ in activations += 1; return .armed }, recordLanding: { _ in landings += 1; return .firstCommitted })
        coordinator.request("none")
        let first = try #require(driver.generations.first)
        driver.emitEnd(generation: first)
        coordinator.request("cancelled")
        let second = try #require(driver.generations.last)
        coordinator.clear()
        driver.emitMatch(selection(), generation: second)
        driver.emitEnd(generation: second)
        #expect(landings == 0)
        #expect(activations == 0)
        #expect(presenter.activations.isEmpty)
    }

    @Test("per-result navigation only records distinct displayed landings")
    func perResultDisplayOutcomeControlsHistoryCommit() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)
        var activations: [Int] = []
        var landings: [Int] = []
        coordinator.configureNavigation(
            activate: { generation in activations.append(generation); return .armed },
            recordLanding: { generation in landings.append(generation); return .firstCommitted }
        )
        presenter.presentationOutcomes = [.displayedSame]
        presenter.activationOutcomes = [.failed]
        coordinator.request("needle")
        let generation = try #require(driver.generations.last)
        driver.emitMatch(selection(), generation: generation)
        driver.emitMatch(selection(), generation: generation)
        driver.emitEnd(generation: generation)
        #expect(activations == [Int(generation)])
        #expect(landings.isEmpty)
        #expect(!coordinator.selectNext())
        #expect(activations == [Int(generation), Int(generation)])
        #expect(landings.isEmpty)
        #expect(coordinator.snapshot.activeMatchIndex == 0)
    }
    @Test("preflight rejection still displays and selects results without history recording")
    func preflightRejectionDoesNotGatePresentation() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)
        var landingCount = 0
        coordinator.configureNavigation(
            activate: { _ in .preflightRejected },
            recordLanding: { _ in landingCount += 1; return .firstCommitted }
        )
        coordinator.request("needle")
        let generation = try #require(driver.generations.last)
        driver.emitMatch(selection(), generation: generation)
        driver.emitMatch(selection(), generation: generation)
        driver.emitEnd(generation: generation)
        #expect(presenter.presentations == [SearchPresentationRecord(count: 2, activeIndex: 0)])
        #expect(coordinator.snapshot.activeMatchIndex == 0)
        #expect(coordinator.selectNext())
        #expect(presenter.activations == [1])
        #expect(coordinator.snapshot.activeMatchIndex == 1)
        #expect(landingCount == 0)
    }
    @Test("failed display keeps the prior selection and never records history")
    func failedDisplaysPreserveSelectionAndHistory() throws {
        let driver = DeterministicSearchDriver()
        let presenter = SearchResultPresenterSpy()
        let coordinator = ReaderSearchCoordinator(driver: driver, presenter: presenter)
        var landings = 0
        coordinator.configureNavigation(
            activate: { _ in .armed },
            recordLanding: { _ in landings += 1; return .firstCommitted }
        )
        presenter.presentationOutcomes = [.failed]
        coordinator.request("initial")
        let initialGeneration = try #require(driver.generations.last)
        driver.emitMatch(selection(), generation: initialGeneration)
        driver.emitEnd(generation: initialGeneration)
        #expect(coordinator.snapshot.activeMatchIndex == nil)
        #expect(landings == 0)

        presenter.presentationOutcomes = [.displayedSame]
        presenter.activationOutcomes = [.failed, .failed]
        coordinator.request("next-previous")
        let generation = try #require(driver.generations.last)
        driver.emitMatch(selection(), generation: generation)
        driver.emitMatch(selection(), generation: generation)
        driver.emitEnd(generation: generation)
        #expect(coordinator.snapshot.activeMatchIndex == 0)
        #expect(!coordinator.selectNext())
        #expect(coordinator.snapshot.activeMatchIndex == 0)
        #expect(!coordinator.selectPrevious())
        #expect(coordinator.snapshot.activeMatchIndex == 0)
        #expect(landings == 0)
    }





    private func selection() -> PDFSelection {
        PDFSelection(document: PDFDocument())
    }
}

@MainActor
private final class DeterministicSearchDriver: ReaderSearchDriving {
    weak var sink: (any ReaderSearchDriverSink)?
    private(set) var queries: [String] = []
    private(set) var generations: [UInt64] = []
    private(set) var cancelledGenerations: [UInt64] = []
    private(set) var detachCount = 0

    func begin(query: String, generation: UInt64) {
        queries.append(query)
        generations.append(generation)
        sink?.searchDriverDidBegin(generation: generation)
    }

    func cancel(generation: UInt64) {
        cancelledGenerations.append(generation)
    }

    func detach() {
        detachCount += 1
        sink = nil
    }

    func emitMatch(_ selection: PDFSelection, generation: UInt64) {
        sink?.searchDriverDidMatch(selection, generation: generation)
    }

    func emitEnd(generation: UInt64) {
        sink?.searchDriverDidEnd(generation: generation)
    }
}

private struct SearchPresentationRecord: Equatable {
    let count: Int
    let activeIndex: Int?
}

@MainActor
private final class SearchResultPresenterSpy: ReaderSearchResultPresenting {
    private(set) var presentations: [SearchPresentationRecord] = []
    private(set) var activations: [Int] = []
    private(set) var clearCount = 0
    var presentationOutcomes: [ReaderSearchResultDisplayOutcome] = []
    var activationOutcomes: [ReaderSearchResultDisplayOutcome] = []

    @discardableResult
    func presentSearchResults(_ selections: [PDFSelection], activeIndex: Int?) -> ReaderSearchResultDisplayOutcome {
        presentations.append(SearchPresentationRecord(count: selections.count, activeIndex: activeIndex))
        return presentationOutcomes.isEmpty ? .displayedDistinct : presentationOutcomes.removeFirst()
    }

    @discardableResult
    func activateSearchResult(at index: Int) -> ReaderSearchResultDisplayOutcome {
        activations.append(index)
        return activationOutcomes.isEmpty ? .displayedDistinct : activationOutcomes.removeFirst()
    }

    func clearSearchResults() { clearCount += 1 }
}

@MainActor
private final class DeterministicSearchScheduler: ReaderSearchReplacementScheduling {
    private var operations: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int { operations.count }

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) { operations.append(operation) }

    func runNext() { guard !operations.isEmpty else { return }; operations.removeFirst()() }
}
