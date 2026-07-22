import AppKit
import CoreText
import CryptoKit
import Foundation
import PDFKit

public enum PDFFixtureError: Error, Equatable {
    case couldNotCreateConsumer
    case couldNotCreateContext
    case couldNotCreateRasterContext
    case couldNotCreateRasterImage
    case couldNotOpenGeneratedDocument
    case couldNotWriteDocument
    case missingGeneratedPage
}

public struct InteractivePDFFixture: Sendable {
    public let url: URL
    public let widgetValue: String
    public let noteContents: String
    public let annotationCount: Int

    public init(url: URL, widgetValue: String, noteContents: String, annotationCount: Int) {
        self.url = url
        self.widgetValue = widgetValue
        self.noteContents = noteContents
        self.annotationCount = annotationCount
    }
}

@MainActor
public enum PDFFixtureFactory {
    @discardableResult
    public static func makeTextPDF(
        in directory: URL,
        name: String = "text-3-page.pdf",
        pageCount: Int = 3,
        repeatedText: String = "copyable needle"
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }

        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 48, y: 720)
            let text = "Page \(pageIndex + 1) unique-page-\(pageIndex + 1) \(repeatedText)"
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            CTLineDraw(line, context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    public static func makeMalformedPDF(
        in directory: URL,
        name: String = "malformed.pdf"
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("this is not a PDF".utf8).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    public static func makeImageOnlyPDF(
        in directory: URL,
        name: String = "image-only-2-page.pdf",
        pageCount: Int = 2
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }
        guard let rasterContext = CGContext(
            data: nil,
            width: 240,
            height: 160,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFFixtureError.couldNotCreateRasterContext
        }
        rasterContext.setFillColor(NSColor(calibratedRed: 0.18, green: 0.34, blue: 0.58, alpha: 1).cgColor)
        rasterContext.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        rasterContext.setFillColor(NSColor(calibratedRed: 0.88, green: 0.68, blue: 0.24, alpha: 1).cgColor)
        rasterContext.fillEllipse(in: CGRect(x: 70, y: 30, width: 100, height: 100))
        guard let rasterImage = rasterContext.makeImage() else {
            throw PDFFixtureError.couldNotCreateRasterImage
        }

        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            let inset = CGFloat(pageIndex) * 12
            context.draw(
                rasterImage,
                in: CGRect(x: 126 + inset, y: 316 - inset, width: 360, height: 240)
            )
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    @discardableResult
    public static func makeEmptyPDF(
        in directory: URL,
        name: String = "empty-page.pdf",
        pageCount: Int = 1
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    public static func makeLockedPDF(
        in directory: URL,
        name: String = "locked.pdf",
        password: String = "reader-test-secret"
    ) throws -> URL {
        let sourceURL = try makeTextPDF(
            in: directory,
            name: "locked-source-\(UUID().uuidString).pdf",
            pageCount: 1
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        guard let document = PDFDocument(url: sourceURL) else {
            throw PDFFixtureError.couldNotOpenGeneratedDocument
        }

        let lockedURL = directory.appendingPathComponent(name)
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: "owner-\(password)",
        ]
        guard document.write(to: lockedURL, withOptions: options) else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        return lockedURL
    }

    public static func makeInteractivePDF(
        in directory: URL,
        name: String = "form-widget-and-annotations.pdf"
    ) throws -> InteractivePDFFixture {
        let sourceURL = try makeTextPDF(
            in: directory,
            name: "interactive-source-\(UUID().uuidString).pdf",
            pageCount: 1
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        guard let document = PDFDocument(url: sourceURL), let page = document.page(at: 0) else {
            throw PDFFixtureError.missingGeneratedPage
        }

        let widgetValue = "original widget value"
        let widget = PDFAnnotation(
            bounds: CGRect(x: 48, y: 620, width: 220, height: 32),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.widgetStringValue = widgetValue

        let noteContents = "original note contents"
        let note = PDFAnnotation(
            bounds: CGRect(x: 300, y: 620, width: 28, height: 28),
            forType: .text,
            withProperties: nil
        )
        note.contents = noteContents

        let link = PDFAnnotation(
            bounds: CGRect(x: 48, y: 560, width: 220, height: 28),
            forType: .link,
            withProperties: nil
        )
        link.action = PDFActionURL(url: URL(string: "https://example.invalid/blocked")!)

        page.addAnnotation(widget)
        page.addAnnotation(note)
        page.addAnnotation(link)

        let outputURL = directory.appendingPathComponent(name)
        guard document.write(to: outputURL) else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        guard let persistedDocument = PDFDocument(url: outputURL), let persistedPage = persistedDocument.page(at: 0) else {
            throw PDFFixtureError.couldNotOpenGeneratedDocument
        }
        return InteractivePDFFixture(
            url: outputURL,
            widgetValue: widgetValue,
            noteContents: noteContents,
            annotationCount: persistedPage.annotations.count
        )
    }

    public static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
