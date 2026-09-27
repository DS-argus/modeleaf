import Foundation
import XCTest

/// Native keyboard-first coverage for the Settings shell and its embedded shortcut editor.
/// Each test gives Modeleaf a private HOME so no user configuration is read or changed.
final class ShortcutSettingsUITests: XCTestCase {
    @MainActor
    func testKeyboardShortcutsOpenByCommandCommaSearchEnterAndEscModes() throws {
        try withEnvironment(settings: Self.baseSettings) { _, app in
            try openSettings(in: app)
            XCTAssertFalse(app.descendants(matching: .any)["shortcutSettings.close"].exists)

            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(row("help.show", in: app).exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(panel(in: app).exists)
            app.typeKey("j", modifierFlags: [])
            app.typeKey("k", modifierFlags: [])
            app.typeKey(.downArrow, modifierFlags: [])
            app.typeKey(.upArrow, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "Press keys", timeout: 2))
            app.typeKey(.escape, modifierFlags: [])

            try beginSearch("No such shortcut action", in: app)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(panel(in: app).exists)
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitUntilAbsent(panel(in: app), timeout: 2))
        }
    }

    @MainActor
    func testEnterFinishesRecordingEscRowExitsPanelEnterAppliesAndEscCloses() throws {
        try withEnvironment(settings: Self.baseSettings) { _, app in
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            app.typeText("z")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "z", timeout: 2))

            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(panel(in: app).exists)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForSettingsStatus(in: app, containing: "Settings applied.", timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitUntilAbsent(panel(in: app), timeout: 2))
        }
    }

    @MainActor
    func testNonEmptyEscapeCancelsAndInvalidEnterPreservesPreviousWithError() throws {
        try withEnvironment(settings: Self.settings(helpShow: ["x"])) { _, app in
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            app.typeText("z")
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "x", timeout: 2))

            app.typeKey(.return, modifierFlags: [])
            app.typeText("abc")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForSettingsStatus(in: app, containing: "two plain keys", timeout: 2))
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "x", timeout: 2))
        }
    }

    @MainActor
    func testBlankEnterUnbindsActionAndPrefixBlankEnterKeepsOld() throws {
        try withEnvironment(settings: Self.settings(helpShow: ["x"], prefix: "<C-x>")) { _, app in
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "Unassigned", timeout: 2))

            try beginSearch("Common Prefix", in: app)
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("input.prefix", in: app), containing: "⌃x", timeout: 2))
        }
    }

    @MainActor
    func testRawControlBPrefixFollowerAndModifiedEnterAreCaptured() throws {
        try withEnvironment(settings: Self.baseSettings) { _, app in
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            app.typeKey("b", modifierFlags: .control)
            app.typeKey("z", modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "<pre>", timeout: 2))

            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: .command)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "⌘", timeout: 2))
        }
    }

    @MainActor
    func testJKRSlashAndTabStayLiteralDuringRecording() throws {
        try withEnvironment(settings: Self.baseSettings) { _, app in
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            for key in ["j", "k", "r", "/"] {
                app.typeKey(.return, modifierFlags: [])
                app.typeKey(key, modifierFlags: [])
                app.typeKey(.return, modifierFlags: [])
                XCTAssertTrue(waitForText(current("help.show", in: app), containing: key, timeout: 2))
            }
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.tab, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "Tab", timeout: 2))
            let searchValue = app.descendants(matching: .any)["shortcutSettings.search"].value as? String ?? ""
            XCTAssertFalse(searchValue.contains("/"), "Slash escaped recording into search")
        }
    }

    @MainActor
    func testFixedFoundationsSurviveEmptyEditableAliasesAndDirtyCloseDialog() throws {
        let settings = Self.settings(helpShow: ["x"])
        try withEnvironment(settings: settings) { environment, app in
            try openSettings(in: app)
            try beginSearch("Scroll Down", in: app)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("scroll.down", in: app), containing: "Unassigned", timeout: 2))
            XCTAssertTrue(row("scroll.down", in: app).exists)

            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            app.typeText("z")
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.escape, modifierFlags: [])
            let keep = try dialogButton("Continue Editing", in: app)
            keep.click()
            XCTAssertTrue(panel(in: app).waitForExistence(timeout: 2))
            app.typeKey(.escape, modifierFlags: [])
            let discard = try dialogButton("Discard and Close", in: app)
            discard.click()

            XCTAssertTrue(waitUntilAbsent(panel(in: app), timeout: 3))
            XCTAssertEqual(try Data(contentsOf: environment.settingsURL), Data(settings.utf8))
        }
    }

    @MainActor
    func testNativeCommandKeysAreNotExecutedDuringRecording() throws {
        try withEnvironment(settings: Self.baseSettings) { _, app in
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            for key in ["q", "w", "o", "p"] {
                app.typeKey(.return, modifierFlags: [])
                app.typeKey(key, modifierFlags: .command)
                XCTAssertTrue(panel(in: app).exists)
                XCTAssertTrue(waitForText(current("help.show", in: app), containing: "⌘\(key)", timeout: 2))
                XCTAssertFalse(app.sheets.firstMatch.waitForExistence(timeout: 0.4))
                app.typeKey(.return, modifierFlags: [])
                app.typeKey(.escape, modifierFlags: [])
                if key != "p" { app.typeKey("j", modifierFlags: []) }
            }
        }
    }

    @MainActor
    func testGeneralFieldsAndConfirmationShareSettingsApply() throws {
        try withEnvironment(settings: Self.baseSettings) { environment, app in
            try openSettings(in: app)
            try replaceText("settings.general.smallScrollPoints", with: "48", in: app)
            try replaceText("settings.general.largeScrollPercent", with: "125", in: app)
            try replaceText("settings.general.zoomFactor", with: "1.25", in: app)
            try control("settings.general.confirmExternalLinks", in: app).click()

            let apply = try control("settings.apply", in: app)
            XCTAssertTrue(apply.isEnabled)
            apply.click()
            XCTAssertTrue(waitForSettingsStatus(in: app, containing: "Settings applied.", timeout: 3))

            let object = try settingsObject(at: environment.settingsURL)
            let settings = try XCTUnwrap(object["settings"] as? [String: Any])
            let navigation = try XCTUnwrap(settings["navigation"] as? [String: Any])
            XCTAssertEqual((navigation["small_scroll_points"] as? NSNumber)?.doubleValue, 48)
            XCTAssertEqual((navigation["large_scroll_viewport_fraction"] as? NSNumber)?.doubleValue, 1.25)
            XCTAssertEqual((navigation["zoom_factor"] as? NSNumber)?.doubleValue, 1.25)
            let links = try XCTUnwrap(settings["links"] as? [String: Any])
            XCTAssertEqual(links["skip_external_link_hint_confirmation"] as? Bool, true)
        }
    }

    @MainActor
    func testKeyboardPrefixTimeoutSharesApplyAndSectionNavigationRetainsDraft() throws {
        try withEnvironment(settings: Self.baseSettings) { environment, app in
            try openSettings(in: app)
            try replaceText("settings.general.smallScrollPoints", with: "48", in: app)
            try control("settings.sidebar.keyboardShortcuts", in: app).click()
            try replaceText("settings.keyboard.prefixTimeoutMilliseconds", with: "650", in: app)
            try control("settings.sidebar.general", in: app).click()
            XCTAssertTrue(waitForText(try control("settings.general.smallScrollPoints", in: app), containing: "48", timeout: 2))
            let apply = try control("settings.apply", in: app)
            XCTAssertTrue(apply.isEnabled)
            apply.click()
            XCTAssertTrue(waitForSettingsStatus(in: app, containing: "Settings applied.", timeout: 3))

            let object = try settingsObject(at: environment.settingsURL)
            let settings = try XCTUnwrap(object["settings"] as? [String: Any])
            let navigation = try XCTUnwrap(settings["navigation"] as? [String: Any])
            let input = try XCTUnwrap(settings["input"] as? [String: Any])
            XCTAssertEqual((navigation["small_scroll_points"] as? NSNumber)?.doubleValue, 48)
            XCTAssertEqual(input["prefix_timeout_ms"] as? Int, 650)
        }
    }

    @MainActor
    func testInvalidNumericDraftBlocksApplyAndLeavesSparseJSONUntouched() throws {
        try withEnvironment(settings: Self.baseSettings) { environment, app in
            let baseline = try Data(contentsOf: environment.settingsURL)
            try openSettings(in: app)
            try replaceText("settings.general.smallScrollPoints", with: "not-a-number", in: app)
            XCTAssertTrue(waitForSettingsStatus(in: app, containing: "Small scroll must be", timeout: 2))
            XCTAssertFalse(try control("settings.apply", in: app).isEnabled)
            XCTAssertEqual(try Data(contentsOf: environment.settingsURL), baseline)
        }
    }

    @MainActor
    func testSparseJSONRoundTripRestartAndOldTOMLIgnoredAndUntouched() throws {
        let legacy = "[keymap]\n\"help.show\" = [\"legacy\"]\n"
        try withEnvironment(settings: Self.settings(helpShow: ["x"]), legacyTOML: legacy) { environment, app in
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            app.typeText("z")
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "z", timeout: 2))
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForSettingsStatus(in: app, containing: "Settings applied.", timeout: 3))

            let object = try settingsObject(at: environment.settingsURL)
            let settings = try XCTUnwrap(object["settings"] as? [String: Any])
            let keymap = try XCTUnwrap(settings["keymap"] as? [String: Any])
            XCTAssertEqual(keymap["help.show"] as? [String], ["z"])
            XCTAssertEqual(try String(contentsOf: environment.legacyTOMLURL, encoding: .utf8), legacy)

            app.terminate()
            app.launch()
            XCTAssertTrue(app.windows["mainWindow"].waitForExistence(timeout: 5))
            app.activate()
            try openSettings(in: app)
            try beginSearch("Keyboard Help", in: app)
            app.typeKey(.return, modifierFlags: [])
            XCTAssertTrue(waitForText(current("help.show", in: app), containing: "z", timeout: 2))
            XCTAssertEqual(try String(contentsOf: environment.legacyTOMLURL, encoding: .utf8), legacy)
        }
    }

    private static let baseSettings = ShortcutSettingsUITests.settings()

    private static func settings(helpShow: [String] = [], prefix: String? = nil) -> String {
        let keymap: [String: [String]] = [
            "help.show": helpShow,
            "scroll.down": [],
            "scroll.up": [],
            "scroll.left": [],
            "search.prompt": [],
        ]
        var settings: [String: Any] = ["keymap": keymap]
        if let prefix {
            settings["input"] = ["prefix": prefix]
        }
        let envelope: [String: Any] = ["version": 1, "settings": settings]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: data, encoding: .utf8)
        else { preconditionFailure("Could not encode UI test settings fixture") }
        return result
    }

    @MainActor
    private func withEnvironment(
        settings: String?,
        legacyTOML: String? = nil,
        body: (UITestEnvironment, XCUIApplication) throws -> Void
    ) throws {
        let environment = try UITestEnvironment(settings: settings ?? Self.baseSettings, legacyTOML: legacyTOML)
        let app = XCUIApplication()
        app.launchEnvironment["HOME"] = environment.home.path
        app.launchEnvironment["CFFIXED_USER_HOME"] = environment.home.path
        var cleaned = false
        let cleanup: @MainActor () -> Void = {
            guard !cleaned else { return }
            cleaned = true
            app.terminate()
            environment.remove()
        }
        addTeardownBlock { @MainActor in cleanup() }
        defer { cleanup() }
        app.launch()
        XCTAssertTrue(app.windows["mainWindow"].waitForExistence(timeout: 5))
        app.activate()
        try body(environment, app)
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) throws {
        app.activate()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(panel(in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(try control("settings.sidebar.general", in: app).exists)
        XCTAssertTrue(try control("settings.general.smallScrollPoints", in: app).exists)
        XCTAssertFalse(app.descendants(matching: .any)["shortcutSettings.close"].exists)
    }

    @MainActor
    private func beginSearch(_ title: String, in app: XCUIApplication) throws {
        try control("settings.sidebar.keyboardShortcuts", in: app).click()
        XCTAssertTrue(try control("settings.keyboard.prefixTimeoutMilliseconds", in: app).waitForExistence(timeout: 3))
        app.typeKey("/", modifierFlags: [])
        let field = try control("shortcutSettings.search", in: app)
        field.typeKey("a", modifierFlags: .command)
        field.typeText(title)
    }

    @MainActor
    private func replaceText(_ identifier: String, with value: String, in app: XCUIApplication) throws {
        let field = try control(identifier, in: app)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(value)
    }

    @MainActor
    private func control(_ identifier: String, in app: XCUIApplication) throws -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 3), "Missing control \(identifier)")
        return element
    }

    @MainActor
    private func row(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["shortcutSettings.row.\(id)"]
    }

    @MainActor
    private func current(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["shortcutSettings.row.\(id).current"]
    }

    @MainActor
    private func panel(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["settingsOverlay"]
    }

    @MainActor
    private func waitForSettingsStatus(in app: XCUIApplication, containing text: String, timeout: TimeInterval) -> Bool {
        waitForText(app.descendants(matching: .any)["settings.status"], containing: text, timeout: timeout)
    }

    @MainActor
    private func waitForText(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { value, _ in
            guard let element = value as? XCUIElement else { return false }
            let value = element.value as? String
            return element.exists && (value?.contains(text) == true || element.label.contains(text))
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func waitUntilAbsent(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { value, _ in
            guard let element = value as? XCUIElement else { return true }
            return !element.exists
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    private func settingsObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [])
        return try XCTUnwrap(object as? [String: Any])
    }

    @MainActor
    private func dialogButton(_ title: String, in app: XCUIApplication) throws -> XCUIElement {
        let button = app.descendants(matching: .button)
            .matching(NSPredicate(format: "label == %@ OR title == %@", title, title))
            .firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "Missing native dialog button \(title)")
        return button
    }
}

private struct UITestEnvironment {
    let home: URL
    let settingsURL: URL
    let legacyTOMLURL: URL

    init(settings: String, legacyTOML: String?) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("modeleaf-shortcut-ui-\(UUID().uuidString)", isDirectory: true)
        let settingsDirectory = home.appendingPathComponent("Library/Application Support/Modeleaf", isDirectory: true)
        settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        let legacyDirectory = home.appendingPathComponent(".config/modeleaf", isDirectory: true)
        legacyTOMLURL = legacyDirectory.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        try Data(settings.utf8).write(to: settingsURL, options: .atomic)
        if let legacyTOML {
            try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
            try Data(legacyTOML.utf8).write(to: legacyTOMLURL, options: .atomic)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}
