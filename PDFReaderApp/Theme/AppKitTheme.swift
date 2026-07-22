import AppKit
import PDFReaderCore

struct AppKitTheme {
    let id: ThemeID
    let displayName: String
    private let colors: [ThemeToken: NSColor]

    init(configuration: ThemeConfiguration) {
        let builtIn = BuiltInThemes.theme(for: configuration.builtIn)
        var values = builtIn.palette.values
        for (token, color) in configuration.overrides {
            values[token] = color
        }

        self.id = builtIn.id
        self.displayName = builtIn.displayName
        self.colors = Dictionary(uniqueKeysWithValues: values.map { token, color in
            (token, NSColor(themeColor: color))
        })
    }

    subscript(token: ThemeToken) -> NSColor {
        guard let color = colors[token] else {
            preconditionFailure("Validated theme omitted \(token.rawValue)")
        }
        return color
    }

    var canvasBackground: NSColor { self[.background] }
    var focusRing: NSColor { self[.focusIndicator] }

    var hover: NSColor {
        self[.inactiveTab].blended(withFraction: 0.10, of: self[.accent]) ?? self[.inactiveTab]
    }

    var separator: NSColor { self[.border].withAlphaComponent(0.62) }
    var overlayShadow: NSColor { NSColor.black.withAlphaComponent(0.35) }

    var searchHighlightPalette: SearchHighlightPalette {
        SearchHighlightPalette(
            allResults: self[.searchHighlight].multiplyingAlpha(by: 0.62),
            activeResult: self[.activeSearchHighlight].multiplyingAlpha(by: 0.92)
        )
    }
}

private extension NSColor {
    func multiplyingAlpha(by factor: CGFloat) -> NSColor {
        withAlphaComponent(alphaComponent * factor)
    }

    convenience init(themeColor: ThemeColor) {
        let source = themeColor.rawValue.dropFirst()
        guard let value = UInt64(source, radix: 16) else {
            preconditionFailure("Validated theme color could not be parsed: \(themeColor.rawValue)")
        }
        let hasAlpha = source.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
