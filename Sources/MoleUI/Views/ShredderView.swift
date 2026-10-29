import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Deletes chosen files permanently, skipping the Trash.
///
/// Honest about what "shredding" can mean on a modern Mac: APFS is
/// copy-on-write and SSDs remap every write, so overwriting a file in place
/// writes the zeros somewhere *else* and leaves the original blocks alone —
/// it is theatre. On those volumes the file is deleted outright, and FileVault
/// is what actually keeps the freed blocks unreadable. On HFS+ and FAT drives,
/// where an overwrite does land on the same blocks, the contents are zeroed
/// first.
@MainActor
final class ShredderModel: ObservableObject {
    struct Item: Identifiable {
        var id: String { path }
        var path: String
        var bytes: Int64
        var overwrite: Bool          // false on APFS/SSD, see above
        var blocked: String?
    }

    @Published var items: [Item] = []
    @Published var confirming = false
    @Published var working = false
    @Published var result: String?
    @Published var failures: [String] = []

    var totalBytes: Int64 { items.filter { $0.blocked == nil }.map(\.bytes).reduce(0, +) }
    var actionable: [Item] { items.filter { $0.blocked == nil } }

    func add(_ urls: [URL]) {
        result = nil
        for url in urls where !items.contains(where: { $0.path == url.path }) {
            let path = url.standardizedFileURL.path
            let format = (try? url.resourceValues(forKeys: [.volumeTypeNameKey]))?.volumeTypeName?.lowercased() ?? "apfs"
            items.append(Item(path: path, bytes: DiskUsage.size(of: path),
                              overwrite: !format.contains("apfs"),
                              blocked: Trash.rejection(for: path)))
        }
    }

    func remove(_ item: Item) { items.removeAll { $0.id == item.id } }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add to Shredder"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func shred() async {
        confirming = false
        working = true
        defer { working = false }
        let targets = actionable
        let outcome = await Task.detached { () -> (done: [String], failed: [String], bytes: Int64) in
            var done: [String] = [], failed: [String] = [], bytes: Int64 = 0
            for item in targets {
                // Re-checked here, not just when the row was added.
                if let refusal = Trash.rejection(for: item.path) {
                    failed.append("\((item.path as NSString).lastPathComponent): \(refusal)"); continue
                }
                if item.overwrite { ShredderModel.zeroFill(item.path) }
                do {
                    try PermanentDelete.forceRemove(item.path)
                    done.append(item.path); bytes += item.bytes
                } catch {
                    failed.append("\((item.path as NSString).lastPathComponent): \(error.localizedDescription)")
                }
            }
            return (done, failed, bytes)
        }.value
        items.removeAll { outcome.done.contains($0.path) }
        failures = outcome.failed
        result = "Permanently deleted \(outcome.done.count) item\(outcome.done.count == 1 ? "" : "s") "
               + "(\(formatBytesDecimal(outcome.bytes)))."
    }

    /// One pass of zeros over every regular file at or below `path`.
    nonisolated static func zeroFill(_ path: String) {
        var files: [String] = []
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let walker = FileManager.default.enumerator(atPath: path)
            while let relative = walker?.nextObject() as? String {
                files.append(path + "/" + relative)
            }
        } else {
            files = [path]
        }
        let zeros = Data(count: 1 << 20)
        for file in files {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  let handle = FileHandle(forWritingAtPath: file) else { continue }
            var written = 0
            while written < size {
                let count = min(zeros.count, size - written)
                handle.write(zeros.prefix(count))
                written += count
            }
            try? handle.synchronize()
            try? handle.close()
        }
    }
}

struct ShredderView: View {
    @StateObject private var model = ShredderModel()
    @State private var targeted = false

    var body: some View {
        PaneScaffold(title: Pane.shredder.title, subtitle: Pane.shredder.subtitle) {
            GhostButton(title: "Add files…", systemImage: "plus") { model.choose() }
            if !model.actionable.isEmpty {
                GhostButton(title: "Clear", systemImage: "xmark") { model.items = [] }
                ActionButton(title: "Shred \(formatBytesDecimal(model.totalBytes))", systemImage: "scissors",
                             destructive: true, loading: model.working) { model.confirming = true }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Notice(icon: "info.circle",
                       text: "Shredding skips the Trash — there is no undo. On this Mac's SSD (APFS), "
                           + "overwriting a file cannot reach its original blocks, so files there are "
                           + "deleted outright and FileVault keeps the freed space unreadable. Files on "
                           + "HFS+ or FAT drives are zeroed first.",
                       tint: Mole.amber)
                if let result = model.result {
                    Notice(icon: model.failures.isEmpty ? "checkmark.seal" : "exclamationmark.triangle",
                           text: result + (model.failures.isEmpty ? "" : " \(model.failures.count) failed."),
                           tint: model.failures.isEmpty ? Mole.moss : Mole.amber)
                    ForEach(model.failures, id: \.self) {
                        Text($0).font(Mole.mono(10)).foregroundStyle(Mole.textFaint)
                    }
                }
                if model.items.isEmpty {
                    dropZone
                } else {
                    Card(title: "\(model.items.count) to shred", trailing: formatBytesDecimal(model.totalBytes)) {
                        ScrollView {
                            LazyVStack(spacing: 2) { ForEach(model.items) { row($0) } }
                        }
                        .scrollableCardContent()
                    }
                    .scrollableCardContent()
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.add([url]) } }
                    }
                }
                return true
            }
            .sheet(isPresented: $model.confirming) {
                ConfirmSheet(title: "Permanently delete \(model.actionable.count) item\(model.actionable.count == 1 ? "" : "s")?",
                             summary: formatBytesDecimal(model.totalBytes),
                             detail: model.actionable.prefix(4).map { ($0.path as NSString).lastPathComponent }
                                        .joined(separator: "\n")
                                   + "\n\nThis skips the Trash and cannot be undone.",
                             confirmTitle: "Shred",
                             onConfirm: { Task { await model.shred() } },
                             onCancel: { model.confirming = false })
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "scissors").font(.system(size: 30, weight: .light))
                .foregroundStyle(targeted ? Mole.danger : Mole.textFaint)
            Text("Drop files or folders here").font(.system(size: 13, weight: .medium)).foregroundStyle(Mole.text)
            Text("or use Add files…").font(.system(size: 11)).foregroundStyle(Mole.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(targeted ? Mole.danger : Mole.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }

    private func row(_ item: ShredderModel.Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.blocked == nil ? "doc" : "nosign")
                .font(.system(size: 11))
                .foregroundStyle(item.blocked == nil ? Mole.textDim : Mole.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text((item.path as NSString).lastPathComponent).font(.system(size: 12)).foregroundStyle(Mole.text)
                Text(item.blocked ?? (item.overwrite ? "zeroed, then deleted" : "deleted (APFS)") + " · " + item.path)
                    .font(Mole.mono(9.5)).foregroundStyle(Mole.textFaint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(formatBytesDecimal(item.bytes)).font(Mole.mono(11)).foregroundStyle(Mole.textDim)
            Button { model.remove(item) } label: {
                Image(systemName: "xmark.circle").foregroundStyle(Mole.textFaint)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }
}
