import Foundation
import PDFReaderCore
import Testing

@Suite("Viewer-first product scope")
struct ProductScopeTests {
    @Test("V-SCOPE-01 action and menu vocabulary excludes advanced research and editing features")
    func publicCommandVocabularyIsViewerOnly() {
        #expect(ActionRegistry.v1.actionIDs == ActionID.allCases)
        #expect(ActionRegistry.v1.actionIDs.count == 27)
        #expect(ActionSurfaceRegistry.validate().isEmpty)

        let publicVocabulary = (
            ActionRegistry.v1.descriptors.flatMap { [$0.id.rawValue, $0.title] }
                + MenuItemRegistry.v1.flatMap { [$0.identifier, $0.title, $0.actionID.rawValue] }
        )
        .joined(separator: " ")
        .lowercased()

        let excludedPhrases = [
            "bookmark",
            "annotation",
            "portal",
            "smart jump",
            "command palette",
            "external command",
            "script",
            "plugin",
            "macro",
            "ocr",
            "print",
            "export",
            "save as",
        ]
        for phrase in excludedPhrases {
            #expect(!publicVocabulary.contains(phrase), "unexpected v1 command surface: \(phrase)")
        }
    }

    @Test("V-SCOPE-02 bundle declares a Viewer-only PDF document role")
    func bundleManifestIsViewerOnly() throws {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent("PDFReaderApp/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(documentTypes.count == 1)
        #expect(documentTypes.first?["CFBundleTypeRole"] as? String == "Viewer")
        #expect(documentTypes.first?["LSItemContentTypes"] as? [String] == ["com.adobe.pdf"])
        #expect(plist["UTExportedTypeDeclarations"] == nil)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
