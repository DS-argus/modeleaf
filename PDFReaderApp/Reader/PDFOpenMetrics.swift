import Foundation
import OSLog

struct OpenTraceID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum PDFOpenMetricName: String, Equatable, Hashable, Sendable {
    case openRequested = "open.requested"
    case openTotal = "open.total"
    case filePreflight
    case pdfDocumentInit
    case documentPolicyValidation
    case sessionConstruct
    case pdfViewDocumentAttach
    case openReady = "open.ready"
    case openFailed = "open.failed"
    case sessionClosed = "session.closed"
}

enum PDFOpenMetricBoundary: String, Equatable, Hashable, Sendable {
    case point
    case begin
    case end
}

enum PDFOpenMetricOutcome: String, Equatable, Hashable, Sendable {
    case success
    case unsupportedLocation
    case missingFile
    case unreadableFile
    case malformedDocument
    case lockedDocument
    case emptyDocument
    case insertionRejected
    case unexpectedFailure
    case userClose
}

struct PDFOpenMetricEvent: Equatable, Sendable {
    let traceID: OpenTraceID
    let name: PDFOpenMetricName
    let boundary: PDFOpenMetricBoundary
    let outcome: PDFOpenMetricOutcome?

    static func point(
        _ name: PDFOpenMetricName,
        traceID: OpenTraceID,
        outcome: PDFOpenMetricOutcome? = nil
    ) -> Self {
        Self(traceID: traceID, name: name, boundary: .point, outcome: outcome)
    }

    static func begin(_ name: PDFOpenMetricName, traceID: OpenTraceID) -> Self {
        Self(traceID: traceID, name: name, boundary: .begin, outcome: nil)
    }

    static func end(
        _ name: PDFOpenMetricName,
        traceID: OpenTraceID,
        outcome: PDFOpenMetricOutcome
    ) -> Self {
        Self(traceID: traceID, name: name, boundary: .end, outcome: outcome)
    }
}

@MainActor
protocol PDFOpenMetrics: AnyObject {
    func record(_ event: PDFOpenMetricEvent)
}

@MainActor
final class NoopPDFOpenMetrics: PDFOpenMetrics {
    func record(_ event: PDFOpenMetricEvent) {}
}

@MainActor
final class OSLogPDFOpenMetrics: PDFOpenMetrics {
    private struct IntervalKey: Hashable {
        let traceID: OpenTraceID
        let name: PDFOpenMetricName
    }

    private let logger = Logger(subsystem: "com.argus.modeleaf", category: "PDFOpen")
    private let clock = ContinuousClock()
    private var intervalStarts: [IntervalKey: ContinuousClock.Instant] = [:]

    func record(_ event: PDFOpenMetricEvent) {
        let key = IntervalKey(traceID: event.traceID, name: event.name)
        var durationMilliseconds: Double?

        switch event.boundary {
        case .begin:
            intervalStarts[key] = clock.now
        case .end:
            if let start = intervalStarts.removeValue(forKey: key) {
                durationMilliseconds = milliseconds(in: start.duration(to: clock.now))
            }
        case .point:
            break
        }

        let outcome = event.outcome?.rawValue ?? "-"
        let duration = durationMilliseconds.map { String(format: "%.3f", $0) } ?? "-"
        let marker = [
            "event=\(event.name.rawValue)",
            "boundary=\(event.boundary.rawValue)",
            "trace=\(event.traceID.rawValue.uuidString.lowercased())",
            "outcome=\(outcome)",
            "duration_ms=\(duration)",
        ].joined(separator: " ")
        logger.notice("\(marker, privacy: .public)")
    }

    private func milliseconds(in duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
