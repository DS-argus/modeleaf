# Step 0 risk-qualification evidence

Date: 2026-07-22 (Asia/Seoul)  
Toolchain: Xcode 26.6 (17F113), Swift 6.3.3  
Deployment probe target: macOS 14+  
Leader sign-off: **PASS — interfaces frozen for production implementation**

## Gate result

The executable `step0-probe` and Swift Testing suite prove all six required seams:

1. AppKit window/responder routing works for an empty canvas, `PDFView`, prompt focus, restoration, and an explicit key-view loop without a global event monitor.
2. Menu equivalents derive from validated bindings and disappear for contextual, unsafe, ambiguous, multi-key, or unbound cases while clickable dispatcher actions remain.
3. Native literal/dead-key/marked-text input remains on `NSTextView`; safe Command globals discard composition once; semantic page digits replay once; stale prefix epochs cannot dispatch.
4. The read-only `PDFView` boundary preserves selection/copy while suppressing form/annotation/link/history/print/context-menu behavior and leaving fixture state unchanged.
5. PDFKit cancellation emits an end boundary before replacement. A replacement must be scheduled after that callback returns; synchronous reentrant begin is not a safe contract.
6. Exact TOMLDecoder 0.4.5 supports bounded parsing, recursive table conversion, sparse decode, line diagnostics, and an adapter-owned duplicate/conflict layer.

## Commands

```sh
swift package resolve
swift test
swift run step0-probe --output artifacts/verification/step0/report.json
swift build -c release
```

## Retained artifacts

- `report.json`: machine-readable probe assertions
- `probe-run.log`: executable output
- `swift-test.log`: focused unit-test output
- `action-registry.snapshot.json`: frozen v1 action/context boundary
- `input-contexts.snapshot.json`: frozen context/prompt/menu contract
- `config-schema.snapshot.json`: frozen config activation boundary
- `session-interface.snapshot.txt`: frozen session/search/teardown boundary
- `sha256.txt`: hashes of this evidence and the probe implementation

These are feasibility assertions, not substitutes for the production `U-*`, `I-*`, and `E2E-*` suites in `.omx/plans/test-spec-macos-vim-pdf-reader.md`.
