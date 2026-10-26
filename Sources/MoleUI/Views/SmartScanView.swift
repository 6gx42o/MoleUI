import SwiftUI

/// Runs the scans worth running together, all at once, and says where to look.
///
/// Every scan runs concurrently — the slowest (`mo clean --dry-run`, a full
/// disk walk) sets the total time, not the sum. Each result is also written to
/// the cache its own pane reads, so "Review" opens that pane instantly instead
/// of scanning a second time.
@MainActor
final class SmartScanModel: ObservableObject {
    struct Tile: Identifiable, Codable {
        var id: String { pane.rawValue }
        var pane: Pane
        var state: State = .pending
        var bytes: Int64?
        var count: Int?
        var line: String?
        /// Counts toward "space you can free".
        var reclaimable: Bool

        enum State: String, Codable { case pending, running, done, failed }
    }

    @Published var tiles: [Tile] = SmartScanModel.blankTiles
    @Published var running = false
    @Published var finishedAt: Date?
    @Published var duration: TimeInterval?

    private static let storeKey = "smartScan.last"

    static let blankTiles: [Tile] = [
        Tile(pane: .clean, reclaimable: true),
        Tile(pane: .leftovers, reclaimable: true),
        Tile(pane: .trashBins, reclaimable: true),
        Tile(pane: .malware, reclaimable: false),
        Tile(pane: .updater, reclaimable: false),
        Tile(pane: .largeFiles, reclaimable: false),
        Tile(pane: .duplicates, reclaimable: true),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            tiles = saved.tiles
            finishedAt = saved.date
            duration = saved.duration
        }
    }

    private struct Saved: Codable { var tiles: [Tile]; var date: Date; var duration: TimeInterval }

    var reclaimableBytes: Int64 {
        tiles.filter(\.reclaimable).compactMap(\.bytes).reduce(0, +)
    }

    func run() async {
        guard !running else { return }
        running = true
        let started = Date()
        for index in tiles.indices { tiles[index] = Tile(pane: tiles[index].pane, state: .running,
                                                         reclaimable: tiles[index].reclaimable) }

        await withTaskGroup(of: Tile.self) { group in
            for tile in tiles {
                group.addTask { await Self.measure(tile) }
            }
            for await result in group {
                if let index = tiles.firstIndex(where: { $0.pane == result.pane }) {
                    tiles[index] = result
                }
            }
        }

        running = false
        finishedAt = Date()
        duration = Date().timeIntervalSince(started)
        if let data = try? JSONEncoder().encode(Saved(tiles: tiles, date: finishedAt ?? Date(),
                                                      duration: duration ?? 0)) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    /// One tile's scan. `mo`-backed panes run their command and leave the raw
    /// output in that pane's cache; native features run their own scanner.
    private nonisolated static func measure(_ tile: Tile) async -> Tile {
        var tile = tile
        do {
            switch tile.pane {
            case .clean:
                let output = try await MoleCLI.shared.run(["clean", "--dry-run"])
                let parsed = MolePreview.parse(output.stdout)
                ScanCache.save(ScanCache.Key.cleanPreview, output.stdout)
                if let listPath = parsed.detailListPath,
                   let list = try? String(contentsOfFile: listPath, encoding: .utf8) {
                    ScanCache.save(ScanCache.Key.cleanFileList, list)
                }
                tile.bytes = parsed.totalBytes
                tile.line = parsed.needsSudo ? "system caches need sudo" : "caches, logs, temp files"
            default:
                guard let feature = Features.forPane(tile.pane) else { break }
                let scan = try await feature.scan()
                FindingsModel.cache(scan, for: feature)
                let rows = scan.findings.filter { $0.blocked == nil }
                tile.count = rows.count
                tile.bytes = rows.compactMap(\.bytes).reduce(0, +)
                switch tile.pane {
                case .malware:
                    let suspicious = scan.findings.filter { $0.info["severity"] == "high" }.count
                    tile.count = suspicious
                    tile.bytes = nil
                    tile.line = suspicious == 0 ? "nothing suspicious" : "\(suspicious) suspicious"
                case .updater:
                    tile.bytes = nil
                    tile.count = scan.findings.count
                    tile.line = scan.findings.isEmpty ? "all up to date" : "\(scan.findings.count) updates"
                case .largeFiles:
                    tile.bytes = nil
                    tile.line = "\(rows.count) large files and folders"
                case .trashBins:    tile.line = "\(rows.count) items in the Trash"
                case .leftovers:    tile.line = "installers, build folders, attachments"
                case .duplicates:
                    // Only the extra copies are reclaimable, not every copy.
                    let byHash = Dictionary(grouping: rows, by: { $0.info["hash"] ?? $0.id })
                    tile.bytes = byHash.values.reduce(0) { $0 + ($1.first?.bytes ?? 0) * Int64($1.count - 1) }
                    tile.line = "\(byHash.count) sets of identical files"
                default: break
                }
            }
            tile.state = .done
        } catch {
            tile.state = .failed
            tile.line = error.localizedDescription
        }
        return tile
    }
}

extension Features {
    static func forPane(_ pane: Pane) -> Feature? {
        switch pane {
        case .leftovers:         return leftovers
        case .trashBins:         return trashBins
        case .malware:           return malware
        case .privacy:           return privacy
        case .wifi:              return savedWiFi
        case .permissions:       return permissions
        case .extensions:        return extensions
        case .updater:           return updater
        case .largeFiles:        return largeFiles
        case .duplicates:        return duplicates
        default:                 return nil
        }
    }
}

struct SmartScanView: View {
    @StateObject private var model = SmartScanModel()
    @EnvironmentObject private var router: Router

    var body: some View {
        PaneScaffold(title: Pane.smartScan.title, subtitle: Pane.smartScan.subtitle) {
            if let finishedAt = model.finishedAt, !model.running {
                ScanAge(date: finishedAt)
            }
            ActionButton(title: model.running ? "Scanning…" : (model.finishedAt == nil ? "Scan" : "Scan again"),
                         systemImage: "sparkle.magnifyingglass", loading: model.running) {
                Task { await model.run() }
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headline
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(model.tiles) { tile($0) }
                    }
                    Notice(icon: "hand.raised",
                           text: "Smart Scan only looks. Nothing is removed until you open a section, "
                               + "review it and confirm there.",
                           tint: Mole.textFaint)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
    }

    private var headline: some View {
        Card {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("YOU CAN FREE")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.8)
                        .foregroundStyle(Mole.textDim)
                    Text(model.finishedAt == nil && !model.running ? "—"
                         : formatBytesDecimal(model.reclaimableBytes))
                        .font(Mole.mono(30, weight: .medium))
                        .foregroundStyle(Mole.amber)
                }
                Divider().frame(height: 34).overlay(Mole.border)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.running ? "Checking junk, leftovers, the Trash, background items, "
                                       + "updates, large files and duplicates at once…"
                         : model.finishedAt == nil ? "Run a scan to check everything in one go."
                         : "Finished in \(String(format: "%.0f", model.duration ?? 0))s.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mole.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private func tile(_ tile: SmartScanModel.Tile) -> some View {
        Button { router.pane = tile.pane } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: tile.pane.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(tile.pane.tint)
                    Text(tile.pane.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Mole.text)
                    Spacer()
                    switch tile.state {
                    case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
                    case .failed:  Image(systemName: "exclamationmark.triangle").foregroundStyle(Mole.amber)
                    case .done:    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Mole.textFaint)
                    case .pending: EmptyView()
                    }
                }
                Text(value(tile))
                    .font(Mole.mono(18, weight: .medium))
                    .foregroundStyle(tone(tile))
                Text(tile.line ?? tile.pane.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Mole.textFaint)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Mole.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Mole.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(tile.pane.title)")
    }

    private func value(_ tile: SmartScanModel.Tile) -> String {
        switch tile.state {
        case .pending: return "—"
        case .running: return "…"
        case .failed:  return "Failed"
        case .done:
            if let bytes = tile.bytes, bytes > 0 { return formatBytesDecimal(bytes) }
            if let count = tile.count { return count == 0 ? "None" : "\(count)" }
            return formatBytesDecimal(tile.bytes ?? 0)
        }
    }

    private func tone(_ tile: SmartScanModel.Tile) -> Color {
        guard tile.state == .done else { return Mole.textDim }
        switch tile.pane {
        case .malware: return (tile.count ?? 0) > 0 ? Mole.amber : Mole.moss
        case .updater: return (tile.count ?? 0) > 0 ? Mole.brand : Mole.moss
        default:       return tile.reclaimable ? Mole.amber : Mole.text
        }
    }
}
