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
    var activeStoreSnapshot: ReaderSessionStoreSnapshot { activePaneID.flatMap { panes[$0] } ?? ReaderSessionStoreSnapshot(tabs: [], activeID: nil) }
    var tabs: [ReaderTabSnapshot] { activeStoreSnapshot.tabs }
    var activeID: TabID? { activeStoreSnapshot.activeID }
    var isEmpty: Bool { activeStoreSnapshot.isEmpty }
}

enum PaneCloseTransition: Equatable {
    case tabSuccessor(pane: PaneID, tab: TabID)
    case paneCollapse(survivor: PaneID)
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
    private var duplicationCompletion: ((any ReaderSessionPresenting, Bool) -> Void)?

    init(initialStore: ReaderSessionStore) {
        if initialStore.snapshot.isEmpty { bootstrapStore = initialStore }
        else {
            let id = PaneID()
            stores[id] = initialStore
            layout = .single(.one(id))
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
                stores[id] = store; layout = .single(.one(id)); setActivePane(id); mutated = true; return true
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
        guard activePaneID != id else { return true }
        setActivePane(id); publish(); return true
    }

    @discardableResult
    func split(direction: PaneOrientation) -> PaneID? {
        guard case let .single(.one(originID)) = layout,
              let source = activeSession as? any ReaderDuplicationSnapshotProviding,
              let candidate = duplicateSession?(source.duplicationSnapshot)
        else { return nil }
        let previous = suppressCallbacks; suppressCallbacks = true
        defer { suppressCallbacks = previous }
        let destinationID = PaneID(); let destination = ReaderSessionStore()
        destination.registerChangeHandler { [weak self] _ in self?.storeDidChange() }
        guard destination.insert(candidate) else { candidate.prepareForClose(); duplicationCompletion?(candidate, false); return nil }
        stores[destinationID] = destination
        layout = direction == .sideBySide
            ? .split(leading: .one(originID), trailing: .one(destinationID))
            : .single(.two(top: originID, bottom: destinationID))
        setActivePane(destinationID)
        suppressCallbacks = previous; publish(); suppressCallbacks = true
        duplicationCompletion?(candidate, true)
        return destinationID
    }

    @discardableResult
    func focus(_ direction: PaneFocusDirection) -> Bool {
        guard let activePaneID else { return false }
        let target: PaneID?
        switch layout {
        case let .split(leading, trailing):
            switch (direction, leading.contains(activePaneID), trailing.contains(activePaneID)) {
            case (.right, true, _): target = trailing.paneIDs.first
            case (.left, _, true): target = leading.paneIDs.first
            default: target = nil
            }
        case let .single(.two(top, bottom)):
            switch (direction, activePaneID) {
            case (.down, top), (.up, bottom): target = activePaneID == top ? bottom : top
            default: target = nil
            }
        default: target = nil
        }
        guard let target else { return false }
        setActivePane(target); publish(); return true
    }

    @discardableResult
    func unsplit(stage: ((PaneCoordinatorSnapshot) -> Bool)? = nil) -> Bool {
        guard layout.isMultiPane, let activePaneID else { return false }
        let removed = layout.paneIDs.filter { $0 != activePaneID }
        let projected = makeSnapshot(layout: .single(.one(activePaneID)), activePaneID: activePaneID, stores: stores.filter { $0.key == activePaneID })
        guard (stage ?? closeStagingHandler ?? { _ in true })(projected) else { publish(); return false }
        let previous = suppressCallbacks; suppressCallbacks = true
        defer { suppressCallbacks = previous }
        for id in removed {
            guard let store = stores[id] else { continue }
            for tab in store.snapshot.tabs { guard let token = store.beginClose(tab.id), store.commitClose(token) else { preconditionFailure("ReaderSessionStore cannot commit unsplit teardown") } }
            stores.removeValue(forKey: id)
        }
        layout = .single(.one(activePaneID)); setActivePane(activePaneID)
        suppressCallbacks = previous; publish(); suppressCallbacks = true
        return true
    }

    @discardableResult
    func closeActiveTab(stage: ((PaneCoordinatorSnapshot) -> Bool)? = nil) -> Bool {
        guard let paneID = activePaneID, let store = stores[paneID], let id = store.snapshot.activeID, let token = store.beginClose(id) else { return false }
        let transition: PaneCloseTransition
        let projected: PaneCoordinatorSnapshot
        if let successor = token.projectedSelection { transition = .tabSuccessor(pane: paneID, tab: successor); projected = makeSnapshot() }
        else if let survivor = layout.paneIDs.first(where: { $0 != paneID }) {
            transition = .paneCollapse(survivor: survivor)
            projected = makeSnapshot(layout: .single(.one(survivor)), activePaneID: survivor, stores: stores.filter { $0.key != paneID })
        } else { transition = .windowEmpty; projected = makeEmptySnapshot() }
        guard (stage ?? closeStagingHandler ?? { _ in true })(projected) else { store.rollbackClose(token); publish(); return false }
        let previous = suppressCallbacks; suppressCallbacks = true
        defer { suppressCallbacks = previous }
        guard store.commitClose(token) else { store.rollbackClose(token); publish(); return false }
        switch transition {
        case .tabSuccessor: break
        case let .paneCollapse(survivor): stores.removeValue(forKey: paneID); layout = .single(.one(survivor)); setActivePane(survivor)
        case .windowEmpty: stores.removeValue(forKey: paneID); layout = .empty; activePaneID = nil
        }
        suppressCallbacks = previous; publish(); suppressCallbacks = true
        return true
    }

    private func setActivePane(_ id: PaneID) {
        precondition(layout.contains(id), "cannot activate pane outside installed layout: \(id) in \(layout)")
        activePaneID = id
    }

    private func storeDidChange() {
        if case .empty = layout, let bootstrapStore, !bootstrapStore.snapshot.isEmpty {
            let id = PaneID(); stores[id] = bootstrapStore; self.bootstrapStore = nil; layout = .single(.one(id)); setActivePane(id)
        }
        if !suppressCallbacks { publish() }
    }

    private func makeEmptySnapshot() -> PaneCoordinatorSnapshot {
        PaneCoordinatorSnapshot(layout: .empty, panes: [:], activePaneID: nil, activeContentView: nil, paneContentViews: [:], paneFocusViews: [:], activeFocusView: nil, activeStatus: nil, windowTitle: "Modeleaf", inputContext: .navigation)
    }

    private func makeSnapshot(layout: PaneLayout? = nil, activePaneID: PaneID? = nil, stores sourceStores: [PaneID: ReaderSessionStore]? = nil) -> PaneCoordinatorSnapshot {
        let effectiveLayout = layout ?? self.layout
        guard effectiveLayout != .empty else { return makeEmptySnapshot() }
        let effectiveActiveID = activePaneID ?? self.activePaneID
        let effectiveStores = sourceStores ?? stores
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
