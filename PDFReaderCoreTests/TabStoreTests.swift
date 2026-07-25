import Foundation
import PDFReaderCore
import Testing

@Suite("Foundation-only tab state")
struct TabStoreTests {
    @Test("U-TAB-01 inserting tabs preserves order and activates the newest tab")
    func insertPreservesOrderAndActivatesNewest() {
        let first = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let second = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let third = TabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        var store = TabStore()

        #expect(store.orderedIDs.isEmpty)
        #expect(store.activeID == nil)
        #expect(store.activeIndex == nil)

        let insertedFirst = store.insert(first)
        #expect(insertedFirst)
        #expect(store.orderedIDs == [first])
        #expect(store.activeID == first)
        #expect(store.activeIndex == 0)

        let insertedSecond = store.insert(second)
        #expect(insertedSecond)
        let insertedThird = store.insert(third)
        #expect(insertedThird)
        #expect(store.orderedIDs == [first, second, third])
        #expect(store.activeID == third)
        #expect(store.activeIndex == 2)
    }

    @Test("U-TAB-01 duplicate tab IDs are rejected without changing selection")
    func duplicateIDsAreRejectedNoOp() {
        let first = fixedID(1)
        let second = fixedID(2)
        var store = TabStore()
        let insertedFirst = store.insert(first)
        #expect(insertedFirst)
        let insertedSecond = store.insert(second)
        #expect(insertedSecond)
        let activatedFirst = store.activate(first)
        #expect(activatedFirst)

        let duplicateRejected = !store.insert(second)
        #expect(duplicateRejected)
        #expect(store.orderedIDs == [first, second])
        #expect(store.activeID == first)
        #expect(store.activeIndex == 0)
    }

    @Test("U-TAB-02 activation requires an existing tab")
    func activationRequiresExistingTab() {
        let first = fixedID(1)
        let missing = fixedID(9)
        var store = TabStore()
        let missingRejected = !store.activate(missing)
        #expect(missingRejected)
        #expect(store.activeID == nil)

        let insertedFirst = store.insert(first)
        #expect(insertedFirst)
        let missingRejectedAfterInsert = !store.activate(missing)
        #expect(missingRejectedAfterInsert)
        #expect(store.activeID == first)
        #expect(store.activeIndex == 0)
    }

    @Test("U-TAB-02 zero-based ordinal activation is bounded and reports actual changes")
    func ordinalActivationIsBounded() {
        let first = fixedID(1)
        let second = fixedID(2)
        let third = fixedID(3)
        var store = TabStore(orderedIDs: [first, second, third], activeID: third)

        let selectedFirst = store.activate(at: 0)
        #expect(selectedFirst)
        #expect(store.activeID == first)
        let sameSelection = store.activate(at: 0)
        let negativeSelection = store.activate(at: -1)
        let outOfRangeSelection = store.activate(at: 3)
        #expect(!sameSelection)
        #expect(!negativeSelection)
        #expect(!outOfRangeSelection)
        #expect(store.activeID == first)
    }

    @Test("U-TAB-02 closing a non-active tab preserves the active tab")
    func closeNonActivePreservesSelection() {
        let first = fixedID(1)
        let second = fixedID(2)
        let third = fixedID(3)
        var store = TabStore(orderedIDs: [first, second, third], activeID: third)

        let closedFirst = store.close(first)
        #expect(closedFirst)
        #expect(store.orderedIDs == [second, third])
        #expect(store.activeID == third)
        #expect(store.activeIndex == 1)
    }

    @Test("U-TAB-02 closing the active tab selects the next adjacent tab when possible")
    func closeActiveSelectsNextAdjacentWhenPossible() {
        let first = fixedID(1)
        let second = fixedID(2)
        let third = fixedID(3)
        var store = TabStore(orderedIDs: [first, second, third], activeID: second)

        let closedSecond = store.close(second)
        #expect(closedSecond)
        #expect(store.orderedIDs == [first, third])
        #expect(store.activeID == third)
        #expect(store.activeIndex == 1)
    }

    @Test("U-TAB-02 closing the active last tab selects the previous adjacent tab")
    func closeActiveLastSelectsPreviousAdjacent() {
        let first = fixedID(1)
        let second = fixedID(2)
        let third = fixedID(3)
        var store = TabStore(orderedIDs: [first, second, third], activeID: third)

        let closedThird = store.close(third)
        #expect(closedThird)
        #expect(store.orderedIDs == [first, second])
        #expect(store.activeID == second)
        #expect(store.activeIndex == 1)
    }

    @Test("U-TAB-02 final close yields an empty inactive state")
    func finalCloseYieldsEmptyState() {
        let only = fixedID(1)
        var store = TabStore(orderedIDs: [only], activeID: only)

        let closedOnly = store.close(only)
        #expect(closedOnly)
        #expect(store.orderedIDs.isEmpty)
        #expect(store.activeID == nil)
        #expect(store.activeIndex == nil)
        let missingCloseRejected = !store.close(only)
        #expect(missingCloseRejected)
    }

    @Test("U-TAB-02 next and previous activation wrap around the ordered tabs")
    func nextPreviousWrapAround() {
        let first = fixedID(1)
        let second = fixedID(2)
        let third = fixedID(3)
        var store = TabStore(orderedIDs: [first, second, third], activeID: first)

        let nextSecond = store.activateNext()
        #expect(nextSecond == second)
        #expect(store.activeID == second)
        let nextThird = store.activateNext()
        #expect(nextThird == third)
        let nextFirst = store.activateNext()
        #expect(nextFirst == first)
        #expect(store.activeIndex == 0)

        let previousThird = store.activatePrevious()
        #expect(previousThird == third)
        #expect(store.activeID == third)
        let previousSecond = store.activatePrevious()
        #expect(previousSecond == second)
    }

    @Test("initializer normalizes duplicate and invalid active inputs")
    func initializerNormalizesInvariants() {
        let first = fixedID(1)
        let duplicate = first
        let second = fixedID(2)
        let missing = fixedID(9)

        let store = TabStore(orderedIDs: [first, duplicate, second], activeID: missing)
        #expect(store.orderedIDs == [first, second])
        #expect(store.activeID == first)
        #expect(store.activeIndex == 0)
    }

    @Test("empty next and previous activation are no-ops")
    func emptyNextPreviousAreNoOps() {
        var store = TabStore()
        let next = store.activateNext()
        #expect(next == nil)
        let previous = store.activatePrevious()
        #expect(previous == nil)
        #expect(store.orderedIDs.isEmpty)
        #expect(store.activeID == nil)
        #expect(store.activeIndex == nil)
    }

    @Test("TabID supports stable raw-value round trips")
    func tabIDRoundTripsRawValue() throws {
        let source = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        let id = TabID(rawValue: source)

        #expect(id.rawValue == source)
        #expect(TabID(rawValue: id.rawValue) == id)
        #expect(TabID().rawValue != TabID().rawValue)
    }

    private func fixedID(_ value: Int) -> TabID {
        TabID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
    }
}
