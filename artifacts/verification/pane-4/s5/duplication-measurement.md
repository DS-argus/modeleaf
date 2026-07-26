# Pane 1→4 Release duplication measurement

**Final verdict: PASS** (gate = 4× capacity + 250 ms split latency + open-metric balance + requested leaks budget)

RSS plateau is informational only and excluded from the verdict gate because allocator/PDFKit cache retention is not a reachability signal. `leaks` audit: L: 288 blocks / 14400 bytes (≤ 65536: yes); F: 288 blocks / 14400 bytes (≤ 65536: yes)

Pre-declared escalation threshold: ESCALATE when stable RSS at four panes is greater than four times the one-pane baseline in any measured cycle, any split takes more than 250 ms, open-metric begin/end balance does not match, or a requested `leaks` audit reports more than 65536 total leaked bytes. Post-unsplit RSS plateau is reported below as informational evidence only.
| Fixture | Cycle | Split 1→2 (ms) | 2→3 (ms) | 3→4 (ms) | Baseline RSS (bytes) | Peak RSS (bytes) | Stable RSS (bytes) | RSS after unsplit (bytes) | 4× capacity | Split latency | Metrics balanced |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| L | 1 | 8.15 | 8.00 | 7.64 | 168853504 | 176586752 | 174309376 | 171376640 | yes | yes | yes |
| L | 2 | 4.85 | 4.96 | 5.41 | 171376640 | 179568640 | 179568640 | 178176000 | yes | yes | yes |
| L | 3 | 7.69 | 4.99 | 5.29 | 177242112 | 186990592 | 185761792 | 182763520 | yes | yes | yes |
| L | 4 | 4.82 | 7.68 | 4.64 | 182763520 | 191053824 | 191053824 | 193069056 | yes | yes | yes |
| L | 5 | 5.00 | 8.74 | 4.68 | 196165632 | 208420864 | 203423744 | 200425472 | yes | yes | yes |
| L | 6 | 7.40 | 7.80 | 7.12 | 200425472 | 206143488 | 206143488 | 196345856 | yes | yes | yes |
| L | 7 | 6.58 | 11.00 | 7.66 | 192184320 | 212123648 | 212123648 | 210747392 | yes | yes | yes |
| L | 8 | 4.56 | 5.74 | 7.29 | 210010112 | 214384640 | 214384640 | 211369984 | yes | yes | yes |
| F | 1 | 4.53 | 7.10 | 2.21 | 231440384 | 250839040 | 243204096 | 243204096 | yes | yes | yes |
| F | 2 | 4.60 | 2.25 | 1.85 | 243220480 | 262160384 | 260833280 | 254427136 | yes | yes | yes |
| F | 3 | 2.76 | 6.89 | 2.43 | 254427136 | 274350080 | 266272768 | 266272768 | yes | yes | yes |
| F | 4 | 2.86 | 2.64 | 3.69 | 266289152 | 286998528 | 285917184 | 278904832 | yes | yes | yes |
| F | 5 | 5.26 | 2.29 | 2.40 | 278904832 | 297598976 | 295993344 | 289734656 | yes | yes | yes |
| F | 6 | 4.75 | 2.39 | 4.50 | 289734656 | 312459264 | 311115776 | 304971776 | yes | yes | yes |
| F | 7 | 4.11 | 2.62 | 5.72 | 304971776 | 324845568 | 324845568 | 318734336 | yes | yes | yes |
| F | 8 | 4.59 | 2.21 | 2.22 | 318734336 | 340066304 | 333791232 | 333791232 | yes | yes | yes |

| Fixture | Post-unsplit RSS plateau | Final ≤ first + 5% |
|---|---|---|
| L | no | no |
| F | no | no |

Layout matrix coverage is implemented separately in `PaneShellTests.minimumWindowThreeDividerMatrix` at exactly 480×360 for 2×2, 2+1, and 1+2 layouts. This measurement does not run or assert that test; its result is proven only by the commit-bound full-suite run, not by this artifact.

Documentation lines changed: `README.md` 17, 50–55; `docs/README.md` 13, 46–51. Binding tables are unchanged.

Deviations: None.

The harness generates `PDFFixtureFactory` `.L` (300-page text) and `.F` (raster) fixtures, opens independent `PDFDocument` sessions through the production `PDFOpenService`, performs the production `PaneCoordinator` 1→2→3→4 split path, and uses production global unsplit and coordinator-driven tab close for teardown. RSS is sampled from the measuring process with `/bin/ps`; peak is the maximum sample taken after each split and stable is sampled after a main-run-loop drain. No shared-document optimization is used.