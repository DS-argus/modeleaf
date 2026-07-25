import Foundation

struct PaneID: RawRepresentable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

enum PaneOrientation: Equatable, Sendable { case sideBySide, stacked }
enum PaneFocusDirection: Equatable, Sendable { case left, down, up, right }
enum PaneColumnSide: Equatable, Sendable { case leading, trailing }
enum PaneRow: Equatable, Sendable { case top, bottom }

enum PaneStack: Equatable, Sendable {
    case one(PaneID)
    case two(top: PaneID, bottom: PaneID)

    var paneIDs: [PaneID] {
        switch self {
        case let .one(id): [id]
        case let .two(top, bottom): [top, bottom]
        }
    }

    func contains(_ id: PaneID) -> Bool { paneIDs.contains(id) }
    func row(of id: PaneID) -> PaneRow? {
        guard case let .two(top, bottom) = self else { return nil }
        return id == top ? .top : id == bottom ? .bottom : nil
    }
}

enum PaneLayout: Equatable, Sendable {
    case empty
    case single(PaneStack)
    case split(leading: PaneStack, trailing: PaneStack)

    var paneIDs: [PaneID] {
        switch self {
        case .empty: []
        case let .single(stack): stack.paneIDs
        case let .split(leading, trailing): leading.paneIDs + trailing.paneIDs
        }
    }

    var isMultiPane: Bool {
        guard case let .single(stack) = self else { return self != .empty }
        guard case .one = stack else { return true }
        return false
    }

    func contains(_ id: PaneID) -> Bool { paneIDs.contains(id) }
    func column(containing id: PaneID) -> PaneStack? {
        switch self {
        case .empty: nil
        case let .single(stack): stack.contains(id) ? stack : nil
        case let .split(leading, trailing):
            leading.contains(id) ? leading : trailing.contains(id) ? trailing : nil
        }
    }

    var topLeftPaneID: PaneID? {
        switch self {
        case .empty: nil
        case let .single(stack): stack.paneIDs.first
        case let .split(leading, _): leading.paneIDs.first
        }
    }

    func side(of id: PaneID) -> PaneColumnSide? {
        switch self {
        case .empty: nil
        case let .single(stack): stack.contains(id) ? .leading : nil
        case let .split(leading, trailing):
            leading.contains(id) ? .leading : trailing.contains(id) ? .trailing : nil
        }
    }

    func row(of id: PaneID) -> PaneRow? { column(containing: id)?.row(of: id) }
}

enum PaneOpenTarget: Equatable, Sendable { case existing(PaneID), createIfEmpty }
