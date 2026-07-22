# Manual visual review

- Date: 2026-07-22
- Reviewer: primary implementation agent
- Evidence: `visual/*-contact-sheet.png`, `visual/*-{empty,single-tab,multi-tab,prompt,search,error}.png`, and `visual/SHA256SUMS`
- Rendering: 24 full-state Retina PNGs at 2080×1520 plus four labeled 1560×820 contact sheets
- Method: inspected all four contact sheets at original detail after final source verification; document states use the same semantic canvas/focus/search token inputs exercised by the real-surface regressions

## Theme verdicts

| Theme | Canvas | Verdict | Notes |
|---|---:|---|---|
| Catppuccin Mocha | `#1E1E2E` | pass | Blue focus/accent, active tab, prompt, status, and pink error remain distinct without competing with the page. |
| Tokyo Night | `#1A1B26` | pass | Cool blue chrome is coherent; tab hierarchy and prompt focus remain clear. |
| Gruvbox Dark | `#282828` | pass | Warm foreground and muted teal accent remain legible against neutral dark chrome. |
| Nord | `#2E3440` | pass | Slate surfaces and cyan accent preserve tab, prompt, status, and error hierarchy. |

## State verdicts

| State | Verdict | Observation |
|---|---|---|
| empty | pass | Centered open affordance is concise; there is no permanent toolbar or sidebar. |
| single tab | pass | One compact active tab, neutral PDF paper, and quiet status line leave the canvas dominant. |
| multiple tabs | pass | Three tabs show clear selected/inactive treatment and non-overlapping close controls. |
| page prompt | pass | The bottom overlay is transient, aligned, and outlined with each theme's semantic focus token. |
| search results | pass | SEARCH context is visible; all-result and active-result highlight colors are distinguishable. |
| error | pass | The diagnostic uses the theme error token; the compact line truncates safely while full detail remains in tooltip/accessibility state. |

## Cross-theme invariants

- No tab, prompt, status, or page content overlaps or clips in the inspected layouts.
- The four surrounding canvas colors are visibly distinct and match their semantic `background` tokens.
- PDF paper remains neutral `#F7F7F5` in every document state and theme; page pixels are not theme-recolored.
- App chrome stays subordinate to the PDF canvas, and prompt/error treatments remain transient.
- Active/inactive tabs, all-result/active-result search colors, and focus indicators remain independently distinguishable.
- Real-surface regression evidence separately proves that `#123456` reaches the actual PDF canvas and `#FEDCBA` reaches the actual reader/prompt focus borders.

## Manual activities not represented as passed

- VoiceOver end-to-end operation: not run; automated AppKit roles, labels, values, and UI-test source coverage are separate evidence.
- Physical non-U.S. keyboard-layout smoke test: not run; Unicode, dead-key/IME, and AppKit adapter tests are separate evidence.
- Trackpad/hover interaction on live hardware: not run; pointer containment and hover implementation are covered by source and integration tests.
- XCUITest GUI execution: not run because the host Xcode installation fails before project load.

These gaps remain explicit and are not converted into passes by deterministic rendering or source typechecking.
