# Architecture invariant audit

## Sources of truth

- `.omx/ultragoal/brief.md`
- `.omx/ultragoal/goals.json` (including accepted Sioyek-reference steering and G011 review-blocker story)
- `.omx/plans/implementation-plan-macos-vim-pdf-reader.md`
- `.omx/plans/prd-macos-vim-pdf-reader.md`
- `.omx/plans/test-spec-macos-vim-pdf-reader.md`
- `.omx/specs/deep-interview-macos-vim-pdf-reader.md`
- `README.md` and `CONFIG.md`
- `docs/README.md` and `docs/CONFIG.md` (public Korean documentation)

Final status: implementation, automated tests, static audits, source integrity, deterministic visual evidence, and distinct independent reviews pass for all invariants. Review artifacts: `review/code-reviewer.md` (`Recommendation: APPROVE`) and `review/architect.md` (`Architectural Status: CLEAR`).

## INV-01 — Native macOS edge with a pure Foundation core

- **Contract:** macOS 14+, Swift 6, AppKit/PDFKit at the platform edge; action/key/config/tab/theme state remains Foundation-only.
- **Implementation evidence:** `Package.swift`; `PDFReaderCore/`; `PDFReaderApp/`; generated six-target `PDFReader.xcodeproj`.
- **Test/audit evidence:** Debug and Release builds pass; `AUD-CORE-01` proves all 28 Core Swift files have no non-Foundation import; project validation proves deployment target 14.0, Swift 6, complete concurrency, and the intended target graph.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-02 — Read-only PDF containment and source immutability

- **Contract:** no PDF/page/annotation/form mutation, save/write/export, or print capability; allowed viewing operations never change the source file.
- **Implementation evidence:** `PDFCapabilityPolicy.swift`, `ReaderPDFView.swift`, `ReaderSession.swift`; Viewer-only `Info.plist`.
- **Test/audit evidence:** read-only capability, source-hash, form/annotation immutability, and teardown regressions pass; `AUD-RO-01` finds no production mutation/export/print operation and `AUD-INFO-01` proves `CFBundleTypeRole=Viewer`.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-03 — Deliberately small, stable viewer action vocabulary

- **Contract:** exactly 27 viewer-first actions; Sioyek informs configurable sequence/navigation ideas only. Marks, bookmarks, annotations, portals, smart jumps, command palette, scripts, plugins, macros, OCR, print/export, and persistence are outside v1.
- **Implementation evidence:** `ActionID.swift`, `ActionRegistry.swift`, `ActionSurfaceRegistry.swift`, and the explicit v1 boundary in `README.md` / `docs/README.md`.
- **Test/audit evidence:** registry/default/scope regressions pass; `AUD-CMD-01` records the exact 27 raw IDs and zero advanced-surface IDs.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-04 — One app-owned command path

- **Contract:** keyboard, menu, prompt buttons, empty-state button, and tab pointer controls converge on stable `ActionID` dispatch rather than parallel runtime mutations.
- **Implementation evidence:** `ActionDispatcher.swift`, `ApplicationController.swift`, `ValidatedMenuBuilder.swift`, `MainWindowController.swift`, `ReaderInputRouter.swift`.
- **Test/audit evidence:** dispatcher/menu/router/controller regressions pass; `AUD-CMD-02` proves tab selection/close compose only `.tabNext`, `.tabPrevious`, and `.documentClose`; `AUD-MENU-01` finds no hidden fixed shortcut.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-05 — First-class isolated tab sessions with one lifetime owner

- **Contract:** each tab owns one document identity, one reader-view path, and isolated search/view state; `ReaderSessionStore` alone owns lifetime and ordered teardown.
- **Implementation evidence:** `ReaderSessionStore.swift`, `ReaderSession.swift`, `PDFViewController.swift`, `TabStore.swift`.
- **Test/audit evidence:** session/tab/two-tab isolation and tab-topology caching regressions pass; `AUD-SESSION-01` proves one document propagation path, one `ReaderPDFView` construction path, one `[TabID: any ReaderSessionPresenting]` store, and lazy short-circuit searchable-text detection.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-06 — Strict, declarative, atomic TOML configuration

- **Contract:** bounded local TOML, recursive leaf allowlist, sparse typed overlay onto complete defaults, whole-config validation, atomic activation, and complete-default fallback on any error. Config cannot execute code; diagnostics aggregate.
- **Implementation evidence:** config source/decoder/service, Core config models/validator, and `CONFIG.md`.
- **Test/audit evidence:** config regressions pass; `AUD-CONFIG-01/02` prove no execution hook and complete summary/detail/tooltip/accessibility diagnostics; the sole exact external pin is TOMLDecoder 0.4.5.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-07 — Deterministic Vim sequence ownership with native prompt/IME precedence

- **Contract:** four input contexts, configurable multi-key prefixes, `g` plus digits, epoch-safe timeouts, and deterministic invalidation. Prompt text, dead keys, and IME composition stay native except validated lifecycle/global bindings; globals remain remappable.
- **Implementation evidence:** Core grammar/trie/engine, `ReaderInputRouter.swift`, `AppKitKeyEventAdapter.swift`, `PromptOverlayView.swift`, and dispatcher prompt lifecycle.
- **Test/audit evidence:** key engine/grammar/adapter/router/composition regressions pass; `AUD-INPUT-02` proves marked composition is discarded before prompt-safe global/session effects and focus restoration; E2E13/14 sources cover Unicode/dead-key and remapped safe-global paths.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-08 — Committed embedded-text search only

- **Contract:** no OCR or incremental search; per-session serialized `idle/running/cancelling(pendingLatest)` coordination; stale callbacks cannot mutate state; traversal wraps; highlights clear on cancel/close; no-match and no-searchable-text are distinct.
- **Implementation evidence:** `ReaderSearchCoordinator.swift`, `ReaderSession.swift`, and `PDFViewController.swift`.
- **Test/audit evidence:** late callback, two-tab isolation, 300-result batching, replacement deferral, image-only/empty, no-match, and teardown regressions pass. Rendering batches once and traversal recolors only old/new active selections.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-09 — Four semantic dark themes without recoloring PDF pixels

- **Contract:** exactly four dark themes with 12 semantic chrome tokens, including distinct all-result, active-result, and focus tokens; PDF paper/content remains unchanged.
- **Implementation evidence:** `Theme.swift`, `BuiltInThemes.swift`, `AppKitTheme.swift`, `ApplicationController.openDocument`, `ReaderSession.applyTheme`, `PDFViewController`, `ReaderPDFView`, and `PromptOverlayView`.
- **Test/audit evidence:** `AUD-THEME-01` proves four explicit complete palettes and end-to-end production consumption with no fixed gray canvas; the real-surface regression proves `#123456` reaches the actual PDF canvas and `#FEDCBA` reaches reader/prompt focus borders; 24 state PNGs/four sheets pass visual review with neutral `#F7F7F5` paper.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-10 — Viewer-first v1 scope remains closed

- **Contract:** no bookmarks, annotations/highlights, marks, portals, research workflow, OCR, scripts/plugins/macros, print/export/save, persistence, sidebar/thumbnails, cloud/collaboration, or distribution work.
- **Implementation evidence:** the explicit v1 boundary in `README.md` / `docs/README.md`, exact action/capability registries, compact shell, and Viewer-only bundle declaration.
- **Test/audit evidence:** scope/capability and E2E11/15 source regressions pass; persistence, security, ABI, and Info.plist audits find no persistence, execution/plugin/network surface, public executable API, or exported type.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## INV-11 — Polished, accessible, canvas-first native UI

- **Contract:** compact native tabs, quiet status/prompt chrome, clear hover/focus/active states, aggregate diagnostics, and accessible identifiers/roles/labels/values; no permanent toolbar/sidebar.
- **Implementation evidence:** shell views and `WindowVisualMetrics.swift`; `MainWindowController` disables automatic loop calculation and installs a deterministic cyclic app-owned loop spanning the active reader, visible prompt controls, and ordered tab select/close controls; `ReaderPDFView` traverses only explicit unbound Tab/Backtab targets.
- **Test/audit evidence:** accessible-surface/tab-identity regressions and the real-window responder regression pass; E2E10 sends Tab/Shift-Tab and reads actual canvas/prompt focus through the public XCTest snapshot `.hasFocus` attribute; `AUD-ACCESS-01` records the app-owned loop; 15 workflows plus one scaffold typecheck; deterministic visual review passes. Physical checks remain unrun.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved for automated/visual scope; declared manual hardware gaps remain separate release validation.

## INV-12 — Production contains no runtime test/automation override path

- **Contract:** tests may isolate OS-owned home-directory variables, but production may not expose fixture, config, launch, environment, or built-app automation overrides.
- **Implementation evidence:** production config/PDF paths use real runtime boundaries; no conditional debug/test branch or built-app automation entry exists.
- **Test/audit evidence:** E2E12 requires successful enumeration and a non-empty production source set; `AUD-INPUT-01` finds zero prohibited override/conditional-compilation hits. Three internal `@testable` seams (`inputContextForTesting`, `routeKeyEventForTesting`, `fireTimeoutForTesting`) are explicitly disclosed: they have no config/launch/environment branch and are not reachable through the built application. `AUD-UI-01` proves the source audit is non-vacuous.
- **Review evidence:** independent code-reviewer `APPROVE` and architect `CLEAR`; see `review/code-reviewer.md` and `review/architect.md`.
- **Status:** proved.

## Current gate disposition

- Implementation evidence: **PASS**
- Post-cleaner automated verification: **PASS — 139 Swift Testing cases/22 suites + 1 XCTest; strict rerun also passes**
- Targeted regressions: **PASS — 37/5 plus final 9/1**
- Static/security/scope/ABI/dependency/source-manifest audits: **PASS**
- Deterministic visual review: **PASS**
- Xcode GUI/XCUITest execution: **NOT RUN — external host installation failure before project load; not represented as pass**
- Physical VoiceOver/non-U.S.-layout/trackpad checks: **NOT RUN**
- Independent code-reviewer: **APPROVE**
- Independent architect: **CLEAR**

`architectureInvariantGate.status`: **PASSED**. All 12 required invariants are proved and both distinct independent reviewers are clean.
