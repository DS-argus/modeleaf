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

    private static let readerContexts: Set<InputContext> = [.navigation, .searchResults]
    private static let promptContexts: Set<InputContext> = [.pagePrompt, .searchPrompt]

    private static let v1Descriptors: [ActionDescriptor] = [
        ActionDescriptor(id: .documentOpen, title: "Open PDF…", scope: .global),
        ActionDescriptor(id: .documentClose, title: "Close PDF", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .appQuit, title: "Quit PDF Reader", scope: .global),

        ActionDescriptor(id: .tabNext, title: "Next Tab", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .tabPrevious, title: "Previous Tab", scope: .contexts(readerContexts)),

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
            isPromptLifecycle: true
        ),
        ActionDescriptor(
            id: .promptCancel,
            title: "Cancel Prompt",
            scope: .contexts(promptContexts),
            isPromptLifecycle: true
        ),

        ActionDescriptor(id: .searchPrompt, title: "Find…", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .searchNext, title: "Next Match", scope: .contexts([.searchResults]), repeatPolicy: .allowed),
        ActionDescriptor(id: .searchPrevious, title: "Previous Match", scope: .contexts([.searchResults]), repeatPolicy: .allowed),
        ActionDescriptor(id: .searchCancel, title: "Clear Search", scope: .contexts([.searchResults])),

        ActionDescriptor(id: .viewZoomIn, title: "Zoom In", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .viewZoomOut, title: "Zoom Out", scope: .contexts(readerContexts), repeatPolicy: .allowed),
        ActionDescriptor(id: .viewZoomReset, title: "Actual Size", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .viewFitWidth, title: "Fit Width", scope: .contexts(readerContexts)),
        ActionDescriptor(id: .viewFitPage, title: "Fit Page", scope: .contexts(readerContexts)),
    ]
}
