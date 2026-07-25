import AppKit
import Foundation
import PDFReaderCore
import Testing

@Suite("Viewer-first product scope")
struct ProductScopeTests {
    @Test("V-SCOPE-01 action and menu vocabulary excludes advanced research and editing features")
    func publicCommandVocabularyIsViewerOnly() {
        #expect(ActionRegistry.v1.actionIDs == ActionID.allCases)
        #expect(ActionRegistry.v1.actionIDs.count == 36)
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

    @Test("V-SCOPE-03 bundle declares the Modeleaf product identity and selected icon")
    func bundleDeclaresModeleafIdentityAndSelectedApplicationIcon() throws {
        let root = repositoryRoot()
        let data = try Data(contentsOf: root.appendingPathComponent("PDFReaderApp/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["CFBundleDisplayName"] as? String == "Modeleaf")
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("PDFReaderApp/Resources/AppIcon.icns").path
            )
        )
        let masterURL = root.appendingPathComponent("Assets/AppIcon/AppIcon-1024.png")
        let representation = try #require(NSBitmapImageRep(data: Data(contentsOf: masterURL)))
        #expect(representation.hasAlpha)
        #expect((representation.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01)
        #expect((representation.colorAt(x: 512, y: 512)?.alphaComponent ?? 0) > 0.99)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
