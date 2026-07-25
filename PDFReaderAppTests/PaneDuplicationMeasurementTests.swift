import Foundation
import PDFReaderCore
import PDFReaderTestSupport
import Testing
@testable import PDFReaderApp

private let measurementCycleCount = 8
private let measurementWarmupCycleCount = 2
// RSS may retain allocator caches after teardown; permit at most 5% growth between cycles and from first to final.
private let maximumPostUnsplitRSSGrowthRatio = 1.05

@Suite("Release pane duplication measurement")
@MainActor
struct PaneDuplicationMeasurementTests {
    @Test("records Release 1-to-4 duplication evidence for L and F fixtures")
    func recordsReleaseDuplicationEvidence() throws {
        guard ProcessInfo.processInfo.environment["PANE_DUPLICATION_MEASUREMENT"] == "1" else { return }

        let reportDirectory = repositoryRoot()
            .appendingPathComponent("artifacts/verification/pane-4/s5", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let leaksRequested = ProcessInfo.processInfo.environment["PANE_MEASUREMENT_RUN_LEAKS"] == "1"
        let results = try [PerformancePDFFixtureKind.L, .F].map {
            try measure($0, reportDirectory: reportDirectory, shouldRunLeaksAudit: leaksRequested)
        }
        let leaksAuditPassed = !leaksRequested || results.allSatisfy { $0.leaksAudit?.withinBudget == true }

        // Gate = four-pane capacity + split latency + open-metric balance, plus
        // the leaks budget when this cycle explicitly runs the audit. RSS
        // plateau remains informational because it includes allocator/PDFKit
        // cache retention and is not a reliable reachability signal.
        let verdict = results.allSatisfy { result in
            result.capacityWithinBudget
                && result.splitLatenciesWithinBudget
                && result.openMetricsBalanced
        } && leaksAuditPassed ? "PASS" : "ESCALATE"
        let matrixEvidence: [String: Any] = [
            "test": "PaneShellTests.minimumWindowThreeDividerMatrix",
            "window_content_size": [480, 360],
            "topologies": ["2x2", "2+1", "1+2"],
            "divider_extremes": "outer min/max crossed with every present inner min/max",
            "assertions": ["pane close button", "pane add button", "PDF surface", "shared status bar", "no ambiguous layout", "top-left-only traffic-light inset", "divider persistence"],
            "evidence": "separately-run PaneShellTests.minimumWindowThreeDividerMatrix",
        ]
        let documentation: [String: Any] = [
            "README.md": [17, 50, 51, 52, 53, 54, 55],
            "docs/README.md": [13, 46, 47, 48, 49, 50, 51],
        ]
        let leaksEvidence: [String: Any] = leaksRequested ? [
            "status": "run",
            "budget_total_leaked_bytes": 65_536,
            "fixtures": results.map(\.leaksJSON),
            "within_budget": leaksAuditPassed,
        ] : [
            "status": "not run this cycle",
            "historical_artifacts_only": ["leaks-L.txt", "leaks-F.txt"],
            "note": "Retained artifacts are historical evidence only; this report makes no current-cycle leaks PASS claim.",
        ]
        let deviations = verdict == "PASS" ? [] : ["ESCALATE: a fixture exceeded the four-pane capacity budget, split-latency budget, open-metric balance requirement, or the requested leaks budget."]
        let payload: [String: Any] = [
            "schema_version": 3,
            "configuration": "Release",
            "threshold": [
                "four_pane_capacity": "stable RSS at four panes must not exceed 4x the one-pane baseline in every measured cycle",
                "split_latency_ms": "each split must not exceed 250 ms",
                "open_metric_balance": "every open metric begin/end pair must balance",
                "leaks_audit_when_run": "total leaked bytes must not exceed 65536",
                "post_unsplit_rss_plateau": "informational only; excluded from the verdict gate",
            ],
            "architect_adjudication": [
                "one_sample_rss_inequality": "invalid leak proxy",
                "rss_plateau_status": "informational only; excluded from the gate",
            ],
            "leaks_audit": leaksEvidence,
            "layout_matrix": matrixEvidence,
            "documentation_lines_changed": documentation,
            "deviations": deviations,
            "fixtures": results.map(\.json),
            "verdict": verdict,
        ]
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: reportDirectory.appendingPathComponent("duplication-measurement.json"), options: .atomic)

        let leaksSummary: String
        if leaksRequested {
            leaksSummary = results.map { result in
                let audit = result.leaksAudit!
                return "\(result.fixture): \(audit.blockCount) blocks / \(audit.totalLeakedBytes) bytes (≤ 65536: \(audit.withinBudget ? "yes" : "no"))"
            }.joined(separator: "; ")
        } else {
            leaksSummary = "Not run this cycle. `leaks-L.txt` and `leaks-F.txt` are retained historical artifacts only, not a current-cycle PASS."
        }
        let markdown = """
        # Pane 1→4 Release duplication measurement

        **Final verdict: \(verdict)** (gate = 4× capacity + 250 ms split latency + open-metric balance\(leaksRequested ? " + requested leaks budget" : ""))

        RSS plateau is informational only and excluded from the verdict gate because allocator/PDFKit cache retention is not a reachability signal. `leaks` audit: \(leaksSummary)

        Pre-declared escalation threshold: ESCALATE when stable RSS at four panes is greater than four times the one-pane baseline in any measured cycle, any split takes more than 250 ms, open-metric begin/end balance does not match, or a requested `leaks` audit reports more than 65536 total leaked bytes. Post-unsplit RSS plateau is reported below as informational evidence only.
        | Fixture | Cycle | Split 1→2 (ms) | 2→3 (ms) | 3→4 (ms) | Baseline RSS (bytes) | Peak RSS (bytes) | Stable RSS (bytes) | RSS after unsplit (bytes) | 4× capacity | Split latency | Metrics balanced |
        |---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
        \(results.flatMap(\.markdownRows).joined(separator: "\n"))

        | Fixture | Post-unsplit RSS plateau | Final ≤ first + 5% |
        |---|---|---|
        \(results.map(\.plateauMarkdownRow).joined(separator: "\n"))

        Layout matrix is verified separately by `PaneShellTests.minimumWindowThreeDividerMatrix` at exactly 480×360 for 2×2, 2+1, and 1+2 layouts; this measurement does not assert that test's result.

        Documentation lines changed: `README.md` 17, 50–55; `docs/README.md` 13, 46–51. Binding tables are unchanged.

        Deviations: \(deviations.isEmpty ? "None." : deviations.joined(separator: " "))

        The harness generates `PDFFixtureFactory` `.L` (300-page text) and `.F` (raster) fixtures, opens independent `PDFDocument` sessions through the production `PDFOpenService`, performs the production `PaneCoordinator` 1→2→3→4 split path, and uses production global unsplit and coordinator-driven tab close for teardown. RSS is sampled from the measuring process with `/bin/ps`; peak is the maximum sample taken after each split and stable is sampled after a main-run-loop drain. No shared-document optimization is used.
        """
        try markdown.write(to: reportDirectory.appendingPathComponent("duplication-measurement.md"), atomically: true, encoding: .utf8)
        #expect(verdict == "PASS", "measurement gate must pass at this completion gate")

    }

    private func measure(
        _ fixture: PerformancePDFFixtureKind,
        reportDirectory: URL,
        shouldRunLeaksAudit: Bool
    ) throws -> FixtureMeasurement {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("modeleaf-pane-duplication-\(fixture.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try PDFFixtureFactory.makePerformancePDF(fixture, in: directory)
        let metrics = MeasurementMetrics()
        let service = PDFOpenService()
        let origin = try service.open(url: url, metrics: metrics)
        let coordinator = PaneCoordinator()
        coordinator.configureDuplication { snapshot in
            try? service.open(url: snapshot.sourceURL, metrics: metrics)
        }
        #expect(coordinator.insert(origin, into: .createIfEmpty))
        for warmupCycle in 1...measurementWarmupCycleCount {
            _ = try measureCycle(-warmupCycle, coordinator: coordinator, metrics: metrics)
        }
        let cycles = try (1...measurementCycleCount).map { try measureCycle($0, coordinator: coordinator, metrics: metrics) }

        while coordinator.closeActiveTab() {}
        runMainLoop()
        #expect(coordinator.snapshot.layout == .empty)
        #expect(coordinator.snapshot.panes.isEmpty)
        coordinator.snapshot.assertCardinality()

        let leaksAudit = shouldRunLeaksAudit
            ? try runLeaksAudit(fixture: fixture, reportDirectory: reportDirectory)
            : nil
        return FixtureMeasurement(fixture: fixture.rawValue, cycles: cycles, leaksAudit: leaksAudit)
    }

    private func runLeaksAudit(fixture: PerformancePDFFixtureKind, reportDirectory: URL) throws -> LeaksAudit {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/leaks")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try output.write(to: reportDirectory.appendingPathComponent("leaks-\(fixture.rawValue).txt"), atomically: true, encoding: .utf8)
        guard [0, 1].contains(process.terminationStatus) else {
            throw MeasurementError("leaks failed for \(fixture.rawValue) with unexpected exit status \(process.terminationStatus)")
        }
        let match = try #require(output.firstMatch(of: /Process \d+: (\d+) leaks for (\d+) total leaked bytes\./))
        let blockCount = try #require(Int(match.1))
        let totalLeakedBytes = try #require(Int64(match.2))
        return LeaksAudit(exitStatus: process.terminationStatus, blockCount: blockCount, totalLeakedBytes: totalLeakedBytes)
    }

    private func measureCycle(_ cycle: Int, coordinator: PaneCoordinator, metrics: MeasurementMetrics) throws -> MeasurementCycle {
        _ = coordinator.snapshot
        let baselineRSSBytes = try residentMemoryBytes()
        var peakRSSBytes = baselineRSSBytes
        var splitLatenciesMilliseconds: [Double] = []

        func split(_ direction: PaneOrientation) throws {
            let start = Date()
            _ = try #require(coordinator.split(direction: direction))
            splitLatenciesMilliseconds.append(Date().timeIntervalSince(start) * 1_000)
            _ = coordinator.snapshot
            peakRSSBytes = max(peakRSSBytes, try residentMemoryBytes())
        }

        try split(.sideBySide)
        try split(.stacked)
        let leading = try #require(coordinator.snapshot.layout.paneIDs.first { $0 != coordinator.activePaneID && coordinator.snapshot.layout.side(of: $0) == .leading })
        #expect(coordinator.activatePane(leading))
        try split(.stacked)
        runMainLoop()
        let stableRSSBytes = try residentMemoryBytes()
        peakRSSBytes = max(peakRSSBytes, stableRSSBytes)

        #expect(coordinator.snapshot.layout.paneIDs.count == 4)
        #expect(coordinator.unsplit())
        runMainLoop()
        let postUnsplitRSSBytes = try residentMemoryBytes()

        return MeasurementCycle(
            cycle: cycle,
            splitLatenciesMilliseconds: splitLatenciesMilliseconds,
            baselineRSSBytes: baselineRSSBytes,
            peakRSSBytes: peakRSSBytes,
            stableRSSBytes: stableRSSBytes,
            postUnsplitRSSBytes: postUnsplitRSSBytes,
            openMetricsBalanced: metrics.isBalanced
        )
    }

    private func runMainLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    private func residentMemoryBytes() throws -> Int64 {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", "\(ProcessInfo.processInfo.processIdentifier)"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MeasurementError("ps failed with exit status \(process.terminationStatus)")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let kilobytes = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)), kilobytes > 0 else {
            throw MeasurementError("ps returned an invalid RSS value: \(text.debugDescription)")
        }
        return kilobytes * 1_024
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
}

@MainActor
private final class MeasurementMetrics: PDFOpenMetrics {
    private var beginnings: [OpenTraceID: [PDFOpenMetricName: Int]] = [:]
    private var endings: [OpenTraceID: [PDFOpenMetricName: Int]] = [:]

    func record(_ event: PDFOpenMetricEvent) {
        switch event.boundary {
        case .begin:
            beginnings[event.traceID, default: [:]][event.name, default: 0] += 1
        case .end:
            endings[event.traceID, default: [:]][event.name, default: 0] += 1
        case .point:
            break
        }
    }

    var isBalanced: Bool {
        Set(beginnings.keys).union(endings.keys).allSatisfy { beginnings[$0] == endings[$0] }
    }
}

private struct LeaksAudit {
    let exitStatus: Int32
    let blockCount: Int
    let totalLeakedBytes: Int64

    var withinBudget: Bool { totalLeakedBytes <= 65_536 }

    var json: [String: Any] {
        [
            "block_count": blockCount,
            "total_leaked_bytes": totalLeakedBytes,
            "exit_status": exitStatus,
            "within_budget": withinBudget,
        ]
    }
}

private struct MeasurementError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct FixtureMeasurement {
    let fixture: String
    let cycles: [MeasurementCycle]

    let leaksAudit: LeaksAudit?

    var leaksJSON: [String: Any] {
        leaksAudit?.json ?? ["status": "not run"]
    }
    var capacityWithinBudget: Bool {
        cycles.allSatisfy { $0.stableRSSBytes <= $0.baselineRSSBytes * 4 }
    }

    var splitLatenciesWithinBudget: Bool {
        cycles.allSatisfy { $0.splitLatenciesMilliseconds.allSatisfy { $0 <= 250 } }
    }

    /// Informational only. Per the architect escalation adjudication
    /// (allocator-artifact, agent 50-EscalationReview) a strict RSS
    /// inequality is not a valid leak oracle: freed small allocations stay
    /// resident in malloc zones and PDFKit caches are reachable by design.
    /// Genuine leak detection is the malloc-reachability audit
    /// (PANE_MEASUREMENT_RUN_LEAKS=1 -> `leaks` self-scan artifact) plus the
    /// weak-object death matrix in PaneCoordinatorTests.
    var postUnsplitRSSPlateaus: Bool {
        guard let first = cycles.first else { return false }
        let cycleToCycleWithinBudget = zip(cycles, cycles.dropFirst()).allSatisfy {
            Double($1.postUnsplitRSSBytes) <= Double($0.postUnsplitRSSBytes) * maximumPostUnsplitRSSGrowthRatio
        }
        return cycleToCycleWithinBudget
            && Double(cycles.last!.postUnsplitRSSBytes) <= Double(first.postUnsplitRSSBytes) * maximumPostUnsplitRSSGrowthRatio
    }

    var openMetricsBalanced: Bool {
        cycles.allSatisfy(\.openMetricsBalanced)
    }

    var json: [String: Any] {
        [
            "fixture": fixture,
            "cycles": cycles.map(\.json),
            "capacity_within_budget": capacityWithinBudget,
            "post_unsplit_rss_plateaus": postUnsplitRSSPlateaus,
            "split_latencies_within_budget": splitLatenciesWithinBudget,
            "open_metrics_balanced": openMetricsBalanced,
        ]
    }

    var markdownRows: [String] {
        cycles.map { $0.markdownRow(fixture: fixture) }
    }

    var plateauMarkdownRow: String {
        let finalWithinFirstBudget = Double(cycles.last!.postUnsplitRSSBytes) <= Double(cycles.first!.postUnsplitRSSBytes) * maximumPostUnsplitRSSGrowthRatio
        return "| \(fixture) | \(postUnsplitRSSPlateaus ? "yes" : "no") | \(finalWithinFirstBudget ? "yes" : "no") |"
    }
}

private struct MeasurementCycle {
    let cycle: Int
    let splitLatenciesMilliseconds: [Double]
    let baselineRSSBytes: Int64
    let peakRSSBytes: Int64
    let stableRSSBytes: Int64
    let postUnsplitRSSBytes: Int64
    let openMetricsBalanced: Bool

    var capacityWithinBudget: Bool {
        stableRSSBytes <= baselineRSSBytes * 4
    }

    var splitLatenciesWithinBudget: Bool {
        splitLatenciesMilliseconds.allSatisfy { $0 <= 250 }
    }

    var json: [String: Any] {
        [
            "cycle": cycle,
            "split_latency_ms": splitLatenciesMilliseconds,
            "baseline_rss_bytes": baselineRSSBytes,
            "peak_rss_bytes": peakRSSBytes,
            "stable_rss_bytes": stableRSSBytes,
            "post_unsplit_rss_bytes": postUnsplitRSSBytes,
            "capacity_within_budget": capacityWithinBudget,
            "split_latencies_within_budget": splitLatenciesWithinBudget,
            "open_metrics_balanced": openMetricsBalanced,
        ]
    }

    func markdownRow(fixture: String) -> String {
        let values = splitLatenciesMilliseconds.map { String(format: "%.2f", $0) }
        return "| \(fixture) | \(cycle) | \(values[0]) | \(values[1]) | \(values[2]) | \(baselineRSSBytes) | \(peakRSSBytes) | \(stableRSSBytes) | \(postUnsplitRSSBytes) | \(capacityWithinBudget ? "yes" : "no") | \(splitLatenciesWithinBudget ? "yes" : "no") | \(openMetricsBalanced ? "yes" : "no") |"
    }
}
