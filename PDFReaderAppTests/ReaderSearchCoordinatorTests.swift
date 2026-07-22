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

    func presentSearchResults(_ selections: [PDFSelection], activeIndex: Int?) {
        presentations.append(SearchPresentationRecord(count: selections.count, activeIndex: activeIndex))
    }

    func activateSearchResult(at index: Int) {
        activations.append(index)
    }

    func clearSearchResults() {
        clearCount += 1
    }
}

@MainActor
private final class DeterministicSearchScheduler: ReaderSearchReplacementScheduling {
    private var operations: [@MainActor @Sendable () -> Void] = []

    var pendingCount: Int { operations.count }

    func schedule(_ operation: @escaping @MainActor @Sendable () -> Void) {
        operations.append(operation)
    }

    func runNext() {
        guard !operations.isEmpty else { return }
        operations.removeFirst()()
    }
}
