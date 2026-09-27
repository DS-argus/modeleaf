import AppKit
import PDFReaderCore

@MainActor
final class SettingsCoordinator {
    static let prefixRowID = "input.prefix"
    private let service: SettingsService
    private let view: SettingsOverlayView
    private weak var window: NSWindow?
    private let currentConfig: () -> ValidatedAppConfig
    private let currentGeneration: () -> Int
    private let install: (ValidatedAppConfig) -> Void
    private let closePanel: () -> Void
    private var snapshot: SettingsSnapshot?
    private var draft = ShortcutSettingsDraft(source: SparseAppConfig())
    private var values = SettingsFormValues()
    private var baselineValues = SettingsFormValues()
    private var generation = 0
    private var recorder: ShortcutRecordingSession?
    private var blocked = false
    private var message: String?

    init(service: SettingsService, view: SettingsOverlayView, window: NSWindow,
         currentConfig: @escaping () -> ValidatedAppConfig,
         currentGeneration: @escaping () -> Int,
         install: @escaping (ValidatedAppConfig) -> Void,
         closePanel: @escaping () -> Void) {
        self.service = service
        self.view = view
        self.window = window
        self.currentConfig = currentConfig
        self.currentGeneration = currentGeneration
        self.install = install
        self.closePanel = closePanel
        view.shortcuts.onRecord = { [weak self] in self?.record(row: $0) }
        view.shortcuts.onReset = { [weak self] in self?.reset(row: $0) }
        view.onGeneralChanged = { [weak self] values in
            guard let self, !self.blocked else { return }
            self.values = values
            self.message = nil
            self.render()
        }
        view.onSectionChanged = { [weak self] _ in self?.recorder?.cancel() }
        view.onApply = { [weak self] in _ = self?.apply() }
        view.onDiscard = { [weak self] in self?.discard() }
        view.onRestoreDefaults = { [weak self] in self?.restoreDefaults() }
        view.onReload = { [weak self] in self?.reloadSaved() }
        view.onClose = { [weak self] in _ = self?.requestClose() }
    }

    func open() { loadSaved(activate: false); render() }
    var isDirty: Bool { draft.isDirty || values != baselineValues }
    var isRecording: Bool { recorder != nil }

    /// Synchronous by contract: MainWindowController.windowShouldClose and
    /// ApplicationController app-quit both use this Bool result. Dirty closes
    /// run the custom modal panel before returning; no async continuation is needed.
    @discardableResult
    func requestClose() -> Bool {
        recorder?.cancel()
        guard isDirty || view.hasPendingEditorForClose else {
            closePanel()
            return true
        }

        switch view.runCloseConfirmation() {
        case .continueEditing:
            view.restoreCloseFocusAfterConfirmation()
            return false
        case .discardAndClose:
            discardDraftForClose()
            closePanel()
            return true
        case .saveAndClose:
            guard apply() else {
                view.restoreCloseFocusAfterConfirmation()
                return false
            }
            closePanel()
            return true
        }
    }

    private func formValues(_ config: EffectiveAppConfig) -> SettingsFormValues {
        SettingsFormValues(
            smallScrollPoints: String(config.navigation.smallScrollPoints),
            largeScrollPercent: String(config.navigation.largeScrollViewportFraction * 100),
            zoomFactor: String(config.navigation.zoomFactor),
            prefixTimeoutMilliseconds: String(config.input.prefixTimeoutMilliseconds),
            confirmExternalLinks: !config.links.skipExternalLinkHintConfirmation
        )
    }

    private func loadSaved(activate: Bool) {
        let loaded = service.load()
        draft = ShortcutSettingsDraft(source: loaded.sparse)
        values = formValues(loaded.activeConfig.config)
        baselineValues = values
        snapshot = loaded.snapshot
        generation = currentGeneration()
        blocked = !loaded.diagnostics.filter { $0.severity == .error }.isEmpty || snapshot == nil
        message = loaded.diagnostics.isEmpty ? nil : loaded.diagnostics.map(\.message).joined(separator: "\n")
        if blocked { return }
        if activate { install(loaded.activeConfig); generation = currentGeneration() }
        else if loaded.activeConfig.config != currentConfig().config {
            blocked = true
            message = "Saved settings changed. Reload saved settings before editing."
        }
    }

    private enum FormError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(text) = self { return text }; return nil }
    }

    private func source(from candidate: ShortcutSettingsDraft) throws -> SparseAppConfig {
        guard let small = Double(values.smallScrollPoints), small.isFinite,
              ConfigBounds.smallScrollPoints.contains(small) else {
            throw FormError.invalid("Small scroll must be 1–512 points.")
        }
        guard let percent = Double(values.largeScrollPercent), percent.isFinite,
              ConfigBounds.largeScrollViewportFraction.contains(percent / 100) else {
            throw FormError.invalid("Large scroll must be 10–200% of the viewport.")
        }
        guard let zoom = Double(values.zoomFactor), zoom.isFinite, ConfigBounds.zoomFactor.contains(zoom) else {
            throw FormError.invalid("Zoom factor must be 1.01–2.0.")
        }
        guard let timeout = Int(values.prefixTimeoutMilliseconds), ConfigBounds.prefixTimeoutMilliseconds.contains(timeout) else {
            throw FormError.invalid("Key sequence timeout must be 100–2,000 milliseconds.")
        }
        guard candidate.hasValidPrefix else { throw FormError.invalid("The common prefix must be one key or modifier chord.") }
        return SparseAppConfig(keymap: candidate.overrides,
            navigation: SparseNavigationConfiguration(smallScrollPoints: small, largeScrollViewportFraction: percent / 100, zoomFactor: zoom),
            input: SparseInputConfiguration(prefixTimeoutMilliseconds: timeout, prefix: candidate.prefix),
            links: SparseLinksConfiguration(skipExternalLinkHintConfirmation: !values.confirmExternalLinks))
    }

    private func record(row id: String) {
        guard !blocked, let window else { return }
        let target: ShortcutRecordingTarget
        if id == Self.prefixRowID { target = .prefix }
        else {
            guard let action = ActionID(rawValue: id), ActionHelpCatalog.isEditableInSettings(action),
                  let prefix = try? KeySequenceParser.parseSingleToken(draft.prefix) else { return }
            target = .binding(prefix: prefix)
        }
        recorder?.cancel()
        let session = ShortcutRecordingSession(window: window, target: target, onChange: { [weak self] text, error in
            guard let self else { return }
            self.view.shortcuts.setRecording(rowID: id, text: text)
            if let error { self.message = error; self.view.shortcuts.flashError(rowID: id, message: error) }
            self.render()
        }, onFinish: { [weak self] outcome in
            guard let self else { return }
            self.recorder = nil
            self.view.shortcuts.endRecording()
            switch outcome {
            case let .recorded(source): self.acceptRecordedSource(source, for: id)
            case .cancelled: self.message = nil; self.render()
            case let .invalid(reason): self.reject(reason, row: id)
            }
        })
        recorder = session
        session.start()
    }

    func acceptRecordedSource(_ value: String, for id: String) {
        guard !blocked else { return }
        var candidate = draft
        if id == Self.prefixRowID {
            guard !value.isEmpty else { return }
            candidate.setPrefix(value)
        } else {
            guard let action = ActionID(rawValue: id), ActionHelpCatalog.isEditableInSettings(action) else { return }
            var aliases = candidate.aliases(for: action)
            if aliases.isEmpty { if !value.isEmpty { aliases.append(value) } }
            else if value.isEmpty { aliases.removeFirst() }
            else { aliases[0] = value }
            candidate.setAliases(aliases, for: action)
        }
        accept(candidate, row: id)
    }

    private func reset(row id: String) {
        guard !blocked, recorder == nil else { return }
        var candidate = draft
        if id == Self.prefixRowID { candidate.setPrefix(BuiltInDefaults.config.input.prefix) }
        else {
            guard let action = ActionID(rawValue: id), ActionHelpCatalog.isEditableInSettings(action) else { return }
            candidate.reset(action)
        }
        accept(candidate, row: id)
    }

    private func accept(_ candidate: ShortcutSettingsDraft, row: String) {
        do {
            let report = ConfigValidator.validate(try source(from: candidate))
            guard report.isValid else { reject(report.diagnostics.map(\.message).joined(separator: "\n"), row: row); return }
            draft = candidate
            message = nil
            render()
        } catch { reject(error.localizedDescription, row: row) }
    }

    private func reject(_ reason: String, row: String) {
        message = reason
        render()
        view.shortcuts.flashError(rowID: row, message: reason)
    }

    private func discard() {
        recorder?.cancel()
        guard !isDirty || confirm("Discard changes in both settings sections?", action: "Discard Changes") else { return }
        discardDraftForClose()
    }

    private func discardDraftForClose() {
        recorder?.cancel()
        view.cancelEditingForClose()
        draft.discard()
        values = baselineValues
        message = nil
        render()
    }

    private func reloadSaved() {
        recorder?.cancel()
        guard !isDirty || confirm("Discard changes and reload saved settings?", action: "Reload Saved Settings") else { return }
        loadSaved(activate: true)
        render()
    }

    private func restoreDefaults() {
        guard !blocked else { return }
        recorder?.cancel()
        guard confirm("Restore General and Keyboard Shortcuts defaults?", action: "Restore Defaults") else { return }
        for action in Array(draft.overrides.keys) {
            if let id = ActionID(rawValue: action) { draft.reset(id) }
        }
        draft.setPrefix(BuiltInDefaults.config.input.prefix)
        values = formValues(BuiltInDefaults.config)
        message = "Defaults restored in the draft. Apply to save."
        render()
    }

    private func confirm(_ title: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Saved settings are not changed until Apply."
        alert.addButton(withTitle: "Continue Editing")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    @discardableResult
    func apply() -> Bool {
        guard !blocked, recorder == nil, !view.hasPendingEditorForClose, isDirty, let snapshot else {
            if view.hasPendingEditorForClose {
                message = "Finish or cancel the active edit before applying."
                render()
            }
            return false
        }
        guard generation == currentGeneration() else {
            blocked = true
            message = "Settings changed. Reload saved settings before applying."
            render()
            return false
        }
        do {
            let bytes = try service.encode(source(from: draft))
            let validated = service.validate(data: bytes)
            guard validated.isValid, let active = validated.validatedConfig, let sparse = validated.sparse else {
                message = validated.diagnostics.map(\.message).joined(separator: "\n")
                render()
                return false
            }
            switch service.store.save(bytes, expected: snapshot) {
            case let .saved(saved):
                acceptSaved(active, source: sparse, snapshot: saved)
                message = "Settings applied."
                render()
                return true
            case let .publishedWarning(saved, warning):
                acceptSaved(active, source: sparse, snapshot: saved)
                blocked = true
                message = warning
            case let .publicationUncertain(reason):
                blocked = true
                message = "Settings publication needs reconciliation: \(reason)"
            case .conflict:
                blocked = true
                message = "Saved settings changed; nothing was overwritten. Reload saved settings."
            case let .precommitFailed(reason):
                message = "Settings were not saved: \(reason)"
            }
        } catch {
            message = error.localizedDescription
        }
        render()
        return false
    }

    private func acceptSaved(_ active: ValidatedAppConfig, source: SparseAppConfig, snapshot: SettingsSnapshot) {
        install(active)
        self.snapshot = snapshot
        draft = ShortcutSettingsDraft(source: source)
        values = formValues(active.config)
        baselineValues = values
        generation = currentGeneration()
    }

    private func render() {
        var rows = [ShortcutSettingsRow(id: Self.prefixRowID, title: "Common Prefix", group: "",
            current: draft.prefix, defaultBinding: BuiltInDefaults.config.input.prefix)]
        for section in ActionHelpCatalog.sections {
            for action in section.actions where ActionHelpCatalog.isEditableInSettings(action) {
                guard let descriptor = ActionRegistry.v1.descriptor(for: action) else { continue }
                let aliases = draft.aliases(for: action)
                rows.append(ShortcutSettingsRow(id: action.rawValue, title: descriptor.title, group: section.title,
                    current: aliases.first, defaultBinding: BuiltInDefaults.editableTemplatedKeymap[action]?.first,
                    additionalBindingCount: max(0, aliases.count - 1)))
            }
        }
        var status = message
        var valid = false
        do {
            let report = ConfigValidator.validate(try source(from: draft))
            valid = report.isValid
            if !valid { status = report.diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "\n") }
        } catch { status = error.localizedDescription }
        let canApply = !blocked && recorder == nil && !view.hasPendingEditorForClose && isDirty && valid
        view.shortcuts.render(rows: rows, status: nil, canApply: canApply, isDirty: isDirty)
        view.shortcuts.setNeedsReconciliation(blocked)
        view.render(values: values, status: status, canApply: canApply, isDirty: isDirty, blocked: blocked)
    }
}
