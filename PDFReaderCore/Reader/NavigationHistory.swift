import Foundation

/// A restorable reading location expressed entirely in PDF page coordinates.
public struct NavigationSnapshot: Equatable, Sendable {
    /// The geometry tolerance used to decide whether two captured locations are the same landing.
    public static let locationTolerance: CGFloat = 0.5

    public let pageIndex: Int
    public let pageSpacePoint: CGPoint

    public init?(pageIndex: Int, pageSpacePoint: CGPoint) {
        guard pageIndex >= 0, pageSpacePoint.x.isFinite, pageSpacePoint.y.isFinite else {
            return nil
        }

        self.pageIndex = pageIndex
        self.pageSpacePoint = pageSpacePoint
    }

    public static func == (lhs: NavigationSnapshot, rhs: NavigationSnapshot) -> Bool {
        lhs.pageIndex == rhs.pageIndex
            && lhs.pageSpacePoint.x == rhs.pageSpacePoint.x
            && lhs.pageSpacePoint.y == rhs.pageSpacePoint.y
    }

    /// Returns whether two captures identify the same reading location.
    public func isSameLocation(as other: NavigationSnapshot) -> Bool {
        pageIndex == other.pageIndex
            && abs(pageSpacePoint.x - other.pageSpacePoint.x) <= Self.locationTolerance
            && abs(pageSpacePoint.y - other.pageSpacePoint.y) <= Self.locationTolerance
    }
}

/// Browser-style, app-owned navigation stacks. The live position is supplied by the caller.
public struct NavigationHistory: Sendable {
    public static let maximumPositionCount = 100

    private var back: [NavigationSnapshot] = []
    private var forward: [NavigationSnapshot] = []

    public init() {}

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }
    public var backCount: Int { back.count }
    public var forwardCount: Int { forward.count }

    /// The destination which may be restored before committing a Back traversal.
    public var backDestination: NavigationSnapshot? { back.last }

    /// The destination which may be restored before committing a Forward traversal.
    public var forwardDestination: NavigationSnapshot? { forward.last }

    /// Records a verified, distinct meaningful jump. The caller must invoke this only after landing succeeds.
    @discardableResult
    public mutating func commitMeaningfulJump(
        origin: NavigationSnapshot,
        landing: NavigationSnapshot
    ) -> Bool {
        guard !origin.isSameLocation(as: landing) else {
            return false
        }

        back.append(origin)
        forward.removeAll()
        evictOldestBackPositionsIfNeeded()
        return true
    }

    /// Commits a previously peeked, successfully restored Back destination.
    @discardableResult
    public mutating func commitBack(current: NavigationSnapshot) -> Bool {
        guard back.popLast() != nil else {
            return false
        }

        forward.append(current)
        return true
    }

    /// Commits a previously peeked, successfully restored Forward destination.
    @discardableResult
    public mutating func commitForward(current: NavigationSnapshot) -> Bool {
        guard forward.popLast() != nil else {
            return false
        }

        back.append(current)
        return true
    }

    private mutating func evictOldestBackPositionsIfNeeded() {
        while back.count + 1 + forward.count > Self.maximumPositionCount {
            back.removeFirst()
        }
    }
}

/// The result of inspecting a generation-tagged, verified distinct search landing.
public enum SearchEpochResult: Equatable, Sendable {
    /// No epoch accepts this landing, including stale-generation callbacks.
    case ignored
    /// The first result requires the reported origin to be committed to history before the epoch commits.
    case first(origin: NavigationSnapshot)
    /// A current result belongs to an already committed epoch and creates no history entry.
    case coalesced
}

/// The lifecycle that coalesces a run of successful search-result landings.
public enum SearchEpoch: Equatable, Sendable {
    case idle
    case armed(origin: NavigationSnapshot, searchGeneration: Int)
    case coalescing(searchGeneration: Int)

    /// Starts an epoch only when the caller has captured a valid live origin.
    public mutating func arm(origin: NavigationSnapshot, searchGeneration: Int) {
        guard case .idle = self else {
            return
        }
        self = .armed(origin: origin, searchGeneration: searchGeneration)
    }

    /// Replaces a query without creating a history boundary or accepting late prior-generation results.
    public mutating func replaceQuery(searchGeneration: Int) {
        switch self {
        case .idle:
            break
        case let .armed(origin, _):
            self = .armed(origin: origin, searchGeneration: searchGeneration)
        case .coalescing:
            self = .coalescing(searchGeneration: searchGeneration)
        }
    }

    /// Inspects a verified distinct search landing without changing lifecycle state.
    public func inspectDisplayedDistinct(searchGeneration: Int) -> SearchEpochResult {
        switch self {
        case let .armed(origin, activeGeneration) where activeGeneration == searchGeneration:
            .first(origin: origin)
        case let .coalescing(activeGeneration) where activeGeneration == searchGeneration:
            .coalesced
        case .idle, .armed, .coalescing:
            .ignored
        }
    }

    /// Commits the first result only after its inspected origin has been successfully committed to history.
    @discardableResult
    public mutating func commitFirstDisplayedDistinct(
        searchGeneration: Int,
        historyCommitted: Bool
    ) -> Bool {
        guard historyCommitted,
              case let .armed(_, activeGeneration) = self,
              activeGeneration == searchGeneration
        else {
            return false
        }

        self = .coalescing(searchGeneration: searchGeneration)
        return true
    }

    /// A same, failed, or absent result is deliberately not a lifecycle transition.
    public mutating func displayedSameFailedOrNoResult(searchGeneration: Int) {}

    /// Clearing or cancelling ends an epoch without changing committed history.
    public mutating func clearOrCancel() {
        self = .idle
    }

    /// A successful distinct non-search jump ends the current epoch after its history commit.
    public mutating func successfulNonSearchJump() {
        self = .idle
    }

    /// Failed and same non-search attempts do not split an epoch.
    public mutating func failedOrSameNonSearchAttempt() {}

    /// A successful Back or Forward traversal ends the current epoch after its directional commit.
    public mutating func successfulTraversal() {
        self = .idle
    }

    /// Failed or empty directional traversals do not split an epoch.
    public mutating func failedOrEmptyTraversal() {}

    /// Excluded movement and tab/pane switching do not affect an epoch.
    public mutating func excludedMovementOrTabSwitch() {}

    /// Session teardown discards any active lifecycle state.
    public mutating func teardown() {
        self = .idle
    }
}
