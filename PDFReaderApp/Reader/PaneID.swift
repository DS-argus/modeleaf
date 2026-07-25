import Foundation

struct PaneID: RawRepresentable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
enum PaneOrientation: Equatable, Sendable { case sideBySide, stacked }
enum PaneFocusDirection: Equatable, Sendable { case left, down, up, right }
enum PaneLayout: Equatable, Sendable {
    case empty
    case single(PaneID)
    case split(orientation: PaneOrientation, leadingOrTop: PaneID, trailingOrBottom: PaneID)
}
enum PaneOpenTarget: Equatable, Sendable { case existing(PaneID), createIfEmpty }
