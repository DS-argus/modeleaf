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

public enum PerformancePDFFixtureKind: String, CaseIterable, Codable, Sendable {
    case S
    case L
    case F
    case B

    public var fileName: String {
        switch self {
        case .S: "fixture-S-text-10.pdf"
        case .L: "fixture-L-text-300.pdf"
        case .F: "fixture-F-raster-12.pdf"
        case .B: "fixture-B-blank.pdf"
        }
    }

    public var pageCount: Int {
        switch self {
        case .S: 10
        case .L: 300
        case .F: 12
        case .B: 1
        }
    }

    public var sentinelPattern: String? {
        switch self {
        case .S: "s-magenta-lime-diagonal-v1"
        case .L: "l-lime-magenta-columns-v1"
        case .F: "f-magenta-lime-frame-v1"
        case .B: nil
        }
    }
}

public struct PerformancePDFSentinel: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let pattern: String

    public init(x: Double, y: Double, width: Double, height: Double, pattern: String) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.pattern = pattern
    }
}

@MainActor
public enum PDFFixtureFactory {
    public static let performanceFixtureGeneratorVersion = "1"
    public static let performanceSentinelBounds = CGRect(x: 48, y: 568, width: 192, height: 128)

    @discardableResult
    public static func makeTextPDF(
        in directory: URL,
        name: String = "text-3-page.pdf",
        pageCount: Int = 3,
        pageSize: CGSize = CGSize(width: 612, height: 792),
        repeatedText: String = "copyable needle"
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }

        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 48, y: max(20, pageSize.height - 72))
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

    /// A 2-page PDF whose first page carries one in-document GoTo link (to page
    /// 2), one external URL link, and a link that wraps onto a second line
    /// (two annotations sharing the same URL).
    @discardableResult
    public static func makeLinkedPDF(
        in directory: URL,
        name: String = "linked.pdf"
    ) throws -> URL {
        let sourceURL = try makeTextPDF(
            in: directory,
            name: "linked-source-\(UUID().uuidString).pdf",
            pageCount: 2
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        guard let document = PDFDocument(url: sourceURL),
              let page1 = document.page(at: 0),
              let page2 = document.page(at: 1)
        else {
            throw PDFFixtureError.missingGeneratedPage
        }

        let goTo = PDFAnnotation(bounds: CGRect(x: 48, y: 700, width: 200, height: 24), forType: .link, withProperties: nil)
        goTo.action = PDFActionGoTo(destination: PDFDestination(page: page2, at: CGPoint(x: 0, y: 780)))

        let external = PDFAnnotation(bounds: CGRect(x: 48, y: 660, width: 200, height: 24), forType: .link, withProperties: nil)
        external.action = PDFActionURL(url: URL(string: "https://example.invalid/open")!)

        let wrappedURL = URL(string: "https://example.invalid/wrapped")!
        let wrapA = PDFAnnotation(bounds: CGRect(x: 48, y: 620, width: 200, height: 24), forType: .link, withProperties: nil)
        wrapA.action = PDFActionURL(url: wrappedURL)
        let wrapB = PDFAnnotation(bounds: CGRect(x: 48, y: 596, width: 110, height: 24), forType: .link, withProperties: nil)
        wrapB.action = PDFActionURL(url: wrappedURL)

        for annotation in [goTo, external, wrapA, wrapB] { page1.addAnnotation(annotation) }

        let outputURL = directory.appendingPathComponent(name)
        guard document.write(to: outputURL) else {
            throw PDFFixtureError.couldNotWriteDocument
        }
        return outputURL
    }
    @discardableResult
    public static func makePerformancePDF(
        _ kind: PerformancePDFFixtureKind,
        in directory: URL
    ) throws -> URL {
        switch kind {
        case .S, .L:
            return try makePerformanceTextPDF(kind, in: directory)
        case .F:
            return try makePerformanceRasterPDF(in: directory)
        case .B:
            return try makeEmptyPDF(in: directory, name: kind.fileName, pageCount: kind.pageCount)
        }
    }

    public static func performanceSentinel(
        for kind: PerformancePDFFixtureKind
    ) -> PerformancePDFSentinel? {
        guard let pattern = kind.sentinelPattern else { return nil }
        let bounds = performanceSentinelBounds
        return PerformancePDFSentinel(
            x: bounds.origin.x,
            y: bounds.origin.y,
            width: bounds.width,
            height: bounds.height,
            pattern: pattern
        )
    }

    public static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makePerformanceTextPDF(
        _ kind: PerformancePDFFixtureKind,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent(kind.fileName)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }

        let font = CTFontCreateWithName("Menlo" as CFString, 14, nil)
        for pageIndex in 0..<kind.pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 48, y: 720)
            let label = "PDFReader performance fixture \(kind.rawValue) page \(pageIndex + 1) of \(kind.pageCount)"
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black.cgColor,
            ]
            CTLineDraw(
                CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes)),
                context
            )
            context.restoreGState()
            if pageIndex == 0 {
                drawPerformanceSentinel(kind, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func makePerformanceRasterPDF(in directory: URL) throws -> URL {
        let kind = PerformancePDFFixtureKind.F
        let url = directory.appendingPathComponent(kind.fileName)
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFFixtureError.couldNotCreateConsumer
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFFixtureError.couldNotCreateContext
        }

        for pageIndex in 0..<kind.pageCount {
            guard let image = makeDeterministicRasterImage(seed: UInt64(pageIndex + 1)) else {
                throw PDFFixtureError.couldNotCreateRasterImage
            }
            context.beginPDFPage(nil)
            context.draw(image, in: mediaBox)
            if pageIndex == 0 {
                drawPerformanceSentinel(kind, in: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func makeDeterministicRasterImage(seed: UInt64) -> CGImage? {
        let width = 850
        let height = 1_100
        let bytesPerRow = width * 3
        var generator = DeterministicByteGenerator(seed: 0x50444652_0000_0000 ^ seed)
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for index in bytes.indices {
            bytes[index] = generator.next()
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func drawPerformanceSentinel(
        _ kind: PerformancePDFFixtureKind,
        in context: CGContext
    ) {
        let bounds = performanceSentinelBounds
        let black = NSColor.black.cgColor
        let white = NSColor.white.cgColor
        let magenta = NSColor(deviceRed: 1, green: 0, blue: 1, alpha: 1).cgColor
        let lime = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1).cgColor
        let colors: [CGColor]
        switch kind {
        case .S:
            colors = [magenta, black, lime, white, black, lime, white, magenta]
        case .L:
            colors = [lime, lime, black, magenta, white, black, magenta, white]
        case .F:
            colors = [black, magenta, black, lime, white, lime, white, magenta]
        case .B:
            return
        }

        context.saveGState()
        context.setFillColor(black)
        context.fill(bounds)
        let columns = 4
        let rows = 2
        let cellWidth = bounds.width / CGFloat(columns)
        let cellHeight = bounds.height / CGFloat(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let color = colors[(row * columns) + column]
                context.setFillColor(color)
                context.fill(
                    CGRect(
                        x: bounds.minX + CGFloat(column) * cellWidth + 4,
                        y: bounds.minY + CGFloat(row) * cellHeight + 4,
                        width: cellWidth - 8,
                        height: cellHeight - 8
                    )
                )
            }
        }
        context.restoreGState()
    }
}

private struct DeterministicByteGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed
    }

    mutating func next() -> UInt8 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return UInt8(truncatingIfNeeded: state >> 24)
    }
}
