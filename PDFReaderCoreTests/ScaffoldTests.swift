import PDFReaderCore
import Testing

@Test("core target is linked")
func coreTargetIsLinked() {
    #expect(PDFReaderCoreVersion.current == "0.1.0-dev")
}
