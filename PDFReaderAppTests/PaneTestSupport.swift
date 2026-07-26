@testable import PDFReaderApp

@MainActor func withStackedOuterBands(_ value: Bool, _ body: () throws -> Void) rethrows {
    let original = PaneFeatureFlags.stackedOuterBands
    PaneFeatureFlags.stackedOuterBands = value
    defer { PaneFeatureFlags.stackedOuterBands = original }
    try body()
}
