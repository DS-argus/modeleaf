import Foundation
import Testing
@testable import PDFReaderCore

@Suite("Update notice")
struct UpdateCheckTests {
    @Test("versions parse tolerantly and compare numerically")
    func versionParsing() {
        #expect(AppVersion("v0.2.0")?.components == [0, 2, 0])
        #expect(AppVersion("0.2")?.components == [0, 2])
        #expect(AppVersion("1.0.0-beta")?.components == [1, 0, 0])
        #expect(AppVersion("")  == nil)
        #expect(AppVersion("vx.y") == nil)
        // numeric, not lexical: 0.10.0 is newer than 0.9.0
        #expect(AppVersion("0.9.0")! < AppVersion("0.10.0")!)
        // trailing zeros are equivalent
        #expect(AppVersion("0.2")! == AppVersion("0.2.0")!)
        #expect(!(AppVersion("0.2.0")! < AppVersion("0.2")!))
    }

    @Test("available update appears only for a strictly newer release")
    func updateGating() throws {
        #expect(UpdateNotice.availableUpdate(current: "0.2.0", latest: "0.2.0") == nil)
        #expect(UpdateNotice.availableUpdate(current: "0.3.0", latest: "0.2.0") == nil)
        #expect(UpdateNotice.availableUpdate(current: "bad", latest: "0.3.0") == nil)
        #expect(UpdateNotice.availableUpdate(current: "0.2.0", latest: "not-a-version") == nil)

        let update = try #require(UpdateNotice.availableUpdate(current: "0.2.0", latest: "v0.3.0"))
        #expect(update.version == AppVersion("0.3.0"))
    }

    @Test("extracts the unfenced highlights section and stops at the next top-level heading")
    func highlightsExtraction() throws {
        let body = """
        # Release v0.3.0

        ## Highlights
        - Faster page navigation
        - More reliable tabs

        ### Details
        This remains part of the summary.

        ## Installation
        brew upgrade --cask modeleaf
        """
        let update = try #require(UpdateNotice.availableUpdate(current: "0.2.0", latest: "0.3.0", body: body))
        #expect(update.highlights == "- Faster page navigation\n- More reliable tabs\n\n### Details\nThis remains part of the summary.")
    }

    @Test("ignores headings inside fenced blocks and treats empty summaries as absent")
    func fencedAndEmptyHighlights() throws {
        let body = """
        ```markdown
        ## Highlights
        - hidden
        ```
        ## Highlights
        ```swift
        ## Still content
        ```
        ## Next
        """
        let update = try #require(UpdateNotice.availableUpdate(current: "0.2.0", latest: "0.3.0", body: body))
        #expect(update.highlights == "```swift\n## Still content\n```")

        let empty = try #require(UpdateNotice.availableUpdate(current: "0.2.0", latest: "0.3.0", body: "## Highlights\n   \n## Notes"))
        #expect(empty.highlights == nil)
    }

    @Test("release links are restricted at both policy and public construction boundaries")
    func releaseURLValidation() throws {
        let version = try #require(AppVersion("0.3.0"))
        let valid = URL(string: "https://github.com/DS-argus/modeleaf/releases/tag/v0.3.0")!
        #expect(AvailableUpdate(version: version, releaseURL: valid).releaseURL == valid)

        for raw in [
            "http://github.com/DS-argus/modeleaf/releases/tag/v0.3.0",
            "https://evil.example/DS-argus/modeleaf/releases/tag/v0.3.0",
            "https://user:password@github.com/DS-argus/modeleaf/releases/tag/v0.3.0",
            "https://github.com:443/DS-argus/modeleaf/releases/tag/v0.3.0",
            "https://github.com/DS-argus/modeleaf/releases/tag/",
            "https://github.com/DS-argus/modeleaf/releases/tag/v0.3.0?download=1",
            "https://github.com/DS-argus/modeleaf/releases/tag/v0.3.0#notes"
        ] {
            let url = try #require(URL(string: raw))
            #expect(AvailableUpdate(version: version, releaseURL: url).releaseURL == nil)
        }

        let update = try #require(UpdateNotice.availableUpdate(
            current: "0.2.0",
            latest: "0.3.0",
            releaseURL: "https://github.com/DS-argus/modeleaf/releases/tag/v0.3.0?download=1"
        ))
        #expect(update.releaseURL == nil)
    }
}
