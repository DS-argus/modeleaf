import Foundation
import PDFReaderCore
import Testing

@Suite("Navigation history")
struct NavigationHistoryTests {
    @Test("AC01: snapshots validate inputs and retain exact value semantics")
    func snapshotsValidateAndCompareLocations() {
        #expect(NavigationSnapshot(pageIndex: -1, pageSpacePoint: CGPoint(x: 0, y: 0)) == nil)
        #expect(NavigationSnapshot(pageIndex: 0, pageSpacePoint: CGPoint(x: .infinity, y: 0)) == nil)
        #expect(NavigationSnapshot(pageIndex: 0, pageSpacePoint: CGPoint(x: 0, y: .nan)) == nil)
        let a = snapshot(0, 10, 20)
        #expect(a == snapshot(0, 10, 20))
        #expect(a != snapshot(0, 10.25, 20))
        #expect(a.isSameLocation(as: snapshot(0, 10.5, 19.5)))
        #expect(!a.isSameLocation(as: snapshot(0, 10.501, 20)))
        #expect(!a.isSameLocation(as: snapshot(1, 10, 20)))
    }

    @Test("AC02: meaningful jumps branch from B after Back from C")
    func meaningfulJumpBranchesAndRejectsSameLandings() {
        let a = snapshot(0, 0, 0)
        let b = snapshot(1, 0, 0)
        let c = snapshot(2, 0, 0)
        let d = snapshot(3, 0, 0)
        var history = NavigationHistory()
        let first = history.commitMeaningfulJump(origin: a, landing: b)
        let second = history.commitMeaningfulJump(origin: b, landing: c)
        #expect(first)
        #expect(second)
        let back = history.commitBack(current: c)
        #expect(back)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == c)
        let branch = history.commitMeaningfulJump(origin: b, landing: d)
        #expect(branch)
        #expect(history.backDestination == b)
        #expect(history.forwardDestination == nil)
        let same = history.commitMeaningfulJump(origin: b, landing: snapshot(1, 0.5, 0.5))
        #expect(!same)
        #expect(history.backDestination == b)
    }

    @Test("AC02: traversal commits only after a destination has been peeked")
    func traversalUsesPeekThenExplicitCommit() {
        let a = snapshot(0, 0, 0)
        let b = snapshot(1, 0, 0)
        let c = snapshot(2, 0, 0)
        var history = NavigationHistory()
        _ = history.commitMeaningfulJump(origin: a, landing: b)
        _ = history.commitMeaningfulJump(origin: b, landing: c)
        #expect(history.backDestination == b)
        let back = history.commitBack(current: c)
        #expect(back)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == c)
        let forward = history.commitForward(current: b)
        #expect(forward)
        #expect(history.backDestination == b)
        #expect(history.forwardDestination == nil)
        var empty = NavigationHistory()
        let emptyBack = empty.commitBack(current: a)
        let emptyForward = empty.commitForward(current: a)
        #expect(!emptyBack)
        #expect(!emptyForward)
    }

    @Test("AC03: capacity includes live current and evicts oldest Back")
    func capacityEvictsOldestBackPosition() {
        var history = NavigationHistory()
        for page in 0 ... 100 {
            _ = history.commitMeaningfulJump(origin: snapshot(page, 0, 0), landing: snapshot(page + 1, 0, 0))
        }
        #expect(history.backCount == 99)
        #expect(history.forwardCount == 0)
        #expect(history.backDestination == snapshot(100, 0, 0))
        var current = snapshot(101, 0, 0)
        for expected in stride(from: 100, through: 2, by: -1) {
            let back = history.commitBack(current: current)
            #expect(back)
            current = snapshot(expected, 0, 0)
        }
        #expect(current == snapshot(2, 0, 0))
        #expect(history.backCount == 0)
        #expect(history.forwardCount == 99)
        #expect(history.forwardDestination == snapshot(3, 0, 0))
        let forward = history.commitForward(current: current)
        #expect(forward)
        #expect(history.backCount == 1)
        #expect(history.forwardCount == 98)
    }

    @Test("T04B: first result inspection is nonmutating until history commits")
    func firstResultUsesSuccessOnlyTwoPhaseCommit() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        let inspection = epoch.inspectDisplayedDistinct(searchGeneration: 1)
        #expect(inspection == .first(origin: a))
        #expect(epoch == .armed(origin: a, searchGeneration: 1))
        let historyCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        #expect(historyCommit)
        let epochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 1, historyCommitted: historyCommit)
        #expect(epochCommit)
        #expect(epoch == .coalescing(searchGeneration: 1))
        #expect(history.backDestination == a)
    }

    @Test("T04B: rejected first history commit leaves epoch armed")
    func rejectedFirstResultDoesNotAdvanceEpoch() {
        let a = snapshot(0, 0, 0)
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        #expect(epoch.inspectDisplayedDistinct(searchGeneration: 1) == .first(origin: a))
        let historyCommit = history.commitMeaningfulJump(origin: a, landing: snapshot(0, 0.5, 0.5))
        let epochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 1, historyCommitted: historyCommit)
        #expect(!historyCommit)
        #expect(!epochCommit)
        #expect(epoch == .armed(origin: a, searchGeneration: 1))
        #expect(history.backCount == 0)
    }

    @Test("T04B: replacement retains armed origin and coalesces current results")
    func replacementAndCoalescingTransitions() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        epoch.replaceQuery(searchGeneration: 2)
        #expect(epoch.inspectDisplayedDistinct(searchGeneration: 1) == .ignored)
        #expect(epoch.inspectDisplayedDistinct(searchGeneration: 2) == .first(origin: a))
        let historyCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        let epochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 2, historyCommitted: historyCommit)
        #expect(historyCommit)
        #expect(epochCommit)
        epoch.replaceQuery(searchGeneration: 3)
        #expect(epoch == .coalescing(searchGeneration: 3))
        #expect(epoch.inspectDisplayedDistinct(searchGeneration: 2) == .ignored)
        #expect(epoch.inspectDisplayedDistinct(searchGeneration: 3) == .coalesced)
        #expect(history.backDestination == a)
    }

    @Test("T04B: same failed no-result and clear cancel preserve required lifecycle")
    func sameFailedNoResultAndClearCancelTransitions() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        let s2 = snapshot(2, 0, 0)
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        epoch.displayedSameFailedOrNoResult(searchGeneration: 1)
        #expect(epoch == .armed(origin: a, searchGeneration: 1))
        epoch.clearOrCancel()
        #expect(epoch == .idle)
        epoch.arm(origin: a, searchGeneration: 2)
        let historyCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        let epochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 2, historyCommitted: historyCommit)
        #expect(historyCommit)
        #expect(epochCommit)
        epoch.displayedSameFailedOrNoResult(searchGeneration: 2)
        #expect(epoch == .coalescing(searchGeneration: 2))
        epoch.clearOrCancel()
        #expect(epoch == .idle)
        epoch.arm(origin: s1, searchGeneration: 3)
        let restartCommit = history.commitMeaningfulJump(origin: s1, landing: s2)
        let restartEpochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 3, historyCommitted: restartCommit)
        #expect(restartCommit)
        #expect(restartEpochCommit)
        #expect(history.backDestination == s1)
    }

    @Test("T04B: failed Back and same branch preserve topology before successful traversal")
    func failedBackAndSameBranchPreserveTopology() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        var live = s1
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        let initialCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        let epochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 1, historyCommitted: initialCommit)
        #expect(initialCommit)
        #expect(epochCommit)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == nil)

        // A failed restore peeks but must not transfer either stack.
        #expect(history.backDestination == a)
        #expect(live == s1)
        #expect(history.backCount == 1)
        #expect(history.forwardCount == 0)
        #expect(epoch == .coalescing(searchGeneration: 1))

        let back = history.commitBack(current: live)
        #expect(back)
        live = a
        epoch.successfulTraversal()
        #expect(live == a)
        #expect(history.backDestination == nil)
        #expect(history.forwardDestination == s1)
        #expect(epoch == .idle)

        let sameBranch = history.commitMeaningfulJump(origin: live, landing: live)
        #expect(!sameBranch)
        #expect(history.backDestination == nil)
        #expect(history.forwardDestination == s1)
        #expect(history.backCount == 0)
        #expect(history.forwardCount == 1)
    }

    @Test("T04B: excluded movement does not split a coalescing search epoch")
    func excludedMovementThenCoalescedResultDoesNotRecord() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        let x = snapshot(1, 40, 40)
        let s2 = snapshot(2, 0, 0)
        var live = s1
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        let initialCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        let epochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 1, historyCommitted: initialCommit)
        #expect(initialCommit)
        #expect(epochCommit)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == nil)

        live = x
        epoch.excludedMovementOrTabSwitch()
        #expect(live == x)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == nil)
        #expect(history.backCount == 1)
        #expect(history.forwardCount == 0)
        #expect(epoch == .coalescing(searchGeneration: 1))

        let result = epoch.inspectDisplayedDistinct(searchGeneration: 1)
        #expect(result == .coalesced)
        live = s2
        #expect(live == s2)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == nil)
        #expect(history.backCount == 1)
        #expect(history.forwardCount == 0)
        #expect(epoch == .coalescing(searchGeneration: 1))
    }

    @Test("T04B: successful Forward ends a reachable active epoch")
    func successfulForwardEndsActiveEpoch() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        var live = s1
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        let initialCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        #expect(initialCommit)
        let back = history.commitBack(current: live)
        #expect(back)
        live = a
        #expect(history.backDestination == nil)
        #expect(history.forwardDestination == s1)

        epoch.arm(origin: live, searchGeneration: 2)
        // The session has a current search epoch at A; no history movement accompanies arming.
        epoch = .coalescing(searchGeneration: 2)
        let forward = history.commitForward(current: live)
        #expect(forward)
        live = s1
        epoch.successfulTraversal()
        #expect(live == s1)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == nil)
        #expect(epoch == .idle)
    }

    @Test("T04B: tab switches preserve armed and coalescing while teardown discards")
    func switchAndTeardownTransitions() {
        let a = snapshot(0, 0, 0)
        var armed: SearchEpoch = .idle
        armed.arm(origin: a, searchGeneration: 1)
        armed.excludedMovementOrTabSwitch()
        #expect(armed == .armed(origin: a, searchGeneration: 1))
        var coalescing: SearchEpoch = .idle
        coalescing.arm(origin: a, searchGeneration: 2)
        var history = NavigationHistory()
        let historyCommit = history.commitMeaningfulJump(origin: a, landing: snapshot(1, 0, 0))
        let epochCommit = coalescing.commitFirstDisplayedDistinct(searchGeneration: 2, historyCommitted: historyCommit)
        #expect(historyCommit)
        #expect(epochCommit)
        coalescing.excludedMovementOrTabSwitch()
        #expect(coalescing == .coalescing(searchGeneration: 2))
        coalescing.teardown()
        #expect(coalescing == .idle)
    }

    @Test("T04C: A S1 Back A S2 clears stale Forward and starts new epoch")
    func traversalBranchesSearchHistory() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        let s2 = snapshot(2, 0, 0)
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        let firstCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        let firstEpochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 1, historyCommitted: firstCommit)
        #expect(firstCommit)
        #expect(firstEpochCommit)
        let back = history.commitBack(current: s1)
        #expect(back)
        epoch.successfulTraversal()
        #expect(history.forwardDestination == s1)
        epoch.arm(origin: a, searchGeneration: 2)
        let secondCommit = history.commitMeaningfulJump(origin: a, landing: s2)
        let secondEpochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 2, historyCommitted: secondCommit)
        #expect(secondCommit)
        #expect(secondEpochCommit)
        #expect(history.backDestination == a)
        #expect(history.forwardDestination == nil)
        #expect(epoch == .coalescing(searchGeneration: 2))
    }

    @Test("T04C: pending search then non-search M starts next epoch from M")
    func pendingSearchNonSearchBoundary() {
        let a = snapshot(0, 0, 0)
        let m = snapshot(1, 0, 0)
        let s1 = snapshot(2, 0, 0)
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        let meaningfulM = history.commitMeaningfulJump(origin: a, landing: m)
        #expect(meaningfulM)
        epoch.successfulNonSearchJump()
        #expect(epoch == .idle)
        epoch.arm(origin: m, searchGeneration: 2)
        #expect(epoch.inspectDisplayedDistinct(searchGeneration: 2) == .first(origin: m))
        let searchCommit = history.commitMeaningfulJump(origin: m, landing: s1)
        let epochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 2, historyCommitted: searchCommit)
        #expect(searchCommit)
        #expect(epochCommit)
        #expect(history.backDestination == m)
        let back = history.commitBack(current: s1)
        #expect(back)
        #expect(history.backDestination == a)
    }

    @Test("T04C: A S1 M S2 Back and Forward traverse exact stack order")
    func exactStackTraversalOrder() {
        let a = snapshot(0, 0, 0)
        let s1 = snapshot(1, 0, 0)
        let m = snapshot(2, 0, 0)
        let s2 = snapshot(3, 0, 0)
        var history = NavigationHistory()
        var epoch: SearchEpoch = .idle
        epoch.arm(origin: a, searchGeneration: 1)
        let firstCommit = history.commitMeaningfulJump(origin: a, landing: s1)
        let firstEpochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 1, historyCommitted: firstCommit)
        #expect(firstCommit)
        #expect(firstEpochCommit)
        let meaningfulM = history.commitMeaningfulJump(origin: s1, landing: m)
        #expect(meaningfulM)
        epoch.successfulNonSearchJump()
        epoch.arm(origin: m, searchGeneration: 2)
        let secondCommit = history.commitMeaningfulJump(origin: m, landing: s2)
        let secondEpochCommit = epoch.commitFirstDisplayedDistinct(searchGeneration: 2, historyCommitted: secondCommit)
        #expect(secondCommit)
        #expect(secondEpochCommit)
        var current = s2
        for expected in [m, s1, a] {
            #expect(history.backDestination == expected)
            let back = history.commitBack(current: current)
            #expect(back)
            current = expected
            epoch.successfulTraversal()
        }
        for expected in [s1, m, s2] {
            #expect(history.forwardDestination == expected)
            let forward = history.commitForward(current: current)
            #expect(forward)
            current = expected
        }
        #expect(current == s2)
        #expect(history.backDestination == m)
        #expect(history.forwardDestination == nil)
        #expect(epoch == .idle)
    }


    private func snapshot(_ pageIndex: Int, _ x: CGFloat, _ y: CGFloat) -> NavigationSnapshot {
        NavigationSnapshot(pageIndex: pageIndex, pageSpacePoint: CGPoint(x: x, y: y))!
    }
}
