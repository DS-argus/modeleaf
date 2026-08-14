import CoreGraphics
import Foundation
import PDFKit
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

@Suite("Reader outline model")
@MainActor
struct ReaderOutlineTests {
    @Test("canonical rows are flat preorder with valid-only consecutive selectors")
    func flatPreorderRowsPreserveInvalidParents() throws {
        let document = PDFDocument()
        let firstPage = PDFPage()
        let secondPage = PDFPage()
        document.insert(firstPage, at: 0)
        document.insert(secondPage, at: 1)
        let root = PDFOutline()
        let first = outline("First", PDFDestination(page: firstPage, at: CGPoint(x: 10, y: 700)))
        let invalid = outline("Invalid parent", nil)
        invalid.insertChild(outline("Nested", PDFDestination(page: secondPage, at: CGPoint(x: 10, y: 600))), at: 0)
        root.insertChild(first, at: 0)
        root.insertChild(invalid, at: 1)
        root.insertChild(outline("Last", PDFDestination(page: secondPage, at: CGPoint(x: 10, y: 300))), at: 2)
        document.outlineRoot = root

        let model = ReaderOutline(document: document, normalizeDestination: normalize(in: document))
        let snapshot = model.snapshot(viewportAnchor: nil, successfulUserMovementRevision: 7)
        #expect(snapshot.rows.map(\.title) == ["First", "Invalid parent", "Nested", "Last"])
        #expect(snapshot.rows.map(\.depth) == [0, 0, 1, 0])
        #expect(snapshot.rows.map(\.selector) == [1, nil, 2, 3])
        #expect(snapshot.rows.map(\.isEnabled) == [true, false, true, true])
        #expect(snapshot.successfulUserMovementRevision == 7)
        #expect(model.destination(for: snapshot.rows[1].id) == nil)
        #expect(model.rowID(forSelector: 2) == snapshot.rows[2].id)
    }

    @Test("Leaf normalization hides a single title wrapper and deeper descendants")
    func leafNormalizationPromotesTwoVisibleLevels() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let root = PDFOutline()
        let wrapper = outline("Table of Contents", PDFDestination(page: page, at: CGPoint(x: 0, y: 750)))
        let preface = outline("Preface", PDFDestination(page: page, at: CGPoint(x: 0, y: 700)))
        let chapter = outline("Chapter 1", PDFDestination(page: page, at: CGPoint(x: 0, y: 650)))
        let section = outline("1.2 Section", PDFDestination(page: page, at: CGPoint(x: 0, y: 600)))
        let hiddenLeaf = outline("1.2.1 Hidden", PDFDestination(page: page, at: CGPoint(x: 0, y: 500)))
        section.insertChild(hiddenLeaf, at: 0)
        chapter.insertChild(section, at: 0)
        wrapper.insertChild(preface, at: 0)
        wrapper.insertChild(chapter, at: 1)
        root.insertChild(wrapper, at: 0)
        document.outlineRoot = root

        let model = ReaderOutline(document: document, normalizeDestination: normalize(in: document))
        let snapshot = model.snapshot(viewportAnchor: NavigationSnapshot(pageIndex: 0, pageSpacePoint: CGPoint(x: 0, y: 500)), successfulUserMovementRevision: 0)
        #expect(snapshot.rows.map(\.title) == ["Preface", "Chapter 1", "1.2 Section"])
        #expect(snapshot.rows.map(\.depth) == [0, 0, 1])
        #expect(snapshot.rows.map(\.selector) == [1, 2, 3])
        #expect(snapshot.currentRowID == snapshot.rows[2].id)
    }

    @Test("same destination rows retain distinct structural IDs and selectors")
    func duplicateDestinationsAreDistinctRows() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let root = PDFOutline()
        let destination = PDFDestination(page: page, at: CGPoint(x: 42, y: 500))
        root.insertChild(outline("First duplicate", destination), at: 0)
        root.insertChild(outline("Second duplicate", destination), at: 1)
        document.outlineRoot = root
        let model = ReaderOutline(document: document, normalizeDestination: normalize(in: document))
        let rows = model.snapshot(viewportAnchor: nil, successfulUserMovementRevision: 0).rows
        #expect(rows[0].id != rows[1].id)
        #expect(rows.map(\.selector) == [1, 2])
        #expect(model.destination(for: rows[0].id) == model.destination(for: rows[1].id))
    }

    @Test("tracking preserves the first duplicate at the same location")
    func trackingUsesPageAndPointOrder() throws {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let root = PDFOutline()
        root.insertChild(outline("Top", PDFDestination(page: page, at: CGPoint(x: 0, y: 700))), at: 0)
        root.insertChild(outline("First duplicate", PDFDestination(page: page, at: CGPoint(x: 0, y: 500))), at: 1)
        root.insertChild(outline("Second duplicate", PDFDestination(page: page, at: CGPoint(x: 0, y: 500))), at: 2)
        document.outlineRoot = root
        let model = ReaderOutline(document: document, normalizeDestination: normalize(in: document))
        let rows = model.snapshot(viewportAnchor: nil, successfulUserMovementRevision: 0).rows
        #expect(model.snapshot(viewportAnchor: NavigationSnapshot(pageIndex: 0, pageSpacePoint: CGPoint(x: 0, y: 750)), successfulUserMovementRevision: 0).currentRowID == nil)
        #expect(model.snapshot(viewportAnchor: NavigationSnapshot(pageIndex: 0, pageSpacePoint: CGPoint(x: 0, y: 500)), successfulUserMovementRevision: 0).currentRowID == rows[1].id)
    }

    @Test("TOC activation commits verified history")
    func verifiedTOCActivationRoundTripsHistory() throws {
        let document = PDFDocument()
        let firstPage = PDFPage()
        let secondPage = PDFPage()
        document.insert(firstPage, at: 0)
        document.insert(secondPage, at: 1)
        let root = PDFOutline()
        root.insertChild(outline("Destination", PDFDestination(page: secondPage, at: CGPoint(x: 40, y: 500))), at: 0)
        document.outlineRoot = root
        let origin = try #require(NavigationSnapshot(pageIndex: 0, pageSpacePoint: CGPoint(x: 40, y: 500)))
        var current = origin
        let session = ReaderSession(sourceURL: URL(fileURLWithPath: "/tmp/toc-history.pdf"), document: document, navigationCapture: { current }, navigationRestore: { destination in current = destination; return .verifiedLanding })
        defer { session.prepareForClose() }
        let row = try #require(session.outlineSnapshot.rows.first)
        #expect(session.activateOutlineRow(id: row.id) == .verifiedLanding)
        #expect(session.canGoBack)
        #expect(session.goBack() == .verifiedLanding)
        #expect(current == origin)
    }

    private func outline(_ label: String, _ destination: PDFDestination?) -> PDFOutline {
        let value = PDFOutline()
        value.label = label
        value.destination = destination
        return value
    }

    private func normalize(in document: PDFDocument) -> (PDFDestination) -> NavigationSnapshot? {
        { destination in
            guard let page = destination.page else { return nil }
            let index = document.index(for: page)
            guard index != NSNotFound else { return nil }
            return NavigationSnapshot(pageIndex: index, pageSpacePoint: destination.point)
        }
    }
}

@Suite("Inference outline acceptance")
@MainActor
struct InferenceOutlineAcceptanceTests {
    @Test("generated outline fixture exercises nested duplicate edge and invalid rows")
    func generatedOutlineFixtureExercisesNestedDuplicateEdgeAndInvalidRows() throws {
        try withTemporaryDirectory { directory in
            let fixture = try PDFFixtureFactory.makeTOCOutlinePDF(in: directory)
            let before = try PDFFixtureFactory.sha256(of: fixture.url)
            let document = try #require(PDFDocument(url: fixture.url))
            let controller = PDFViewController(document: document, traceID: OpenTraceID(), metrics: NoopPDFOpenMetrics())
            let model = ReaderOutline(document: document) { controller.navigationSnapshot(forOutlineDestination: $0) }
            let rows = model.snapshot(viewportAnchor: nil, successfulUserMovementRevision: 0).rows
            let outlines = leafVisibleOutlines(document.outlineRoot)
            let edgeIndices = edgeOutlineIndices(outlines)

            #expect(rows.count > 10)
            #expect(rows.count == outlines.count)
            #expect(rows[2].id != rows[3].id)
            #expect(rows[2].selector == 3 && rows[3].selector == 4)
            #expect(rows.contains { !$0.isEnabled && $0.selector == nil })
            #expect(rows.filter(\.isEnabled).count == rows.compactMap(\.selector).count)
            #expect(!edgeIndices.isEmpty)
            for index in edgeIndices {
                #expect(rows[index].isEnabled)
                #expect(rows[index].selector != nil)
            }
            #expect(try PDFFixtureFactory.sha256(of: fixture.url) == before)
        }
    }

    @Test("realInferenceOutlineNormalizesEdgeDestinationsAndPreservesSourceHash")
    func realInferenceOutlineNormalizesEdgeDestinationsAndPreservesSourceHash() throws {
        guard let path = ProcessInfo.processInfo.environment["MODELEAF_INFERENCE_PDF"] else { return }
        #expect(!path.isEmpty)
        #expect(FileManager.default.isReadableFile(atPath: path))
        let url = URL(fileURLWithPath: path)
        let before = try PDFFixtureFactory.sha256(of: url)
        let document = try #require(PDFDocument(url: url))
        let controller = PDFViewController(document: document, traceID: OpenTraceID(), metrics: NoopPDFOpenMetrics())
        let model = ReaderOutline(document: document) { controller.navigationSnapshot(forOutlineDestination: $0) }
        let rows = model.snapshot(viewportAnchor: nil, successfulUserMovementRevision: 0).rows
        let outlines = leafVisibleOutlines(document.outlineRoot)
        let edgeIndices = edgeOutlineIndices(outlines)

        #expect(rows.count == outlines.count)
        #expect(!edgeIndices.isEmpty)
        for index in edgeIndices {
            #expect(rows[index].isEnabled)
            #expect(rows[index].selector != nil)
        }
        #expect(rows.filter(\.isEnabled).count == rows.compactMap(\.selector).count)
        #expect(try PDFFixtureFactory.sha256(of: url) == before)
    }

    private func leafVisibleOutlines(_ root: PDFOutline?) -> [PDFOutline] {
        guard let root else { return [] }
        let topLevel = (0..<root.numberOfChildren).compactMap { root.child(at: $0) }
        let visibleTopLevel: [PDFOutline]
        if topLevel.count == 1, let wrapper = topLevel.first, wrapper.numberOfChildren > 0 {
            visibleTopLevel = (0..<wrapper.numberOfChildren).compactMap { wrapper.child(at: $0) }
        } else {
            visibleTopLevel = topLevel
        }
        return visibleTopLevel.flatMap { outline in
            [outline] + (0..<outline.numberOfChildren).compactMap { outline.child(at: $0) }
        }
    }

    private func edgeOutlineIndices(_ outlines: [PDFOutline]) -> [Int] {
        outlines.enumerated().compactMap { index, outline in
            guard let destination = outline.destination,
                  let page = destination.page,
                  abs(destination.point.y - 679) <= 4,
                  abs(page.bounds(for: .mediaBox).maxY - 676.3) <= 4
            else { return nil }
            return index
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
