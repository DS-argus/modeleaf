import Foundation
import Testing
@testable import PDFReaderApp

@Suite("Read-only production boundary")
struct ReadOnlyBoundaryTests {
    @Test("I-PDF-09 session and view source expose no PDF mutation implementation")
    func productionSourceHasNoMutationImplementation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relativePaths = [
            "PDFReaderApp/Reader/ReaderSession.swift",
            "PDFReaderApp/Reader/PDFViewController.swift",
            "PDFReaderApp/Input/ReaderPDFView.swift",
            "PDFReaderApp/Reader/PDFOpenService.swift",
        ]
        let productionSource = try relativePaths
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        let forbiddenPatterns = [
            #"\.write\s*\("#,
            #"\.addAnnotation\s*\("#,
            #"\.removeAnnotation\s*\("#,
            #"\binsertPage\s*\("#,
            #"\bremovePage\s*\("#,
            #"\bexchangePage\s*\("#,
            #"\bPDFAnnotation\s*\("#,
            #"\bwidgetStringValue\s*="#,
            #"\.contents\s*="#,
            #"\bunlock\w*\s*\("#,
        ]

        for pattern in forbiddenPatterns {
            #expect(productionSource.range(of: pattern, options: .regularExpression) == nil)
        }
        #expect(productionSource.contains("document = nil"))
        #expect(productionSource.contains("currentSelection = nil"))
    }

    @Test("application bundle declares PDF documents as Viewer role")
    func documentRoleIsViewer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("PDFReaderApp/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let pdfType = try #require(documentTypes.first)

        #expect(pdfType["CFBundleTypeRole"] as? String == "Viewer")
        #expect((pdfType["LSItemContentTypes"] as? [String]) == ["com.adobe.pdf"])
    }
}
