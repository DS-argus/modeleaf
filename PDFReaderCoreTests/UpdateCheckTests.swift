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

    @Test("banner appears only for a strictly newer release")
    func bannerGating() {
        #expect(UpdateNotice.bannerText(current: "0.2.0", latest: "0.2.0", source: .homebrew) == nil)
        #expect(UpdateNotice.bannerText(current: "0.3.0", latest: "0.2.0", source: .manual) == nil)
        #expect(UpdateNotice.bannerText(current: "bad", latest: "0.3.0", source: .homebrew) == nil)
        #expect(UpdateNotice.bannerText(current: "0.2.0", latest: "not-a-version", source: .homebrew) == nil)
    }

    @Test("banner instruction depends on the install source")
    func bannerBySource() throws {
        let brew = try #require(UpdateNotice.bannerText(current: "0.2.0", latest: "v0.3.0", source: .homebrew))
        #expect(brew == "\u{2191} Modeleaf 0.3.0 available \u{2014} brew upgrade --cask modeleaf")

        let manual = try #require(UpdateNotice.bannerText(current: "0.2.0", latest: "v0.3.0", source: .manual))
        #expect(manual == "\u{2191} Modeleaf 0.3.0 available \u{2014} click to open Releases")
    }
}
