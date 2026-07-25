import Foundation

/// Stable identifier for a reader tab.
///
/// The core tab model intentionally stores only identity and ordering. Titles,
/// PDFKit objects, AppKit views, file URLs, and session state are owned by the
/// app/session layer.
public struct TabID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }
}

/// Foundation-only tab ordering and active-selection state.
///
/// `TabStore` does not own reader sessions. It keeps a duplicate-free ordered
/// list of `TabID` values plus a valid active selection whenever the list is
/// non-empty.
public struct TabStore: Equatable, Sendable {
    public private(set) var orderedIDs: [TabID]
    public private(set) var activeID: TabID?

    public var activeIndex: Int? {
        guard let activeID else { return nil }
        return orderedIDs.firstIndex(of: activeID)
    }

    public init(orderedIDs: [TabID] = [], activeID: TabID? = nil) {
        var uniqueIDs: [TabID] = []
        uniqueIDs.reserveCapacity(orderedIDs.count)
        for id in orderedIDs where !uniqueIDs.contains(id) {
            uniqueIDs.append(id)
        }

        self.orderedIDs = uniqueIDs
        if let activeID, uniqueIDs.contains(activeID) {
            self.activeID = activeID
        } else {
            self.activeID = uniqueIDs.first
        }
    }

    @discardableResult
    public mutating func insert(_ id: TabID) -> Bool {
        guard !orderedIDs.contains(id) else { return false }
        orderedIDs.append(id)
        activeID = id
        return true
    }

    @discardableResult
    public mutating func activate(_ id: TabID) -> Bool {
        guard orderedIDs.contains(id) else { return false }
        activeID = id
        return true
    }

    /// Activates a tab by its zero-based visual position.
    ///
    /// Returns `true` only when the active tab actually changes. Invalid
    /// positions and re-selecting the active tab are intentional no-ops.
    @discardableResult
    public mutating func activate(at zeroBasedIndex: Int) -> Bool {
        guard orderedIDs.indices.contains(zeroBasedIndex) else { return false }
        let id = orderedIDs[zeroBasedIndex]
        guard activeID != id else { return false }
        activeID = id
        return true
    }

    @discardableResult
    public mutating func close(_ id: TabID) -> Bool {
        guard let closingIndex = orderedIDs.firstIndex(of: id) else { return false }
        let wasActive = activeID == id
        orderedIDs.remove(at: closingIndex)

        if orderedIDs.isEmpty {
            activeID = nil
        } else if wasActive {
            let nextIndex = min(closingIndex, orderedIDs.count - 1)
            activeID = orderedIDs[nextIndex]
        } else if let currentActiveID = activeID, !orderedIDs.contains(currentActiveID) {
            activeID = orderedIDs[min(closingIndex, orderedIDs.count - 1)]
        }

        return true
    }

    @discardableResult
    public mutating func activateNext() -> TabID? {
        guard !orderedIDs.isEmpty else { return nil }
        let currentIndex = activeIndex ?? 0
        let nextIndex = orderedIDs.index(after: currentIndex) % orderedIDs.count
        let id = orderedIDs[nextIndex]
        activeID = id
        return id
    }

    @discardableResult
    public mutating func activatePrevious() -> TabID? {
        guard !orderedIDs.isEmpty else { return nil }
        let currentIndex = activeIndex ?? 0
        let previousIndex = (currentIndex + orderedIDs.count - 1) % orderedIDs.count
        let id = orderedIDs[previousIndex]
        activeID = id
        return id
    }
}
