import Foundation
import PDFKit

public enum ProbeSearchState: Equatable, Sendable {
    case idle
    case running(query: String, generation: Int)
    case cancelling(query: String, generation: Int, pendingLatest: String?)
}

@MainActor
private protocol ProbeSearchDriverSink: AnyObject {
    func searchDriverDidBegin()
    func searchDriverDidMatch(_ selection: PDFSelection?)
    func searchDriverDidEnd()
}

@MainActor
private protocol ProbeSearchDriver: AnyObject {
    var sink: (any ProbeSearchDriverSink)? { get set }
    func begin(query: String)
    func cancel()
}

@MainActor
private final class ProbeSearchCoordinator: ProbeSearchDriverSink {
    private let driver: any ProbeSearchDriver
    private(set) var state: ProbeSearchState = .idle
    private(set) var acceptedMatchCount = 0
    private(set) var startedQueries: [String] = []
    private(set) var lifecycle: [String] = []
    private var nextGeneration = 0

    init(driver: any ProbeSearchDriver) {
        self.driver = driver
        driver.sink = self
    }

    func request(_ query: String) {
        switch state {
        case .idle:
            start(query)
        case let .running(active, generation):
            state = .cancelling(query: active, generation: generation, pendingLatest: query)
            lifecycle.append("cancel:\(active)")
            driver.cancel()
        case let .cancelling(active, generation, _):
            state = .cancelling(query: active, generation: generation, pendingLatest: query)
            lifecycle.append("replace-pending:\(query)")
        }
    }

    func cancel() {
        switch state {
        case .idle:
            return
        case let .running(query, generation):
            state = .cancelling(query: query, generation: generation, pendingLatest: nil)
            lifecycle.append("cancel:\(query)")
            driver.cancel()
        case let .cancelling(query, generation, _):
            state = .cancelling(query: query, generation: generation, pendingLatest: nil)
        }
    }

    func searchDriverDidBegin() {
        lifecycle.append("callback:begin")
    }

    func searchDriverDidMatch(_ selection: PDFSelection?) {
        guard case .running = state else {
            lifecycle.append("callback:ignored-match")
            return
        }
        acceptedMatchCount += 1
        lifecycle.append("callback:match")
    }

    func searchDriverDidEnd() {
        lifecycle.append("callback:end")
        switch state {
        case .idle:
            return
        case .running:
            state = .idle
        case let .cancelling(_, _, pendingLatest):
            state = .idle
            if let pendingLatest {
                // PDFKit still reports `isFinding == true` while invoking its end callback.
                // Crossing one main-queue turn makes the end boundary observable before
                // a replacement begin call, instead of relying on callback reentrancy.
                DispatchQueue.main.async { [weak self] in
                    self?.startIfIdle(pendingLatest)
                }
            }
        }
    }

    private func start(_ query: String) {
        nextGeneration += 1
        state = .running(query: query, generation: nextGeneration)
        startedQueries.append(query)
        lifecycle.append("begin:\(query)")
        driver.begin(query: query)
    }

    private func startIfIdle(_ query: String) {
        guard state == .idle else { return }
        start(query)
    }
}

@MainActor
private final class DeterministicSearchDriver: ProbeSearchDriver {
    weak var sink: (any ProbeSearchDriverSink)?
    private(set) var began: [String] = []
    private(set) var cancelCount = 0

    func begin(query: String) {
        began.append(query)
        sink?.searchDriverDidBegin()
    }

    func cancel() {
        cancelCount += 1
    }

    func emitLateMatch() {
        sink?.searchDriverDidMatch(nil)
    }

    func emitMatch() {
        sink?.searchDriverDidMatch(nil)
    }

    func emitEnd() {
        sink?.searchDriverDidEnd()
    }
}

@MainActor
private final class PDFKitSearchDriver: NSObject, ProbeSearchDriver, @preconcurrency PDFDocumentDelegate {
    weak var sink: (any ProbeSearchDriverSink)?
    let document: PDFDocument
    private(set) var events: [String] = []

    init(document: PDFDocument) {
        self.document = document
        super.init()
        document.delegate = self
    }

    func begin(query: String) {
        events.append("command:begin:\(query)")
        document.beginFindString(query, withOptions: [.caseInsensitive, .literal])
    }

    func cancel() {
        events.append("command:cancel")
        document.cancelFindString()
    }

    func documentDidBeginDocumentFind(_ notification: Notification) {
        events.append("callback:begin")
        sink?.searchDriverDidBegin()
    }

    func didMatchString(_ instance: PDFSelection) {
        events.append("callback:match")
        sink?.searchDriverDidMatch(instance)
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        events.append("callback:end")
        sink?.searchDriverDidEnd()
    }
}

@MainActor
public enum SearchProbe {
    public static func run() throws -> ProbeSection {
        let fake = DeterministicSearchDriver()
        let deterministic = ProbeSearchCoordinator(driver: fake)
        deterministic.request("alpha")
        deterministic.request("beta")
        fake.emitLateMatch()
        deterministic.request("gamma")

        let heldUntilEnd = fake.began == ["alpha"]
        let ignoredLateMatch = deterministic.acceptedMatchCount == 0
        fake.emitEnd()
        let fakeDeadline = Date().addingTimeInterval(1)
        while Date() < fakeDeadline && fake.began.count < 2 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
        }
        let latestOnlyStarted = fake.began == ["alpha", "gamma"]
        fake.emitMatch()
        fake.emitEnd()
        let deterministicFinished = deterministic.state == .idle
            && deterministic.acceptedMatchCount == 1
            && fake.cancelCount == 1

        let document = try PDFFixtureFactory.searchableDocument(pageCount: 40, repeatedText: "needle needle needle")
        let actualDriver = PDFKitSearchDriver(document: document)
        let actual = ProbeSearchCoordinator(driver: actualDriver)
        actual.request("needle")
        actual.request("definitely-not-present")

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if actual.state == .idle && actual.startedQueries.count == 2 { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        let firstEndIndex = actualDriver.events.firstIndex(of: "callback:end")
        let secondBeginIndex = actualDriver.events.firstIndex(of: "command:begin:definitely-not-present")
        let actualSerialized = firstEndIndex != nil
            && secondBeginIndex != nil
            && firstEndIndex! < secondBeginIndex!
        let actualFinished = actual.state == .idle
            && actual.startedQueries == ["needle", "definitely-not-present"]

        document.delegate = nil

        return ProbeSection(
            id: "search-ordering",
            title: "Serialized asynchronous PDFKit search",
            checks: [
                checked("pending-held", heldUntilEnd, detail: "a replacement does not call begin while the prior search is cancelling"),
                checked("late-callback-ignored", ignoredLateMatch, detail: "a late match during cancelling cannot repopulate results"),
                checked("latest-wins", latestOnlyStarted, detail: "pendingLatest replaces intermediate beta and starts only gamma after end"),
                checked("deterministic-state-machine", deterministicFinished, detail: "idle-running-cancelling-pendingLatest completes with one accepted generation"),
                checked("pdfkit-end-boundary", actualSerialized, detail: "the actual PDFKit adapter observes callback:end before issuing the replacement begin command"),
                checked("pdfkit-completion", actualFinished, detail: "state=\(actual.state), started=\(actual.startedQueries), events=\(actualDriver.events)"),
            ]
        )
    }
}
