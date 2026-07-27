import PDFKit

enum PDFCapability: String, CaseIterable, Sendable {
    case display
    case scrolling
    case selection
    case pointerCoexistence
    case copy
    case registryNavigation
    case registryZoom
    case registrySearch
    case registryDocument
    case registryTab
    case formEditing
    case annotationEditing
    case contextMenuOutsideAllowlist
    case printExport
    case pageHistory
    case linkActivation
    case embeddedMedia
}

enum PDFCapabilityDisposition: String, Sendable {
    case allowed
    case registryRouted
    case systemOwned
    case suppressed
}

@MainActor
enum PDFCapabilityPolicy {
    static let suppressedMouseAreas: PDFAreaOfInterest = [
        .annotationArea,
        .controlArea,
        .textFieldArea,
        .iconArea,
        .popupArea,
    ]

    static func disposition(for capability: PDFCapability) -> PDFCapabilityDisposition {
        switch capability {
        case .display, .scrolling, .selection, .pointerCoexistence, .linkActivation:
            .allowed
        case .copy:
            .systemOwned
        case .registryNavigation, .registryZoom, .registrySearch, .registryDocument, .registryTab:
            .registryRouted
        case .formEditing, .annotationEditing, .contextMenuOutsideAllowlist, .printExport,
             .pageHistory, .embeddedMedia:
            .suppressed
        }
    }

    static func allowsMouseInteraction(in area: PDFAreaOfInterest) -> Bool {
        // Links are followable (in-document jump / open URL in browser); that is
        // navigation, not mutation, so their areas forward the click. Every other
        // annotation area stays inert to preserve read-only interaction.
        if area.contains(.linkArea) { return true }
        return area.intersection(suppressedMouseAreas).isEmpty
    }
}
