import Foundation

public enum ActionID: String, CaseIterable, Codable, Hashable, Sendable {
    case documentOpen = "document.open"
    case documentClose = "document.close"
    case appQuit = "app.quit"

    case tabNext = "tab.next"
    case tabPrevious = "tab.previous"

    case scrollLeft = "scroll.left"
    case scrollDown = "scroll.down"
    case scrollUp = "scroll.up"
    case scrollRight = "scroll.right"
    case scrollLargeDown = "scroll.largeDown"
    case scrollLargeUp = "scroll.largeUp"

    case pageNext = "page.next"
    case pagePrevious = "page.previous"
    case pageFirst = "page.first"
    case pageLast = "page.last"
    case pagePrompt = "page.prompt"

    case promptCommit = "prompt.commit"
    case promptCancel = "prompt.cancel"

    case searchPrompt = "search.prompt"
    case searchNext = "search.next"
    case searchPrevious = "search.previous"
    case searchCancel = "search.cancel"

    case viewZoomIn = "view.zoomIn"
    case viewZoomOut = "view.zoomOut"
    case viewZoomReset = "view.zoomReset"
    case viewFitWidth = "view.fitWidth"
    case viewFitPage = "view.fitPage"
}
