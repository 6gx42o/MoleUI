import Foundation

/// `MoleUI --scan <pane|all>` — runs feature scanners headlessly and prints
/// what each found and how long it took. Runs inside the signed app binary, so
/// it sees exactly what the panes see (Full Disk Access included), and it never
/// performs an action — scanning only.
///
/// Launch it with `open -n -a MoleUI.app --args --scan all`: TCC attributes a
/// process started from a terminal to the terminal, so a shell launch measures
/// the terminal's permissions, not MoleUI's (see FDACheck). The report is
/// written to ~/Library/Logs/MoleUI/scan.txt for exactly that reason.
enum ScanProbe {
    private static var report = ""

    private static func print(_ line: String) {
        Swift.print(line)
        report += line + "\n"
    }

    static func start(_ target: String) -> Never {
        if target == "smart" {
            Task { @MainActor in
                let model = SmartScanModel()
                await model.run()
                for tile in model.tiles {
                    print(String(format: "%-12@ %-7@ %10@  %@", tile.pane.rawValue as NSString,
                                 tile.state.rawValue as NSString,
                                 (tile.bytes.map { formatBytesDecimal($0) } ?? (tile.count.map(String.init) ?? "-")) as NSString,
                                 (tile.line ?? "") as NSString))
                }
                print(String(format: "you can free %@ · finished in %.1fs",
                             formatBytesDecimal(model.reclaimableBytes) as NSString, model.duration ?? 0))
                print("RESULT: smart scan completed")
                try? report.write(toFile: DiagnosticsDir.file("scan.txt"), atomically: true, encoding: .utf8)
                exit(0)
            }
            dispatchMain()
        }
        let panes = target == "all"
            ? Pane.allCases.filter { Features.forPane($0) != nil }
            : [Pane(rawValue: target)].compactMap { $0 }
        guard !panes.isEmpty else {
            print("unknown pane '\(target)'. Try: " + Pane.allCases.filter { Features.forPane($0) != nil }
                .map(\.rawValue).joined(separator: ", "))
            exit(2)
        }
        Task { @MainActor in
            var failed = false
            for pane in panes {
                guard let feature = Features.forPane(pane) else { continue }
                let started = Date()
                do {
                    let scan = try await feature.scan()
                    let elapsed = Date().timeIntervalSince(started)
                    let bytes = scan.findings.compactMap(\.bytes).reduce(0, +)
                    let blocked = scan.findings.filter { $0.blocked != nil }.count
                    let groups = Dictionary(grouping: scan.findings, by: { $0.group ?? "" })
                        .map { "\($0.key.isEmpty ? "-" : $0.key)=\($0.value.count)" }.sorted()
                    print(String(format: "%-18@ %5d rows  %10@  %6.2fs  blocked=%d", pane.rawValue as NSString,
                                 scan.findings.count, formatBytesDecimal(bytes) as NSString, elapsed, blocked))
                    print("    groups: " + groups.prefix(8).joined(separator: ", "))
                    for note in scan.notes { print("    note: " + note) }
                    for row in scan.findings.sorted(by: { ($0.tone == .warning ? 0 : 1) < ($1.tone == .warning ? 0 : 1) }).prefix(target == "all" ? 2 : 40) {
                        print("    · [\(row.group ?? "")] \(row.title)" + (row.bytes.map { "  \(formatBytesDecimal($0))" } ?? "")
                              + (row.detail.map { "  — \($0.prefix(90))" } ?? ""))
                    }
                } catch {
                    failed = true
                    print(String(format: "%-18@ FAILED after %.2fs: %@", pane.rawValue as NSString,
                                 Date().timeIntervalSince(started), error.localizedDescription as NSString))
                }
            }
            print(failed ? "RESULT: failures above" : "RESULT: all scanners completed")
            try? report.write(toFile: DiagnosticsDir.file("scan.txt"), atomically: true, encoding: .utf8)
            exit(failed ? 1 : 0)
        }
        dispatchMain()
    }
}
