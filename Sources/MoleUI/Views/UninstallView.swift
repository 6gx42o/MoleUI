import SwiftUI
import AppKit

@MainActor
final class UninstallModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    /// Keyed on `path`, which is `InstalledApp.id` and actually unique.
    /// Keying on `uninstall_name` meant duplicates collapsed: this machine has
    /// three distinct ChatGPT bundles sharing that name, so ticking one row
    /// checked all three, `selectedApps` returned three apps for one entry, and
    /// the confirm sheet counted wrong.
    @Published var selection: Set<String> = []
    @Published var search = ""
    @Published var plan: UninstallPlan.Result?
    @Published var loading = false
    @Published var previewing = false
    @Published var removing = false
    @Published var confirming = false
    @Published var error: String?
    @Published var lastResult: String?
    /// When the displayed list was measured — it can come from the cache, so
    /// the pane says how old it is rather than implying it is live.
    @Published var scannedAt: Date?

    @Published var sort: ListSort = .stored("uninstall") {
        didSet { sort.store("uninstall") }
    }

    /// path → bytes, parsed once from the pre-formatted `size` string mole
    /// hands back ("1.2GB"). Re-parsing inside the comparator would run four
    /// substring searches per comparison, on every keystroke in the filter.
    private var sizes: [String: Int64] = [:]

    /// Unused Apps lives here as a filter rather than as its own section: it is
    /// the same list and the same uninstall, just narrowed down.
    @Published var unusedOnly = false
    @Published private(set) var lastUsed: [String: Date] = [:]
    @Published private(set) var unused: Set<String> = []

    var filtered: [InstalledApp] {
        let pool = unusedOnly ? apps.filter { unused.contains($0.path) } : apps
        let matches = search.isEmpty ? pool : pool.filter {
            $0.name.localizedCaseInsensitiveContains(search)
            || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
        return sort.sort(matches, name: { $0.name }, bytes: { sizes[$0.path] ?? 0 })
    }

    var selectedApps: [InstalledApp] {
        apps.filter { selection.contains($0.path) }
    }

    /// Second gate on the same rule `toggle` enforces, applied where the
    /// arguments are actually built — so no future path into `selection` can
    /// route a flag-shaped name into an uninstall command. Deduplicated,
    /// because several bundles can share one uninstall name and passing it
    /// twice is meaningless.
    var safeSelection: [String] {
        Set(selectedApps.map(\.uninstallName))
            .filter(UninstallPlan.isSafeName)
            .sorted()
    }

    /// True when the selection contains bundles that share an uninstall name.
    /// `mo uninstall <name>` cannot distinguish them, so the UI says so rather
    /// than letting the user believe they picked one specific copy.
    var hasAmbiguousNames: Bool {
        Set(selectedApps.map(\.uninstallName)).count != selectedApps.count
    }

    func load() async {
        guard apps.isEmpty else { return }

        // Measuring every bundle in /Applications takes long enough to notice,
        // and this pane's model is rebuilt each time the sidebar comes back to
        // it. Show the last list first; the Rescan button is right there.
        if let cached = ScanCache.load(ScanCache.Key.apps) {
            do {
                try adopt(cached.text, at: cached.date)
                return
            } catch {
                // Written by an older build whose fields no longer decode.
                ScanCache.clear(ScanCache.Key.apps)
            }
        }

        loading = true
        defer { loading = false }
        do {
            // `run` rather than `installedApps()`: the raw JSON is what gets
            // cached, so it has to be in hand here.
            let output = try await MoleCLI.shared.run(["uninstall", "--list"])
            try adopt(output.stdout, at: Date())
            ScanCache.save(ScanCache.Key.apps, output.stdout)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Re-measure from scratch. Selections survive — a rescan is a refresh, not
    /// a reset — and anything that has since disappeared simply stops matching.
    func rescan() async {
        ScanCache.clear(ScanCache.Key.apps)
        apps = []
        await load()
    }

    private func adopt(_ json: String, at date: Date) throws {
        let decoded = try MoleCLI.decodeJSON([InstalledApp].self, json,
                                             command: "uninstall --list")
        apps = decoded
        sizes = Dictionary(decoded.map { ($0.path, MolePreview.parseBytes($0.size) ?? 0) },
                           uniquingKeysWith: { first, _ in first })
        scannedAt = date
        error = nil
        Task { await measureUsage() }
    }

    /// Last-used dates for every app, off the main thread — about 0.1s for a
    /// hundred apps, so the list appears first and the dates fill in.
    private func measureUsage() async {
        let paths = apps.map(\.path)
        let cutoff = Date().addingTimeInterval(-TimeInterval(Prefs.int(Prefs.unusedDays, 90)) * 86_400)
        let results = await Task.detached(priority: .userInitiated) {
            paths.map { ($0, Features.usage(ofAppAt: $0, cutoff: cutoff)) }
        }.value
        lastUsed = Dictionary(results.compactMap { path, usage in usage.lastUsed.map { (path, $0) } },
                              uniquingKeysWith: { first, _ in first })
        unused = Set(results.filter { $0.1.unused }.map(\.0))
    }

    func toggle(_ app: InstalledApp) {
        // Any change invalidates the plan — never let a stale preview back a
        // confirmation for a different set of apps.
        plan = nil
        lastResult = nil
        if selection.contains(app.path) {
            selection.remove(app.path)
        } else {
            guard UninstallPlan.isSafeName(app.uninstallName) else {
                error = "\"\(app.name)\" has a name that mo would read as a command-line "
                      + "flag, so it can't be uninstalled from here. Remove it manually."
                return
            }
            selection.insert(app.path)
        }
    }

    func preview() async {
        guard !selection.isEmpty else { return }
        previewing = true
        defer { previewing = false }

        // The scan takes seconds, and the list stays clickable throughout.
        // `toggle()` clears `plan`, but that is undone the moment an in-flight
        // preview lands and assigns its result — a plan computed for the old
        // selection, arming the destructive button for the new one. Remember
        // what this run was for and discard it if the selection moved on.
        let previewedFor = Set(safeSelection)
        do {
            let output = try await MoleCLI.shared.run(
                ["uninstall", "--dry-run"] + previewedFor.sorted(),
                input: UninstallPlan.confirmationInput,
                env: UninstallPlan.trashModeEnv
            )
            guard previewedFor == Set(safeSelection) else { return }

            let parsed = UninstallPlan.parse(output.stdout)
            // `aborted` was parsed and never read. A run that bailed produces no
            // file list, and storing it anyway armed "Uninstall" behind a plan
            // showing nothing — the user would confirm an empty list and delete
            // the real thing.
            guard !parsed.aborted, !parsed.apps.isEmpty else {
                error = "Mole did not return a removal plan for this selection, so "
                      + "there is nothing to confirm against. Try the preview again."
                plan = nil
                return
            }
            plan = parsed
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func uninstall() async {
        confirming = false
        // Only ever removes what a reviewed plan listed — never re-resolves
        // names at this point. See UninstallPlan.remove for why MoleUI, not
        // `mo uninstall`, performs the removal.
        guard let plan, !plan.apps.isEmpty else {
            error = "Preview the selection first, so there is a reviewed plan to remove."
            return
        }
        // Homebrew installed these; trashing the bundle would leave brew
        // believing they are still installed.
        let brewApps = selectedApps.filter(\.isHomebrew).map(\.name)
        guard brewApps.isEmpty else {
            error = "\(brewApps.joined(separator: ", ")) came from Homebrew — remove with "
                  + "`brew uninstall --cask` so Homebrew stays in sync."
            return
        }
        removing = true
        defer { removing = false }
        let outcome = await UninstallPlan.remove(plan)
        lastResult = "Moved \(outcome.moved) file\(outcome.moved == 1 ? "" : "s") from "
                   + "\(plan.apps.count) app\(plan.apps.count == 1 ? "" : "s") to the Trash"
                   + (outcome.failed.isEmpty ? "." : " · \(outcome.failed.count) could not be moved.")
        if !outcome.failed.isEmpty { error = outcome.failed.prefix(3).joined(separator: "\n") }
        selection.removeAll()
        self.plan = nil
        // The cached list still contains what was just removed, and load()
        // would restore it verbatim — clear it so the refresh is real.
        await rescan()
    }
}

struct UninstallView: View {
    @StateObject private var model = UninstallModel()

    var body: some View {
        PaneScaffold(title: Pane.uninstall.title,
                     subtitle: model.apps.isEmpty
                        ? "Remove apps completely"
                        : "\(model.apps.count) applications installed") {
            if !model.apps.isEmpty {
                if let scannedAt = model.scannedAt {
                    ScanAge(date: scannedAt)
                }
                Picker("", selection: $model.unusedOnly) {
                    Text("All apps").tag(false)
                    Text("Unused \(model.unused.isEmpty ? "" : "(\(model.unused.count))")").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Apps not opened in the last \(Prefs.int(Prefs.unusedDays, 90)) days — change in Settings")
                SortMenu(order: $model.sort, help: "Order the application list")
                GhostButton(title: "Rescan", systemImage: "arrow.clockwise") {
                    Task { await model.rescan() }
                }
            }
            if !model.selection.isEmpty {
                GhostButton(title: "Clear", systemImage: "xmark") {
                    model.selection.removeAll()
                    model.plan = nil
                }
                if model.plan == nil {
                    ActionButton(title: "Preview \(model.selection.count) app\(model.selection.count == 1 ? "" : "s")",
                                 systemImage: "eye",
                                 loading: model.previewing) {
                        Task { await model.preview() }
                    }
                } else {
                    ActionButton(title: "Uninstall", systemImage: "trash",
                                 destructive: true, loading: model.removing) {
                        model.confirming = true
                    }
                }
            }
        } content: {
            content
        }
        .task { await model.load() }
        .sheet(isPresented: $model.confirming) {
            ConfirmSheet(
                title: "Uninstall \(model.selection.count) app\(model.selection.count == 1 ? "" : "s")?",
                summary: model.plan?.summary
                    ?? model.selectedApps.map(\.name).joined(separator: ", "),
                detail: "\(model.plan?.totalFiles ?? 0) files across "
                      + "\(model.selectedApps.count) app(s) will be moved to the Trash, "
                      + "where you can still recover them. Exactly the files in the plan above "
                      + "are moved — nothing else. Apps from the App Store ask for your password."
                      + (model.hasAmbiguousNames
                         ? "\n\nSome of these share a name that `mo uninstall` matches by, "
                         + "so it may remove more than the copies you ticked."
                         : ""),
                confirmTitle: "Move to Trash",
                onConfirm: { Task { await model.uninstall() } },
                onCancel: { model.confirming = false }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            StateMessage(icon: "hourglass", title: "Scanning applications…",
                         message: "Reading /Applications and measuring each bundle.")
        } else if let error = model.error, model.apps.isEmpty {
            StateMessage(icon: "exclamationmark.triangle", title: "Could not list apps",
                         message: error, tint: Mole.amber)
        } else {
            VStack(spacing: 12) {
                // `model.error` used to be readable only through the empty-list
                // branch above, so every later failure was invisible: a preview
                // that returned no plan, a flag-shaped app name, a failed
                // uninstall. The pane just sat there looking idle.
                if let error = model.error, !model.apps.isEmpty {
                    Notice(icon: "exclamationmark.triangle", text: error)
                }
                HStack(alignment: .top, spacing: 12) {
                    appList
                    planPanel.frame(width: 400)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    private var appList: some View {
        Card(title: "Applications",
             trailing: model.selection.isEmpty ? nil : "\(model.selection.count) selected") {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Mole.textFaint)
                    TextField("Filter by name or bundle id", text: $model.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mole.text)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Mole.surfaceHigh, in: RoundedRectangle(cornerRadius: 5))

                // See CleanView: an unconstrained ScrollView inflates the Card
                // to its full content height and overflows the window.
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(model.filtered) { app in
                            appRow(app)
                        }
                    }
                }
                .scrollableCardContent()
            }
        }
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let selected = model.selection.contains(app.path)
        return Button {
            model.toggle(app)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Mole.danger : Mole.textFaint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Mole.text)
                        .lineLimit(1)
                    Text(app.bundleID.isEmpty ? app.path : app.bundleID)
                        .font(Mole.mono(9.5))
                        .foregroundStyle(Mole.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if app.isHomebrew {
                    Text("BREW")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Mole.brand)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Mole.brand.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 3))
                }

                if let used = model.lastUsed[app.path] {
                    Text("opened \(relative(used))")
                        .font(Mole.mono(9.5))
                        .foregroundStyle(model.unused.contains(app.path) ? Mole.amber : Mole.textFaint)
                } else if model.unused.contains(app.path) {
                    Text("never opened").font(Mole.mono(9.5)).foregroundStyle(Mole.amber)
                }

                Text(app.hasKnownSize ? app.size : "—")
                    .font(Mole.mono(10))
                    .monospacedDigit()
                    .foregroundStyle(app.hasKnownSize ? Mole.textDim : Mole.textFaint)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Mole.danger.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private var planPanel: some View {
        Card(title: "Removal plan",
             trailing: model.plan.map { "\($0.totalFiles) files" }) {
            if let result = model.lastResult {
                VStack(alignment: .leading, spacing: 8) {
                    Label(result, systemImage: "checkmark.seal")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mole.moss)
                    Text("Removed items are in the Trash until you empty it.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Mole.textFaint)
                }
            } else if model.previewing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading what would be removed…")
                        .font(.system(size: 11))
                        .foregroundStyle(Mole.textDim)
                }
            } else if let plan = model.plan {
                planContent(plan)
            } else if model.selection.isEmpty {
                Text("Select one or more applications to see exactly which files "
                   + "would be removed before anything happens.")
                    .font(.system(size: 11))
                    .foregroundStyle(Mole.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.selectedApps) { app in
                        Text(app.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Mole.text)
                    }
                    Text("Run the preview to list every file that would be removed.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Mole.textFaint)
                }
            }
        }
    }

    private func planContent(_ plan: UninstallPlan.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = plan.summary {
                Text(summary)
                    .font(Mole.mono(11))
                    .foregroundStyle(Mole.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan.apps.isEmpty {
                Notice(icon: "questionmark.circle",
                       text: "Mole reported no files for this selection. It may not "
                           + "recognise the app name — check it against `mo uninstall --list`.")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(plan.apps) { app in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(app.name)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Mole.text)
                                Spacer()
                                if let size = app.size {
                                    Text(size)
                                        .font(Mole.mono(10))
                                        .foregroundStyle(Mole.amber)
                                }
                            }
                            ForEach(app.files) { file in
                                HStack(spacing: 6) {
                                    Text(file.path)
                                        .font(Mole.mono(10))
                                        .foregroundStyle(Mole.textDim)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(file.path)
                                    Spacer(minLength: 6)
                                    Text(file.size ?? "")
                                        .font(Mole.mono(9.5))
                                        .monospacedDigit()
                                        .foregroundStyle(Mole.textFaint)
                                }
                            }
                        }
                    }
                }
                .scrollableCardContent()
            }
        }
    }
}
