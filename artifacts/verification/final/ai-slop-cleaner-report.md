# AI slop cleanup report

## Scope

The cleanup remained limited to the G011 review blockers and directly related regressions: documentation; action/config/theme contracts; AppKit dispatcher, prompt, diagnostic, search, tab, canvas, focus, and responder-loop code; and their Core, AppKit, and UI-test sources. No dependency or speculative abstraction was added.

## Behavior lock

- Before cleanup: 136 Swift Testing cases in 22 suites plus 1 XCTest passed.
- Final tree: 139 Swift Testing cases in 22 suites plus 1 XCTest passed in both normal and `-warnings-as-errors` runs.
- Focused post-cleaner regressions: 37 tests in 5 suites passed.
- Final key-view/theme regressions: 9 tests in 1 suite passed.
- Evidence: `ai-slop-cleaner-plan.md` and `post-cleaner/{swift-test,swift-test-warnings-as-errors,targeted-regressions,key-view-targeted}.log`.

## Fallback review

| Finding | Classification | Disposition |
|---|---|---|
| Invalid TOML activates complete built-ins while retaining all diagnostics | grounded required fail-safe | preserved and tested |
| UI-test source typecheck when Xcode cannot load | grounded host-toolchain fallback record | preserved, explicitly not an XCUITest substitute |
| AppKit color blending falls back to the inactive-tab color | grounded visual boundary fail-safe | preserved |
| `try? removeItem` in temporary test cleanup | grounded test-only cleanup | preserved |
| Generic PDF-open catch maps the error to a visible diagnostic | grounded boundary error presentation | preserved |
| Optional enumerator with `?? []` in the UI source audit | masking fallback capable of a vacuous pass | removed; enumeration and non-empty sources are required |
| Native PDFKit key-view selector fallback | could re-enter PDFKit's private responder chain | removed; traversal uses only the explicit app-owned loop |

No hidden skip, swallowed production error, executable config/plugin path, release-only override, or alternate command path remains.

## Cleanup passes completed

1. Removed the vacuous UI production-source enumeration fallback.
2. Simplified duplicate search-cancellation transitions and made cancellation naming truthful.
3. Removed unused prompt theme state and the production-only composition counter.
4. Discarded native marked composition before prompt-safe global/session transitions restore context and focus.
5. Routed tab pointer controls through stable `ActionID` dispatch only.
6. Propagated semantic canvas and focus tokens to the real `PDFView`, container, and prompt.
7. Added a deterministic cyclic key-view loop owned by the app; unbound Tab/Backtab can leave the PDF canvas without falling into PDFKit internals.
8. Reinforced regressions for composition, globals, late search callbacks, batching, tab topology, diagnostics, theme tokens, real canvas/focus colors, and responder traversal.

## Performance and clarity repairs

- Search matches accumulate and render once at completion rather than rerendering quadratically.
- Search next/previous recolors only the old and new active selection.
- Tab topology is cached so page, zoom, and search-status changes do not rebuild tab controls.
- Searchable-text presence is determined lazily once and short-circuits at the first embedded-text page after a zero-result search.
- Built-in palettes use four explicit complete `[ThemeToken: String]` maps; invalid internal colors fail loudly.

## Quality gates

- Dependency resolution: pass, exact `TOMLDecoder 0.4.5`.
- Debug, Release, and Release `-warnings-as-errors` SwiftPM builds: pass.
- Full tests: pass, 139 Swift Testing cases/22 suites plus 1 XCTest/0 failures, both normally and with compiler warnings treated as errors.
- Targeted tests: pass, 37 tests/5 suites plus final 9-test key-view/theme suite.
- Static compiler-warning audit: zero compiler warning lines; retained PDFKit/CoreGraphics runtime diagnostics are separately classified.
- Generated Xcode project validation and Info.plist lint: pass.
- UI-test source: 15 production workflows plus 1 scaffold method typecheck for macOS 14 arm64 with warnings-as-errors; E2E focus reads the public XCTest snapshot `.hasFocus` attribute; GUI execution remains unrun.
- App launch smoke: Debug and Release processes remained alive for the bounded two-second check.
- Visual gate: 24 state PNGs and four contact sheets regenerated and manually reviewed.
- Source/security/ABI/scope audits: all 16 source checks plus security, dependency, and 108-file source-manifest validation pass.

## Remaining risks

- Xcode 26.6 is incomplete on this host: `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/CoreSimulator` is absent, so `xcodebuild` exits before project loading. This is external to the repository; raw evidence is retained under `xcode/`.
- XCUITest GUI workflows and physical VoiceOver, non-U.S. keyboard-layout, trackpad, and hover checks were not run.
- PDFKit/CoreGraphics runtime diagnostics remain visible in raw test logs. They are not compiler warnings and did not fail either 139-test run.
