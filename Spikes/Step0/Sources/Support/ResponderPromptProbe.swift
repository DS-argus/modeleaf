import AppKit
import Foundation
import PDFKit

@MainActor
private final class ProbeEmptyView: NSView {
    private(set) var received: [String] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        received.append(event.charactersIgnoringModifiers ?? "")
    }
}

@MainActor
private final class ProbeReaderPDFView: PDFView {
    private(set) var received: [String] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        received.append(event.charactersIgnoringModifiers ?? "")
    }
}

@MainActor
private final class ProbePromptTextView: NSTextView {
    private(set) var rawKeyDownCount = 0

    override func keyDown(with event: NSEvent) {
        rawKeyDownCount += 1
        super.keyDown(with: event)
    }
}

private struct PrefixEpochProbe {
    private(set) var epoch = 0
    private(set) var pendingPrefix: String?
    private(set) var dispatchedTimeouts = 0
    private(set) var pageDigits = ""

    mutating func begin(_ prefix: String) -> Int {
        epoch += 1
        pendingPrefix = prefix
        return epoch
    }

    mutating func replaySemanticMismatch(_ token: Character) {
        pendingPrefix = nil
        if token.isNumber {
            pageDigits.append(token)
        }
    }

    mutating func invalidate() {
        epoch += 1
        pendingPrefix = nil
    }

    mutating func timeout(epoch candidate: Int) {
        guard candidate == epoch, pendingPrefix != nil else { return }
        dispatchedTimeouts += 1
        pendingPrefix = nil
    }
}

@MainActor
public enum ResponderPromptProbe {
    public static func run() -> ProbeSection {
        _ = NSApplication.shared

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false

        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        let emptyView = ProbeEmptyView(frame: container.bounds)
        let pdfView = ProbeReaderPDFView(frame: container.bounds)
        let prompt = ProbePromptTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        container.addSubview(emptyView)
        container.addSubview(pdfView)
        container.addSubview(prompt)
        window.contentView = container

        window.makeKeyAndOrderFront(nil)

        emptyView.nextKeyView = pdfView
        pdfView.nextKeyView = prompt
        prompt.nextKeyView = emptyView

        let emptyFocused = window.makeFirstResponder(emptyView)
        if let event = keyEvent(character: "j", keyCode: 38, window: window) {
            window.sendEvent(event)
        }

        let pdfFocused = window.makeFirstResponder(pdfView)
        if let event = keyEvent(character: "k", keyCode: 40, window: window) {
            window.sendEvent(event)
        }

        let promptFocused = window.makeFirstResponder(prompt)
        prompt.string = ""
        prompt.insertText("jk", replacementRange: NSRange(location: NSNotFound, length: 0))
        let literalPreserved = prompt.string == "jk"

        prompt.setMarkedText(
            "ㅎ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let compositionStarted = prompt.hasMarkedText()
        prompt.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: prompt.markedRange()
        )
        prompt.unmarkText()
        let imePreserved = prompt.string.contains("한")

        prompt.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        let deadKeyResultPreserved = prompt.string.contains("é")

        prompt.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        let beforeDeleteCount = prompt.string.utf16.count
        prompt.deleteBackward(nil)
        let nativeEditingWorked = prompt.string.utf16.count == beforeDeleteCount - 1

        prompt.setMarkedText(
            "조합",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let rawBefore = prompt.rawKeyDownCount
        let safeGlobalDispatched = dispatchSafeGlobal(from: prompt, restoring: pdfView, in: window)
        let compositionDiscardedOnce = !prompt.hasMarkedText() && prompt.rawKeyDownCount == rawBefore

        let restoredAfterPrompt = window.firstResponder === pdfView

        var epoch = PrefixEpochProbe()
        let staleEpoch = epoch.begin("g")
        epoch.replaySemanticMismatch("1")
        epoch.invalidate()
        epoch.timeout(epoch: staleEpoch)

        let keyLoopStable = emptyView.nextKeyView === pdfView
            && pdfView.nextKeyView === prompt
            && prompt.nextKeyView === emptyView

        window.orderOut(nil)
        window.close()

        return ProbeSection(
            id: "responder-prompt",
            title: "Responder routing, prompt input, and timer epochs",
            checks: [
                checked("empty-window-route", emptyFocused && emptyView.received == ["j"], detail: "the empty view receives remapped input through the window responder chain"),
                checked("pdf-route", pdfFocused && pdfView.received == ["k"], detail: "ReaderPDFView accepts first responder and receives key events"),
                checked("prompt-focus", promptFocused, detail: "prompt becomes first responder deterministically"),
                checked("key-view-loop", keyLoopStable, detail: "canvas and prompt participate in an explicit key-view loop"),
                checked("literal-text", literalPreserved, detail: "literal jk remains native prompt text"),
                checked("ime-composition", compositionStarted && imePreserved, detail: "marked text can be committed through NSTextInputClient without raw replay"),
                checked("dead-key-result", deadKeyResultPreserved, detail: "a composed dead-key result remains intact"),
                checked("native-editing", nativeEditingWorked, detail: "native delete editing remains owned by NSTextView"),
                checked("safe-global-during-composition", safeGlobalDispatched && compositionDiscardedOnce, detail: "a validated safe global discards marked composition once and dispatches without raw text replay"),
                checked("focus-restoration", restoredAfterPrompt, detail: "safe prompt exit restores the PDF canvas first responder"),
                checked("semantic-digit-replay", epoch.pageDigits == "1", detail: "eligible g-prefix mismatch replays one semantic digit into the page prompt"),
                checked("stale-timer-invalidated", epoch.dispatchedTimeouts == 0, detail: "an invalidated prefix epoch cannot dispatch later"),
            ]
        )
    }

    private static func dispatchSafeGlobal(
        from prompt: ProbePromptTextView,
        restoring pdfView: ProbeReaderPDFView,
        in window: NSWindow
    ) -> Bool {
        let action = ProbeActionDescriptor(id: "document.open", scope: .global)
        let decision = ProbePromptSafeBindingPredicate.evaluate(
            action: action,
            sequence: ProbeKeySequence("<D-F12>")
        )
        guard decision.isValid else { return false }
        if prompt.hasMarkedText() {
            prompt.unmarkText()
        }
        return window.makeFirstResponder(pdfView)
    }

    private static func keyEvent(character: String, keyCode: UInt16, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
