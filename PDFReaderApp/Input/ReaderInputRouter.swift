import AppKit
import PDFReaderCore

@MainActor
final class ReaderInputRouter {
    private var engine: KeySequenceEngine
    private let automaticallySchedulesTimeouts: Bool
    private let pendingHandler: (String) -> Void
    private let dispatchHandler: (KeyActionDispatch) -> Void
    private var timeoutTask: Task<Void, Never>?

    init(
        config: ValidatedAppConfig,
        automaticallySchedulesTimeouts: Bool = true,
        pendingHandler: @escaping (String) -> Void,
        dispatchHandler: @escaping (KeyActionDispatch) -> Void
    ) {
        self.engine = config.makeKeyEngine(context: .navigation)
        self.automaticallySchedulesTimeouts = automaticallySchedulesTimeouts
        self.pendingHandler = pendingHandler
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

    func synchronizeContext(_ context: InputContext) {
        guard engine.context != context else { return }
        cancelTimeoutAndClearPrefix()
        _ = engine.changeContext(to: context)
    }

    func reconfigure(config: ValidatedAppConfig) {
        let context = engine.context
        cancelTimeoutAndClearPrefix()
        engine = config.makeKeyEngine(context: context)
    }
    func invalidate(_ reason: KeyInputInvalidationReason) {
        cancelTimeoutAndClearPrefix()
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
