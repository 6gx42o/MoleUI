import Foundation

/// `MoleUI --selftest` — decodes every captured fixture and prints what came
/// out. Mole's JSON is emitted partly by Go and partly by hand-rolled bash
/// printf, so it can drift without any compile-time signal here. This catches
/// that in a second, without launching a window.
enum SelfTest {

    static func run() -> Bool {
        let root = fixturesDirectory()
        print("MoleUI self-test")
        print("fixtures: \(root.path)\n")

        var ok = true
        ok = check("status.json", root) {
            let snapshot = try decode(StatusSnapshot.self, root, "status.json")
            return [
                "health \(snapshot.healthScore) (\(snapshot.healthScoreMsg))",
                "cpu \(String(format: "%.1f", snapshot.cpu.usage))% over \((snapshot.cpu.perCore ?? []).count) cores",
                "memory \(formatBytesBinary(snapshot.memory.used))/\(formatBytesBinary(snapshot.memory.total))",
                "\((snapshot.disks ?? []).count) disks, \((snapshot.network ?? []).count) interfaces",
                "\((snapshot.topProcesses ?? []).count) top processes",
            ]
        } && ok

        ok = check("analyze_overview.json", root) {
            let result = try decode(AnalyzeResult.self, root, "analyze_overview.json")
            return ["overview=\(result.overview)",
                    "\((result.entries ?? []).count) entries",
                    "total \(formatBytesDecimal(result.totalSize, fractionDigits: 1))",
                    "insights \((result.entries ?? []).filter(\.insight).count)"]
        } && ok

        ok = check("analyze_dir.json", root) {
            let result = try decode(AnalyzeResult.self, root, "analyze_dir.json")
            return ["path \(result.path)",
                    "\((result.entries ?? []).count) entries",
                    "\((result.largeFiles ?? []).count) large files"]
        } && ok

        ok = check("apps.json", root) {
            let apps = try decode([InstalledApp].self, root, "apps.json")
            let brew = apps.filter(\.isHomebrew).count
            return ["\(apps.count) apps (\(brew) via Homebrew)",
                    "sized: \(apps.filter(\.hasKnownSize).count)",
                    "first: \(apps.first?.uninstallName ?? "—")"]
        } && ok

        ok = check("history.json", root) {
            let history = try decode(HistoryLog.self, root, "history.json")
            return ["\((history.sessions ?? []).count) sessions",
                    "\((history.deletions ?? []).count) deletions"]
        } && ok

        ok = check("clean_dryrun.txt", root) {
            let preview = MolePreview.parse(try text(root, "clean_dryrun.txt"))
            guard let total = preview.totalBytes else {
                throw Failure("no total parsed out of the headline")
            }
            guard preview.detailListPath != nil else {
                throw Failure("no detailed file list path found")
            }
            return ["\(preview.sections.count) sections",
                    "\(preview.sections.map(\.actionable).reduce(0,+)) actionable items",
                    "headline total \(formatBytesDecimal(total))",
                    "headline: \(preview.headline ?? "—")",
                    "list: \(preview.detailListPath ?? "—")",
                    "needsSudo=\(preview.needsSudo)"]
        } && ok

        ok = check("clean-list.txt", root) {
            let categories = CleanFileList.parse(try text(root, "clean-list.txt"))
            let files = categories.map(\.entries.count).reduce(0, +)
            guard files > 0 else { throw Failure("no file entries parsed") }
            return ["\(categories.count) categories, \(files) files",
                    "sum \(formatBytesDecimal(categories.map(\.bytes).reduce(0,+)))",
                    "largest: \(categories.max(by: { $0.bytes < $1.bytes })?.name ?? "—")"]
        } && ok

        ok = check("optimize_dryrun.txt", root) {
            let raw = try text(root, "optimize_dryrun.txt")
            let preview = MolePreview.parse(raw)
            guard !preview.sections.isEmpty else { throw Failure("no sections parsed") }

            // The actionable count must equal the number of `→` lines that
            // actually sit inside a section. Mole opens its previews with
            // "→ DRY RUN MODE …" using the same glyph, which inflated this by
            // one on every scan until the banner was skipped explicitly.
            let expected = actionLinesInsideSections(raw)
            let counted = preview.sections.map(\.actionable).reduce(0, +)
            guard counted == expected else {
                throw Failure("counted \(counted) actions but the file has \(expected) `→` lines")
            }
            return ["\(preview.sections.count) sections",
                    "\(counted) actions (matches the file)",
                    "headline: \(preview.headline ?? "—")"]
        } && ok

        // The *result* of a real run, not a preview. Different wording
        // ("Applied N" rather than "Would apply N") and mostly ✓ lines, since
        // applied work reports back as already-done. This is the format the
        // panes show after you confirm, and it went untested for far too long.
        ok = check("optimize_run.txt", root) {
            let result = MolePreview.parse(try text(root, "optimize_run.txt"))
            guard !result.sections.isEmpty else { throw Failure("no sections parsed") }
            guard let headline = result.headline, headline.hasPrefix("Applied") else {
                throw Failure("result headline not recognised: \(result.headline ?? "nil")")
            }
            guard result.summary.contains(where: { $0.contains("unchanged") }) else {
                throw Failure("counts line missing from summary")
            }
            return ["\(result.sections.count) sections",
                    "headline: \(headline)",
                    "summary lines: \(result.summary.count)"]
        } && ok

        // A *real* (non --dry-run) clean, captured with MOLE_TEST_MODE=1 so the
        // real code path runs and deletes nothing — verified by the deletions
        // log and cache size being unchanged. Covers the completion footer,
        // which is worded differently from the preview and previously matched
        // none of the headline patterns.
        ok = check("clean_run.txt", root) {
            let result = MolePreview.parse(try text(root, "clean_run.txt"))
            guard let headline = result.headline else {
                throw Failure("real-run completion produced no headline")
            }
            return ["headline: \(headline)",
                    "summary lines: \(result.summary.count)",
                    "sections: \(result.sections.count)"]
        } && ok

        ok = check("purge_dryrun.txt", root) {
            let result = ArtifactList.parsePurge(try text(root, "purge_dryrun.txt"))
            guard !result.items.isEmpty else { throw Failure("no items parsed") }
            guard result.headline != nil else { throw Failure("no 'Would free' headline") }
            guard result.items.allSatisfy({ $0.path?.hasPrefix("/") == true }) else {
                throw Failure("a ~ path was not expanded")
            }
            return ["\(result.items.count) items",
                    "largest: \(result.items[0].name) \(result.items[0].size)",
                    "headline: \(result.headline ?? "—")"]
        } && ok

        ok = check("installer_dryrun.txt", root) {
            let result = ArtifactList.parseInstaller(try text(root, "installer_dryrun.txt"))
            guard !result.items.isEmpty else { throw Failure("no installers parsed") }
            guard result.items.allSatisfy({ $0.location != nil }) else {
                throw Failure("an item lost its location column")
            }
            guard let declared = result.declaredTotal else {
                throw Failure("selector total [n/N] not parsed — truncation would go unnoticed")
            }
            return ["\(result.items.count) of \(declared) installers",
                    "truncated=\(result.isTruncated)",
                    "largest: \(result.items[0].name) \(result.items[0].size)",
                    "sum \(formatBytesDecimal(result.sumBytes))"]
        } && ok

        // The stderr stream from `mo installer --dry-run --debug` — the only
        // place that command gives paths, and therefore the only thing that
        // makes the Installers pane able to delete rather than just list.
        ok = check("installer_debug.txt", root) {
            let result = ArtifactList.parseInstallerDebug(try text(root, "installer_debug.txt"))
            guard !result.items.isEmpty else { throw Failure("no installers parsed") }
            guard result.items.allSatisfy({ $0.path?.hasPrefix("/") == true }) else {
                throw Failure("an item came through without an absolute path — "
                            + "the pane would offer it for deletion with nothing to delete")
            }
            // The selector block clips names to the column width. If these ever
            // start arriving clipped, matching them to a file is guesswork and
            // the delete must not be offered.
            guard result.items.allSatisfy({ !$0.name.hasSuffix("...") && !$0.name.hasSuffix("\u{2026}") }) else {
                throw Failure("a name is truncated — this stream is supposed to be verbatim")
            }
            // Compared against the lines in the file, not against what is still
            // on disk — these .dmg files are exactly what the pane now deletes,
            // so an assertion about their continued existence would fail the
            // first time the feature is used.
            let declared = try text(root, "installer_debug.txt")
                .components(separatedBy: .newlines)
                .filter { $0.contains("Found installer:") }.count
            guard result.items.count == declared else {
                throw Failure("\(declared) lines in the fixture but \(result.items.count) parsed")
            }
            let selector = ArtifactList.parseInstaller(try text(root, "installer_dryrun.txt"))
            let locations = Set(result.items.compactMap(\.location))
            return ["\(result.items.count) installers with full paths "
                  + "(selector page showed \(selector.items.count))",
                    "locations: \(locations.sorted().joined(separator: ", "))",
                    "largest: \(result.items[0].name) \(result.items[0].size)"]
        } && ok

        // Unit check on the size scanner, which every bar width depends on.
        ok = check("byte parsing", root) {
            let cases: [(String, Int64)] = [
                ("79 items, 4.67GB dry", Int64(4.67 * 1_000_000_000)),
                ("163.3MB dry", Int64(163.3 * 1_000_000)),
                ("799KB dry", Int64(799 * 1_000)),
                ("21.00GB \u{00B7} ~/.lmstudio/models", Int64(21 * 1_000_000_000)),
            ]
            for (input, expected) in cases {
                guard let parsed = MolePreview.parseBytes(input) else {
                    throw Failure("failed to parse \"\(input)\"")
                }
                guard abs(parsed - expected) < 1024 * 1024 else {
                    throw Failure("\"\(input)\" → \(parsed), expected ≈\(expected)")
                }
            }
            guard MolePreview.parseBytes("would clean") == nil else {
                throw Failure("\"would clean\" should yield no size")
            }

            // Absurd digit runs must be rejected, not trapped. Double→Int64
            // aborts the process on overflow, and scanning by position means a
            // filename gets examined before the real size.
            for hostile in ["9999999TB", "/tmp/9999999999999999999KB_dump",
                            "\(String(repeating: "9", count: 40))GB"] {
                guard MolePreview.parseBytes(hostile) == nil else {
                    throw Failure("\"\(hostile)\" should be rejected, not converted")
                }
            }
            // Position must beat magnitude: mo purge appends free disk space to
            // its summary, and matching the larger trailing unit reported the
            // whole disk as reclaimable.
            let twoSizes = "Would free: 412.6MB | Items: 12 | Free: 77.67GB"
            guard let first = MolePreview.parseBytes(twoSizes),
                  abs(first - 412_600_000) < 1_000_000 else {
                throw Failure("picked the wrong size out of \"\(twoSizes)\" — got "
                            + "\(MolePreview.parseBytes(twoSizes).map(String.init) ?? "nil")")
            }
            return ["\(cases.count) size strings + the no-size case"]
        } && ok

        // Ordering, on the real clean-list fixture rather than a toy array —
        // every pane's list runs through this one comparator.
        ok = check("sorting", root) {
            let entries = CleanFileList.parse(try text(root, "clean-list.txt"))
                .flatMap(\.entries)
            guard entries.count > 2 else { throw Failure("fixture has too few entries to sort") }

            let name = { (entry: CleanFileList.Entry) in entry.path }
            let bytes = { (entry: CleanFileList.Entry) in entry.bytes ?? 0 }

            let largest = ListSort.sizeDescending.sort(entries, name: name, bytes: bytes)
            let smallest = ListSort.sizeAscending.sort(entries, name: name, bytes: bytes)
            guard zip(largest, largest.dropFirst()).allSatisfy({ bytes($0) >= bytes($1) }) else {
                throw Failure("\"largest first\" is not descending")
            }
            guard zip(smallest, smallest.dropFirst()).allSatisfy({ bytes($0) <= bytes($1) }) else {
                throw Failure("\"smallest first\" is not ascending")
            }
            guard largest.count == entries.count, smallest.count == entries.count else {
                throw Failure("sorting changed the number of rows")
            }
            // Thousands of these files are the same size, so without the
            // name tiebreaker the order would differ run to run — and appear to
            // reshuffle itself every time the pane redrew.
            guard largest.map(name) == ListSort.sizeDescending
                    .sort(entries.reversed(), name: name, bytes: bytes).map(name) else {
                throw Failure("equal sizes do not resolve to a stable order")
            }

            let byName = ListSort.nameAscending.sort(entries, name: name, bytes: bytes)
            guard zip(byName, byName.dropFirst()).allSatisfy({
                name($0).localizedStandardCompare(name($1)) != .orderedDescending
            }) else {
                throw Failure("\"name A–Z\" is not ascending")
            }
            guard ListSort.nameDescending.sort(entries, name: name, bytes: bytes).map(name)
                    == byName.map(name).reversed() else {
                throw Failure("Z–A is not the reverse of A–Z")
            }
            return ["\(entries.count) entries ordered four ways",
                    "largest: \(largest[0].size ?? "—") \(largest[0].path)"]
        } && ok

        // The cache is what stops every pane visit re-running a scan, so a
        // round trip through the real directory is worth a second here.
        ok = check("scan cache", root) {
            let key = "selftest"
            let payload = "➤ Caches\n→ Xcode DerivedData · 4.67GB dry\n"
            ScanCache.save(key, payload)
            guard let entry = ScanCache.load(key) else {
                throw Failure("nothing came back from the cache")
            }
            guard entry.text == payload else { throw Failure("cached text round-tripped wrong") }
            guard abs(entry.date.timeIntervalSinceNow) < 60 else {
                throw Failure("cache timestamp is \(entry.date), not now")
            }
            guard MolePreview.parse(entry.text).sections.count == 1 else {
                throw Failure("cached text no longer parses")
            }
            ScanCache.clear(key)
            guard ScanCache.load(key) == nil else {
                throw Failure("clear() left the entry behind — a deleted scan would come back")
            }
            return ["saved, reparsed and cleared",
                    "age label: \(ScanCache.ageLabel(Date().addingTimeInterval(-4_000)))"]
        } && ok

        // The guard list, which is the only thing standing between a parser bug
        // and a deleted home folder. Checked before anything else about the
        // delete path, and checked exhaustively — every entry here is a path
        // that has appeared in some pane's list at some point.
        ok = check("trash guards", root) {
            let home = NSHomeDirectory()
            let mustRefuse = [
                "/", "/System", "/System/Library/CoreServices", "/Library",
                "/Applications", "/Users", "/Users/Shared", "/usr", "/usr/bin",
                "/bin/zsh", "/etc", "/etc/hosts", "/var", "/tmp", "/private",
                "/dev/null", "/Volumes", "/opt",
                home, home + "/Downloads", home + "/Documents", home + "/Desktop",
                home + "/Library", home + "/Pictures", home + "/Movies",
                home + "/Music", home + "/Public",
                "", "   ", "relative/path", "~/Downloads/thing.dmg", "/Nonexistent",
            ]
            for path in mustRefuse {
                guard Trash.rejection(for: path) != nil else {
                    throw Failure("\"\(path)\" was NOT refused — it would have been trashed")
                }
            }

            // A real file in a real place has to be accepted, or the guard is
            // just an off switch.
            let probe = NSTemporaryDirectory() + "MoleUI-guard-probe.txt"
            try "probe".write(toFile: probe, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: probe) }
            if let reason = Trash.rejection(for: probe) {
                throw Failure("an ordinary temp file was refused: \(reason)")
            }
            // …and a path that used to exist must stop being accepted.
            try FileManager.default.removeItem(atPath: probe)
            guard Trash.rejection(for: probe)?.contains("no longer on disk") == true else {
                throw Failure("a deleted path is still considered trashable")
            }
            return ["\(mustRefuse.count) protected paths refused",
                    "ordinary file accepted, missing file refused"]
        } && ok

        // One real round trip through FileManager.trashItem. Everything above
        // is logic; this is the only check that proves the delete itself works,
        // and it is worth the one small file it leaves in the Trash.
        // Opt-in (`--selftest --trash`): it is the one check with a side
        // effect, a 1KB probe file left in the user's Trash.
        if CommandLine.arguments.contains("--trash") { ok = check("trash round trip", root) {
            let probe = NSTemporaryDirectory()
                + "MoleUI-selftest-trash-probe-\(ProcessInfo.processInfo.processIdentifier).txt"
            try String(repeating: "x", count: 1_024).write(toFile: probe, atomically: true,
                                                           encoding: .utf8)
            let outcome = Trash.recycleSync([Trash.Item(path: probe, bytes: 1_024)])
            guard outcome.trashed == [probe], outcome.failed.isEmpty else {
                throw Failure("recycle reported \(outcome.summary) for one plain file")
            }
            guard !FileManager.default.fileExists(atPath: probe) else {
                throw Failure("the file is still at its original path after being trashed")
            }
            return ["1KB probe moved to the Trash and gone from \(probe)",
                    "summary: \(outcome.summary)"]
        } && ok }

        // Duplicates, on files with a known answer. The decoy shares the size and
        // the first and last 16KB with the real pair, so only the full-hash
        // stage can tell it apart; the hard link is the same file under a
        // second name and must not count as a copy.
        ok = check("duplicate detection", root) {
            let dir = NSTemporaryDirectory() + "moleui-dup-\(ProcessInfo.processInfo.processIdentifier)"
            let fm = FileManager.default
            try fm.createDirectory(atPath: dir + "/a", withIntermediateDirectories: true)
            try fm.createDirectory(atPath: dir + "/b", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: dir) }

            var bytes = [UInt8](repeating: 0, count: 2_000_000)
            for index in bytes.indices { bytes[index] = UInt8((index * 31 + 7) % 251) }
            let original = Data(bytes)
            var decoy = bytes
            decoy[1_000_000] ^= 0xFF                       // differs only in the middle
            var other = bytes
            other[0] ^= 0xFF

            try original.write(to: URL(fileURLWithPath: dir + "/a/movie.mov"))
            try original.write(to: URL(fileURLWithPath: dir + "/b/movie copy.mov"))
            try Data(decoy).write(to: URL(fileURLWithPath: dir + "/b/decoy.mov"))
            try Data(other).write(to: URL(fileURLWithPath: dir + "/a/other.mov"))
            try fm.linkItem(atPath: dir + "/a/movie.mov", toPath: dir + "/a/hardlink.mov")

            let semaphore = DispatchSemaphore(value: 0)
            var outcome: Result<[(digest: String, copies: [Features.Candidate])], Error> = .success([])
            Task.detached {
                do { outcome = .success(try await Features.findDuplicates(in: [dir], minimum: 1_000_000).groups) }
                catch { outcome = .failure(error) }
                semaphore.signal()
            }
            semaphore.wait()
            let groups = try outcome.get()
            guard groups.count == 1 else { throw Failure("expected 1 duplicate set, found \(groups.count)") }
            let names = Set(groups[0].copies.map { ($0.path as NSString).lastPathComponent })
            guard names == ["movie.mov", "movie copy.mov"] || names == ["hardlink.mov", "movie copy.mov"] else {
                throw Failure("wrong files grouped: \(names.sorted())")
            }
            guard groups[0].copies.count == 2 else {
                throw Failure("the hard link was counted as a separate copy")
            }

            // The selection rules on top: never every copy, auto-select keeps one.
            let rows = groups[0].copies.map { Finding(id: $0.path, title: "", paths: [$0.path],
                                                      date: $0.created, info: ["hash": groups[0].digest]) }
            let feature = Features.duplicates
            guard feature.validate?(rows, Set(rows.map(\.id))) != nil else {
                throw Failure("selecting every copy was allowed")
            }
            let picked = feature.autoSelect?.pick(rows) ?? []
            guard picked.count == 1, feature.validate?(rows, picked) == nil else {
                throw Failure("auto-select should pick exactly the one extra copy")
            }
            return ["identical pair found; decoy and hard link rejected",
                    "remove-every-copy refused; auto-select keeps one"]
        } && ok

        print(ok ? "\nAll fixtures decoded." : "\nFAILURES above.")
        return ok
    }

    // MARK: -

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func check(_ name: String, _ root: URL,
                              _ body: () throws -> [String]) -> Bool {
        do {
            let lines = try body()
            print("  ok  \(name)")
            for line in lines { print("        \(line)") }
            return true
        } catch {
            // localizedDescription on a DecodingError says only "the data is
            // missing" — useless for finding which key drifted.
            print("  FAIL \(name): \(describe(error))")
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case let .keyNotFound(key, context):
            return "missing key \"\(key.stringValue)\" at \(path(context).isEmpty ? "<root>" : path(context))"
        case let .typeMismatch(type, context):
            return "expected \(type) at \(path(context))"
        case let .valueNotFound(type, context):
            return "null \(type) at \(path(context))"
        case let .dataCorrupted(context):
            return "corrupt data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return decoding.localizedDescription
        }
    }

    /// Counts the `→` lines the parser should treat as actions: every one that
    /// opens a line, except the "DRY RUN MODE" banner. Lines before the first
    /// `➤` count too — the parser files them under an implicit "Before
    /// scanning" section on purpose, and Mole 1.62 added one there ("Would
    /// offer detach for 1 mounted image(s)") that an after-the-first-header
    /// count missed.
    private static func actionLinesInsideSections(_ raw: String) -> Int {
        raw.components(separatedBy: .newlines)
            .map { MoleCLI.stripANSI($0).trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("\u{2192}") && !$0.contains("DRY RUN MODE") }
            .count
    }

    private static func text(_ root: URL, _ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ root: URL, _ name: String) throws -> T {
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Works from `swift run` (cwd = package root) and from inside the bundle.
    private static func fixturesDirectory() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("fixtures")
        if FileManager.default.fileExists(atPath: cwd.path) { return cwd }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("MoleUI/fixtures")
    }
}
