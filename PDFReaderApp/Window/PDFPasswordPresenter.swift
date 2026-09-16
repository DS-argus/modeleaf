import AppKit

@MainActor
protocol PDFPasswordPresenting: AnyObject {
    func requestPassword(for url: URL, invalidPassword: Bool) -> String?
}

@MainActor
final class NativePDFPasswordPresenter: PDFPasswordPresenting {
    func makeAlert(for url: URL, invalidPassword: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Password Required"
        alert.informativeText = invalidPassword
            ? "Incorrect password. Try again to open “\(url.lastPathComponent)”."
            : "Enter the password to open “\(url.lastPathComponent)”."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Password"
        field.setAccessibilityLabel("PDF password")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert
    }

    func requestPassword(for url: URL, invalidPassword: Bool) -> String? {
        let alert = makeAlert(for: url, invalidPassword: invalidPassword)
        guard let field = alert.accessoryView as? NSSecureTextField else { return nil }
        defer {
            field.currentEditor()?.string = ""
            field.stringValue = ""
        }
        // App-modal presentation preserves the synchronous open/duplicate transaction
        // and serializes batches of external URLs without retaining passwords.
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
