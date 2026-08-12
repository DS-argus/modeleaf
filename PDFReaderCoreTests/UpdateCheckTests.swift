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
}
