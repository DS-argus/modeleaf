import AppKit
import PDFReaderCore

struct PaneCoordinatorSnapshot {
    let layout: PaneLayout
    let panes: [PaneID: ReaderSessionStoreSnapshot]
    let activePaneID: PaneID?
    let activeContentView: NSView?
    let paneContentViews: [PaneID: NSView]
    let activeFocusView: NSView?
    let activeStatus: ReaderStatusSnapshot?
    let windowTitle: String
    let inputContext: InputContext

    func assertCardinality() {
        switch layout {
        case .empty:
            precondition(panes.isEmpty && activePaneID == nil && activeContentView == nil && activeFocusView == nil && activeStatus == nil)
        case let .single(id):
            precondition(panes.count == 1 && panes[id]?.isEmpty == false && activePaneID == id && activeContentView != nil && activeFocusView != nil && activeStatus != nil)
        case let .split(_, leadingOrTop, trailingOrBottom):
            precondition(
                panes.count == 2 && panes[leadingOrTop]?.isEmpty == false && panes[trailingOrBottom]?.isEmpty == false,
                "split cardinality violated: leading=\(leadingOrTop) trailing=\(trailingOrBottom) panes=\(panes.map { "\($0.key): \($0.value.tabs.count) tabs" }.sorted())"
            )
            precondition(activePaneID == leadingOrTop || activePaneID == trailingOrBottom, "split active pane \(String(describing: activePaneID)) is not a member pane")
            precondition(activeContentView != nil && activeFocusView != nil && activeStatus != nil, "split snapshot is missing active view/status fields")
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
        if initialStore.snapshot.isEmpty {
            bootstrapStore = initialStore
        } else {
            let id = PaneID()
            stores[id] = initialStore
            layout = .single(id)
            activePaneID = id
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
        let previousSuppression = suppressCallbacks
        suppressCallbacks = true
        var didMutate = false
        defer {
            suppressCallbacks = previousSuppression
            if didMutate { publish() }
        }

        switch target {
        case .createIfEmpty:
            switch layout {
            case .empty:
                let id = PaneID()
                let store = bootstrapStore ?? ReaderSessionStore()
                if store.onChange == nil {
                    store.registerChangeHandler { [weak self] _ in self?.storeDidChange() }
                }
                let wasBootstrapStore = bootstrapStore === store
                if wasBootstrapStore { bootstrapStore = nil }
                guard store.insert(session) else {
                    if wasBootstrapStore { bootstrapStore = store }
                    return false
                }
                stores[id] = store
                layout = .single(id)
                activePaneID = id
                didMutate = true
                return true
            case .single, .split:
                guard let store = activeStore, store.insert(session) else { return false }
                didMutate = true
                return true
            }
        case let .existing(id):
            guard let store = stores[id], !store.snapshot.isEmpty, store.insert(session) else { return false }
            activePaneID = id
            didMutate = true
            return true
        }
    }

    @discardableResult func activate(tab id: TabID) -> Bool { activeStore?.activate(id) ?? false }
    @discardableResult func activateTab(atOneBasedOrdinal ordinal: Int) -> Bool { activeStore?.activateTab(atOneBasedOrdinal: ordinal) ?? false }
    @discardableResult func activateNext() -> TabID? { activeStore?.activateNext() }
    @discardableResult func activatePrevious() -> TabID? { activeStore?.activatePrevious() }

    @discardableResult
    func activatePane(_ id: PaneID) -> Bool {
        guard stores[id] != nil, activePaneID != id else { return stores[id] != nil }
        activePaneID = id
        publish()
        return true
    }

    @discardableResult
    func split(direction: PaneOrientation) -> PaneID? {
        guard case let .single(originID) = layout,
              let source = activeSession as? any ReaderDuplicationSnapshotProviding,
              let candidate = duplicateSession?(source.duplicationSnapshot)
        else { return nil }

        let previousSuppression = suppressCallbacks
        suppressCallbacks = true
        defer { suppressCallbacks = previousSuppression }
        let destinationID = PaneID()
        let destination = ReaderSessionStore()
        destination.registerChangeHandler { [weak self] _ in self?.storeDidChange() }
        guard destination.insert(candidate) else {
            candidate.prepareForClose()
            duplicationCompletion?(candidate, false)
            return nil
        }
        stores[destinationID] = destination
        layout = .split(orientation: direction, leadingOrTop: originID, trailingOrBottom: destinationID)
        activePaneID = destinationID
        suppressCallbacks = previousSuppression
        publish()
        suppressCallbacks = true
        duplicationCompletion?(candidate, true)
        return destinationID
    }

    @discardableResult
    func focus(_ direction: PaneFocusDirection) -> Bool {
        guard case let .split(orientation, leadingOrTop, trailingOrBottom) = layout,
              let activePaneID
        else { return false }
        let target: PaneID?
        switch (orientation, activePaneID, direction) {
        case (.sideBySide, leadingOrTop, .right), (.sideBySide, trailingOrBottom, .left),
             (.stacked, leadingOrTop, .down), (.stacked, trailingOrBottom, .up):
            target = activePaneID == leadingOrTop ? trailingOrBottom : leadingOrTop
        default:
            target = nil
        }
        guard let target else { return false }
        self.activePaneID = target
        publish()
        return true
    }

    @discardableResult
    func unsplit(stage: ((PaneCoordinatorSnapshot) -> Bool)? = nil) -> Bool {
        guard case let .split(_, leadingOrTop, trailingOrBottom) = layout,
              let activePaneID,
              let removedID = [leadingOrTop, trailingOrBottom].first(where: { $0 != activePaneID }),
              let removedStore = stores[removedID]
        else { return false }
        let projected = makeSnapshot(layout: .single(activePaneID), activePaneID: activePaneID, stores: stores.filter { $0.key != removedID })
        guard (stage ?? closeStagingHandler ?? { _ in true })(projected) else { publish(); return false }
        let previousSuppression = suppressCallbacks
        suppressCallbacks = true
        defer { suppressCallbacks = previousSuppression }
        for tab in removedStore.snapshot.tabs {
            guard let token = removedStore.beginClose(tab.id), removedStore.commitClose(token) else {
                preconditionFailure("ReaderSessionStore cannot commit unsplit teardown")
            }
        }
        stores.removeValue(forKey: removedID)
        layout = .single(activePaneID)
        suppressCallbacks = previousSuppression
        publish()
        suppressCallbacks = true
        return true
    }

    @discardableResult
    func closeActiveTab(stage: ((PaneCoordinatorSnapshot) -> Bool)? = nil) -> Bool {
        guard let paneID = activePaneID,
              let store = stores[paneID],
              let id = store.snapshot.activeID,
              let token = store.beginClose(id)
        else { return false }
        let transition: PaneCloseTransition
        let projected: PaneCoordinatorSnapshot
        if token.projectedSelection != nil {
            transition = .tabSuccessor(pane: paneID, tab: token.projectedSelection!)
            projected = makeSnapshot()
        } else if case let .split(_, leadingOrTop, trailingOrBottom) = layout,
                  let survivor = [leadingOrTop, trailingOrBottom].first(where: { $0 != paneID }) {
            transition = .paneCollapse(survivor: survivor)
            projected = makeSnapshot(layout: .single(survivor), activePaneID: survivor, stores: stores.filter { $0.key != paneID })
        } else {
            transition = .windowEmpty
            projected = makeEmptySnapshot()
        }
        guard (stage ?? closeStagingHandler ?? { _ in true })(projected) else {
            store.rollbackClose(token)
            publish()
            return false
        }
        let previousSuppression = suppressCallbacks
        suppressCallbacks = true
        defer { suppressCallbacks = previousSuppression }
        guard store.commitClose(token) else {
            store.rollbackClose(token)
            publish()
            return false
        }
        switch transition {
        case .tabSuccessor: break
        case let .paneCollapse(survivor):
            stores.removeValue(forKey: paneID)
            layout = .single(survivor)
            activePaneID = survivor
        case .windowEmpty:
            stores.removeValue(forKey: paneID)
            layout = .empty
            activePaneID = nil
        }
        suppressCallbacks = previousSuppression
        publish()
        suppressCallbacks = true
        return true
    }

    private func storeDidChange() {
        if case .empty = layout, let bootstrapStore, !bootstrapStore.snapshot.isEmpty {
            let id = PaneID()
            stores[id] = bootstrapStore
            self.bootstrapStore = nil
            layout = .single(id)
            activePaneID = id
        }
        if !suppressCallbacks { publish() }
    }

    private func makeEmptySnapshot() -> PaneCoordinatorSnapshot {
        PaneCoordinatorSnapshot(layout: .empty, panes: [:], activePaneID: nil, activeContentView: nil, paneContentViews: [:], activeFocusView: nil, activeStatus: nil, windowTitle: "Modeleaf", inputContext: .navigation)
    }

    private func makeSnapshot(layout: PaneLayout? = nil, activePaneID: PaneID? = nil, stores sourceStores: [PaneID: ReaderSessionStore]? = nil) -> PaneCoordinatorSnapshot {
        let effectiveLayout = layout ?? self.layout
        let effectiveActivePaneID = activePaneID ?? self.activePaneID
        let effectiveStores = sourceStores ?? stores
        guard let effectiveActivePaneID, let activeStore = effectiveStores[effectiveActivePaneID], !activeStore.snapshot.isEmpty else { return makeEmptySnapshot() }
        let panes = Dictionary(uniqueKeysWithValues: effectiveStores.map { ($0.key, $0.value.snapshot) })
        let paneContentViews = Dictionary(uniqueKeysWithValues: effectiveStores.compactMap { id, store in store.activeSession.map { (id, $0.contentView) } })
        let active = activeStore.activeSession
        let result = PaneCoordinatorSnapshot(layout: effectiveLayout, panes: panes, activePaneID: effectiveActivePaneID, activeContentView: active?.contentView, paneContentViews: paneContentViews, activeFocusView: active?.focusView, activeStatus: active?.statusSnapshot, windowTitle: active.map { "\($0.title) — Modeleaf" } ?? "Modeleaf", inputContext: active?.preferredInputContext ?? .navigation)
        result.assertCardinality()
        return result
    }

    private func publish() { onSnapshot?(snapshot) }
}
