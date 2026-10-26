import SwiftUI
import AppKit

@MainActor
final class CleanModel: ObservableObject {
    enum Phase: Equatable {
        case idle, scanning, previewed, cleaning, finished
    }

    @Published var phase: Phase = .idle
    @Published var preview: MolePreview.Result?
    @Published var categories: [CleanFileList.Category] = []
    @Published var selectedCategory: CleanFileList.Category.ID?
    @Published var resultSummary: [String] = []
    @Published var error: String?
    @Published var confirming = false
    /// When the displayed scan was taken. Non-nil for a restored one too — the
    /// pane has to be able to say "this is 40 minutes old".
    @Published var scannedAt: Date?

    @Published var sort: ListSort = .stored("clean") {
        didSet {
            sort.store("clean")
            applySort()
        }
    }

    /// Sections, categories and per-file paths in the chosen order. Sorted here
    /// and stored, not computed in `body`: one category holds tens of thousands
    /// of paths, and re-sorting that on every re-render — selecting a chip, or
    /// just the sidebar's live CPU readout ticking — would stall the main
    /// thread twice a second.
    @Published private(set) var sortedSections: [MolePreview.Section] = []
    @Published private(set) var sortedCategories: [CleanFileList.Category] = []

    /// path → bytes across every category, for sizing a selection that spans
    /// more than one. Built once per scan rather than per render: this list runs
    /// to tens of thousands of paths, and rebuilding the dictionary on every
    /// checkbox click would cost more than the click.
    @Published private(set) var weights: [String: Int64] = [:]

    var totalBytes: Int64? { preview?.totalBytes }

    /// The exact wording of Mole's own headline, shown verbatim rather than
    /// recomputed. See MolePreview.Result.totalBytes for why.
    var headline: String { preview?.headline ?? "" }

    func scan() async {
        phase = .scanning
        error = nil
        resultSummary = []
        do {
            let output = try await MoleCLI.shared.run(["clean", "--dry-run"])
            let parsed = MolePreview.parse(output.stdout)
            // Only read the file list when *this* run said it wrote one. Falling
            // back to the default path meant a scan that produced no list (mole
            // skips writing when nothing was found) silently displayed a previous
            // run's paths under "Files to be removed", complete with a file
            // count, indistinguishable from a fresh list.
            let listText = parsed.detailListPath.flatMap {
                try? String(contentsOfFile: $0, encoding: .utf8)
            }
            adopt(parsed, fileList: listText, at: Date())

            ScanCache.save(ScanCache.Key.cleanPreview, output.stdout)
            if let listText {
                ScanCache.save(ScanCache.Key.cleanFileList, listText)
            } else {
                ScanCache.clear(ScanCache.Key.cleanFileList)
            }
        } catch {
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    /// Show the last scan instead of running a new one. Returns false when there
    /// is nothing usable cached, leaving the pane in its normal idle state.
    @discardableResult
    func restore() -> Bool {
        guard phase == .idle,
              let cached = ScanCache.load(ScanCache.Key.cleanPreview) else { return false }
        let parsed = MolePreview.parse(cached.text)
        // A cache that parses to nothing is worse than none: it would show an
        // empty "0 targets" preview that looks like a machine with nothing to
        // clean. Fall through to a real scan instead.
        guard !parsed.sections.isEmpty else { return false }

        // The file list comes from our own snapshot, never re-read from
        // ~/.config/mole/clean-list.txt: any later `mo` run — this app's or one
        // in a terminal — overwrites that file in place, and pairing a newer
        // list with an older summary would show paths the headline never counted.
        adopt(parsed,
              fileList: ScanCache.load(ScanCache.Key.cleanFileList)?.text,
              at: cached.date)
        return true
    }

    private func adopt(_ parsed: MolePreview.Result, fileList: String?, at date: Date) {
        preview = parsed
        categories = fileList.map(CleanFileList.parse) ?? []
        selectedCategory = categories.max(by: { $0.bytes < $1.bytes })?.id
        scannedAt = date
        applySort()
        phase = .previewed
    }

    /// A trash operation removes files the cached preview still counts, so the
    /// figures on screen are now high by however much went. The next visit
    /// measures again rather than restoring a total that is no longer true.
    func invalidateCache() {
        ScanCache.clear(ScanCache.Key.cleanPreview, ScanCache.Key.cleanFileList)
        scannedAt = nil
    }

    private func applySort() {
        weights = Dictionary(categories.flatMap(\.entries).map { ($0.path, $0.bytes ?? 0) },
                             uniquingKeysWith: { first, _ in first })

        sortedSections = sort.sort(preview?.sections ?? [],
                                   name: { $0.title },
                                   bytes: { $0.bytes })

        // Category.bytes sums its entries, so it is measured once per category
        // up front rather than inside the comparator, which would re-walk every
        // path in the list on each of the O(n log n) comparisons.
        let weights = Dictionary(categories.map { ($0.id, $0.bytes) },
                                 uniquingKeysWith: { first, _ in first })
        sortedCategories = sort
            .sort(categories, name: { $0.name }, bytes: { weights[$0.id] ?? 0 })
            .map { category in
                var sorted = category
                sorted.entries = sort.sort(category.entries,
                                           name: { $0.path },
                                           bytes: { $0.bytes ?? 0 })
                return sorted
            }
    }

    func clean() async {
        confirming = false
        phase = .cleaning
        do {
            let output = try await MoleCLI.shared.run(["clean"])
            let parsed = MolePreview.parse(output.stdout)
            // Headline first — it is the one line that states the outcome
            // ("Tracked cleanup: 1.2GB | Items cleaned: 340"). The remaining
            // footer lines (free space, the 4K-movie comparison) follow it.
            resultSummary = ([parsed.headline].compactMap { $0 }
                             + parsed.summary.filter { $0 != parsed.headline })
            if resultSummary.isEmpty {
                // Nothing matched: show the footer verbatim rather than an empty
                // "Cleanup complete" card that says nothing about what happened.
                resultSummary = output.stdout
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.contains("clean") || $0.contains("freed") || $0.contains("Free") }
                    .suffix(4)
                    .map { $0 }
            }
            // The cached preview described files that are now gone. Keeping it
            // would mean the next visit to this pane restored a stale total and
            // a list of deleted paths, with a Clean button armed behind it.
            ScanCache.clear(ScanCache.Key.cleanPreview, ScanCache.Key.cleanFileList)
            preview = nil
            categories = []
            scannedAt = nil
            applySort()
            phase = .finished
        } catch {
            self.error = error.localizedDescription
            phase = .previewed
        }
    }
}

struct CleanView: View {
    @StateObject private var model = CleanModel()
    @StateObject private var trash = TrashController()
    @EnvironmentObject private var router: Router

    var body: some View {
        PaneScaffold(title: Pane.clean.title, subtitle: Pane.clean.subtitle) {
            if model.phase == .previewed, let scannedAt = model.scannedAt {
                ScanAge(date: scannedAt)
            }
            if model.phase == .previewed {
                SortMenu(order: $model.sort)
            }
            if model.phase == .previewed || model.phase == .finished {
                GhostButton(title: "Rescan", systemImage: "arrow.clockwise") {
                    trash.reset()
                    Task { await model.scan() }
                }
            }
            if model.phase == .previewed, trash.count == 0,
               let total = model.totalBytes, total > 0 {
                ActionButton(title: "Clean \(formatBytesDecimal(total))",
                             systemImage: "sparkles",
                             destructive: true) { model.confirming = true }
            }
            // Two destructive buttons side by side, one permanent and one
            // recoverable, is a mis-click waiting to happen — so ticking a file
            // swaps "Clean everything" out for "Move these to the Trash".
            if model.phase == .previewed {
                TrashBar(controller: trash, bytes: trash.bytes(model.weights))
            }
        } content: {
            // The trash confirmation hangs off the content, not off the same
            // view as the `mo clean` one below. Two `.sheet(isPresented:)`
            // modifiers on a single view is one presentation slot with two
            // claimants, and only one of them ends up working.
            content
                .sheet(isPresented: $trash.confirming) {
                    TrashConfirmSheet(
                        count: trash.count,
                        bytes: trash.bytes(model.weights),
                        sample: trash.sample(),
                        what: "file",
                        onConfirm: {
                            Task {
                                let moved = await trash.run(weights: model.weights)
                                if !moved.isEmpty { model.invalidateCache() }
                            }
                        },
                        onCancel: { trash.confirming = false }
                    )
                }
        }
        .task {
            // Consumed unconditionally: leaving the flag set would make some
            // later, unrelated visit to this pane start a scan on its own.
            let autoscanRequested = router.consumeAutoscan()
            guard model.phase == .idle else { return }
            // A cached scan is the fast path in and covers the autoscan request
            // too — the menu bar's Clean shortcut wants the numbers on screen,
            // not specifically a fresh measurement.
            guard !model.restore(), autoscanRequested else { return }
            await model.scan()
        }
        .sheet(isPresented: $model.confirming) {
            ConfirmSheet(
                title: "Delete these files?",
                summary: model.headline.isEmpty
                    ? "Run cleanup" : model.headline,
                detail: "Files go straight to deletion, not the Trash. "
                      + "This runs `mo clean` non-interactively, so this dialog is the "
                      + "only confirmation step. System caches are excluded unless a sudo "
                      + "session is already active."
                      // The preview can be restored from cache, so the figure
                      // above is not necessarily one this session measured.
                      // Whatever its age, mole re-measures when it runs.
                      + (model.scannedAt.map {
                            "\n\nThis preview was taken \(ScanCache.ageLabel($0)); "
                          + "mo measures again when it runs, so the amount freed may differ."
                        } ?? ""),
                confirmTitle: "Clean now",
                onConfirm: { Task { await model.clean() } },
                onCancel: { model.confirming = false }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            StateMessage(
                icon: "sparkles",
                title: "Preview a cleanup",
                message: model.error
                    ?? "Runs `mo clean --dry-run` and shows every file it would remove, "
                     + "grouped by category. Nothing is deleted until you confirm.",
                tint: model.error == nil ? Mole.textFaint : Mole.amber,
                action: (title: "Scan", run: { Task { await model.scan() } })
            )

        case .scanning:
            StateMessage(icon: "hourglass", title: "Scanning caches…",
                         message: "Measuring every cache directory. This takes a minute or two "
                                + "on a full disk.")

        case .cleaning:
            StateMessage(icon: "sparkles", title: "Cleaning…",
                         message: "Running mo clean.", tint: Mole.brand)

        case .finished:
            VStack(spacing: 14) {
                StateMessage(icon: "checkmark.seal", title: "Cleanup complete",
                             tint: Mole.moss)
                if !model.resultSummary.isEmpty {
                    Card(title: "Result") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.resultSummary, id: \.self) { line in
                                Text(line)
                                    .font(Mole.mono(11))
                                    .foregroundStyle(Mole.text)
                            }
                        }
                    }
                    .frame(maxWidth: 480)
                }
                Spacer()
            }
            .padding(.horizontal, 22)

        case .previewed:
            previewContent
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let preview = model.preview {
            VStack(spacing: 12) {
                headerCard(preview)

                if let outcome = trash.result {
                    TrashResultNotice(outcome: outcome)
                }

                HStack(alignment: .top, spacing: 12) {
                    sectionsCard(preview)
                        .frame(width: 380)
                    filesCard
                }
                .scrollableCardContent()
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    private func headerCard(_ preview: MolePreview.Result) -> some View {
        VStack(spacing: 10) {
            Card {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RECLAIMABLE")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Mole.textDim)
                        Text(preview.totalBytes.map { formatBytesDecimal($0) } ?? "—")
                            .font(Mole.mono(30, weight: .medium))
                            .foregroundStyle(Mole.amber)
                    }

                    Divider().frame(height: 34).overlay(Mole.border)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(preview.headline ?? "")
                            .font(Mole.mono(11))
                            .foregroundStyle(Mole.textDim)
                        Text("\(preview.sections.map(\.actionable).reduce(0,+)) targets across "
                           + "\(preview.sections.filter { !$0.isClear }.count) categories")
                            .font(.system(size: 11))
                            .foregroundStyle(Mole.textFaint)
                    }
                    Spacer()
                }
            }

            if preview.needsSudo {
                Notice(
                    icon: "lock",
                    text: "System caches were skipped — they need an active sudo session. "
                        + "Run `sudo -v` in Terminal (or enable `mo touchid`) and rescan to include them.",
                    trailing: AnyView(
                        GhostButton(title: "Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("sudo -v && mo clean --dry-run",
                                                           forType: .string)
                        }
                    )
                )
            }
        }
    }

    private func sectionsCard(_ preview: MolePreview.Result) -> some View {
        Card(title: "Categories", trailing: "from mo clean --dry-run") {
            // A ScrollView's ideal height is its *content* height, so without
            // this it reports thousands of points, inflates the Card, and
            // pushes the pane header (and the split view's sidebar) off-screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.sortedSections) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(section.title)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(section.isClear ? Mole.textFaint : Mole.text)
                                Spacer()
                                if section.bytes > 0 {
                                    Text(formatBytesDecimal(section.bytes))
                                        .font(Mole.mono(10))
                                        .monospacedDigit()
                                        .foregroundStyle(Mole.amber)
                                }
                            }

                            ForEach(section.items) { item in
                                itemRow(item, sectionMax: preview.sectionSum)
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .scrollableCardContent()
        }
    }

    private func itemRow(_ item: MolePreview.Item, sectionMax: Int64) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: glyph(item.kind))
                .font(.system(size: 9))
                .foregroundStyle(color(item.kind))
                .frame(width: 11)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.system(size: 11))
                    .foregroundStyle(item.kind == .action ? Mole.text : Mole.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                if let bytes = item.bytes, item.kind == .action, sectionMax > 0 {
                    StratumBar(fraction: Double(bytes) / Double(sectionMax),
                               color: Mole.amber, height: 3)
                }
            }

            Spacer(minLength: 4)

            if let detail = item.detail {
                Text(detail.replacingOccurrences(of: " dry", with: ""))
                    .font(Mole.mono(9.5))
                    .foregroundStyle(Mole.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 130, alignment: .trailing)
            }
        }
    }

    private func glyph(_ kind: MolePreview.Kind) -> String {
        switch kind {
        case .action:  return "arrow.right"
        case .clear:   return "checkmark"
        case .skipped: return "minus.circle"
        case .note:    return "info.circle"
        case .unknown: return "circle"
        }
    }

    private func color(_ kind: MolePreview.Kind) -> Color {
        switch kind {
        case .action:  return Mole.amber
        case .clear:   return Mole.moss
        case .skipped: return Mole.textFaint
        case .note:    return Mole.brand
        case .unknown: return Mole.textFaint
        }
    }

    /// The per-file drill-down. `mo clean --dry-run` writes every exact path it
    /// would remove to ~/.config/mole/clean-list.txt — the terminal UI only ever
    /// shows the rolled-up totals, so this is strictly more than the CLI offers
    /// before you commit.
    private var filesCard: some View {
        Card(title: "Files to be removed",
             trailing: model.categories.isEmpty ? nil : "\(totalFiles) files") {
            if model.categories.isEmpty {
                Text("No detailed file list was written for this scan.")
                    .font(.system(size: 11))
                    .foregroundStyle(Mole.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Category chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.sortedCategories) { category in
                                chip(category)
                            }
                        }
                    }

                    Divider().overlay(Mole.border)

                    if let category = model.sortedCategories.first(where: { $0.id == model.selectedCategory }) {
                        ScrollView {
                            // Lazy, not a plain VStack: with Full Disk Access a
                            // single category runs to tens of thousands of
                            // paths, and instantiating every row at once wedges
                            // the main thread.
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(category.entries.filter {
                                    !trash.removed.contains($0.path)
                                }) { entry in
                                    fileRow(entry)
                                }
                            }
                        }
                        .scrollableCardContent()
                    }
                }
            }
        }
    }

    /// One path from clean-list.txt. Ticking it moves that single file to the
    /// Trash — which is deliberately *not* what the "Clean" button does: that
    /// runs `mo clean`, and mole deletes outright.
    private func fileRow(_ entry: CleanFileList.Entry) -> some View {
        let blocked = Trash.rejection(for: entry.path)
        let selected = trash.isSelected(entry.path)

        return HStack(spacing: 8) {
            Button { trash.toggle(entry.path) } label: {
                SelectBox(selected: selected, blocked: blocked != nil)
            }
            .buttonStyle(.plain)
            .disabled(blocked != nil)
            .help(blocked ?? "Select for the Trash")

            Text(shorten(entry.path))
                .font(Mole.mono(10.5))
                .foregroundStyle(Mole.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.path)
            Spacer(minLength: 8)
            Text(entry.size ?? "")
                .font(Mole.mono(10))
                .monospacedDigit()
                .foregroundStyle(Mole.textFaint)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(selected ? Mole.danger.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func chip(_ category: CleanFileList.Category) -> some View {
        let selected = category.id == model.selectedCategory
        return Button {
            model.selectedCategory = category.id
        } label: {
            HStack(spacing: 5) {
                Text(category.name)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                Text(formatBytesDecimal(category.bytes))
                    .font(Mole.mono(9.5))
                    .foregroundStyle(selected ? Mole.amber : Mole.textFaint)
            }
            .foregroundStyle(selected ? Mole.text : Mole.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Mole.surfaceHigh : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Mole.amber.opacity(0.4) : Mole.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var totalFiles: Int {
        model.categories.map(\.entries.count).reduce(0, +)
    }

    /// Collapse the home prefix so paths stay readable in a narrow column.
    private func shorten(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory())
            ? "~" + path.dropFirst(NSHomeDirectory().count)
            : path
    }
}
