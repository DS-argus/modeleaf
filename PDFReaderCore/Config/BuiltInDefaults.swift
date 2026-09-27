import Foundation

public enum ConfigBounds {
    public static let smallScrollPoints = 1.0...512.0
    public static let largeScrollViewportFraction = 0.1...2.0
    public static let zoomFactor = 1.01...2.0
    public static let prefixTimeoutMilliseconds = 100...2_000
}

public enum BuiltInDefaults {
    private static let defaultPrefix = "<C-b>"

    public static let config = EffectiveAppConfig(
        keymap: keymap,
        navigation: NavigationConfiguration(smallScrollPoints: 32.0, largeScrollViewportFraction: 0.8, zoomFactor: 1.10),
        input: InputConfiguration(prefixTimeoutMilliseconds: 400, prefix: defaultPrefix),
        links: LinksConfiguration(skipExternalLinkHintConfirmation: false)
    )

    /// The source templates used to seed the built-in effective keymap.
    /// Foundation entries remain here so this map continues to describe the complete
    /// built-in vocabulary; use `editableTemplatedKeymap` for alias presentation.
    public static let templatedKeymap: [ActionID: [String]] = [
        .documentOpen: ["<D-o>"], .documentClose: ["<D-w>"], .documentPrint: ["<D-p>"], .documentCopyPath: ["yy"], .documentRevealInFinder: ["of"], .appQuit: ["<D-q>"], .appNew: ["<D-n>"], .paletteOpen: [":", "<D-S-p>"], .helpShow: ["?"],
        .tabNext: ["N"], .tabPrevious: ["P"],
        .tabSelect1: ["<D-1>"], .tabSelect2: ["<D-2>"], .tabSelect3: ["<D-3>"],
        .tabSelect4: ["<D-4>"], .tabSelect5: ["<D-5>"], .tabSelect6: ["<D-6>"],
        .tabSelect7: ["<D-7>"], .tabSelect8: ["<D-8>"], .tabSelect9: ["<D-9>"],
        .scrollLeft: ["h", "<Left>"], .scrollDown: ["j", "<Down>"], .scrollUp: ["k", "<Up>"], .scrollRight: ["l", "<Right>"],
        .scrollLargeDown: ["d"], .scrollLargeUp: ["u"],
        .pageNext: ["n"], .pagePrevious: ["p"], .pageFirst: ["gg"], .pageLast: ["G"], .pagePrompt: ["g"],
        .historyBack: ["<C-o>"], .historyForward: ["<C-i>"],
        .promptCommit: ["<Enter>"], .promptCancel: ["<Esc>"],
        .searchPrompt: ["/"], .searchNext: ["<Enter>"], .searchPrevious: ["<S-Enter>"], .searchCancel: ["<Esc>"],
        .viewZoomIn: ["="], .viewZoomOut: ["-"], .viewZoomReset: ["0"], .viewFitWidth: ["w"], .viewFitPage: ["F"], .viewRotateLeft: ["["], .viewRotateRight: ["]"], .linkHint: ["f"], .citationPreviewToggle: ["C"],
        .tocToggle: ["t"], .tocScrollDown: ["J"], .tocScrollUp: ["K"],
        .settingsOpen: ["<D-,>"],
        .themePicker: ["T"], .indicatorPicker: ["I"], .updateShow: ["U"],
        .paneSplitRight: ["<prefix>|"], .paneSplitDown: ["<prefix>-"], .paneUnsplit: ["<prefix>o"],
        .paneFocusLeft: ["<C-h>"], .paneFocusDown: ["<C-j>"], .paneFocusUp: ["<C-k>"], .paneFocusRight: ["<C-l>"],
    ]

    /// Built-in source templates with each action's own immutable foundation removed.
    /// `<prefix>` references and all other source spellings are retained verbatim.
    public static let editableTemplatedKeymap: [ActionID: [String]] = makeEditableTemplatedKeymap(templatedKeymap)

    public static let keymap = resolvedKeymap(templatedKeymap, prefix: defaultPrefix)

    private static func makeEditableTemplatedKeymap(
        _ templates: [ActionID: [String]]
    ) -> [ActionID: [String]] {
        var editable = templates
        for (action, sources) in templates {
            guard ActionRegistry.v1.descriptor(for: action)?.isFixedBinding != true else {
                editable[action] = []
                continue
            }
            let foundations = Set(FoundationalBindings.sequences(for: action))
            editable[action] = sources.filter { source in
                let expanded = source.replacingOccurrences(of: "<prefix>", with: defaultPrefix)
                guard let parsed = try? KeySequenceParser.parse(expanded) else { return true }
                return !foundations.contains(parsed)
            }
        }
        return editable
    }

    private static func resolvedKeymap(
        _ templates: [ActionID: [String]],
        prefix: String
    ) -> [ActionID: [KeySequence]] {
        let aliases = templates.mapValues { sources in
            sources.map { source in
                do {
                    return try KeySequenceParser.parse(source.replacingOccurrences(of: "<prefix>", with: prefix))
                } catch {
                    preconditionFailure("invalid built-in binding \(source): \(error)")
                }
            }
        }
        return FoundationalBindings.compose(aliases, registry: .v1)
    }

    public static func categoryTitle(for id: ActionID) -> String {
        switch String(id.rawValue.prefix(while: { $0 != "." })) {
        case "app", "document": return "Application"
        case "palette": return "Command palette"
        case "help": return "Help"
        case "tab": return "Tabs"
        case "scroll": return "Scroll"
        case "page": return "Pages"
        case "search": return "Search"
        case "history": return "Navigation"
        case "link": return "Links"
        case "citation": return "Experimental"
        case "toc": return "Table of contents"
        case "settings": return "Settings"
        case "view": return "View / Zoom"
        case "theme": return "Theme"
        case "pane": return "Panes"
        case "indicator": return "Link indicator"
        case "update": return "Update"
        default: return "Other"
        }
    }
}
