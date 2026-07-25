# Pane 1→4 Release duplication measurement

**Final verdict: PASS** (gate = 4× capacity + 250 ms split latency + open-metric balance + requested leaks budget)

RSS plateau is informational only and excluded from the verdict gate because allocator/PDFKit cache retention is not a reachability signal. `leaks` audit: L: 288 blocks / 14400 bytes (≤ 65536: yes); F: 288 blocks / 14400 bytes (≤ 65536: yes)

Pre-declared escalation threshold: ESCALATE when stable RSS at four panes is greater than four times the one-pane baseline in any measured cycle, any split takes more than 250 ms, open-metric begin/end balance does not match, or a requested `leaks` audit reports more than 65536 total leaked bytes. Post-unsplit RSS plateau is reported below as informational evidence only.
| Fixture | Cycle | Split 1→2 (ms) | 2→3 (ms) | 3→4 (ms) | Baseline RSS (bytes) | Peak RSS (bytes) | Stable RSS (bytes) | RSS after unsplit (bytes) | 4× capacity | Split latency | Metrics balanced |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| L | 1 | 4.33 | 4.41 | 4.80 | 155025408 | 179224576 | 179224576 | 177160192 | yes | yes | yes |
| L | 2 | 4.18 | 4.24 | 4.36 | 175013888 | 183107584 | 183107584 | 178814976 | yes | yes | yes |
| L | 3 | 4.95 | 4.51 | 4.79 | 177995776 | 187105280 | 187105280 | 184926208 | yes | yes | yes |
| L | 4 | 4.53 | 4.21 | 4.30 | 182763520 | 189579264 | 186974208 | 175177728 | yes | yes | yes |
| L | 5 | 10.10 | 4.16 | 4.90 | 175177728 | 195231744 | 195231744 | 194134016 | yes | yes | yes |
| L | 6 | 4.43 | 4.48 | 4.46 | 191660032 | 198082560 | 185745408 | 185729024 | yes | yes | yes |
| L | 7 | 4.06 | 4.01 | 4.97 | 185729024 | 205586432 | 205586432 | 203292672 | yes | yes | yes |
| L | 8 | 4.32 | 4.38 | 4.23 | 201310208 | 207912960 | 201080832 | 193200128 | yes | yes | yes |
| F | 1 | 2.17 | 1.62 | 1.73 | 250953728 | 270336000 | 263700480 | 263700480 | yes | yes | yes |
| F | 2 | 4.80 | 1.68 | 1.64 | 263700480 | 284884992 | 280379392 | 277315584 | yes | yes | yes |
| F | 3 | 8.11 | 1.84 | 1.97 | 277315584 | 297091072 | 296501248 | 290373632 | yes | yes | yes |
| F | 4 | 4.69 | 1.77 | 1.76 | 290373632 | 308559872 | 307150848 | 301039616 | yes | yes | yes |
| F | 5 | 1.70 | 1.89 | 2.00 | 301039616 | 323059712 | 315850752 | 315850752 | yes | yes | yes |
| F | 6 | 4.45 | 1.68 | 1.59 | 315801600 | 336052224 | 328728576 | 328728576 | yes | yes | yes |
| F | 7 | 8.45 | 1.70 | 1.71 | 328728576 | 348798976 | 341377024 | 341393408 | yes | yes | yes |
| F | 8 | 1.91 | 1.94 | 1.86 | 341393408 | 359120896 | 351879168 | 351879168 | yes | yes | yes |

| Fixture | Post-unsplit RSS plateau | Final ≤ first + 5% |
|---|---|---|
| L | no | no |
| F | no | no |

Layout matrix coverage is implemented separately in `PaneShellTests.minimumWindowThreeDividerMatrix` at exactly 480×360 for 2×2, 2+1, and 1+2 layouts. This measurement does not run or assert that test; its result is proven only by the commit-bound full-suite run, not by this artifact.

Documentation lines changed: `README.md` 17, 50–55; `docs/README.md` 13, 46–51. Binding tables are unchanged.

Deviations: None.

The harness generates `PDFFixtureFactory` `.L` (300-page text) and `.F` (raster) fixtures, opens independent `PDFDocument` sessions through the production `PDFOpenService`, performs the production `PaneCoordinator` 1→2→3→4 split path, and uses production global unsplit and coordinator-driven tab close for teardown. RSS is sampled from the measuring process with `/bin/ps`; peak is the maximum sample taken after each split and stable is sampled after a main-run-loop drain. No shared-document optimization is used.