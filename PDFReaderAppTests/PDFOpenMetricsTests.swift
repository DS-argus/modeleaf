import AppKit
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Per-open metrics and terminal balance")
@MainActor
struct PDFOpenMetricsTests {
    @Test("successful service open emits balanced phases under one explicit trace")
    func successfulServiceOpenIsBalanced() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let metrics = RecordingPDFOpenMetrics()
            let traceID = fixedTraceID(1)
            let session = try PDFOpenService().open(url: url, traceID: traceID, metrics: metrics)

            #expect(metrics.events.map(\.traceID) == Array(repeating: traceID, count: 10))
            #expect(metrics.events.map(\.signature) == [
                "filePreflight.begin.-",
                "filePreflight.end.success",
                "pdfDocumentInit.begin.-",
                "pdfDocumentInit.end.success",
                "documentPolicyValidation.begin.-",
                "documentPolicyValidation.end.success",
                "sessionConstruct.begin.-",
                "pdfViewDocumentAttach.begin.-",
                "pdfViewDocumentAttach.end.success",
                "sessionConstruct.end.success",
            ])

            session.prepareForClose()
            #expect(metrics.events.last?.signature == "session.closed.point.userClose")
            session.prepareForClose()
            #expect(metrics.events.filter { $0.name == .sessionClosed }.count == 1)
        }
    }

    @Test("validation, loader, and policy failures stop at their owning phase")
    func failureTaxonomyStopsAtOwningPhase() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing.pdf")
            let malformed = try PDFFixtureFactory.makeMalformedPDF(in: directory)
            let locked = try PDFFixtureFactory.makeLockedPDF(in: directory)
            let emptySource = try PDFFixtureFactory.makeTextPDF(
                in: directory,
                name: "empty-document-source.pdf",
                pageCount: 1
            )

            try expectFailure(
                url: missing,
                error: .missingFile(missing.path),
                signatures: ["filePreflight.begin.-", "filePreflight.end.missingFile"]
            )
            try expectFailure(
                url: malformed,
                error: .malformedDocument(malformed.path),
                signatures: [
                    "filePreflight.begin.-",
                    "filePreflight.end.success",
                    "pdfDocumentInit.begin.-",
                    "pdfDocumentInit.end.malformedDocument",
                ]
            )
            try expectFailure(
                url: locked,
                error: .lockedDocument(locked.path),
                signatures: [
                    "filePreflight.begin.-",
                    "filePreflight.end.success",
                    "pdfDocumentInit.begin.-",
                    "pdfDocumentInit.end.success",
                    "documentPolicyValidation.begin.-",
                    "documentPolicyValidation.end.lockedDocument",
                ]
            )
            try expectFailure(
                url: emptySource,
                error: .emptyDocument(emptySource.path),
                signatures: [
                    "filePreflight.begin.-",
                    "filePreflight.end.success",
                    "pdfDocumentInit.begin.-",
                    "pdfDocumentInit.end.success",
                    "documentPolicyValidation.begin.-",
                    "documentPolicyValidation.end.emptyDocument",
                ],
                service: PDFOpenService(documentLoader: { _ in PDFDocument() })
            )
        }
    }

    @Test("controller publishes one ready terminal after synchronous insertion")
    func controllerPublishesReadyTerminal() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let metrics = RecordingPDFOpenMetrics()
            let store = ReaderSessionStore()
            let controller = makeController(
                directory: directory,
                sessionStore: store,
                metrics: metrics
            )
            defer {
                while controller.coordinator.closeActiveTab() {}
                controller.mainWindowController.close()
            }

            #expect(controller.openDocument(at: url))
            let traceIDs = Set(metrics.events.map(\.traceID))
            #expect(traceIDs.count == 1)
            #expect(metrics.events.prefix(2).map(\.signature) == [
                "open.requested.point.-",
                "open.total.begin.-",
            ])
            #expect(metrics.events.suffix(2).map(\.signature) == [
                "open.ready.point.success",
                "open.total.end.success",
            ])
            #expect(store.sessionCount == 1)
        }
    }

    @Test("insertion rejection closes the constructed session before the failed terminal")
    func insertionRejectionClosesSessionBeforeFailure() throws {
        try withTemporaryDirectory { directory in
            let url = try PDFFixtureFactory.makeTextPDF(in: directory, pageCount: 1)
            let duplicateID = fixedTabID(7)
            let store = ReaderSessionStore()
            let existing = MetricsStubSession(id: duplicateID)
            #expect(store.insert(existing))
            let metrics = RecordingPDFOpenMetrics()
            let service = PDFOpenService(sessionIDFactory: { duplicateID })
            let controller = makeController(
                directory: directory,
                sessionStore: store,
                pdfOpenService: service,
                metrics: metrics
            )
            defer {
                while controller.coordinator.closeActiveTab() {}
                controller.mainWindowController.close()
            }

            #expect(!controller.openDocument(at: url))
            #expect(store.sessionCount == 1)
            #expect(existing.prepareForCloseCount == 0)
            #expect(metrics.events.suffix(3).map(\.signature) == [
                "session.closed.point.insertionRejected",
                "open.failed.point.insertionRejected",
                "open.total.end.insertionRejected",
            ])
        }
    }

    private func expectFailure(
        url: URL,
        error expectedError: PDFOpenError,
        signatures: [String],
        service: PDFOpenService = PDFOpenService()
    ) throws {
        let metrics = RecordingPDFOpenMetrics()
        let traceID = fixedTraceID(2)
        do {
            _ = try service.open(url: url, traceID: traceID, metrics: metrics)
            Issue.record("Expected PDFOpenError")
        } catch let error as PDFOpenError {
            #expect(error == expectedError)
        }
        #expect(metrics.events.map(\.traceID).allSatisfy { $0 == traceID })
        #expect(metrics.events.map(\.signature) == signatures)
    }

    private func makeController(
        directory: URL,
        sessionStore: ReaderSessionStore,
        pdfOpenService: PDFOpenService = PDFOpenService(),
        metrics: any PDFOpenMetrics
    ) -> ApplicationController {
        ApplicationController(
            configService: ConfigService(
                source: ConfigFileSource(url: directory.appendingPathComponent("missing-config.toml"))
            ),
            sessionStore: sessionStore,
            pdfOpenService: pdfOpenService,
            openMetrics: metrics,
            terminationHandler: {}
        )
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-reader-metrics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func fixedTraceID(_ value: Int) -> OpenTraceID {
        OpenTraceID(rawValue: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", value))!)
    }

    private func fixedTabID(_ value: Int) -> TabID {
        TabID(rawValue: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", value))!)
    }
}

@MainActor
private final class RecordingPDFOpenMetrics: PDFOpenMetrics {
    private(set) var events: [PDFOpenMetricEvent] = []

    func record(_ event: PDFOpenMetricEvent) {
        events.append(event)
    }
}

@MainActor
private final class MetricsStubSession: ReaderSessionPresenting {
    func applyTheme(_ theme: AppKitTheme) {}
    let id: TabID
    let title = "existing.pdf"
    let contentView = NSView()
    private(set) var prepareForCloseCount = 0

    init(id: TabID) {
        self.id = id
    }

    var statusSnapshot: ReaderStatusSnapshot {
        ReaderStatusSnapshot(context: "NORMAL", page: "1 / 1", zoom: "100%", detail: title)
    }

    func prepareForClose() {
        prepareForCloseCount += 1
    }
}

private extension PDFOpenMetricEvent {
    var signature: String {
        "\(name.rawValue).\(boundary.rawValue).\(outcome?.rawValue ?? "-")"
    }
}
