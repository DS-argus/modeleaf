import AppKit
import CoreGraphics
import PDFKit
import PDFReaderCore
import Testing
@testable import PDFReaderApp

@Suite("TOC widget")
@MainActor
struct TOCWidgetTests {
    @Test("headerless widget has a body-only empty state")
    func emptyOutlineShowsBodyOnlyEmptyState() throws {
        let widget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        widget.toggle(snapshot: .empty, onActivate: { _ in .preflightRejected })
        let empty = try #require(descendant(in: widget, identifier: "tocWidget.empty") as? NSTextField)
        #expect(!empty.isHidden)
        #expect(empty.stringValue == "No table of contents")
        #expect(descendant(in: widget, identifier: "tocDrawer.header") == nil)
        #expect(descendant(of: widget, as: NSOutlineView.self) == nil)
    }

    @Test("flat table uses 20 point rows and bounded compact preferred geometry")
    func flatTableUsesCompactGeometry() throws {
        let widget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let snapshot = makeSnapshot(count: 12)
        widget.toggle(snapshot: snapshot, onActivate: { _ in .noOp })
        let table = try #require(descendant(of: widget, as: NSTableView.self))
        #expect(table.rowHeight == 20)
        #expect(widget.intrinsicContentSize.width == 300)
        #expect(widget.intrinsicContentSize.height == 264)
        let firstID = snapshot.rows[0].id.accessibilityIdentifier
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        row.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        row.layoutSubtreeIfNeeded()
        let selector = try #require(descendant(in: row, identifier: "tocWidget.row.\(firstID).selector") as? NSTextField)
        let separator = try #require(descendant(in: row, identifier: "tocWidget.row.\(firstID).separator"))
        let title = try #require(descendant(in: row, identifier: "tocWidget.row.\(firstID).title") as? NSTextField)
        #expect(selector.alignment == .right)
        #expect(title.alignment == .left)
        #expect(separator.frame.width >= 1)
    }

    @Test("widget grows to content or at most half the pane")
    func widgetUsesHalfPaneMaximumHeight() throws {
        let root = ReaderRootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        root.layoutSubtreeIfNeeded()
        let paneID = PaneID()
        root.toggleTOCWidget(in: paneID, snapshot: makeSnapshot(count: 30), onActivate: { _ in .noOp })
        root.layoutSubtreeIfNeeded()
        let large = try #require(root.tocWidgetForTesting(paneID))
        let hostHeight = try #require(large.superview).bounds.height
        #expect(large.frame.height <= hostHeight * 0.5 + 0.5)
        #expect(abs((large.frame.height - large.footerHeight).truncatingRemainder(dividingBy: large.rowHeight)) < 0.5)

        root.closeTOCWidget(in: paneID)
        root.toggleTOCWidget(in: paneID, snapshot: makeSnapshot(count: 2), onActivate: { _ in .noOp })
        root.layoutSubtreeIfNeeded()
        #expect(abs(large.frame.height - (2 * large.rowHeight + large.footerHeight)) < 0.5)

        let compactRoot = ReaderRootView(frame: NSRect(x: 0, y: 0, width: 480, height: 186))
        compactRoot.layoutSubtreeIfNeeded()
        let compactPane = PaneID()
        compactRoot.toggleTOCWidget(in: compactPane, snapshot: makeSnapshot(count: 30), onActivate: { _ in .noOp })
        compactRoot.layoutSubtreeIfNeeded()
        let compact = try #require(compactRoot.tocWidgetForTesting(compactPane))
        #expect(abs((compact.frame.height - compact.footerHeight).truncatingRemainder(dividingBy: compact.rowHeight)) < 0.5)
        #expect(compact.frame.height <= (try #require(compact.superview)).bounds.height * 0.5 + 0.5)
    }

    @Test("TOC key handling never falls back to another pane")
    func keyHandlingIsStrictlyPaneLocal() throws {
        let root = ReaderRootView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let owner = PaneID()
        let activeWithoutTOC = PaneID()
        root.toggleTOCWidget(in: owner, snapshot: makeSnapshot(count: 1), onActivate: { _ in .noOp })
        let widget = try #require(root.tocWidgetForTesting(owner))
        #expect(!widget.isHidden)

        let escape = try #require(makeKeyEvent(characters: "", keyCode: 53))
        #expect(!root.handleTOCKey(in: activeWithoutTOC, event: escape))
        #expect(!widget.isHidden)
    }

    @Test("numeric accumulation is visible in the footer until commit")
    func numericBufferAppearsInFooterUntilCommit() throws {
        #expect(TOCWidgetView.digitCommitDelayMilliseconds == 400)
        let scheduler = ManualTOCDigitCommitScheduler()
        let widget = TOCWidgetView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            digitCommitScheduler: scheduler.schedule
        )
        let snapshot = makeSnapshot(count: 12)
        var activations: [ReaderOutlineRowID] = []
        widget.toggle(snapshot: snapshot, onActivate: { id in activations.append(id); return .noOp })
        let hint = try #require(descendant(in: widget, identifier: "tocWidget.hint") as? NSTextField)
        #expect(hint.stringValue == "J / K  Scroll    #  Jump    Esc / t  Close")

        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "1"))))
        #expect(hint.stringValue == "1  Jump    Esc / t  Close")
        #expect(activations.isEmpty)
        scheduler.advance(byMilliseconds: 399)
        #expect(activations.isEmpty)
        scheduler.advance(byMilliseconds: 1)

        #expect(activations == [try #require(snapshot.rows.first).id])
        #expect(hint.stringValue == "J / K  Scroll    #  Jump    Esc / t  Close")
    }

    @Test("multi-digit selector commits exactly one full selector and invalid input is silent")
    func numericSelectorCommitsAtomically() throws {
        let scheduler = ManualTOCDigitCommitScheduler()
        let widget = TOCWidgetView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            digitCommitScheduler: scheduler.schedule
        )
        let snapshot = makeSnapshot(count: 12)
        var activations: [ReaderOutlineRowID] = []
        widget.toggle(snapshot: snapshot, onActivate: { id in activations.append(id); return .verifiedLanding })
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "1"))))
        scheduler.advance(byMilliseconds: 250)
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "2"))))
        scheduler.advance(byMilliseconds: 399)
        #expect(activations.isEmpty)
        scheduler.advance(byMilliseconds: 1)
        #expect(activations == [snapshot.rows[11].id])

        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "9"))))
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "9"))))
        scheduler.advance(byMilliseconds: TOCWidgetView.digitCommitDelayMilliseconds)
        #expect(activations.count == 1)
    }

    @Test("escape, deactivation, and dismissal cancel pending numeric work")
    func cancellationsAreSilent() throws {
        let scheduler = ManualTOCDigitCommitScheduler()
        let widget = TOCWidgetView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            digitCommitScheduler: scheduler.schedule
        )
        let snapshot = makeSnapshot(count: 1)
        var calls = 0
        widget.toggle(snapshot: snapshot, onActivate: { _ in calls += 1; return .noOp })
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "1"))))
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "", keyCode: 53))))
        #expect(widget.isHidden)
        widget.setPaneActive(false)
        widget.dismiss()
        scheduler.advance(byMilliseconds: TOCWidgetView.digitCommitDelayMilliseconds)
        #expect(calls == 0)
    }

    @Test("reentrant activation renders prior tracking then commits the exact row")
    func reentrantActivationCommitsExactRow() throws {
        let scheduler = ManualTOCDigitCommitScheduler()
        let widget = TOCWidgetView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            digitCommitScheduler: scheduler.schedule
        )
        let snapshot = makeSnapshot(count: 2)
        widget.toggle(snapshot: snapshot, onActivate: { _ in
            widget.render(snapshot)
            return .verifiedLanding
        })
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "2"))))
        scheduler.advance(byMilliseconds: TOCWidgetView.digitCommitDelayMilliseconds)
        let selected = descendant(of: widget, as: NSTableView.self)?.view(atColumn: 0, row: 1, makeIfNecessary: true)
        #expect(selected?.accessibilityValue() as? String == "Selected")
    }

    @Test("failed activation preserves the prior exact row")
    func failedActivationRollsBackToPriorExactRow() throws {
        let scheduler = ManualTOCDigitCommitScheduler()
        let widget = TOCWidgetView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200),
            digitCommitScheduler: scheduler.schedule
        )
        let snapshot = makeSnapshot(count: 2)
        var outcome: NavigationTransactionOutcome = .verifiedLanding
        widget.toggle(snapshot: snapshot, onActivate: { _ in outcome })
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "1"))))
        scheduler.advance(byMilliseconds: TOCWidgetView.digitCommitDelayMilliseconds)
        outcome = .preflightRejected
        #expect(widget.handleKey(try #require(makeKeyEvent(characters: "2"))))
        scheduler.advance(byMilliseconds: TOCWidgetView.digitCommitDelayMilliseconds)
        let table = try #require(descendant(of: widget, as: NSTableView.self))
        #expect((table.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityValue() as? String) == "Selected")
    }

    @Test("J and K clamp clip movement to exactly one row")
    func rowScrollingIsBoundedToTwentyPoints() throws {
        let widget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        widget.toggle(snapshot: makeSnapshot(count: 12), onActivate: { _ in .noOp })
        let scroll = try #require(descendant(of: widget, as: NSScrollView.self))
        let start = scroll.contentView.bounds.origin.y
        widget.scrollByRows(1)
        #expect(abs(scroll.contentView.bounds.origin.y - start - 20) < 0.5)
        widget.scrollByRows(-1)
        #expect(abs(scroll.contentView.bounds.origin.y - start) < 0.5)
        widget.scrollByRows(-1)
        #expect(scroll.contentView.bounds.origin.y == 0)
    }

    @Test("stale outline snapshots cannot rewind tracking selection")
    func staleSnapshotDoesNotRewindTracking() throws {
        let widget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let base = makeSnapshot(count: 2)
        let current = ReaderOutlineSnapshot(rows: base.rows, currentRowID: base.rows[1].id, successfulUserMovementRevision: 2)
        widget.toggle(snapshot: current, onActivate: { _ in .noOp })
        let stale = ReaderOutlineSnapshot(rows: base.rows, currentRowID: base.rows[0].id, successfulUserMovementRevision: 1)
        widget.render(stale)
        let table = try #require(descendant(of: widget, as: NSTableView.self))
        #expect((table.view(atColumn: 0, row: 1, makeIfNecessary: true)?.accessibilityValue() as? String) == "Selected")
        #expect((table.view(atColumn: 0, row: 0, makeIfNecessary: true)?.accessibilityValue() as? String) != "Selected")
    }

    @Test("footer reflects effective rebound scroll keys")
    func footerUsesEffectiveBindings() throws {
        let widget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        widget.setKeyHints(scrollDown: "⌃J", scrollUp: "⌃K", toggle: "⌃T")
        let hint = try #require(descendant(in: widget, identifier: "tocWidget.hint") as? NSTextField)
        #expect(hint.stringValue == "⌃J / ⌃K  Scroll    #  Jump    Esc / ⌃T  Close")
        widget.setKeyHints(scrollDown: "", scrollUp: "", toggle: "")
        #expect(hint.stringValue == "#  Jump    Esc  Close")
        #expect(hint.alignment == .left)
        #expect(hint.attributedStringValue.length > 0)
    }

    @Test("Dracula and Solarized Dark keep selectors and second-level titles legible")
    func darkThemeSecondaryRowsRemainLegible() throws {
        let snapshot = makeNestedSnapshot()
        for themeID in [ThemeID.dracula, .solarizedDark] {
            let theme = AppKitTheme(themeID: themeID)
            let widget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            widget.apply(theme: theme)
            widget.toggle(snapshot: snapshot, onActivate: { _ in .noOp })
            let table = try #require(descendant(of: widget, as: NSTableView.self))
            let item = snapshot.rows[1]
            let row = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
            let selector = try #require(descendant(in: row, identifier: "tocWidget.row.\(item.id.accessibilityIdentifier).selector") as? NSTextField)
            let title = try #require(descendant(in: row, identifier: "tocWidget.row.\(item.id.accessibilityIdentifier).title") as? NSTextField)
            let selectorContrast = contrastRatio(try #require(selector.textColor), over: theme[.activeTab])
            let titleContrast = contrastRatio(try #require(title.textColor), over: theme[.activeTab])
            #expect(selectorContrast >= 4.0, "\(themeID) selector contrast was \(selectorContrast)")
            #expect(titleContrast >= 4.0, "\(themeID) second-level contrast was \(titleContrast)")
        }
    }

    @Test("enabled rows expose AXPress while disabled rows reject it")
    func rowsImplementAccessibilityPress() throws {
        var activations = 0
        let enabledWidget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        enabledWidget.toggle(snapshot: makeSnapshot(count: 1), onActivate: { _ in activations += 1; return .noOp })
        let enabledTable = try #require(descendant(of: enabledWidget, as: NSTableView.self))
        let enabledRow = try #require(enabledTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(enabledRow.accessibilityPerformPress())
        #expect(activations == 1)
        #expect(enabledRow.acceptsFirstMouse(for: nil))

        let disabledWidget = TOCWidgetView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        disabledWidget.toggle(snapshot: makeInvalidSnapshot(), onActivate: { _ in activations += 1; return .noOp })
        let disabledTable = try #require(descendant(of: disabledWidget, as: NSTableView.self))
        let disabledRow = try #require(disabledTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect(!disabledRow.accessibilityPerformPress())
        #expect(!disabledRow.acceptsFirstMouse(for: nil))
        #expect(activations == 1)
    }

    @Test("all themes render a non-focus widget")
    func allThemesApplyWithoutChangingFocusBehavior() {
        for themeID in ThemeID.allCases {
            let widget = TOCWidgetView()
            widget.apply(theme: AppKitTheme(themeID: themeID))
            #expect(!widget.acceptsFirstResponder)
        }
        #expect(ThemeID.allCases.count == 7)
    }

    private func makeInvalidSnapshot() -> ReaderOutlineSnapshot {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let root = PDFOutline()
        let item = PDFOutline()
        item.label = "Unavailable"
        root.insertChild(item, at: 0)
        document.outlineRoot = root
        return ReaderOutline(document: document) { _ in nil }
            .snapshot(viewportAnchor: nil, successfulUserMovementRevision: 0)
    }

    private func makeNestedSnapshot() -> ReaderOutlineSnapshot {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let root = PDFOutline()
        let parent = PDFOutline()
        parent.label = "Chapter"
        parent.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: 700))
        let child = PDFOutline()
        child.label = "Section"
        child.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: 600))
        parent.insertChild(child, at: 0)
        let sibling = PDFOutline()
        sibling.label = "Appendix"
        sibling.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: 500))
        root.insertChild(parent, at: 0)
        root.insertChild(sibling, at: 1)
        document.outlineRoot = root
        return ReaderOutline(document: document) { destination in
            NavigationSnapshot(pageIndex: 0, pageSpacePoint: destination.point)
        }.snapshot(viewportAnchor: nil, successfulUserMovementRevision: 0)
    }

    private func contrastRatio(_ foreground: NSColor, over background: NSColor) -> CGFloat {
        let foreground = foreground.usingColorSpace(.sRGB) ?? foreground
        let background = background.usingColorSpace(.sRGB) ?? background
        let alpha = foreground.alphaComponent
        let red = foreground.redComponent * alpha + background.redComponent * (1 - alpha)
        let green = foreground.greenComponent * alpha + background.greenComponent * (1 - alpha)
        let blue = foreground.blueComponent * alpha + background.blueComponent * (1 - alpha)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let foregroundLuminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let backgroundLuminance = 0.2126 * linear(background.redComponent) + 0.7152 * linear(background.greenComponent) + 0.0722 * linear(background.blueComponent)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05) / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }

    private func makeSnapshot(count: Int) -> ReaderOutlineSnapshot {
        let document = PDFDocument()
        let page = PDFPage()
        document.insert(page, at: 0)
        let root = PDFOutline()
        for index in 0..<count {
            let item = PDFOutline()
            item.label = "Section \(index + 1)"
            item.destination = PDFDestination(page: page, at: CGPoint(x: 20, y: 700 - CGFloat(index)))
            root.insertChild(item, at: index)
        }
        document.outlineRoot = root
        return ReaderOutline(document: document) { destination in
            NavigationSnapshot(pageIndex: 0, pageSpacePoint: destination.point)
        }.snapshot(viewportAnchor: nil, successfulUserMovementRevision: 0)
    }

    private func descendant(in view: NSView, identifier: String) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews { if let match = descendant(in: child, identifier: identifier) { return match } }
        return nil
    }

    private func descendant<View: NSView>(of view: NSView, as type: View.Type) -> View? {
        if let result = view as? View { return result }
        for child in view.subviews { if let result = descendant(of: child, as: type) { return result } }
        return nil
    }
}

@MainActor
private final class ManualTOCDigitCommitScheduler {
    private struct ScheduledItem {
        let deadlineMilliseconds: Int
        let item: DispatchWorkItem
    }

    private var nowMilliseconds = 0
    private var scheduled: [ScheduledItem] = []

    func schedule(afterMilliseconds delay: Int, _ item: DispatchWorkItem) {
        scheduled.append(ScheduledItem(deadlineMilliseconds: nowMilliseconds + delay, item: item))
    }

    func advance(byMilliseconds interval: Int) {
        precondition(interval >= 0)
        let target = nowMilliseconds + interval
        while let nextIndex = scheduled.indices
            .filter({ scheduled[$0].deadlineMilliseconds <= target })
            .min(by: { scheduled[$0].deadlineMilliseconds < scheduled[$1].deadlineMilliseconds }) {
            let next = scheduled.remove(at: nextIndex)
            nowMilliseconds = next.deadlineMilliseconds
            next.item.perform()
        }
        nowMilliseconds = target
    }
}
