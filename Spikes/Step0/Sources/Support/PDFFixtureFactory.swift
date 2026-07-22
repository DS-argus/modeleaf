import AppKit
import CoreText
import Foundation
import PDFKit

@MainActor
enum PDFFixtureFactory {
    static func searchableDocument(pageCount: Int, repeatedText: String) throws -> PDFDocument {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ProbeFailure.invariant("unable to create PDF data consumer")
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ProbeFailure.invariant("unable to create PDF graphics context")
        }

        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 48, y: 720)
            let text = "Page \(pageIndex + 1) \(repeatedText)"
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

        guard let document = PDFDocument(data: data as Data) else {
            throw ProbeFailure.invariant("PDFKit could not reopen generated text fixture")
        }
        return document
    }
}
