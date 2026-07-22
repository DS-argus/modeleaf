import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

enum PDFOpenError: Error, Equatable, LocalizedError {
    case unsupportedLocation(String)
    case missingFile(String)
    case unreadableFile(String)
    case malformedDocument(String)
    case lockedDocument(String)
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
        case let .lockedDocument(path):
            "Password-protected PDFs are not supported yet: \(path)"
        case let .emptyDocument(path):
            "PDF contains no pages: \(path)"
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

    init(
        fileManager: FileManager = .default,
        documentLoader: @escaping (URL) -> PDFDocument? = { PDFDocument(url: $0) }
    ) {
        self.fileManager = fileManager
        self.documentLoader = documentLoader
    }

    func open(url: URL) throws -> ReaderSession {
        guard url.isFileURL else {
            throw PDFOpenError.unsupportedLocation(url.absoluteString)
        }

        let fileURL = url.standardizedFileURL
        let path = fileURL.path
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw PDFOpenError.missingFile(path)
        }
        guard fileManager.isReadableFile(atPath: path) else {
            throw PDFOpenError.unreadableFile(path)
        }
        guard let document = documentLoader(fileURL) else {
            throw PDFOpenError.malformedDocument(path)
        }
        guard !document.isLocked else {
            throw PDFOpenError.lockedDocument(path)
        }
        guard document.pageCount > 0 else {
            throw PDFOpenError.emptyDocument(path)
        }
        return ReaderSession(sourceURL: fileURL, document: document)
    }
}
