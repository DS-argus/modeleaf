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
    case single(PaneStack)
    case split(orientation: PaneOrientation, leading: PaneStack, trailing: PaneStack)

    var paneIDs: [PaneID] {
        switch self {
        case .empty: []
        case let .single(stack): stack.paneIDs
        case let .split(_, leading, trailing): leading.paneIDs + trailing.paneIDs
        }
    }

    var isMultiPane: Bool {
        guard case let .single(stack) = self else { return self != .empty }
        guard case .one = stack else { return true }
        return false
    }

    func contains(_ id: PaneID) -> Bool { paneIDs.contains(id) }
    func band(containing id: PaneID) -> PaneStack? {
        switch self {
        case .empty: nil
        case let .single(stack): stack.contains(id) ? stack : nil
        case let .split(_, leading, trailing):
            leading.contains(id) ? leading : trailing.contains(id) ? trailing : nil
        }
    }

    var topLeftPaneID: PaneID? {
        switch self {
        case .empty: nil
        case let .single(stack): stack.paneIDs.first
        case let .split(_, leading, _): leading.paneIDs.first
        }
    }

    func side(of id: PaneID) -> PaneBandSide? {
        switch self {
        case .empty: nil
        case let .single(stack): stack.contains(id) ? .leading : nil
        case let .split(_, leading, trailing):
            leading.contains(id) ? .leading : trailing.contains(id) ? .trailing : nil
        }
    }

    func slot(of id: PaneID) -> PaneBandSlot? { band(containing: id)?.slot(of: id) }

    func applyingSplit(_ orientation: PaneOrientation, to activePaneID: PaneID, inserting destination: PaneID) -> PaneLayout? {
        switch (orientation, self) {
        case let (.sideBySide, .single(stack)):
            return .split(orientation: .sideBySide, leading: stack, trailing: .one(destination))
        case let (.stacked, .single(.one(origin))) where origin == activePaneID:
            return .single(.two(first: origin, second: destination))
        case let (.stacked, .split(_, leading, trailing)):
            if case let .one(origin) = leading, origin == activePaneID {
                return .split(orientation: .sideBySide, leading: .two(first: origin, second: destination), trailing: trailing)
            }
            if case let .one(origin) = trailing, origin == activePaneID {
                return .split(orientation: .sideBySide, leading: leading, trailing: .two(first: origin, second: destination))
            }
            return nil
        default:
            return nil
        }
    }
}
enum PaneOpenTarget: Equatable, Sendable { case existing(PaneID), createIfEmpty }
