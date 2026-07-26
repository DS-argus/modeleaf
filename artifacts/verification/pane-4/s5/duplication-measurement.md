# Pane 1→4 Release duplication measurement

**Final verdict: PASS** (gate = 4× capacity + 250 ms split latency + open-metric balance + requested leaks budget)

RSS plateau is informational only and excluded from the verdict gate because allocator/PDFKit cache retention is not a reachability signal. `leaks` audit: L: 288 blocks / 14400 bytes (≤ 65536: yes); F: 288 blocks / 14400 bytes (≤ 65536: yes)

Pre-declared escalation threshold: ESCALATE when stable RSS at four panes is greater than four times the one-pane baseline in any measured cycle, any split takes more than 250 ms, open-metric begin/end balance does not match, or a requested `leaks` audit reports more than 65536 total leaked bytes. Post-unsplit RSS plateau is reported below as informational evidence only.
| Fixture | Cycle | Split 1→2 (ms) | 2→3 (ms) | 3→4 (ms) | Baseline RSS (bytes) | Peak RSS (bytes) | Stable RSS (bytes) | RSS after unsplit (bytes) | 4× capacity | Split latency | Metrics balanced |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| L | 1 | 4.49 | 4.84 | 4.63 | 170246144 | 179683328 | 179683328 | 176717824 | yes | yes | yes |
| L | 2 | 4.81 | 4.94 | 7.43 | 174555136 | 182960128 | 182288384 | 179421184 | yes | yes | yes |
| L | 3 | 4.76 | 4.67 | 4.42 | 177274880 | 186040320 | 184401920 | 180584448 | yes | yes | yes |
| L | 4 | 4.56 | 4.54 | 4.86 | 170295296 | 184745984 | 184745984 | 183304192 | yes | yes | yes |
| L | 5 | 6.69 | 5.01 | 4.58 | 182534144 | 189906944 | 187105280 | 181403648 | yes | yes | yes |
| L | 6 | 4.77 | 4.88 | 4.92 | 172474368 | 192512000 | 192512000 | 197722112 | yes | yes | yes |
| L | 7 | 8.54 | 4.40 | 4.49 | 200032256 | 212189184 | 209354752 | 206209024 | yes | yes | yes |
| L | 8 | 6.91 | 4.97 | 4.79 | 205324288 | 213483520 | 213483520 | 211894272 | yes | yes | yes |
| F | 1 | 6.91 | 2.10 | 1.87 | 192937984 | 211697664 | 207323136 | 200261632 | yes | yes | yes |
| F | 2 | 3.12 | 2.02 | 2.12 | 200261632 | 218759168 | 218742784 | 212582400 | yes | yes | yes |
| F | 3 | 2.13 | 1.99 | 1.99 | 212582400 | 226410496 | 223182848 | 217055232 | yes | yes | yes |
| F | 4 | 2.12 | 1.93 | 5.37 | 217055232 | 232587264 | 230146048 | 223100928 | yes | yes | yes |
| F | 5 | 2.32 | 1.84 | 2.08 | 223100928 | 238813184 | 238813184 | 232685568 | yes | yes | yes |
| F | 6 | 2.33 | 1.88 | 1.76 | 232685568 | 252297216 | 247136256 | 234274816 | yes | yes | yes |
| F | 7 | 2.30 | 3.46 | 2.05 | 234274816 | 251052032 | 249659392 | 243449856 | yes | yes | yes |
| F | 8 | 2.31 | 3.59 | 1.93 | 243449856 | 259801088 | 257392640 | 250986496 | yes | yes | yes |

| Fixture | Post-unsplit RSS plateau | Final ≤ first + 5% |
|---|---|---|
| L | no | no |
| F | no | no |

Layout matrix coverage is implemented separately in `PaneShellTests.minimumWindowThreeDividerMatrix` at exactly 480×360 for 2×2, 2+1, and 1+2 layouts. This measurement does not run or assert that test; its result is proven only by the commit-bound full-suite run, not by this artifact.

Documentation lines changed: `README.md` 17, 50–55; `docs/README.md` 13, 46–51. Binding tables are unchanged.

Deviations: None.

The harness generates `PDFFixtureFactory` `.L` (300-page text) and `.F` (raster) fixtures, opens independent `PDFDocument` sessions through the production `PDFOpenService`, performs the production `PaneCoordinator` 1→2→3→4 split path, and uses production global unsplit and coordinator-driven tab close for teardown. RSS is sampled from the measuring process with `/bin/ps`; peak is the maximum sample taken after each split and stable is sampled after a main-run-loop drain. No shared-document optimization is used.