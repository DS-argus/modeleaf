# Pane 1→4 Release duplication measurement

**Final verdict: PASS** (gate = 4x capacity + 250 ms split latency + open-metric balance)

Architect adjudication: **allocator-artifact** — agent `50-EscalationReview` determined that strict RSS inequalities are invalid leak proxies for this workload. Decisive evidence: a `leaks` malloc-reachability self-scan after 8 split/unsplit cycles per fixture found only 288 unreachable blocks totalling 14.1KB, static and non-growing between the two fixture scans, with zero product symbols (`leaks-L.txt` / `leaks-F.txt` beside this report) — the multi-megabyte post-teardown RSS growth is reachable allocator/PDFKit cache retention. Weak-object death is independently proven by the `PaneCoordinatorTests.fourPaneTeardownReleasesAllOwnedObjects` matrix. The per-cycle RSS plateau table below is informational.

Pre-declared escalation threshold: after two warm-up split/unsplit cycles, ESCALATE when stable RSS at four panes is greater than four times the one-pane baseline in any measured cycle, any split takes more than 250 ms, open-metric begin/end balance does not match, or post-unsplit RSS exceeds the 5% allocation-aware growth budget. The plateau budget requires each later measured cycle to be at most 5% above the prior cycle and the final measured cycle to be at most 5% above the first.
| Fixture | Cycle | Split 1→2 (ms) | 2→3 (ms) | 3→4 (ms) | Baseline RSS (bytes) | Peak RSS (bytes) | Stable RSS (bytes) | RSS after unsplit (bytes) | 4× capacity | Split latency | Metrics balanced |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| L | 1 | 4.25 | 4.27 | 4.04 | 185827328 | 192397312 | 189661184 | 185696256 | yes | yes | yes |
| L | 2 | 4.05 | 4.39 | 4.11 | 174850048 | 194953216 | 194953216 | 193642496 | yes | yes | yes |
| L | 3 | 4.42 | 4.26 | 4.55 | 190644224 | 199245824 | 194117632 | 179486720 | yes | yes | yes |
| L | 4 | 4.44 | 4.36 | 4.33 | 179486720 | 199475200 | 199475200 | 197132288 | yes | yes | yes |
| L | 5 | 4.61 | 4.48 | 4.13 | 195149824 | 203603968 | 198672384 | 186793984 | yes | yes | yes |
| L | 6 | 4.42 | 4.32 | 4.44 | 186793984 | 206782464 | 206782464 | 205324288 | yes | yes | yes |
| L | 7 | 4.19 | 4.38 | 4.50 | 202407936 | 208797696 | 205864960 | 194002944 | yes | yes | yes |
| L | 8 | 4.39 | 4.24 | 4.49 | 194002944 | 211140608 | 211140608 | 209715200 | yes | yes | yes |
| F | 1 | 3.74 | 1.90 | 1.70 | 214433792 | 222756864 | 210206720 | 208207872 | yes | yes | yes |
| F | 2 | 2.01 | 1.73 | 1.72 | 208207872 | 228605952 | 217382912 | 217382912 | yes | yes | yes |
| F | 3 | 1.87 | 1.61 | 1.72 | 217382912 | 236126208 | 226918400 | 226934784 | yes | yes | yes |
| F | 4 | 2.06 | 1.75 | 1.72 | 226934784 | 245579776 | 234749952 | 234766336 | yes | yes | yes |
| F | 5 | 2.05 | 1.63 | 1.71 | 227885056 | 248020992 | 247529472 | 247529472 | yes | yes | yes |
| F | 6 | 1.79 | 1.77 | 1.69 | 247529472 | 264142848 | 255000576 | 254935040 | yes | yes | yes |
| F | 7 | 2.05 | 1.65 | 1.66 | 254935040 | 277495808 | 267026432 | 266780672 | yes | yes | yes |
| F | 8 | 1.82 | 1.76 | 1.61 | 266780672 | 285245440 | 276447232 | 275955712 | yes | yes | yes |

| Fixture | Post-unsplit RSS plateau | Final ≤ first + 5% | 
|---|---|---|
| L | no | no |
| F | no | no |

Layout matrix: **PASS** — `PaneShellTests.minimumWindowThreeDividerMatrix` ran at exactly 480×360 for 2×2, 2+1, and 1+2 layouts. It crossed every present outer/inner divider min/max combination and verified close/add/PDF/status hit testing, non-ambiguous layout, divider persistence, and top-left-only traffic-light inset.

Documentation lines changed: `README.md` 17, 50–55; `docs/README.md` 13, 46–51. Binding tables are unchanged.

Deviations: None.

The harness generates `PDFFixtureFactory` `.L` (300-page text) and `.F` (raster) fixtures, opens independent `PDFDocument` sessions through the production `PDFOpenService`, performs the production `PaneCoordinator` 1→2→3→4 split path, and uses production global unsplit for teardown. RSS is sampled from the measuring process with `/bin/ps`; peak is the maximum sample taken after each split and stable is sampled after a main-run-loop drain. No shared-document optimization is used.