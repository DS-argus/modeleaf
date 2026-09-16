# Handoff: #68 Support password-protected PDFs

- Issue: https://github.com/DS-argus/modeleaf/issues/68
- Priority: P0
- Worktree: `.worktrees/password-protected-pdfs`
- Branch: `feat/password-protected-pdfs` (based on `origin/main`)

## Objective

Allow a user to open a locally stored password-protected PDF without weakening Modeleaf's read-only boundary. The password must exist only long enough to unlock the in-memory `PDFDocument`; never persist, log, or display it.

## Original behavior (before implementation)

`PDFReaderApp/Reader/PDFOpenService.swift` creates `PDFDocument(url:)`, then rejects `document.isLocked` as `PDFOpenError.lockedDocument`. Its message says password-protected PDFs are unsupported.

`PDFReaderApp/App/ApplicationController.swift` routes all open paths through `openDocument(at:target:)`. It inserts a successful `ReaderSession`, records the recent file, and presents `PDFOpenError.presentation` on failure. The native open panel and external/open-with URLs converge there.

`PDFReaderAppTests/PDFOpenServiceTests.swift` uses `PDFFixtureFactory.makeLockedPDF` and currently asserts rejection.

## Required behavior

1. A locked local PDF presents a native password-entry flow instead of an unsupported-document diagnostic.
2. A valid password unlocks and opens the document in the requested pane/tab.
3. A wrong password gives a clear error and lets the user retry.
4. Cancel leaves no session/tab and does not add the document to recent files.
5. Unlocked, malformed, unreadable, empty, and remote URL behavior stays unchanged.
6. Never persist, log, or include the password in diagnostics, telemetry, or recent-file state.
7. Preserve Modeleaf's read-only boundary: no PDF edits, annotations, exports, or file rewrites.

## Implementation boundaries

- Build on the existing PDFKit `PDFDocument` API; do not add a password cache or configuration setting.
- Keep password orchestration separate from ordinary file preflight/document validation so unit tests can cover valid, invalid, and cancel outcomes deterministically.
- Do not turn an invalid password into `malformedDocument` or silently open a locked document.
- Ensure focus returns to the reader after success or cancellation.
- Update user-facing error copy to describe invalid password rather than the old unsupported-feature message.

## Likely affected files

- `PDFReaderApp/Reader/PDFOpenService.swift`
- `PDFReaderApp/App/ApplicationController.swift`
- A focused native prompt/presenter under `PDFReaderApp/Window/` or `PDFReaderApp/Reader/`
- `PDFReaderAppTests/PDFOpenServiceTests.swift`
- Focused application/prompt tests as needed
- `Modeleaf.xcodeproj/project.pbxproj` only if a new source file requires registration

## Verification

Run from this worktree:

```sh
swift test
python3 Tools/validate_xcode_project.py
git diff --check
Tools/build_release_app.sh
```

Also manually verify, with a real locked fixture if practical:

- valid password opens one usable session;
- wrong password retains/re-presents the prompt with a clear error;
- cancel creates no tab and no recent-file entry;
- a normal PDF still opens from both the picker and external URL flow.

## Repository rules

Do not commit, push, create a PR, or merge without an explicit user request. Keep all feature changes in this worktree; do not modify the parent checkout.

## Work record — 2026-09-16 (Asia/Seoul)

### Implementation completed

- Added a native `NSAlert` with `NSSecureTextField`, explicit incorrect-password feedback, retry, and cancellation. The field and its editor are cleared after each prompt.
- Added injectable password orchestration to `PDFOpenService`, unlocking the existing in-memory `PDFDocument` before constructing a session. Passwords are neither cached nor included in diagnostics, metrics, or recent-file state.
- Routed picker, external URL, recent-file, and duplicate opens through the password flow. Cancellation creates no tab or recent-file entry; focus returns to the reader or empty-state Open control.
- Replaced unsupported-password error copy with password-required handling and added a cancellation metric outcome.
- Added service, metrics, native-prompt configuration, application routing, pane-target, focus, cancellation, duplication, and unchanged-source-byte coverage. Updated the read-only boundary assertion to permit in-memory unlocking while continuing to prohibit PDF writes and edits.
- Updated English and Korean feature documentation. Xcode uses synchronized source groups, so no project-file change was required.

### Verification completed

- `swift test`: 570 tests passed (153 core, 405 app, 12 CLI), with all three test-run completion summaries confirmed.
- `python3 Tools/validate_xcode_project.py`: passed.
- `git diff --check`: passed.
- `Tools/build_release_app.sh`: passed, including app/embedded-CLI signature verification and version consistency.
- Native modal accept/cancel and secure-field cleanup passed in a separate verification process. Running native application-modal loops inside the concurrent unit-test process interfered with suite completion; that runtime check was isolated rather than treating an early process exit as a passing suite.
- Real encrypted fixtures cover correct password, retry, cancellation, requested-pane insertion, and unchanged encrypted source bytes. Normal picker/external opens remain covered by regression tests.
- Independent bounded native-flow review reported no findings. Existing CLI compiler warnings and Xcode device/simulator environment warnings remain unrelated to this change.
- Generated `artifacts/manual-tests/password-test-B950A96D.pdf` for user testing and launched this worktree's Release app. The user subsequently approved merging. No claim is made that every manual checklist item was individually observed.
- Local logs and native verification harness are under ignored `artifacts/verification/pdfkit-fast-open/local/`; fixtures and build outputs are not committed.

### Integration authorization

The user explicitly requested merging into `main` and recording this work in the handoff, superseding the earlier no-commit/no-push restriction for this integration. Feature changes and this record are submitted together through a pull request; merge is gated on the repository's CI and review requirements. No release or tag was requested.
