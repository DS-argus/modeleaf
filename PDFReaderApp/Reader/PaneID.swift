import Foundation

struct PaneID: RawRepresentable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

enum PaneOrientation: Equatable, Sendable { case sideBySide, stacked }
enum PaneFocusDirection: Equatable, Sendable { case left, down, up, right }
enum PaneBandSide: Equatable, Sendable { case leading, trailing }
enum PaneBandSlot: Equatable, Sendable { case first, second }

enum PaneStack: Equatable, Sendable {
    case one(PaneID)
    case two(first: PaneID, second: PaneID)

    var paneIDs: [PaneID] {
        switch self {
        case let .one(id): [id]
        case let .two(first, second): [first, second]
        }
    }

    func contains(_ id: PaneID) -> Bool { paneIDs.contains(id) }
    func slot(of id: PaneID) -> PaneBandSlot? {
        guard case let .two(first, second) = self else { return nil }
        return id == first ? .first : id == second ? .second : nil
    }
}

enum PaneLayout: Equatable, Sendable {
    case empty
    case single(PaneID)
    case split(orientation: PaneOrientation, leading: PaneStack, trailing: PaneStack)

    var paneIDs: [PaneID] {
        switch self {
        case .empty: []
        case let .single(id): [id]
        case let .split(_, leading, trailing): leading.paneIDs + trailing.paneIDs
        }
    }

    var isMultiPane: Bool { paneIDs.count > 1 }

    func contains(_ id: PaneID) -> Bool { paneIDs.contains(id) }
    func band(containing id: PaneID) -> PaneStack? {
        guard case let .split(_, leading, trailing) = self else { return nil }
        return leading.contains(id) ? leading : trailing.contains(id) ? trailing : nil
    }

    var topLeftPaneID: PaneID? {
        switch self {
        case .empty: nil
        case let .single(id): id
        case let .split(_, leading, _): leading.paneIDs.first
        }
    }

    func side(of id: PaneID) -> PaneBandSide? {
        guard case let .split(_, leading, trailing) = self else { return nil }
        return leading.contains(id) ? .leading : trailing.contains(id) ? .trailing : nil
    }

    func slot(of id: PaneID) -> PaneBandSlot? { band(containing: id)?.slot(of: id) }

    func applyingSplit(_ orientation: PaneOrientation, to activePaneID: PaneID, inserting destination: PaneID) -> PaneLayout? {
        switch self {
        case let .single(origin) where origin == activePaneID:
            return .split(orientation: orientation, leading: .one(origin), trailing: .one(destination))
        case let .split(outer, leading, trailing):
            guard orientation != outer else { return nil }
            if case let .one(origin) = leading, origin == activePaneID {
                return .split(orientation: outer, leading: .two(first: origin, second: destination), trailing: trailing)
            }
            if case let .one(origin) = trailing, origin == activePaneID {
                return .split(orientation: outer, leading: leading, trailing: .two(first: origin, second: destination))
            }
            return nil
        case .empty, .single:
            return nil
        }
    }
}
enum PaneOpenTarget: Equatable, Sendable { case existing(PaneID), createIfEmpty }
