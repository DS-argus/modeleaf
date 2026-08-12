import AppKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("Update banner UI + source detection")
@MainActor
struct UpdateBannerTests {
    @Test("presenting an update shows the banner text; clearing removes it")
    func presentAndClear() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        #expect(bar.updateText == nil)

        let text = "\u{2191} Modeleaf 0.3.0 available \u{2014} brew upgrade --cask modeleaf"
        bar.presentUpdate(text)
        #expect(bar.updateText == text)

        bar.presentUpdate(nil)
        #expect(bar.updateText == nil)
        bar.presentUpdate("   ")
        #expect(bar.updateText == nil) // whitespace-only is treated as no banner
    }

    @Test("clicking the banner fires the callback")
    func click() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        var fired = 0
        bar.onUpdateClicked = { fired += 1 }
        bar.presentUpdate("\u{2191} update")
        bar.performUpdateClickForTesting()
        #expect(fired == 1)
    }

    @Test("the status bar has no ambiguous layout with the banner shown")
    func unambiguousLayout() {
        let bar = StatusBarView(frame: NSRect(x: 0, y: 0, width: 480, height: 24))
        bar.apply(theme: AppKitTheme(themeID: .tokyoNight))
        bar.presentUpdate("\u{2191} Modeleaf 0.3.0 available \u{2014} brew upgrade --cask modeleaf")
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.hasAmbiguousLayout)
    }

    @Test("install source is homebrew only when a Caskroom copy exists")
    func installSource() {
        #expect(InstallSourceDetector.detect { _ in false } == .manual)
        #expect(InstallSourceDetector.detect { _ in true } == .homebrew)
        #expect(InstallSourceDetector.detect { $0 == "/opt/homebrew/Caskroom/modeleaf" } == .homebrew)
    }
}
