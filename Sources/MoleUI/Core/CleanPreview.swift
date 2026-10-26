import Foundation

/// Parser for the text previews (`mo clean --dry-run`, `mo optimize --dry-run`).
/// These two are the only commands with no JSON mode, so their pretty output is
/// the interface. NO_COLOR=1 keeps ANSI escapes out; the leading glyphs below
/// are literal UTF-8 in the output, not styling.
enum MolePreview {

    /// The glyph that opens each line is Mole's own status vocabulary.
    enum Kind {
        case action      // → something will happen
        case clear       // ✓ nothing to do
        case skipped     // ◎ deliberately not touched
        case note        // ⊙ informational
        case unknown

        init(glyph: Character) {
            switch glyph {
            case "\u{2192}": self = .action     // →
            case "\u{2713}": self = .clear      // ✓
            case "\u{25CE}": self = .skipped    // ◎
            case "\u{2299}": self = .note       // ⊙
            default: self = .unknown
            }
        }
    }

    struct Item: Identifiable {
        let id = UUID()
        var kind: Kind
        var label: String
        var detail: String?    // "79 items, 4.67GB dry" or a path
        var bytes: Int64?      // parsed out of detail, for proportional bars
    }

    struct Section: Identifiable {
        let id = UUID()
        var title: String
        var items: [Item]
        /// Only `.action` items count — a `⊙` note like "LM Studio models ·
        /// 21.00GB" is telling you something is big, not that it will be
        /// deleted. Summing notes overstated the total by 21GB.
        var bytes: Int64 {
            items.filter { $0.kind == .action }.compactMap(\.bytes).reduce(0, +)
        }
        /// `allSatisfy` is vacuously true on an empty collection, so a section
        /// whose lines were all unrecognised rendered as a confident
        /// "Nothing to clean" — the one output that should never be inferred
        /// from a parse failure. An empty section is unknown, not clear.
        var isClear: Bool { !items.isEmpty && items.allSatisfy { $0.kind == .clear } }
        var actionable: Int { items.filter { $0.kind == .action }.count }
    }

    struct Result {
        var sections: [Section] = []
        var summary: [String] = []      // the lines inside the ==== footer
        var headline: String?           // "Potential space: 12.41GB | Items: 656 …"
        var detailListPath: String?     // ~/.config/mole/clean-list.txt
        var needsSudo = false           // system caches were skipped for lack of sudo

        /// **The** total, taken from Mole's own summary line. Never sum the
        /// sections for this: Mole deduplicates paths that appear under more
        /// than one category before totalling (`emit_deduplicated_dry_run_ledger`
        /// in bin/clean.sh), so adding the sections up double-counts.
        var totalBytes: Int64? { headline.flatMap(parseBytes) }

        /// Section sum — for bar proportions within the list only, never shown
        /// as a figure.
        var sectionSum: Int64 { sections.map(\.bytes).reduce(0, +) }
    }

    private static let sectionGlyph: Character = "\u{27A4}"   // ➤

    static func parse(_ rawText: String) -> Result {
        let text = MoleCLI.stripANSI(rawText)
        var result = Result()
        var current: Section?
        var inFooter = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("====") {
                inFooter.toggle()
                continue
            }

            if line.contains("System caches need sudo") {
                result.needsSudo = true
                continue
            }

            // "→ DRY RUN MODE, No files will be modified" opens clean, optimize
            // and purge. Mole's ICON_DRY_RUN is U+2192 — the very same glyph as
            // an action item — so this banner was being counted as pending work,
            // inflating the actionable totals by one on every preview.
            if line.contains("DRY RUN MODE") { continue }

            if inFooter {
                // "Tracked cleanup:" is what a *real* `mo clean` prints on
                // completion (bin/clean.sh, summary_line) — the preview says
                // "Potential space:" and the two were never the same string.
                // Without it the Clean pane's result had no headline at all and
                // fell back to raw summary lines.
                if line.hasPrefix("Potential space:") || line.hasPrefix("Tracked cleanup:")
                    || line.hasPrefix("Would apply") || line.hasPrefix("Applied")
                    || line.hasPrefix("Would free:") || line.hasPrefix("Test mode") {
                    result.headline = line
                }
                if let path = line.range(of: "Detailed file list: ") {
                    result.detailListPath = String(line[path.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                result.summary.append(line)
                continue
            }

            guard let glyph = line.first else { continue }

            if glyph == sectionGlyph {
                if let current { result.sections.append(current) }
                current = Section(title: String(line.dropFirst()).trimmingCharacters(in: .whitespaces),
                                  items: [])
                continue
            }

            let kind = Kind(glyph: glyph)
            guard kind != .unknown else { continue }

            // Mole emits status lines before the first `➤` — the sudo notice,
            // the whitelist summary, `mo optimize`'s PERFORMANCE DIAGNOSIS.
            // Requiring an open section dropped every one of them silently.
            // An implicit leading section keeps them instead of losing them.
            if current == nil {
                current = Section(title: "Before scanning", items: [])
            }

            let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)

            // Split on the LAST " · ", not the first. The separator appears
            // inside labels too — `mo optimize` emits lines such as
            // "Login Items · 3 disabled · 128KB", where taking the first
            // component threw away the middle. Keeping everything up to the
            // final separator as the label preserves the whole description, and
            // the size is what the trailing component actually carries.
            let separator = " \u{00B7} "
            let label: String
            let detail: String?
            if let split = body.range(of: separator, options: .backwards) {
                label = String(body[..<split.lowerBound])
                detail = String(body[split.upperBound...])
            } else {
                label = body
                detail = nil
            }

            // Fall back to the label for a size when the detail has none:
            // "Application Support logs/caches · 44.4MB" puts it in the detail,
            // but "Crashlytics data 238KB" style lines put it in the label.
            current?.items.append(Item(kind: kind,
                                       label: label,
                                       detail: detail,
                                       bytes: detail.flatMap(parseBytes) ?? parseBytes(label)))
        }
        if let current { result.sections.append(current) }
        return result
    }

    /// Pulls the **first size by position** out of strings like
    /// "79 items, 4.67GB dry", "163.3MB dry", "21.00GB · ~/.lmstudio/models".
    ///
    /// Two things here were wrong and both produced visibly wrong numbers.
    ///
    /// *Units are decimal.* Mole is bash, and its formatter `bytes_to_human()`
    /// (lib/core/base.sh) branches on 1e9 / 1e6 / 1e3. The old code used 1024
    /// multipliers and cited a Go file that does not exist in this tool.
    ///
    /// *Position beats magnitude.* The old code tried TB, then GB, then MB, then
    /// KB, returning the first *unit* it found anywhere — not the first *size*.
    /// `mo purge` always appends free disk space to its summary
    /// ("Would free: 412.6MB | Items: 12 | Free: 77.67GB"), so a sub-gigabyte
    /// result matched the trailing "GB" and the pane reported 77.7GB as
    /// reclaimable. Scanning left to right is the whole fix.
    static func parseBytes(_ text: String) -> Int64? {
        let units: [(String, Double)] = [
            ("TB", 1_000_000_000_000), ("GB", 1_000_000_000),
            ("MB", 1_000_000), ("KB", 1_000),
        ]
        let scanner = text as NSString

        var best: (location: Int, value: Int64)?
        for (suffix, multiplier) in units {
            let range = scanner.range(of: suffix)
            guard range.location != NSNotFound else { continue }

            // Walk backwards over the numeric literal preceding the unit.
            var start = range.location
            while start > 0 {
                let ch = scanner.character(at: start - 1)
                let isDigitOrDot = (ch >= 48 && ch <= 57) || ch == 46
                if !isDigitOrDot { break }
                start -= 1
            }
            guard start < range.location else { continue }
            let numeric = scanner.substring(with: NSRange(location: start,
                                                          length: range.location - start))
            // A path or app name can put a huge digit run in front of a unit
            // ("…/9999999999999999999KB_dump"), and Double→Int64 *traps* rather
            // than saturating — that aborts the whole app. Scanning by position
            // rather than by magnitude made this more reachable, not less, since
            // a filename now gets looked at before the real size. An absurd
            // value is garbage either way, so drop it instead of crashing.
            //
            // .rounded() matters: Int64(exactly:) rejects non-integral Doubles,
            // and 163.3 * 1e6 is 163300000.00000003, so without it every normal
            // MB figure would parse as nil.
            guard let value = Double(numeric),
                  let bytes = Int64(exactly: (value * multiplier).rounded()) else { continue }
            if start < (best?.location ?? Int.max) {
                best = (start, bytes)
            }
        }
        return best?.value
    }
}

/// The per-file breakdown `mo clean --dry-run` writes alongside its summary.
/// Richer than the pretty output: every exact path with its own size, grouped by
/// category — which is what makes a real "here is precisely what will be
/// deleted" review possible before confirming.
enum CleanFileList {

    struct Entry: Identifiable {
        let id = UUID()
        var path: String
        var size: String?
        var bytes: Int64?
    }

    struct Category: Identifiable {
        let id = UUID()
        var name: String
        var entries: [Entry]
        var bytes: Int64 { entries.compactMap(\.bytes).reduce(0, +) }
    }

    /// Only `parse` — there is deliberately no `load(from:)` helper any more.
    /// The Clean pane reads the list once, at the path *that scan* reported, and
    /// snapshots the text into `ScanCache`; a convenience loader that re-reads
    /// ~/.config/mole/clean-list.txt later would silently pair a newer file with
    /// an older summary, since every `mo` run overwrites it in place.
    static func parse(_ text: String) -> [Category] {
        var categories: [Category] = []
        var current: Category?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("=== "), line.hasSuffix(" ===") {
                if let current { categories.append(current) }
                let name = line.dropFirst(4).dropLast(4)
                current = Category(name: String(name), entries: [])
                continue
            }
            // Everything else starting with # is header or the summary block.
            guard !line.hasPrefix("#") else { continue }

            // "/some/path  # 2.4MB" — the size comment is optional.
            if let hash = line.range(of: "  # ", options: .backwards) {
                let path = String(line[..<hash.lowerBound])
                let size = String(line[hash.upperBound...])
                current?.entries.append(Entry(path: path,
                                              size: size,
                                              bytes: MolePreview.parseBytes(size)))
            } else {
                current?.entries.append(Entry(path: line, size: nil, bytes: nil))
            }
        }
        if let current { categories.append(current) }
        return categories
    }
}
