import CoreGraphics
import PDFKit
import PDFReaderCore

struct ReaderOutlineRowID: Hashable, Equatable, Sendable {
    fileprivate let path: [Int]
    var accessibilityIdentifier: String { path.map(String.init).joined(separator: ".") }
}

struct ReaderOutlineRowSnapshot: Equatable, Hashable, Sendable {
    let id: ReaderOutlineRowID
    let title: String
    let depth: Int
    let selector: Int?
    let isEnabled: Bool
}

struct ReaderOutlineSnapshot: Equatable, Sendable {
    let rows: [ReaderOutlineRowSnapshot]
    let currentRowID: ReaderOutlineRowID?
    let successfulUserMovementRevision: UInt64

    static let empty = ReaderOutlineSnapshot(rows: [], currentRowID: nil, successfulUserMovementRevision: 0)
}

@MainActor
final class ReaderOutline {
    private struct Row {
        let snapshot: ReaderOutlineRowSnapshot
        let destination: NavigationSnapshot?
    }

    private let rows: [Row]
    private let destinationsByID: [ReaderOutlineRowID: NavigationSnapshot]
    private let idsBySelector: [Int: ReaderOutlineRowID]

    init(document: PDFDocument, normalizeDestination: (PDFDestination) -> NavigationSnapshot?) {
        var nextSelector = 1
        var flattened: [Row] = []
        var destinations: [ReaderOutlineRowID: NavigationSnapshot] = [:]
        var selectors: [Int: ReaderOutlineRowID] = [:]

        func append(_ outline: PDFOutline, id: ReaderOutlineRowID, displayDepth: Int) {
            let destination = outline.destination.flatMap(normalizeDestination)
            let selector = destination.map { _ in
                defer { nextSelector += 1 }
                return nextSelector
            }
            let title = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let row = ReaderOutlineRowSnapshot(
                id: id,
                title: title?.isEmpty == false ? title! : "Untitled section",
                depth: displayDepth,
                selector: selector,
                isEnabled: destination != nil
            )
            flattened.append(Row(snapshot: row, destination: destination))
            if let destination {
                destinations[id] = destination
                selectors[selector!] = id
            }
            guard displayDepth < 1 else { return }
            for childIndex in 0..<outline.numberOfChildren {
                guard let child = outline.child(at: childIndex) else { continue }
                append(child, id: ReaderOutlineRowID(path: id.path + [childIndex]), displayDepth: displayDepth + 1)
            }
        }

        if let root = document.outlineRoot {
            let hidesSingleTitleWrapper = root.numberOfChildren == 1 && (root.child(at: 0)?.numberOfChildren ?? 0) > 0
            if hidesSingleTitleWrapper, let wrapper = root.child(at: 0) {
                for childIndex in 0..<wrapper.numberOfChildren {
                    guard let child = wrapper.child(at: childIndex) else { continue }
                    append(child, id: ReaderOutlineRowID(path: [0, childIndex]), displayDepth: 0)
                }
            } else {
                for index in 0..<root.numberOfChildren {
                    guard let outline = root.child(at: index) else { continue }
                    append(outline, id: ReaderOutlineRowID(path: [index]), displayDepth: 0)
                }
            }
        }
        rows = flattened
        destinationsByID = destinations
        idsBySelector = selectors
    }

    func snapshot(
        viewportAnchor: NavigationSnapshot?,
        successfulUserMovementRevision: UInt64
    ) -> ReaderOutlineSnapshot {
        ReaderOutlineSnapshot(
            rows: rows.map(\.snapshot),
            currentRowID: currentRowID(viewportAnchor: viewportAnchor),
            successfulUserMovementRevision: successfulUserMovementRevision
        )
    }

    func destination(for id: ReaderOutlineRowID) -> NavigationSnapshot? {
        destinationsByID[id]
    }

    func destination(forSelector selector: Int) -> NavigationSnapshot? {
        idsBySelector[selector].flatMap { destinationsByID[$0] }
    }

    func rowID(forSelector selector: Int) -> ReaderOutlineRowID? {
        idsBySelector[selector]
    }

    private func currentRowID(viewportAnchor: NavigationSnapshot?) -> ReaderOutlineRowID? {
        guard let viewportAnchor else { return nil }
        var current: Row?
        for row in rows {
            guard let destination = row.destination, Self.precedes(destination, viewportAnchor) else { continue }
            guard let existing = current?.destination else {
                current = row
                continue
            }
            if Self.precedes(existing, destination), !destination.isSameLocation(as: existing) {
                current = row
            }
        }
        return current?.snapshot.id
    }

    /// PDF page coordinates grow upward, so a visually earlier heading has a greater y coordinate.
    private static func precedes(_ destination: NavigationSnapshot, _ anchor: NavigationSnapshot) -> Bool {
        guard destination.pageIndex == anchor.pageIndex else { return destination.pageIndex < anchor.pageIndex }
        if destination.pageSpacePoint.y != anchor.pageSpacePoint.y { return destination.pageSpacePoint.y > anchor.pageSpacePoint.y }
        return destination.pageSpacePoint.x <= anchor.pageSpacePoint.x
    }
}
