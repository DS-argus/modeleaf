# G011 AI slop cleaner plan

## Scope

This pass is restricted to the G011 review-blocker edits:

- `README.md`, `CONFIG.md`, and the public documentation under `docs/`;
- action/config/theme contracts changed for tab surfaces and 12 semantic tokens;
- AppKit dispatcher, diagnostics, search, theme, prompt, tab, and status presentation files;
- the directly corresponding core, AppKit, and 15-workflow UI tests.

Generated Xcode content, dependency/build outputs, `.omx` state, and unrelated greenfield files are not cleanup edit targets.

## Behavior lock

- Targeted action, search, session, config-diagnostic, theme, and shell suites passed before cleanup.
- Full pre-cleaner `swift test` passed: 136 Swift Testing cases in 22 suites plus 1 XCTest.
- Generated-project validation passed.
- All 15 `PDFReaderUITests` workflows typechecked against the macOS SDK.

## Fallback-like inventory and classification

1. Invalid-config complete-default activation is a **grounded fail-safe** required by the product contract. It preserves aggregate diagnostics and has error-plus-warning and warning-only tests.
2. The documented UI-test source typecheck is a **grounded external-toolchain fallback record**. It explicitly does not replace an executed `.xcresult`, and raw Xcode failure evidence is retained.
3. AppKit color blending falling back to the inactive-tab color is a **grounded visual fail-safe** at an external color-space boundary; it cannot widen capability or hide user data loss.
4. `try? removeItem` appears only in temporary test-fixture cleanup and is a **grounded test-cleanup fail-safe**; production behavior and assertions do not depend on it.
5. Generic PDF-open errors are mapped to visible diagnostics rather than swallowed, so the boundary catch is **grounded error presentation**.
6. The UI source-scope audit used `enumerator?.allObjects as? [URL] ?? []`. This is **masking fallback slop** because an enumeration failure could make the forbidden-surface test pass vacuously. Replace it with an explicit required enumerator and non-empty source assertion.

No quick hacks, workaround branches, hidden skips, executable plugin/script paths, or swallowed production failures were found. No nested ralplan escalation is needed.

## Ordered cleanup passes

1. **Fallback gate:** remove the vacuous UI source-audit fallback.
2. **Boundary repair:** make every session-change prompt dismissal explicitly discard marked composition, including pointer-driven tab changes.
3. **Dead code:** confirm no debug markers, stale cancellation names, hidden shortcuts, or persistence calls remain.
4. **Duplication/performance:** retain the explicit 15 workflow methods, but keep search-result rendering batched and tab topology cached so status changes do not rebuild tab controls.
5. **Naming/error handling:** preserve truthful `requestCancellation` / `searchCancellationRequested` terminology and aggregate diagnostic detail.
6. **Test reinforcement:** add the narrow session-change composition regression and rerun targeted suites after each edit.

The pass adds no dependency or speculative abstraction.
