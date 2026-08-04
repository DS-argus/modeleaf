import AppKit
import PDFReaderCore

struct PaneCoordinatorSnapshot {
    let layout: PaneLayout
    let panes: [PaneID: ReaderSessionStoreSnapshot]
    let activePaneID: PaneID?
    let activeContentView: NSView?
    let paneContentViews: [PaneID: NSView]
    let paneFocusViews: [PaneID: NSView]
    let activeFocusView: NSView?
    let activeStatus: ReaderStatusSnapshot?
    let windowTitle: String
    let inputContext: InputContext

    func assertCardinality() {
        let ids = Set(layout.paneIDs)
        switch layout {
        case .empty:
            precondition(panes.isEmpty && activePaneID == nil && activeContentView == nil && activeFocusView == nil && activeStatus == nil && paneContentViews.isEmpty && paneFocusViews.isEmpty, "empty cardinality violated: layout=\(layout) panes=\(panes.keys) content=\(paneContentViews.keys) focus=\(paneFocusViews.keys)")
        case .single, .split:
            precondition(Set(panes.keys) == ids && Set(paneContentViews.keys) == ids && Set(paneFocusViews.keys) == ids, "layout/key-set mismatch: layout=\(layout) panes=\(panes.keys) content=\(paneContentViews.keys) focus=\(paneFocusViews.keys)")
            precondition(panes.values.allSatisfy { !$0.isEmpty }, "non-empty layout contains empty store: layout=\(layout)")
            precondition(activePaneID.map(ids.contains) == true && activeContentView != nil && activeFocusView != nil && activeStatus != nil, "non-empty cardinality violated: layout=\(layout) active=\(String(describing: activePaneID))")
        }
    }
}

extension PaneCoordinatorSnapshot {
    var activeStoreSnapshot: ReaderSessionStoreSnapshot {
        guard let activePaneID else {
            precondition(layout == .empty, "missing active pane in non-empty layout: \(layout)")
            return ReaderSessionStoreSnapshot(tabs: [], activeID: nil)
        }
        guard let store = panes[activePaneID] else { preconditionFailure("active pane missing from snapshot: \(activePaneID)") }
        return store
    }
    var tabs: [ReaderTabSnapshot] { activeStoreSnapshot.tabs }
    var activeID: TabID? { activeStoreSnapshot.activeID }
    var isEmpty: Bool { activeStoreSnapshot.isEmpty }
}

enum PaneCloseTransition: Equatable {
    case tabSuccessor
    case bandMemberCollapse(survivor: PaneID)
    case bandCollapse(survivor: PaneID)
    case windowEmpty
}

@MainActor
final class PaneCoordinator {
    private var stores: [PaneID: ReaderSessionStore] = [:]
    private var bootstrapStore: ReaderSessionStore?
    private var suppressCallbacks = false
    private var duplicateSession: ((ReaderDuplicationSnapshot) -> (any ReaderSessionPresenting)?)?
    private var closeStagingHandler: ((PaneCoordinatorSnapshot) -> Bool)?
    private(set) var layout: PaneLayout = .empty
    private(set) var activePaneID: PaneID?
    var onSnapshot: ((PaneCoordinatorSnapshot) -> Void)?
    private var lastFocusedSlotByBand: [PaneBandSide: PaneBandSlot] = [:]
    private var duplicationCompletion: ((any ReaderSessionPresenting, Bool) -> Void)?

    init(initialStore: ReaderSessionStore) {
        if initialStore.snapshot.isEmpty { bootstrapStore = initialStore }
        else {
            let id = PaneID()
            stores[id] = initialStore
            layout = .single(id)
            setActivePane(id)
        }
        initialStore.registerChangeHandler { [weak self] _ in self?.storeDidChange() }
    }

    init() {}

    func configureDuplication(_ handler: @escaping (ReaderDuplicationSnapshot) -> (any ReaderSessionPresenting)?) { duplicateSession = handler }
    func configureDuplicationCompletion(_ handler: @escaping (any ReaderSessionPresenting, Bool) -> Void) { duplicationCompletion = handler }
    func configureCloseStaging(_ handler: @escaping (PaneCoordinatorSnapshot) -> Bool) { closeStagingHandler = handler }
    var snapshot: PaneCoordinatorSnapshot { makeSnapshot() }
    private var activeStore: ReaderSessionStore? { activePaneID.flatMap { stores[$0] } ?? bootstrapStore }
    var activeSession: (any ReaderSessionPresenting)? { activeStore?.activeSession }
    func store(for id: PaneID) -> ReaderSessionStore? { stores[id] }
    func session(for id: TabID) -> (any ReaderSessionPresenting)? { activeStore?.session(for: id) }
    func applyTheme(_ theme: AppKitTheme) {
        stores.values.forEach { $0.applyTheme(theme) }
        bootstrapStore?.applyTheme(theme)
    }

    @discardableResult
    func insert(_ session: any ReaderSessionPresenting, into target: PaneOpenTarget) -> Bool {
        let previous = suppressCallbacks; suppressCallbacks = true; var mutated = false
        defer { suppressCallbacks = previous; if mutated { publish() } }
        switch target {
        case .createIfEmpty:
            if case .empty = layout {
                let id = PaneID(); let store = bootstrapStore ?? ReaderSessionStore()
                if store.onChange == nil { store.registerChangeHandler { [weak self] _ in self?.storeDidChange() } }
                let wasBootstrap = bootstrapStore === store
                if wasBootstrap { bootstrapStore = nil }
                guard store.insert(session) else { if wasBootstrap { bootstrapStore = store }; return false }
                stores[id] = store; layout = .single(id); setActivePane(id); mutated = true; return true
            }
            guard let store = activeStore, store.insert(session) else { return false }; mutated = true; return true
        case let .existing(id):
            guard let store = stores[id], !store.snapshot.isEmpty, store.insert(session) else { return false }
            setActivePane(id); mutated = true; return true
        }
    }

    @discardableResult func activate(tab id: TabID) -> Bool { activeStore?.activate(id) ?? false }
    @discardableResult func activateTab(atOneBasedOrdinal ordinal: Int) -> Bool { activeStore?.activateTab(atOneBasedOrdinal: ordinal) ?? false }
    @discardableResult func activateNext() -> TabID? { activeStore?.activateNext() }
    @discardableResult func activatePrevious() -> TabID? { activeStore?.activatePrevious() }

    @discardableResult func activatePane(_ id: PaneID) -> Bool {
        guard stores[id] != nil else { return false }
        guard activePaneID != id else { setActivePane(id); return true }
        setActivePane(id); publish(); return true
    }

    @discardableResult
    func split(direction: PaneOrientation) -> PaneID? {
        guard let sourcePaneID = activePaneID else { return nil }
        let destinationID = PaneID()
        guard let destinationLayout = layout.applyingSplit(direction, to: sourcePaneID, inserting: destinationID),
              let source = activeSession as? any ReaderDuplicationSnapshotProviding,
              let snapshot = source.duplicationSnapshot,
              let candidate = duplicateSession?(snapshot),
              let validator = candidate as? any ReaderDuplicateValidating
        else { return nil }

        let originalLayout = layout
        let originalActivePaneID = activePaneID
        let previous = suppressCallbacks
        suppressCallbacks = true
        defer { suppressCallbacks = previous }
        let destination = ReaderSessionStore()
        destination.registerChangeHandler { [weak self] _ in self?.storeDidChange() }
        guard destination.insert(candidate) else {
            candidate.prepareForClose()
            duplicationCompletion?(candidate, false)
            return nil
        }
        stores[destinationID] = destination
        layout = destinationLayout
        setActivePane(destinationID)

        var finalized = false
        var succeeded = false
        validator.configureDuplicateValidation { [weak self, weak candidate] success in
            guard let self, let candidate, !finalized else { return }
            finalized = true
            succeeded = success
            if success {
                self.duplicationCompletion?(candidate, true)
                return
            }
            self.stores.removeValue(forKey: destinationID)
            self.layout = originalLayout
            self.setActivePane(originalActivePaneID)
            candidate.prepareForClose()
            self.duplicationCompletion?(candidate, false)
            if !self.suppressCallbacks { self.publish() }
        }

        suppressCallbacks = previous
        publish()
        suppressCallbacks = true
        return finalized && !succeeded ? nil : destinationID
    }
    @discardableResult
    func focus(_ direction: PaneFocusDirection) -> Bool {
        guard let activePaneID, case let .split(orientation, leading, trailing) = layout else { return false }
        let isLeading = leading.contains(activePaneID)
        let source = isLeading ? leading : trailing

        let target: PaneID?
        switch (orientation, direction) {
        case (.sideBySide, .left) where !isLeading:
            target = focusTarget(in: leading, side: .leading, from: source)
        case (.sideBySide, .right) where isLeading:
            target = focusTarget(in: trailing, side: .trailing, from: source)
        case (.stacked, .up) where !isLeading:
            target = focusTarget(in: leading, side: .leading, from: source)
        case (.stacked, .down) where isLeading:
            target = focusTarget(in: trailing, side: .trailing, from: source)
        case (.sideBySide, .up), (.sideBySide, .down), (.stacked, .left), (.stacked, .right):
            switch (direction, source.slot(of: activePaneID)) {
            case (.down, .first?), (.right, .first?): target = source.paneIDs.last
            case (.up, .second?), (.left, .second?): target = source.paneIDs.first
            default: target = nil
            }
        default:
            target = nil
        }
        guard let target else { return false }
        setActivePane(target); publish(); return true
    }
    func unsplit(stage: ((PaneCoordinatorSnapshot) -> Bool)? = nil) -> Bool {
        guard layout.isMultiPane, let activePaneID else { return false }
        // Same reentrancy boundary as closeActiveTab: begun closes make the
        // removed panes' stores inconsistent with the still-installed layout
        // until commit or rollback, so staging-time store changes must not
        // publish.
        let previous = suppressCallbacks
        suppressCallbacks = true
        defer { suppressCallbacks = previous }
        let oldLayout = layout
        let oldMemory = lastFocusedSlotByBand
        let removed = layout.paneIDs.filter { $0 != activePaneID }
        let tokens = removed.flatMap { id -> [(PaneID, PreparedTabClose)] in
            guard let store = stores[id] else {
                preconditionFailure("missing layout-owned store during unsplit teardown: pane=\(id)")
            }
            return store.snapshot.tabs.map { tab in
                guard let token = store.beginClose(tab.id) else {
                    preconditionFailure("ReaderSessionStore cannot begin unsplit teardown: pane=\(id) tab=\(tab.id)")
                }
                return (id, token)
            }
        }
        let projected = makeSnapshot(layout: .single(activePaneID), activePaneID: activePaneID, stores: stores.filter { $0.key == activePaneID })
        guard (stage ?? closeStagingHandler ?? { _ in true })(projected) else {
            for (id, token) in tokens.reversed() { stores[id]?.rollbackClose(token) }
            suppressCallbacks = previous; publish(); suppressCallbacks = true
            return false
        }
        for (id, token) in tokens {
            guard stores[id]?.commitClose(token) == true else {
                preconditionFailure("ReaderSessionStore cannot commit unsplit teardown: pane=\(id) closingTab=\(token.closingTab)")
            }
        }
        for id in removed { stores.removeValue(forKey: id) }
        layout = .single(activePaneID); setActivePane(activePaneID)
        normalizeMemory(from: oldLayout, to: layout, previousMemory: oldMemory)
        suppressCallbacks = previous; publish(); suppressCallbacks = true
        return true
    }

    @discardableResult
    func closeActiveTab(stage: ((PaneCoordinatorSnapshot) -> Bool)? = nil) -> Bool {
        guard let paneID = activePaneID, let store = stores[paneID], let id = store.snapshot.activeID, let token = store.beginClose(id) else { return false }
        // Suppress from here: beginClose already removed the tab from the
        // store, so any store change published before commit/rollback (e.g.
        // PDFKit notifications fired while the staging handler renders the
        // projection and unmounts views) would snapshot a mid-transaction
        // state and trap the strict makeSnapshot preconditions.
        let previous = suppressCallbacks
        suppressCallbacks = true
        defer { suppressCallbacks = previous }
        let oldLayout = layout
        let oldMemory = lastFocusedSlotByBand
        let transition: PaneCloseTransition
        let projected: PaneCoordinatorSnapshot
        if token.projectedSelection != nil {
            transition = .tabSuccessor
            projected = makeSnapshot()
        } else if let collapse = layoutAfterRemovingLastTab(in: paneID) {
            transition = collapseTransition(for: paneID, in: oldLayout, survivor: collapse.activePaneID)
            projected = makeSnapshot(layout: collapse.layout, activePaneID: collapse.activePaneID, stores: stores.filter { $0.key != paneID })
        } else {
            transition = .windowEmpty
            projected = makeEmptySnapshot()
        }
        guard (stage ?? closeStagingHandler ?? { _ in true })(projected) else {
            store.rollbackClose(token)
            suppressCallbacks = previous; publish(); suppressCallbacks = true
            return false
        }
        guard store.commitClose(token) else {
            preconditionFailure("ReaderSessionStore cannot commit active-tab close: pane=\(paneID) closingTab=\(token.closingTab)")
        }
        switch transition {
        case .tabSuccessor:
            break
        case let .bandMemberCollapse(survivor), let .bandCollapse(survivor):
            stores.removeValue(forKey: paneID)
            guard let collapse = layoutAfterRemovingLastTab(in: paneID, from: oldLayout) else { preconditionFailure("missing pane collapse") }
            layout = collapse.layout
            setActivePane(survivor)
            normalizeMemory(from: oldLayout, to: layout, previousMemory: oldMemory)
        case .windowEmpty:
            stores.removeValue(forKey: paneID)
            layout = .empty
            setActivePane(nil)
        }
        suppressCallbacks = previous; publish(); suppressCallbacks = true
        return true
    }

    private func collapseTransition(for paneID: PaneID, in layout: PaneLayout, survivor: PaneID) -> PaneCloseTransition {
        switch layout {
        case let .split(_, leading, trailing):
            let stack = leading.contains(paneID) ? leading : trailing
            if case .two = stack { return .bandMemberCollapse(survivor: survivor) }
            return .bandCollapse(survivor: survivor)
        case .empty, .single:
            preconditionFailure("non-terminal pane collapse has no source stack")
        }
    }
    /// tmux crossing semantics: a source `.two` crosses to the geometrically
    /// overlapping slot. A full-span source uses the destination band's MRU
    /// slot, falling back to its first member.
    private func focusTarget(in stack: PaneStack, side: PaneBandSide, from source: PaneStack) -> PaneID {
        switch stack {
        case let .one(id):
            return id
        case let .two(first, second):
            guard case .two = source else {
                return lastFocusedSlotByBand[side] == .second ? second : first
            }
            guard let activePaneID, source.slot(of: activePaneID) == .second else { return first }
            return second
        }
    }

    private func layoutAfterRemovingLastTab(in paneID: PaneID, from source: PaneLayout? = nil) -> (layout: PaneLayout, activePaneID: PaneID)? {
        let source = source ?? layout
        switch source {
        case .empty, .single:
            return nil
        case let .split(orientation, leading, trailing):
            if leading.contains(paneID) {
                switch leading {
                case let .one(removed):
                    switch trailing {
                    case let .one(survivor):
                        return (.single(survivor), survivor)
                    case let .two(first, second):
                        return (.split(orientation: orientation.perpendicular, leading: .one(first), trailing: .one(second)), focusTarget(in: trailing, side: .trailing, from: .one(removed)))
                    }
                case let .two(first, second):
                    let survivor = paneID == first ? second : first
                    return (.split(orientation: orientation, leading: .one(survivor), trailing: trailing), survivor)
                }
            }
            if trailing.contains(paneID) {
                switch trailing {
                case let .one(removed):
                    switch leading {
                    case let .one(survivor):
                        return (.single(survivor), survivor)
                    case let .two(first, second):
                        return (.split(orientation: orientation.perpendicular, leading: .one(first), trailing: .one(second)), focusTarget(in: leading, side: .leading, from: .one(removed)))
                    }
                case let .two(first, second):
                    let survivor = paneID == first ? second : first
                    return (.split(orientation: orientation, leading: leading, trailing: .one(survivor)), survivor)
                }
            }
            return nil
        }
    }

    private func normalizeMemory(from oldLayout: PaneLayout, to newLayout: PaneLayout, previousMemory: [PaneBandSide: PaneBandSlot]) {
        var normalized: [PaneBandSide: PaneBandSlot] = [:]
        for newSide in [PaneBandSide.leading, .trailing] {
            guard let newStack = stack(in: newLayout, at: newSide), case let .two(first, second) = newStack else { continue }
            let rememberedPane = [PaneBandSide.leading, .trailing].lazy.compactMap { oldSide -> PaneID? in
                guard let oldStack = self.stack(in: oldLayout, at: oldSide), case let .two(oldFirst, oldSecond) = oldStack else { return nil }
                let remembered = previousMemory[oldSide] == .second ? oldSecond : oldFirst
                return newStack.contains(remembered) ? remembered : nil
            }.first
            if rememberedPane == first { normalized[newSide] = .first }
            else if rememberedPane == second { normalized[newSide] = .second }
            else if activePaneID == first { normalized[newSide] = .first }
            else if activePaneID == second { normalized[newSide] = .second }
            else { normalized[newSide] = .first }
        }
        lastFocusedSlotByBand = normalized
    }


    private func stack(in layout: PaneLayout, at side: PaneBandSide) -> PaneStack? {
        switch (layout, side) {
        case let (.split(_, leading, _), .leading): return leading
        case let (.split(_, _, trailing), .trailing): return trailing
        default: return nil
        }
    }

    private func setActivePane(_ id: PaneID?) {
        guard let id else {
            precondition(layout == .empty, "cannot clear active pane outside empty layout: \(layout)")
            activePaneID = nil
            lastFocusedSlotByBand.removeAll()
            return
        }
        precondition(layout.contains(id), "cannot activate pane outside installed layout: \(id) in \(layout)")
        activePaneID = id
        if let side = layout.side(of: id), let slot = layout.slot(of: id) {
            lastFocusedSlotByBand[side] = slot
        }
    }

    private func storeDidChange() {
        if case .empty = layout, let bootstrapStore, !bootstrapStore.snapshot.isEmpty {
            let id = PaneID(); stores[id] = bootstrapStore; self.bootstrapStore = nil; layout = .single(id); setActivePane(id)
        }
        if !suppressCallbacks { publish() }
    }

    private func makeEmptySnapshot(stores: [PaneID: ReaderSessionStore] = [:], activePaneID: PaneID? = nil) -> PaneCoordinatorSnapshot {
        precondition(stores.isEmpty && activePaneID == nil, "empty snapshot requires no installed stores or active pane")
        return PaneCoordinatorSnapshot(layout: .empty, panes: [:], activePaneID: nil, activeContentView: nil, paneContentViews: [:], paneFocusViews: [:], activeFocusView: nil, activeStatus: nil, windowTitle: "Modeleaf", inputContext: .navigation)
    }

    private func makeSnapshot(layout: PaneLayout? = nil, activePaneID: PaneID? = nil, stores sourceStores: [PaneID: ReaderSessionStore]? = nil) -> PaneCoordinatorSnapshot {
        let effectiveLayout = layout ?? self.layout
        let effectiveActiveID = activePaneID ?? self.activePaneID
        let effectiveStores = sourceStores ?? stores
        guard effectiveLayout != .empty else {
            precondition(effectiveStores.isEmpty && effectiveActiveID == nil, "empty snapshot input contains stores or an active pane")
            return makeEmptySnapshot(stores: effectiveStores, activePaneID: effectiveActiveID)
        }
        let ids = Set(effectiveLayout.paneIDs)
        let storeKeys = Set(effectiveStores.keys)
        precondition(storeKeys == ids, "snapshot store/layout key mismatch: layout=\(effectiveLayout) layoutIDs=\(ids) stores=\(storeKeys)")
        precondition(effectiveActiveID.map(ids.contains) == true, "snapshot active/layout mismatch: layout=\(effectiveLayout) active=\(String(describing: effectiveActiveID))")
        let panes = Dictionary(uniqueKeysWithValues: effectiveLayout.paneIDs.map { ($0, effectiveStores[$0]!.snapshot) })
        let paneContentViews = Dictionary(uniqueKeysWithValues: effectiveLayout.paneIDs.map { id in
            guard let content = effectiveStores[id]?.activeSession?.contentView else { preconditionFailure("snapshot missing content view: layout=\(effectiveLayout) pane=\(id) stores=\(storeKeys)") }
            return (id, content)
        })
        let paneFocusViews = Dictionary(uniqueKeysWithValues: effectiveLayout.paneIDs.map { id in
            guard let focus = effectiveStores[id]?.activeSession?.focusView else { preconditionFailure("snapshot missing focus view: layout=\(effectiveLayout) pane=\(id) stores=\(storeKeys)") }
            return (id, focus)
        })
        guard let activeID = effectiveActiveID, let active = effectiveStores[activeID]?.activeSession else { preconditionFailure("snapshot missing active session: layout=\(effectiveLayout) active=\(String(describing: effectiveActiveID))") }
        let result = PaneCoordinatorSnapshot(layout: effectiveLayout, panes: panes, activePaneID: activeID, activeContentView: active.contentView, paneContentViews: paneContentViews, paneFocusViews: paneFocusViews, activeFocusView: active.focusView, activeStatus: active.statusSnapshot, windowTitle: "\(active.title) — Modeleaf", inputContext: active.preferredInputContext)
        result.assertCardinality(); return result
    }

    private func publish() { onSnapshot?(snapshot) }
}

