import AppKit
import PDFReaderCore

@MainActor
final class ReaderInputRouter {
    private var engine: KeySequenceEngine
    private let automaticallySchedulesTimeouts: Bool
    private let pendingHandler: (String) -> Void
    private let dispatchHandler: (KeyActionDispatch) -> Void
    private var historySequences: [[KeyToken]]
    private var modalHistoryEpoch: UInt64 = 0
    private var modalHistoryTimeoutTask: Task<Void, Never>?
    private var modalHistoryTimeoutMilliseconds: Int
    private var modalHistoryPrefix: [KeyToken] = []
    private var timeoutTask: Task<Void, Never>?

    init(
        config: ValidatedAppConfig,
        automaticallySchedulesTimeouts: Bool = true,
        pendingHandler: @escaping (String) -> Void,
        dispatchHandler: @escaping (KeyActionDispatch) -> Void
    ) {
        self.engine = config.makeKeyEngine(context: .navigation)
        self.automaticallySchedulesTimeouts = automaticallySchedulesTimeouts
        self.modalHistoryTimeoutMilliseconds = config.config.input.prefixTimeoutMilliseconds
        self.pendingHandler = pendingHandler
        self.historySequences = [ActionID.historyBack, .historyForward]
            .flatMap { config.keymap.bindings(for: $0).map(\.tokens) }
        self.dispatchHandler = dispatchHandler
    }

    var context: InputContext { engine.context }
    var pending: PendingKeySequence? { engine.pending }

    func handle(_ event: NSEvent) -> Bool {
        let candidates = AppKitKeyEventAdapter.tokens(for: event)
        guard !candidates.isEmpty else { return false }

        let original = engine
        var firstAttempt: (engine: KeySequenceEngine, outcome: KeyInputOutcome)?
        for token in candidates {
            var trial = original
            let outcome = trial.handle(token, eventIsRepeat: event.isARepeat)
            if firstAttempt == nil { firstAttempt = (trial, outcome) }
            guard outcome.isCandidateMatch else { continue }
            engine = trial
            return apply(outcome)
        }

        guard let firstAttempt else { return false }
        engine = firstAttempt.engine
        return apply(firstAttempt.outcome)
    }
    /// Consumes only effective history bindings while a transient modal owns
    /// routing. It intentionally never dispatches and ignores non-history keys.
    func handleHistoryWhileModal(_ event: NSEvent) -> Bool {
        let candidates = AppKitKeyEventAdapter.tokens(for: event)
        guard !candidates.isEmpty else { return false }
        for token in candidates where handleModalHistoryToken(token, isRepeat: event.isARepeat) {
            return true
        }
        resetModalHistorySuppression()
        return false
    }

    func resetModalHistorySuppression() {
        modalHistoryEpoch &+= 1
        modalHistoryPrefix.removeAll()
        modalHistoryTimeoutTask?.cancel()
        modalHistoryTimeoutTask = nil
    }

    func fireModalHistoryTimeoutForTesting(epoch: UInt64) {
        guard epoch == modalHistoryEpoch else { return }
        resetModalHistorySuppression()
    }

    var modalHistoryEpochForTesting: UInt64 { modalHistoryEpoch }

    private func handleModalHistoryToken(_ token: KeyToken, isRepeat: Bool) -> Bool {
        let attempt = modalHistoryPrefix + [token]
        let matches = historySequences.filter { $0.starts(with: attempt) }
        guard !matches.isEmpty else {
            if !modalHistoryPrefix.isEmpty {
                resetModalHistorySuppression()
                return handleModalHistoryToken(token, isRepeat: isRepeat)
            }
            return false
        }
        guard !isRepeat else { return true }
        if matches.contains(where: { $0.count == attempt.count }) {
            resetModalHistorySuppression()
        } else {
            modalHistoryPrefix = attempt
            scheduleModalHistoryTimeout()
        }
        return true
    }

    private func scheduleModalHistoryTimeout() {
        modalHistoryTimeoutTask?.cancel()
        let epoch = modalHistoryEpoch
        let nanoseconds = UInt64(modalHistoryTimeoutMilliseconds) * 1_000_000
        guard automaticallySchedulesTimeouts else { return }
        modalHistoryTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.fireModalHistoryTimeoutForTesting(epoch: epoch)
        }
    }

    func synchronizeContext(_ context: InputContext) {
        guard engine.context != context else { return }
        cancelTimeoutAndClearPrefix()
        _ = engine.changeContext(to: context)
    }

    func reconfigure(config: ValidatedAppConfig) {
        let context = engine.context
        cancelTimeoutAndClearPrefix()
        engine = config.makeKeyEngine(context: context)
        historySequences = [ActionID.historyBack, .historyForward]
            .flatMap { config.keymap.bindings(for: $0).map(\.tokens) }
        modalHistoryTimeoutMilliseconds = config.config.input.prefixTimeoutMilliseconds
        resetModalHistorySuppression()
    }

    func invalidate(_ reason: KeyInputInvalidationReason) {
        cancelTimeoutAndClearPrefix()
        resetModalHistorySuppression()
        _ = engine.invalidate(reason)
    }

    func fireTimeoutForTesting(epoch: PrefixEpoch) {
        resolveTimeout(epoch: epoch)
    }

    private func apply(_ outcome: KeyInputOutcome) -> Bool {
        switch outcome {
        case .native:
            return false
        case let .pending(pending):
            pendingHandler(pending.sequence.description)
            scheduleTimeout(for: pending)
            return true
        case let .dispatch(dispatch):
            cancelTimeoutAndClearPrefix()
            dispatchHandler(dispatch)
            return true
        case let .ignored(reason):
            if reason.clearsVisiblePrefix {
                cancelTimeoutAndClearPrefix()
            }
            if reason == .rejectedPagePromptText {
                NSSound.beep()
            }
            return reason.consumesEvent
        }
    }

    private func scheduleTimeout(for pending: PendingKeySequence) {
        timeoutTask?.cancel()
        guard automaticallySchedulesTimeouts else { return }
        let nanoseconds = UInt64(pending.timeoutMilliseconds) * 1_000_000
        timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.resolveTimeout(epoch: pending.epoch)
        }
    }

    private func resolveTimeout(epoch: PrefixEpoch) {
        let outcome = engine.timeout(epoch: epoch)
        _ = apply(outcome)
    }

    private func cancelTimeoutAndClearPrefix() {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingHandler("")
    }
}

private extension KeyInputOutcome {
    var isCandidateMatch: Bool {
        switch self {
        case .native, .pending, .dispatch:
            true
        case .ignored:
            false
        }
    }
}

private extension KeyInputIgnoreReason {
    var consumesEvent: Bool {
        switch self {
        case .noBinding, .staleTimeout, .timeoutWithoutExactAction, .invalidated:
            false
        case .invalidSequence, .rejectedPagePromptText, .repeatSuppressed,
             .repeatCannotBeginPrefix, .repeatDuringPrefix:
            true
        }
    }

    var clearsVisiblePrefix: Bool {
        switch self {
        case .noBinding, .invalidSequence, .rejectedPagePromptText,
             .timeoutWithoutExactAction, .invalidated:
            true
        case .repeatSuppressed, .repeatCannotBeginPrefix, .repeatDuringPrefix, .staleTimeout:
            false
        }
    }
}
