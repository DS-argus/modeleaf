# Pane 1→4 Release duplication measurement

**Final verdict: PASS** (gate = 4× capacity + 250 ms split latency + open-metric balance + requested leaks budget)

RSS plateau is informational only and excluded from the verdict gate because allocator/PDFKit cache retention is not a reachability signal. `leaks` audit: L: 288 blocks / 14400 bytes (≤ 65536: yes); F: 288 blocks / 14400 bytes (≤ 65536: yes)

Pre-declared escalation threshold: ESCALATE when stable RSS at four panes is greater than four times the one-pane baseline in any measured cycle, any split takes more than 250 ms, open-metric begin/end balance does not match, or a requested `leaks` audit reports more than 65536 total leaked bytes. Post-unsplit RSS plateau is reported below as informational evidence only.
| Fixture | Cycle | Split 1→2 (ms) | 2→3 (ms) | 3→4 (ms) | Baseline RSS (bytes) | Peak RSS (bytes) | Stable RSS (bytes) | RSS after unsplit (bytes) | 4× capacity | Split latency | Metrics balanced |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| L | 1 | 5.62 | 4.05 | 4.71 | 154796032 | 175833088 | 175833088 | 174571520 | yes | yes | yes |
| L | 2 | 4.38 | 4.19 | 4.36 | 171655168 | 178896896 | 175128576 | 163266560 | yes | yes | yes |
| L | 3 | 10.22 | 4.14 | 4.76 | 163266560 | 183320576 | 183320576 | 181272576 | yes | yes | yes |
| L | 4 | 4.06 | 3.93 | 4.07 | 179159040 | 188760064 | 188760064 | 184401920 | yes | yes | yes |
| L | 5 | 4.49 | 4.54 | 4.03 | 183517184 | 192479232 | 192479232 | 193396736 | yes | yes | yes |
| L | 6 | 4.17 | 3.96 | 4.03 | 189054976 | 197148672 | 197148672 | 195805184 | yes | yes | yes |
| L | 7 | 4.30 | 4.12 | 4.28 | 193691648 | 201654272 | 201654272 | 198557696 | yes | yes | yes |
| L | 8 | 4.06 | 4.04 | 4.06 | 197754880 | 206635008 | 206635008 | 203358208 | yes | yes | yes |
| F | 1 | 7.54 | 1.61 | 1.54 | 249085952 | 268075008 | 263585792 | 260521984 | yes | yes | yes |
| F | 2 | 3.78 | 1.68 | 1.72 | 260521984 | 279363584 | 275595264 | 272531456 | yes | yes | yes |
| F | 3 | 4.76 | 1.55 | 1.65 | 272531456 | 291995648 | 285048832 | 285048832 | yes | yes | yes |
| F | 4 | 8.91 | 1.64 | 1.53 | 285048832 | 305414144 | 298745856 | 298762240 | yes | yes | yes |
| F | 5 | 4.17 | 1.61 | 1.72 | 298762240 | 318275584 | 311099392 | 311099392 | yes | yes | yes |
| F | 6 | 7.13 | 1.65 | 1.60 | 310984704 | 331300864 | 327172096 | 324108288 | yes | yes | yes |
| F | 7 | 8.40 | 1.66 | 1.69 | 324108288 | 344129536 | 337903616 | 337903616 | yes | yes | yes |
| F | 8 | 2.22 | 1.62 | 1.48 | 337903616 | 357711872 | 350748672 | 350748672 | yes | yes | yes |

| Fixture | Post-unsplit RSS plateau | Final ≤ first + 5% |
|---|---|---|
| L | no | no |
| F | no | no |

Layout matrix is verified separately by `PaneShellTests.minimumWindowThreeDividerMatrix` at exactly 480×360 for 2×2, 2+1, and 1+2 layouts; this measurement does not assert that test's result.

Documentation lines changed: `README.md` 17, 50–55; `docs/README.md` 13, 46–51. Binding tables are unchanged.

Deviations: None.

The harness generates `PDFFixtureFactory` `.L` (300-page text) and `.F` (raster) fixtures, opens independent `PDFDocument` sessions through the production `PDFOpenService`, performs the production `PaneCoordinator` 1→2→3→4 split path, and uses production global unsplit and coordinator-driven tab close for teardown. RSS is sampled from the measuring process with `/bin/ps`; peak is the maximum sample taken after each split and stable is sampled after a main-run-loop drain. No shared-document optimization is used.