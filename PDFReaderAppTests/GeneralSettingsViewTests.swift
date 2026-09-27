import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("General settings view", .serialized)
@MainActor
struct GeneralSettingsViewTests {
    @Test("numeric draft fields and confirmation checkbox render and emit one complete DTO")
    func controlsRenderAndChange() {
        let view = GeneralSettingsView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let values = SettingsFormValues(
            smallScrollPoints: "48",
            largeScrollPercent: "125",
            zoomFactor: "1.25",
            prefixTimeoutMilliseconds: "650",
            confirmExternalLinks: true
        )
        view.render(values: values)
        #expect(view.smallScrollPointsFieldForTesting.stringValue == "48")
        #expect(view.largeScrollPercentFieldForTesting.stringValue == "125")
        #expect(view.zoomFactorFieldForTesting.stringValue == "1.25")
        #expect(view.confirmExternalLinksButtonForTesting.state == .on)

        var changes: [SettingsFormValues] = []
        view.onChanged = { changes.append($0) }
        view.smallScrollPointsFieldForTesting.stringValue = "52"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.smallScrollPointsFieldForTesting))
        #expect(changes.last?.smallScrollPoints == "52")
        #expect(changes.last?.prefixTimeoutMilliseconds == "650")
        view.confirmExternalLinksButtonForTesting.performClick(nil)
        #expect(changes.last?.confirmExternalLinks == false)
    }

    @Test("fields retain text through a render while one native field is focused")
    func focusedDraftIsNotOverwritten() {
        let view = GeneralSettingsView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        view.render(values: SettingsFormValues(smallScrollPoints: "32"))
        _ = window.makeFirstResponder(view.smallScrollPointsFieldForTesting)
        view.smallScrollPointsFieldForTesting.stringValue = "invalid"
        view.render(values: SettingsFormValues(smallScrollPoints: "64"))
        #expect(view.smallScrollPointsFieldForTesting.stringValue == "invalid")
    }

    @Test("units and range guidance are exposed beside every numeric field")
    func rangeGuidance() {
        let view = GeneralSettingsView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        #expect(descendant(in: view, identifier: "settings.general.smallScrollPoints.unit") != nil)
        #expect(descendant(in: view, identifier: "settings.general.smallScrollPoints.help") != nil)
        #expect(descendant(in: view, identifier: "settings.general.largeScrollPercent.unit") != nil)
        #expect(descendant(in: view, identifier: "settings.general.zoomFactor.help") != nil)
    }

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let match = descendant(in: child, identifier: identifier) { return match }
        }
        return nil
    }
}
