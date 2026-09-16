import AppKit
import Foundation
import PDFKit
import PDFReaderCore
import UniformTypeIdentifiers

enum PDFOpenError: Error, Equatable, LocalizedError {
    case unsupportedLocation(String)
    case missingFile(String)
    case unreadableFile(String)
    case malformedDocument(String)
    case passwordRequired(String)
    case cancelled
    case emptyDocument(String)

    var errorDescription: String? { presentation }

    var presentation: String {
        switch self {
        case let .unsupportedLocation(value):
            "Only local PDF files can be opened: \(value)"
        case let .missingFile(path):
            "PDF file not found: \(path)"
        case let .unreadableFile(path):
            "PDF file is not readable: \(path)"
        case let .malformedDocument(path):
            "PDF is malformed or unsupported: \(path)"
        case let .passwordRequired(path):
            "Password required to open PDF: \(path)"
        case .cancelled:
            "PDF opening was cancelled."
        case let .emptyDocument(path):
            "PDF contains no pages: \(path)"
        }
    }

    var metricOutcome: PDFOpenMetricOutcome {
        switch self {
        case .unsupportedLocation:
            .unsupportedLocation
        case .missingFile:
            .missingFile
        case .unreadableFile:
            .unreadableFile
        case .malformedDocument:
            .malformedDocument
        case .passwordRequired:
            .lockedDocument
        case .cancelled:
            .cancelled
        case .emptyDocument:
            .emptyDocument
        }
    }
}

@MainActor
protocol PDFOpenPanelPresenting: AnyObject {
    func present(attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void)
}

@MainActor
final class NativePDFOpenPanelPresenter: PDFOpenPanelPresenting {
    func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = "Open PDF"
        panel.prompt = "Open"
        return panel
    }

    func present(attachedTo window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = makePanel()
        if let window {
            panel.beginSheetModal(for: window) { [panel] response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}

@MainActor
final class PDFOpenService {
    private let fileManager: FileManager
    private let documentLoader: (URL) -> PDFDocument?
    private let sessionIDFactory: () -> TabID

    init(
        fileManager: FileManager = .default,
        documentLoader: @escaping (URL) -> PDFDocument? = { PDFDocument(url: $0) },
        sessionIDFactory: @escaping () -> TabID = { TabID() }
    ) {
        self.fileManager = fileManager
        self.documentLoader = documentLoader
        self.sessionIDFactory = sessionIDFactory
    }

    func open(
        url: URL,
        traceID: OpenTraceID = OpenTraceID(),
        metrics: any PDFOpenMetrics = NoopPDFOpenMetrics(),
        passwordProvider: ((Bool) -> String?)? = nil
    ) throws -> ReaderSession {
        metrics.record(.begin(.filePreflight, traceID: traceID))
        guard url.isFileURL else {
            metrics.record(.end(.filePreflight, traceID: traceID, outcome: .unsupportedLocation))
            throw PDFOpenError.unsupportedLocation(url.absoluteString)
        }

        let fileURL = url.standardizedFileURL
        let path = fileURL.path
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            metrics.record(.end(.filePreflight, traceID: traceID, outcome: .missingFile))
            throw PDFOpenError.missingFile(path)
        }
        guard fileManager.isReadableFile(atPath: path) else {
            metrics.record(.end(.filePreflight, traceID: traceID, outcome: .unreadableFile))
            throw PDFOpenError.unreadableFile(path)
        }
        metrics.record(.end(.filePreflight, traceID: traceID, outcome: .success))

        metrics.record(.begin(.pdfDocumentInit, traceID: traceID))
        guard let document = documentLoader(fileURL) else {
            metrics.record(.end(.pdfDocumentInit, traceID: traceID, outcome: .malformedDocument))
            throw PDFOpenError.malformedDocument(path)
        }
        metrics.record(.end(.pdfDocumentInit, traceID: traceID, outcome: .success))

        metrics.record(.begin(.documentPolicyValidation, traceID: traceID))
        do {
            try unlockIfNeeded(
                document: document,
                path: path,
                passwordProvider: passwordProvider
            )
        } catch {
            let outcome = (error as? PDFOpenError)?.metricOutcome ?? .unexpectedFailure
            metrics.record(.end(.documentPolicyValidation, traceID: traceID, outcome: outcome))
            throw error
        }
        guard document.pageCount > 0 else {
            metrics.record(.end(.documentPolicyValidation, traceID: traceID, outcome: .emptyDocument))
            throw PDFOpenError.emptyDocument(path)
        }
        metrics.record(.end(.documentPolicyValidation, traceID: traceID, outcome: .success))

        return ReaderSession(
            id: sessionIDFactory(),
            sourceURL: fileURL,
            document: document,
            traceID: traceID,
            metrics: metrics
        )
    }

    private func unlockIfNeeded(
        document: PDFDocument,
        path: String,
        passwordProvider: ((Bool) -> String?)?
    ) throws {
        guard document.isLocked else { return }
        guard let passwordProvider else {
            throw PDFOpenError.passwordRequired(path)
        }

        var hadInvalidAttempt = false
        while true {
            guard let password = passwordProvider(hadInvalidAttempt) else {
                throw PDFOpenError.cancelled
            }

            let didUnlock = document.unlock(withPassword: password)
            if didUnlock && !document.isLocked {
                return
            }
            guard document.isLocked else {
                throw PDFOpenError.passwordRequired(path)
            }
            hadInvalidAttempt = true
        }
    }
}
