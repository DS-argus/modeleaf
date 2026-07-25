import Foundation
import PDFReaderCore

@MainActor
protocol ReaderWorkflowPresenting: AnyObject {
    var activePromptKind: ReaderPromptKind? { get }
    var activePromptText: String { get }

    func presentPrompt(_ presentation: PromptPresentation)
    func showPromptValidation(_ message: String)
    func prepareForGlobalAction()
    func dismissPromptAndRestoreFocus(
        to context: InputContext,
        reason: KeyInputInvalidationReason
    )
}

extension ReaderWorkflowPresenting {
    func dismissPromptAndRestoreFocus(reason: KeyInputInvalidationReason) {
        dismissPromptAndRestoreFocus(to: .navigation, reason: reason)
    }
}

@MainActor
final class ActionDispatcher {
    private let sessionStore: ReaderSessionStore
    private let navigation: NavigationConfiguration
    private var openDocumentHandler: () -> Void
    private var terminationHandler: () -> Void

    weak var presentation: (any ReaderWorkflowPresenting)?

    init(
        sessionStore: ReaderSessionStore,
        navigation: NavigationConfiguration,
        openDocumentHandler: @escaping () -> Void = {},
        terminationHandler: @escaping () -> Void = {}
    ) {
        self.sessionStore = sessionStore
        self.navigation = navigation
        self.openDocumentHandler = openDocumentHandler
        self.terminationHandler = terminationHandler
    }

    func configureLifecycleHandlers(
        openDocument: @escaping () -> Void,
        terminate: @escaping () -> Void
    ) {
        openDocumentHandler = openDocument
        terminationHandler = terminate
    }

    func dispatch(_ keyDispatch: KeyActionDispatch) {
        if keyDispatch.actionID == .pagePrompt {
            let initialText = keyDispatch.semanticReplay.flatMap(Self.pageDigit(from:)) ?? ""
            presentPagePrompt(initialText: initialText)
            return
        }
        dispatch(keyDispatch.actionID)
    }

    func dispatch(_ action: ActionID) {
        switch action {
        case .documentOpen:
            presentation?.prepareForGlobalAction()
            openDocumentHandler()
        case .documentClose:
            _ = sessionStore.closeActive()
        case .appQuit:
            presentation?.prepareForGlobalAction()
            terminationHandler()

        case .tabNext:
            _ = sessionStore.activateNext()
        case .tabPrevious:
            _ = sessionStore.activatePrevious()
        case .tabSelect1:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 1)
        case .tabSelect2:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 2)
        case .tabSelect3:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 3)
        case .tabSelect4:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 4)
        case .tabSelect5:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 5)
        case .tabSelect6:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 6)
        case .tabSelect7:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 7)
        case .tabSelect8:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 8)
        case .tabSelect9:
            _ = sessionStore.activateTab(atOneBasedOrdinal: 9)

        case .scrollLeft:
            activeSession?.moveHorizontally(byPoints: -navigation.smallScrollPoints)
        case .scrollDown:
            activeSession?.moveVertically(byPoints: navigation.smallScrollPoints)
        case .scrollUp:
            activeSession?.moveVertically(byPoints: -navigation.smallScrollPoints)
        case .scrollRight:
            activeSession?.moveHorizontally(byPoints: navigation.smallScrollPoints)
        case .scrollLargeDown:
            activeSession?.moveVertically(byViewportFraction: navigation.largeScrollViewportFraction)
        case .scrollLargeUp:
            activeSession?.moveVertically(byViewportFraction: -navigation.largeScrollViewportFraction)

        case .pageNext:
            _ = activeSession?.goToNextPage()
        case .pagePrevious:
            _ = activeSession?.goToPreviousPage()
        case .pageFirst:
            _ = activeSession?.goToFirstPage()
        case .pageLast:
            _ = activeSession?.goToLastPage()
        case .pagePrompt:
            presentPagePrompt(initialText: "")

        case .promptCommit:
            commitPrompt()
        case .promptCancel:
            presentation?.dismissPromptAndRestoreFocus(
                to: activeSession?.preferredInputContext ?? .navigation,
                reason: .promptCancelled
            )

        case .viewZoomIn:
            activeSession?.zoom(by: navigation.zoomFactor)
        case .viewZoomOut:
            activeSession?.zoom(by: 1 / navigation.zoomFactor)
        case .viewZoomReset:
            activeSession?.resetZoom()
        case .viewFitWidth:
            activeSession?.fitWidth()
        case .viewFitPage:
            activeSession?.fitPage()

        case .searchPrompt:
            presentSearchPrompt()
        case .searchNext:
            _ = activeSession?.selectNextSearchResult()
        case .searchPrevious:
            _ = activeSession?.selectPreviousSearchResult()
        case .searchCancel:
            activeSession?.clearSearch()
            presentation?.dismissPromptAndRestoreFocus(to: .navigation, reason: .explicitCancel)
        }
    }

    private var activeSession: (any ReaderSessionPresenting)? {
        sessionStore.activeSession
    }

    private func presentPagePrompt(initialText: String) {
        guard activeSession != nil else {
            presentation?.dismissPromptAndRestoreFocus(to: .navigation, reason: .explicitCancel)
            return
        }
        presentation?.presentPrompt(
            PromptPresentation(kind: .page, text: initialText, validationMessage: nil)
        )
    }

    private func commitPrompt() {
        switch presentation?.activePromptKind {
        case .page:
            commitPagePrompt()
        case .search:
            commitSearchPrompt()
        case nil:
            return
        }
    }

    private func commitPagePrompt() {
        guard let session = activeSession else {
            presentation?.showPromptValidation("No PDF is open.")
            return
        }
        let text = presentation?.activePromptText ?? ""
        guard text.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            presentation?.showPromptValidation("Use digits 0–9 only.")
            return
        }

        let result = PageNumberInputBuffer(digits: text).resolve(maximumPageCount: session.pageCount)
        switch result {
        case let .success(page):
            guard session.goToPage(page) else {
                presentation?.showPromptValidation("Could not move to page \(page).")
                return
            }
            presentation?.dismissPromptAndRestoreFocus(
                to: session.preferredInputContext,
                reason: .promptCommitted
            )
        case let .failure(error):
            presentation?.showPromptValidation(error.presentation)
        }
    }

    private func presentSearchPrompt() {
        guard let session = activeSession else {
            presentation?.dismissPromptAndRestoreFocus(to: .navigation, reason: .explicitCancel)
            return
        }
        presentation?.presentPrompt(
            PromptPresentation(
                kind: .search,
                text: session.searchSnapshot.query,
                validationMessage: nil
            )
        )
    }

    private func commitSearchPrompt() {
        guard let session = activeSession else {
            presentation?.showPromptValidation("No PDF is open.")
            return
        }
        let query = (presentation?.activePromptText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            presentation?.showPromptValidation("Enter text to search.")
            return
        }

        session.beginSearch(query)
        presentation?.dismissPromptAndRestoreFocus(
            to: .searchResults,
            reason: .promptCommitted
        )
    }

    private static func pageDigit(from replay: SemanticKeyReplay) -> String? {
        guard replay.targetContext == .pagePrompt,
              replay.tokenClass == .decimalDigit,
              let digit = replay.token.asciiDecimalDigit
        else {
            return nil
        }
        return String(digit)
    }
}

private extension PageNumberInputError {
    var presentation: String {
        switch self {
        case .empty:
            "Enter a page number."
        case .zeroIsNotAPage:
            "Page numbers start at 1."
        case .numericOverflow:
            "Page number is too large."
        case .documentHasNoPages:
            "This PDF has no pages."
        case let .outOfRange(requested, maximum):
            "Page \(requested) is outside 1–\(maximum)."
        }
    }
}
