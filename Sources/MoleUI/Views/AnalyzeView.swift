import SwiftUI
import AppKit

@MainActor
final class AnalyzeModel: ObservableObject {
    @Published var result: AnalyzeResult?
    @Published var scanning = false
    @Published var error: String?
    @Published var showLargeFiles = false
    /// Breadcrumb trail; nil path means the machine-wide overview.
    @Published var trail: [(name: String, path: String?)] = [("Overview", nil)]
    /// Set only while the overview is on screen — a drill-down is always live,
    /// so labelling one with an age would be a lie.
    @Published var scannedAt: Date?

    @Published var sort: ListSort = .stored("analyze") {
        didSet { sort.store("analyze") }
    }

    private var task: Task<Void, Never>?

    var currentPath: String? { trail.last?.path }

    func scan(name: String, path: String?, pushing: Bool) {
        task?.cancel()
        if pushing {
            trail.append((name, path))
        }
        error = nil
        scanning = true
        showLargeFiles = false
        scannedAt = nil

        var args = ["analyze", "--json"]
        if let path { args.append(path) }

        task = Task {
            do {
                let output = try await MoleCLI.shared.run(args)
                let scanned = try MoleCLI.decodeJSON(AnalyzeResult.self, output.stdout,
                                                     command: args.joined(separator: " "))
                guard !Task.isCancelled else { return }
                result = scanned
                scannedAt = Date()
                // Only the machine-wide overview is cached. It is the one this
                // pane runs by itself on every visit, and it is the slow one —
                // it walks /Applications and /Library. A drill-down is an
                // explicit request for a specific directory, so it always runs.
                if path == nil {
                    ScanCache.save(ScanCache.Key.analyze, output.stdout)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            scanning = false
        }
    }

    /// A delete moves every total on screen, and the cached overview would put
    /// the old ones back on the next visit.
    func invalidateCache() {
        ScanCache.clear(ScanCache.Key.analyze)
        if currentPath == nil { scannedAt = nil }
    }

    /// Show the cached overview instead of walking the disk again on every
    /// visit to this pane.
    @discardableResult
    func restore() -> Bool {
        guard result == nil, currentPath == nil,
              let cached = ScanCache.load(ScanCache.Key.analyze),
              let decoded = try? MoleCLI.decodeJSON(AnalyzeResult.self, cached.text,
                                                    command: "analyze --json"),
              !(decoded.entries ?? []).isEmpty
        else { return false }
        result = decoded
        scannedAt = cached.date
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
        scanning = false
    }

    func jump(to index: Int) {
        guard index < trail.count - 1 else { return }
        let target = trail[index]
        trail = Array(trail.prefix(index + 1))

        // Walking back up to the overview should be instant. It is the slow
        // scan — /Applications and /Library — and the cached copy is literally
        // what was on screen before the user descended.
        if target.path == nil {
            task?.cancel()
            result = nil
            scanning = false
            showLargeFiles = false
            if restore() { return }
        }
        scan(name: target.name, path: target.path, pushing: false)
    }

    func open(_ entry: AnalyzeResult.Entry) {
        guard entry.isDir else { return }
        scan(name: entry.name, path: entry.path, pushing: true)
    }
}

struct AnalyzeView: View {
    @StateObject private var model = AnalyzeModel()
    @StateObject private var trash = TrashController()

    /// path → bytes for everything currently listed, so the confirmation and
    /// the freed total are measured against what the scan actually found.
    private var weights: [String: Int64] {
        var map: [String: Int64] = [:]
        for entry in model.result?.entries ?? [] { map[entry.path] = entry.size }
        for file in model.result?.largeFiles ?? [] { map[file.path] = file.size }
        return map
    }

    var body: some View {
        PaneScaffold(title: Pane.analyze.title,
                     subtitle: model.result.map { result in
                        result.overview ? "Machine overview" : result.path
                     } ?? "Explore disk usage") {
            if model.scanning {
                GhostButton(title: "Cancel", systemImage: "xmark.circle") { model.cancel() }
            } else if model.result != nil {
                if let scannedAt = model.scannedAt, model.currentPath == nil {
                    ScanAge(date: scannedAt)
                }
                SortMenu(order: $model.sort, help: "Order folders and files")
                if !(model.result?.largeFiles ?? []).isEmpty {
                    GhostButton(title: model.showLargeFiles ? "Show folders" : "Largest files",
                                systemImage: "doc.text.magnifyingglass") {
                        model.showLargeFiles.toggle()
                    }
                }
                GhostButton(title: "Rescan", systemImage: "arrow.clockwise") {
                    trash.reset()
                    model.scan(name: model.trail.last?.name ?? "Overview",
                               path: model.currentPath, pushing: false)
                }
                TrashBar(controller: trash, bytes: trash.bytes(weights))
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                breadcrumb
                content
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .task {
            guard model.result == nil, !model.scanning, !model.restore() else { return }
            model.scan(name: "Overview", path: nil, pushing: false)
        }
        .sheet(isPresented: $trash.confirming) {
            TrashConfirmSheet(
                count: trash.count,
                bytes: trash.bytes(weights),
                sample: trash.sample(),
                what: "item",
                onConfirm: {
                    Task {
                        let moved = await trash.run(weights: weights)
                        if !moved.isEmpty { model.invalidateCache() }
                    }
                },
                onCancel: { trash.confirming = false }
            )
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.trail.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Mole.textFaint)
                }
                Button {
                    model.jump(to: index)
                } label: {
                    Text(crumb.name)
                        .font(.system(size: 11,
                                      weight: index == model.trail.count - 1 ? .semibold : .regular))
                        .foregroundStyle(index == model.trail.count - 1 ? Mole.text : Mole.textDim)
                }
                .buttonStyle(.plain)
                .disabled(index == model.trail.count - 1)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.scanning && model.result == nil {
            StateMessage(icon: "chart.bar.doc.horizontal", title: "Scanning…",
                         message: "Measuring every directory under this path. "
                                + "A full overview walks /Applications and /Library and takes a while.")
        } else if let error = model.error, model.result == nil {
            StateMessage(icon: "exclamationmark.triangle", title: "Scan failed",
                         message: error, tint: Mole.amber)
        } else if let result = model.result {
            resultView(result)
        } else {
            StateMessage(icon: "chart.bar.doc.horizontal", title: "Nothing scanned yet",
                         message: nil)
        }
    }

    private func resultView(_ result: AnalyzeResult) -> some View {
        // Anything already trashed is gone from the list rather than sitting
        // there still claiming space it no longer occupies.
        let entries = model.sort.sort((result.entries ?? [])
                                        .filter { !trash.removed.contains($0.path) },
                                      name: { $0.name }, bytes: { $0.size })
        let largeFiles = model.sort.sort((result.largeFiles ?? [])
                                        .filter { !trash.removed.contains($0.path) },
                                         name: { $0.name }, bytes: { $0.size })
        // The biggest entry, not the first one: under "Smallest first" the head
        // of the list is the narrowest bar, and scaling to it would draw every
        // row full width.
        let maxSize = max(entries.map(\.size).max() ?? 1, 1)

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                Card {
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TOTAL")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(Mole.textDim)
                            Text(formatBytesDecimal(result.totalSize, fractionDigits: 1))
                                .font(Mole.mono(24, weight: .medium))
                                .foregroundStyle(Mole.text)
                        }
                        Divider().frame(height: 30).overlay(Mole.border)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entries.count) entries")
                                .font(.system(size: 11))
                                .foregroundStyle(Mole.textDim)
                            if !largeFiles.isEmpty {
                                Text("\(largeFiles.count) large files")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Mole.textFaint)
                            }
                        }
                        Spacer()
                        if model.scanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("rescanning")
                                    .font(Mole.mono(10))
                                    .foregroundStyle(Mole.textFaint)
                            }
                        }
                    }
                }
            }

            if let outcome = trash.result {
                TrashResultNotice(outcome: outcome)
            }

            Card(title: model.showLargeFiles ? "Largest files" : "Contents",
                 trailing: "click a folder to descend") {
                // See CleanView: an unconstrained ScrollView inflates the Card
                // to its full content height and overflows the window.
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.showLargeFiles {
                            ForEach(largeFiles) { file in
                                fileRow(file, maxSize: largeFiles.map(\.size).max() ?? 1)
                            }
                        } else {
                            ForEach(entries) { entry in
                                entryRow(entry, maxSize: maxSize)
                            }
                        }
                    }
                }
                .scrollableCardContent()
            }
            .scrollableCardContent()
        }
    }

    private func entryRow(_ entry: AnalyzeResult.Entry, maxSize: Int64) -> some View {
        let blocked = Trash.rejection(for: entry.path)

        return HStack(spacing: 10) {
            // The overview lists ~/Documents, /Applications and friends as rows.
            // Trash.rejection refuses those outright, so they get a struck-out
            // box explaining why rather than a tickable one.
            Button { trash.toggle(entry.path) } label: {
                SelectBox(selected: trash.isSelected(entry.path), blocked: blocked != nil)
            }
            .buttonStyle(.plain)
            .disabled(blocked != nil)
            .help(blocked ?? "Select for the Trash")

            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(entry.isDir ? Mole.brand.opacity(0.8) : Mole.textFaint)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Mole.text)
                        .lineLimit(1)

                    if entry.cleanable {
                        tag("CLEANABLE", Mole.amber)
                    }
                    if entry.insight {
                        tag("INSIGHT", Mole.brand)
                    }
                    if let access = entry.lastAccess, let age = staleness(access) {
                        tag(age, Mole.textFaint)
                    }
                    Spacer(minLength: 6)
                    Text(formatBytesDecimal(entry.size, fractionDigits: 1))
                        .font(Mole.mono(11))
                        .monospacedDigit()
                        .foregroundStyle(Mole.textDim)
                }
                StratumBar(fraction: Double(entry.size) / Double(maxSize),
                           color: entry.cleanable ? Mole.amber : Mole.brand.opacity(0.7),
                           height: 5)
            }

            Button {
                NSWorkspace.shared.selectFile(entry.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                    .foregroundStyle(Mole.textFaint)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.open(entry) }
        .background(trash.isSelected(entry.path)
                        ? Mole.danger.opacity(0.08)
                        : Mole.surfaceHigh.opacity(entry.isDir ? 0.35 : 0),
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func fileRow(_ file: AnalyzeResult.LargeFile, maxSize: Int64) -> some View {
        let blocked = Trash.rejection(for: file.path)

        return HStack(spacing: 10) {
            Button { trash.toggle(file.path) } label: {
                SelectBox(selected: trash.isSelected(file.path), blocked: blocked != nil)
            }
            .buttonStyle(.plain)
            .disabled(blocked != nil)
            .help(blocked ?? "Select for the Trash")

            Image(systemName: "doc")
                .font(.system(size: 10))
                .foregroundStyle(Mole.textFaint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(file.name)
                        .font(.system(size: 12))
                        .foregroundStyle(Mole.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(formatBytesDecimal(file.size, fractionDigits: 1))
                        .font(Mole.mono(11))
                        .monospacedDigit()
                        .foregroundStyle(Mole.textDim)
                }
                StratumBar(fraction: Double(file.size) / Double(max(maxSize, 1)),
                           color: Mole.amber, height: 5)
                Text(file.path)
                    .font(Mole.mono(9.5))
                    .foregroundStyle(Mole.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button {
                NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 10))
                    .foregroundStyle(Mole.textFaint)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(trash.isSelected(file.path) ? Mole.danger.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 3))
    }

    /// "not opened in 8 months" is the number that actually decides whether
    /// something can go, so it earns a place next to the size.
    private func staleness(_ iso: String) -> String? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return nil }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        switch days {
        case ..<30:   return nil
        case ..<365:  return "\(days / 30)mo idle"
        default:      return "\(days / 365)y idle"
        }
    }
}
