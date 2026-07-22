import PDFReaderCore
import PDFReaderTestSupport
import XCTest

final class ScaffoldAppTests: XCTestCase {
    func testAppDependencyGraph() {
        XCTAssertEqual(TestFixtureMarker.coreVersion, PDFReaderCoreVersion.current)
    }
}
