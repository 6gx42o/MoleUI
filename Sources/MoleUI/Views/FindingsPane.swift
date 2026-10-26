import SwiftUI
import AppKit

@MainActor
final class FindingsModel: ObservableObject {
    let feature: Feature

    @Published private(set) var scan: FindingScan?
    @Published private(set) var scanning = false
    @Published var error: String?
    @Published private(set) var scannedAt: Date?
    @Published private(set) var selection: Set<String> = []
    @Published var confirming = false
    @Published private(set) var working = false
    @Published var outcome: FindingOutcome?
    @Published var search = "" { didSet { regroup() } }
    @Published var sort: ListSort { didSet { sort.store(feature.pane.rawValue); regroup() } }

    /// Rows in display order, grouped. Computed when the inputs change rather
    /// than in `body`, so a duplicate scan with thousands of rows does not
    /// re-sort on every checkbox click.
    @Published private(set) var sections: [(group: String, rows: [Finding])] = []
    private var removed: Set<String> = []

    init(feature: Feature) {
        self.feature = feature
        self.sort = .stored(feature.pane.rawValue)
    }

    var rows: [Finding] { sections.flatMap(\.rows) }
    var isEmpty: Bool { rows.isEmpty }

    var selectedRows: [Finding] { rows.filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { selectedRows.compactMap(\.bytes).reduce(0, +) }

    // MARK: Scanning

    @discardableResult
    func restore() -> Bool {
        guard scan == nil, feature.cacheable,
              let cached = ScanCache.load(feature.pane.cacheKey),
              let decoded = try? JSONDecoder().decode(FindingScan.self, from: Data(cached.text.utf8))
        else { return false }
        adopt(decoded, at: cached.date)
        return true
    }

    func run() async {
        guard !scanning else { return }
        scanning = true
        error = nil
        defer { scanning = false }
        do {
            let result = try await feature.scan()
            try Task.checkCancellation()
            outcome = nil
            selection = []
            removed = []
            adopt(result, at: Date())
            Self.cache(result, for: feature)
        } catch is CancellationError {
            // Left the pane mid-scan; the child process was already killed.
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Shared with Smart Scan, which runs several features' scans at once and
    /// leaves each result where that feature's pane will find it.
    nonisolated static func cache(_ result: FindingScan, for feature: Feature) {
        guard feature.cacheable, let data = try? JSONEncoder().encode(result) else { return }
        ScanCache.save(feature.pane.cacheKey, String(decoding: data, as: UTF8.self))
    }

    private func adopt(_ result: FindingScan, at date: Date) {
        scan = result
        scannedAt = date
        regroup()
    }

    private func regroup() {
        let needle = search.trimmingCharacters(in: .whitespaces)
        let live = (scan?.findings ?? []).filter { finding in
            !removed.contains(finding.id)
                && (needle.isEmpty
                    || finding.title.localizedCaseInsensitiveContains(needle)
                    || (finding.detail ?? "").localizedCaseInsensitiveContains(needle))
        }
        // Groups keep the order the scanner emitted them in — it knows that
        // "Suspicious" belongs above "Signed by a known developer".
        var order: [String] = []
        var buckets: [String: [Finding]] = [:]
        for finding in live {
            let key = finding.group ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(finding)
        }
        sections = order.map { key in
            (key, sort.sort(buckets[key] ?? [], name: { $0.title }, bytes: { $0.bytes ?? 0 }))
        }
        selection.formIntersection(Set(live.map(\.id)))
    }

    // MARK: Selection

    func toggle(_ finding: Finding) {
        guard finding.blocked == nil else { return }
        outcome = nil
        if selection.contains(finding.id) { selection.remove(finding.id) }
        else { selection.insert(finding.id) }
    }

    func selectAll() {
        outcome = nil
        selection = Set(rows.filter { $0.blocked == nil }.map(\.id))
    }

    func autoSelect() {
        guard let pick = feature.autoSelect?.pick else { return }
        outcome = nil
        let allowed = Set(rows.filter { $0.blocked == nil }.map(\.id))
        selection = pick(rows).intersection(allowed)
    }

    func clearSelection() { selection = [] }

    /// Opens the confirmation, unless the feature's own rule refuses first.
    func requestAction() {
        if let refusal = feature.validate?(scan?.findings ?? [], selection) {
            outcome = FindingOutcome(message: refusal)
            return
        }
        confirming = true
    }

    func perform() async {
        guard let action = feature.action, !selection.isEmpty else { return }
        confirming = false
        working = true
        defer { working = false }
        let picked = selectedRows
        let result = await action.perform(picked)
        outcome = result
        if action.removesRows {
            removed.formUnion(result.succeeded)
            // Rows changed under the cached copy; the next visit measures again.
            if !result.succeeded.isEmpty { ScanCache.clear(feature.pane.cacheKey) }
        }
        selection.subtract(result.succeeded)
        regroup()
    }
}

/// The view every list-style feature uses.
struct FindingsPane: View {
    @StateObject private var model: FindingsModel
    private let feature: Feature

    init(feature: Feature) {
        self.feature = feature
        _model = StateObject(wrappedValue: FindingsModel(feature: feature))
    }

    var body: some View {
        PaneScaffold(title: feature.pane.title, subtitle: feature.pane.subtitle) {
            actions
        } content: {
            content
                .sheet(isPresented: $model.confirming) { confirmation }
        }
        // `.task` is cancelled when the pane goes away, which cancels the scan
        // and terminates whatever child process it was waiting on — leaving a
        // pane never leaves a disk walk running behind it.
        .task {
            guard model.scan == nil, !model.restore() else { return }
            await model.run()
        }
    }

    // MARK: Header

    @ViewBuilder
    private var actions: some View {
        if model.scanning {
            ProgressView().controlSize(.small)
        } else if model.scan != nil {
            if let scannedAt = model.scannedAt, feature.cacheable {
                ScanAge(date: scannedAt)
            }
            if !model.isEmpty { SortMenu(order: $model.sort) }
            GhostButton(title: "Rescan", systemImage: "arrow.clockwise") {
                Task { await model.run() }
            }
        }

        if let action = feature.action, !model.isEmpty {
            if model.selection.isEmpty {
                if let auto = feature.autoSelect {
                    GhostButton(title: auto.title, systemImage: "wand.and.stars") { model.autoSelect() }
                } else {
                    GhostButton(title: "Select all", systemImage: "checklist") { model.selectAll() }
                }
            } else {
                Text(selectionLabel)
                    .font(Mole.mono(10.5))
                    .foregroundStyle(Mole.textDim)
                GhostButton(title: "Clear", systemImage: "xmark") { model.clearSelection() }
                ActionButton(title: action.title, systemImage: action.icon,
                             destructive: action.destructive, loading: model.working) {
                    model.requestAction()
                }
            }
        }
    }

    private var selectionLabel: String {
        let bytes = model.selectedBytes
        return "\(model.selection.count) selected" + (bytes > 0 ? " · \(formatBytesDecimal(bytes))" : "")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if model.scan == nil {
            if let error = model.error {
                StateMessage(icon: "exclamationmark.triangle", title: "Scan failed",
                             message: error, tint: Mole.amber,
                             action: (title: "Try again", run: { Task { await model.run() } }))
            } else {
                StateMessage(icon: feature.pane.icon, title: "Scanning…",
                             message: feature.pane.subtitle, tint: Mole.brand)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.scan?.notes ?? [], id: \.self) { note in
                    Notice(icon: "info.circle", text: note, tint: Mole.brand)
                }
                if let outcome = model.outcome {
                    Notice(icon: outcome.failures.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
                           text: outcome.message, tint: outcome.failures.isEmpty ? Mole.moss : Mole.amber)
                    ForEach(outcome.failures.prefix(4), id: \.id) { failure in
                        Text("\(failure.id) — \(failure.reason)")
                            .font(Mole.mono(10)).foregroundStyle(Mole.textFaint)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if let error = model.error {
                    Notice(icon: "exclamationmark.triangle", text: error)
                }

                if model.isEmpty && model.search.isEmpty {
                    StateMessage(icon: "checkmark.seal", title: feature.emptyTitle,
                                 message: feature.emptyMessage, tint: Mole.moss)
                } else {
                    if let notice = feature.notice {
                        Notice(icon: "info.circle", text: notice, tint: Mole.textFaint)
                    }
                    list
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
    }

    private var list: some View {
        Card(title: "\(model.rows.count) found",
             trailing: totalLabel) {
            VStack(spacing: 8) {
                if (model.scan?.findings.count ?? 0) > 12 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10)).foregroundStyle(Mole.textFaint)
                        TextField("Filter", text: $model.search)
                            .textFieldStyle(.plain).font(.system(size: 11.5))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Mole.surfaceHigh, in: RoundedRectangle(cornerRadius: 5))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.sections, id: \.group) { section in
                            Section {
                                ForEach(section.rows) { row($0, maxBytes: maxBytes) }
                            } header: {
                                if !section.group.isEmpty {
                                    sectionHeader(section.group, section.rows)
                                }
                            }
                        }
                    }
                }
                .scrollableCardContent()
            }
        }
        .scrollableCardContent()
    }

    private var totalLabel: String? {
        let total = model.rows.compactMap(\.bytes).reduce(0, +)
        return total > 0 ? formatBytesDecimal(total) : nil
    }

    private var maxBytes: Int64 { max(model.rows.compactMap(\.bytes).max() ?? 1, 1) }

    private func sectionHeader(_ title: String, _ rows: [Finding]) -> some View {
        let total = rows.compactMap(\.bytes).reduce(0, +)
        return HStack {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Mole.textDim)
            Spacer()
            Text(total > 0 ? "\(rows.count) · \(formatBytesDecimal(total))" : "\(rows.count)")
                .font(Mole.mono(9.5)).foregroundStyle(Mole.textFaint)
        }
        .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 3)
        .background(Mole.surface)
    }

    private func row(_ finding: Finding, maxBytes: Int64) -> some View {
        let selected = model.selection.contains(finding.id)
        return HStack(alignment: .center, spacing: 9) {
            if feature.action != nil {
                Button { model.toggle(finding) } label: {
                    SelectBox(selected: selected, blocked: finding.blocked != nil)
                }
                .buttonStyle(.plain)
                .help(finding.blocked ?? "Select")
            }
            Image(systemName: icon(finding.tone))
                .font(.system(size: 10))
                .foregroundStyle(color(finding.tone))
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.title)
                        .font(.system(size: 12)).foregroundStyle(Mole.text)
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(finding.badges, id: \.self) { badge in
                        Text(badge.uppercased())
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(finding.tone == .warning ? Mole.amber : Mole.brand)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background((finding.tone == .warning ? Mole.amber : Mole.brand).opacity(0.13),
                                        in: RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer(minLength: 6)
                    if let date = finding.date {
                        Text("\(finding.dateLabel ?? "") \(relative(date))")
                            .font(Mole.mono(9.5)).foregroundStyle(Mole.textFaint)
                    }
                    if let bytes = finding.bytes {
                        Text(formatBytesDecimal(bytes))
                            .font(Mole.mono(11)).monospacedDigit()
                            .foregroundStyle(Mole.textDim)
                            .frame(minWidth: 62, alignment: .trailing)
                    }
                }
                if let bytes = finding.bytes, bytes > 0 {
                    StratumBar(fraction: Double(bytes) / Double(maxBytes),
                               color: finding.tone == .warning ? Mole.amber : Mole.brand.opacity(0.7),
                               height: 3)
                }
                if let detail = finding.detail ?? finding.blocked {
                    Text(detail)
                        .font(Mole.mono(9.5)).foregroundStyle(Mole.textFaint)
                        .lineLimit(1).truncationMode(.middle)
                        .help(detail)
                }
            }

            if let path = finding.revealPath, DiskUsage.exists(path) {
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10)).foregroundStyle(Mole.textFaint)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(selected ? (feature.action?.destructive == true ? Mole.danger : Mole.brand).opacity(0.08)
                             : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { if feature.action != nil { model.toggle(finding) } }
    }

    private var confirmation: some View {
        let action = feature.action
        let names = model.selectedRows.prefix(4).map(\.title)
        let more = model.selection.count - names.count
        let bytes = model.selectedBytes
        return ConfirmSheet(
            title: "\(action?.title ?? "Apply") — \(model.selection.count) item\(model.selection.count == 1 ? "" : "s")?",
            summary: bytes > 0 ? formatBytesDecimal(bytes) : names.first ?? "",
            detail: names.joined(separator: "\n") + (more > 0 ? "\n…and \(more) more" : "")
                  + "\n\n" + (action?.explanation ?? ""),
            confirmTitle: action?.title ?? "Apply",
            destructive: action?.destructive ?? true,
            onConfirm: { Task { await model.perform() } },
            onCancel: { model.confirming = false }
        )
    }

    private func icon(_ tone: Finding.Tone) -> String {
        switch tone {
        case .normal:  return "circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .good:    return "checkmark.circle.fill"
        }
    }

    private func color(_ tone: Finding.Tone) -> Color {
        switch tone {
        case .normal:  return Mole.brand.opacity(0.5)
        case .warning: return Mole.amber
        case .good:    return Mole.moss
        }
    }
}

/// "3d ago", "8mo ago", "2y ago" — for dates in rows, where a full timestamp
/// would crowd out the size column.
func relative(_ date: Date) -> String {
    let seconds = Date().timeIntervalSince(date)
    let days = Int(seconds / 86_400)
    switch days {
    case ..<0:    return "soon"
    case 0:       return "today"
    case ..<30:   return "\(days)d ago"
    case ..<365:  return "\(days / 30)mo ago"
    default:      return "\(days / 365)y ago"
    }
}
