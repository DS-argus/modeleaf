import Foundation

public struct ActionRegistry: Sendable {
    public static let v1 = ActionRegistry(descriptors: Self.v1Descriptors)

    public let descriptors: [ActionDescriptor]
    private let descriptorsByID: [ActionID: ActionDescriptor]

    public init(descriptors: [ActionDescriptor]) {
        precondition(Set(descriptors.map(\.id)).count == descriptors.count, "action identifiers must be unique")
        self.descriptors = descriptors
        self.descriptorsByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    }

    public var actionIDs: [ActionID] { descriptors.map(\.id) }

    public func descriptor(for id: ActionID) -> ActionDescriptor? {
        descriptorsByID[id]
    }

    public func isFixedBinding(_ id: ActionID) -> Bool {
        descriptorsByID[id]?.isFixedBinding ?? false
    }

    public var userConfigurableDescriptors: [ActionDescriptor] {
        descriptors.filter { !$0.isFixedBinding }
    }

    private static let readerContexts: Set<InputContext> = [.navigation, .searchResults]
    private static let promptContexts: Set<InputContext> = [.pagePrompt, .searchPrompt]

    private static let v1Descriptors: [ActionDescriptor] = [
        ActionDescriptor(id: .documentOpen, title: "Open PDF…", scope: .global),
        ActionDescriptor(id: .documentClose, title: "Close PDF", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .appQuit, title: "Quit Modeleaf", scope: .global),
        ActionDescriptor(id: .appNew, title: "New Window", scope: .global),
        ActionDescriptor(id: .paletteOpen, title: "Command Palette", scope: .contexts(readerContexts)),
        // Help is navigation-only by contract (EF3): '?' must stay native text in
        // prompts and unmapped in search results.
        ActionDescriptor(id: .helpShow, title: "Keyboard Help", scope: .contexts([.navigation])),

        ActionDescriptor(id: .tabNext, title: "Next Tab", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabPrevious, title: "Previous Tab", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect1, title: "Select Tab 1", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect2, title: "Select Tab 2", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect3, title: "Select Tab 3", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect4, title: "Select Tab 4", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect5, title: "Select Tab 5", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect6, title: "Select Tab 6", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect7, title: "Select Tab 7", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect8, title: "Select Tab 8", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabSelect9, title: "Select Tab 9", scope: .contexts(readerContexts)),

        ActionDescriptor(id: .scrollLeft, title: "Scroll Left", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .scrollDown, title: "Scroll Down", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .scrollUp, title: "Scroll Up", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .scrollRight, title: "Scroll Right", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .scrollLargeDown, title: "Scroll Down by Viewport", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .scrollLargeUp, title: "Scroll Up by Viewport", scope: .contexts(readerContexts), repeatPolicy: .allowed),

        ActionDescriptor(id: .pageNext, title: "Next Page", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .pagePrevious, title: "Previous Page", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .pageFirst, title: "First Page", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .pageLast, title: "Last Page", scope: .contexts(readerContexts)),
        ActionDescriptor(
            id: .pagePrompt,
            title: "Go to Page…",
            scope: .contexts(readerContexts),
            prefixFallbackPolicy: .transitionAndReplay(to: .pagePrompt, acceptedToken: .decimalDigit)
        ),

        ActionDescriptor(
            id: .promptCommit,
            title: "Commit Prompt",
            scope: .contexts(promptContexts),
            isPromptLifecycle: true,
            isFixedBinding: true
        ),
        ActionDescriptor(
            id: .promptCancel,
            title: "Cancel Prompt",
            scope: .contexts(promptContexts),
            isPromptLifecycle: true,
            isFixedBinding: true
        ),

        ActionDescriptor(id: .searchPrompt, title: "Find…", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .searchNext, title: "Next Match", scope: .contexts([.searchResults]), repeatPolicy: .allowed, isFixedBinding: true),
        ActionDescriptor(id: .searchPrevious, title: "Previous Match", scope: .contexts([.searchResults]), repeatPolicy: .allowed, isFixedBinding: true),
        ActionDescriptor(id: .searchCancel, title: "Clear Search", scope: .contexts([.searchResults])),

        ActionDescriptor(id: .viewZoomIn, title: "Zoom In", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .viewZoomOut, title: "Zoom Out", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .viewZoomReset, title: "Actual Size", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .viewFitWidth, title: "Fit Width", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .viewFitPage, title: "Fit Page", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .configReload, title: "Reload Config", scope: .contexts([.navigation]), repeatPolicy: .suppressed),
        ActionDescriptor(id: .themePicker, title: "Theme picker", scope: .contexts(readerContexts), repeatPolicy: .suppressed),

        ActionDescriptor(id: .paneSplitRight, title: "Split Right", scope: .contexts([.navigation, .searchResults]), repeatPolicy: .suppressed),
        ActionDescriptor(id: .paneSplitDown, title: "Split Down", scope: .contexts([.navigation, .searchResults]), repeatPolicy: .suppressed),
        ActionDescriptor(id: .paneFocusLeft, title: "Focus Left Pane", scope: .contexts([.navigation, .searchResults]), repeatPolicy: .suppressed),
        ActionDescriptor(id: .paneFocusDown, title: "Focus Down Pane", scope: .contexts([.navigation, .searchResults]), repeatPolicy: .suppressed),
        ActionDescriptor(id: .paneFocusUp, title: "Focus Up Pane", scope: .contexts([.navigation, .searchResults]), repeatPolicy: .suppressed),
        ActionDescriptor(id: .paneFocusRight, title: "Focus Right Pane", scope: .contexts([.navigation, .searchResults]), repeatPolicy: .suppressed),
        ActionDescriptor(id: .paneUnsplit, title: "Close Other Pane", scope: .contexts([.navigation, .searchResults]), repeatPolicy: .suppressed),
    ]
}
