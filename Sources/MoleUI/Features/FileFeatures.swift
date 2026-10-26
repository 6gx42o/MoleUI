import Foundation
import CoreServices
import CryptoKit

private let home = NSHomeDirectory()

private func shortPath(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// Path components that mean "this file lives inside a package". Removing a
/// file from inside a Photos library or a sparse bundle corrupts the whole
/// thing, so those files are never offered individually.
private let packageMarkers = [".app/", ".photoslibrary/", ".musiclibrary/", ".tvlibrary/",
                              ".imovielibrary/", ".fcpbundle/", ".logicx/", ".band/",
                              ".xcarchive/", ".bundle/", ".framework/", ".sparsebundle/",
                              ".vmwarevm/", ".pvm/", ".utm/", ".photolibrary/", ".aplibrary/"]

private func isInsidePackage(_ path: String) -> Bool {
    packageMarkers.contains { path.contains($0) }
}

/// The user's own files: home, minus ~/Library (app data, not documents) and
/// hidden folders — but including iCloud Drive, which lives under Library.
private func isUserFile(_ path: String) -> Bool {
    guard path.hasPrefix(home + "/"), !isInsidePackage(path) else { return false }
    let relative = path.dropFirst(home.count + 1)
    if relative.hasPrefix("Library/Mobile Documents/") { return true }
    if relative.hasPrefix("Library/") || relative.hasPrefix(".Trash/") { return false }
    return !relative.split(separator: "/").contains { $0.hasPrefix(".") }
}

private func kind(of path: String) -> String {
    switch (path as NSString).pathExtension.lowercased() {
    case "mov", "mp4", "m4v", "mkv", "avi", "webm":          return "video"
    case "mp3", "m4a", "wav", "aiff", "flac", "aac":         return "audio"
    case "jpg", "jpeg", "png", "heic", "raw", "cr2", "nef", "dng", "tif", "tiff", "psd": return "image"
    case "zip", "rar", "7z", "tar", "gz", "tgz", "xz", "bz2": return "archive"
    case "dmg", "pkg", "iso", "xip":                         return "installer"
    case "pdf", "doc", "docx", "pages", "key", "ppt", "pptx", "xls", "xlsx", "numbers": return "document"
    case "gguf", "safetensors", "ckpt", "bin", "pt", "onnx": return "model"
    default:                                                 return "file"
    }
}

extension Features {

    // MARK: - Large & Old Files

    static func largeFileScan() async throws -> FindingScan {
            let minimum = Int64(Prefs.int(Prefs.largeFileMB, 100)) * 1_000_000
            // Spotlight already knows every file's size, so the query returns in
            // well under a second where walking the home folder takes minutes.
            let output = try await MoleCLI.shared.tool("/usr/bin/mdfind",
                                                       ["-onlyin", home, "kMDItemFSSize >= \(minimum)"])
            var paths = output.stdout.components(separatedBy: .newlines).filter(isUserFile)
            var note: String?
            if paths.isEmpty {
                // Spotlight disabled or still indexing: walk instead.
                note = "Spotlight returned nothing, so the folders were walked directly — slower, but complete."
                paths = walkLargeFiles(minimum: minimum)
            }

            let now = Date()
            var findings: [Finding] = []
            for path in paths {
                try Task.checkCancellation()
                let url = URL(fileURLWithPath: path)
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey,
                                                                     .totalFileAllocatedSizeKey,
                                                                     .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                let bytes = Int64(values.totalFileAllocatedSize ?? 0)
                guard bytes >= minimum else { continue }
                let used = MDItemCreate(kCFAllocatorDefault, path as CFString)
                    .flatMap { MDItemCopyAttribute($0, kMDItemLastUsedDate) as? Date }
                let date = used ?? values.contentModificationDate
                let days = date.map { Int(now.timeIntervalSince($0) / 86_400) } ?? 9_999
                let group = days >= 365 ? "Over a year old"
                          : days >= 180 ? "6–12 months"
                          : days >= 30  ? "1–6 months" : "Recent"
                var badges = [kind(of: path)]
                if path.contains("/Library/Mobile Documents/") { badges.append("iCloud") }
                findings.append(Finding(id: path, title: url.lastPathComponent,
                                        detail: shortPath(url.deletingLastPathComponent().path),
                                        paths: [path], bytes: bytes, date: date,
                                        dateLabel: used == nil ? "modified" : "opened",
                                        group: group, badges: badges,
                                        tone: days >= 365 ? .warning : .normal,
                                        blocked: Trash.rejection(for: path)))
            }
            let order = ["Over a year old", "6–12 months", "1–6 months", "Recent"]
            findings.sort { (order.firstIndex(of: $0.group ?? "") ?? 9) < (order.firstIndex(of: $1.group ?? "") ?? 9) }
            return FindingScan(findings: findings,
                               notes: ["Files of \(Prefs.int(Prefs.largeFileMB, 100))MB and up — change the threshold in Settings."]
                                    + (note.map { [$0] } ?? []))
        }

    private static func walkLargeFiles(minimum: Int64) -> [String] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: home), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [String] = []
        while let url = walker.nextObject() as? URL {
            if url.path == home + "/Library" { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  Int64(values.totalFileAllocatedSize ?? 0) >= minimum else { continue }
            found.append(url.path)
        }
        return found.filter(isUserFile)
    }

    // MARK: - Duplicates

    static let duplicateRoots = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                                 "Library/Mobile Documents/com~apple~CloudDocs"].map { home + "/" + $0 }

    struct Candidate {
        var path: String
        var bytes: Int64
        var modified: Date
        var created: Date
    }

    private static func hash(_ path: String, partial: Bool) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunk = 1 << 20
        if partial {
            // The first and last 16KB separate almost every same-sized pair
            // without reading the middle of multi-gigabyte files.
            hasher.update(data: handle.readData(ofLength: 16_384))
            if let end = try? handle.seekToEnd(), end > 32_768 {
                try? handle.seek(toOffset: end - 16_384)
                hasher.update(data: handle.readData(ofLength: 16_384))
            }
        } else {
            while autoreleasepool(invoking: {
                let data = handle.readData(ofLength: chunk)
                hasher.update(data: data)
                return !data.isEmpty
            }) {}
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a batch on every core.
    private static func hashAll(_ paths: [String], partial: Bool) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: (String, String?).self) { group in
            var results: [String: String] = [:]
            var next = 0
            let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
            for path in paths.prefix(width) {
                group.addTask(priority: .userInitiated) { (path, hash(path, partial: partial)) }
                next += 1
            }
            while let (path, digest) = try await group.next() {
                try Task.checkCancellation()
                if let digest { results[path] = digest }
                if next < paths.count {
                    let path = paths[next]
                    next += 1
                    group.addTask(priority: .userInitiated) { (path, hash(path, partial: partial)) }
                }
            }
            return results
        }
    }

    /// Size, then the first and last 16KB, then a full SHA-256 — each stage
    /// only reads files the previous one could not tell apart, so most of a
    /// folder is never opened at all. Split out of the scan so the self-test can
    /// run it on files with known answers.
    static func findDuplicates(in roots: [String], minimum: Int64) async throws
        -> (groups: [(digest: String, copies: [Candidate])], scanned: Int) {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                                          .creationDateKey, .fileResourceIdentifierKey, .isSymbolicLinkKey]
            var seenInodes = Set<NSObject>()
            var bySize: [Int64: [Candidate]] = [:]
            var scanned = 0

            for root in roots where DiskUsage.exists(root) {
                guard let walker = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                while let url = walker.nextObject() as? URL {
                    scanned += 1
                    if scanned % 2_000 == 0 { try Task.checkCancellation() }
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, Int64(size) >= minimum,
                          !isInsidePackage(url.path) else { continue }
                    // Hard links are one file under two names — removing one
                    // frees nothing, so they are not duplicates.
                    if let inode = values.fileResourceIdentifier as? NSObject,
                       !seenInodes.insert(inode).inserted { continue }
                    bySize[Int64(size), default: []].append(Candidate(
                        path: url.path, bytes: Int64(size),
                        modified: values.contentModificationDate ?? .distantPast,
                        created: values.creationDate ?? .distantPast))
                }
            }

            // Only sizes shared by two or more files can be duplicates.
            let sameSize = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
            let partial = try await hashAll(sameSize.map(\.path), partial: true)
            var byPartial: [String: [Candidate]] = [:]
            for candidate in sameSize {
                guard let digest = partial[candidate.path] else { continue }
                byPartial["\(candidate.bytes):\(digest)", default: []].append(candidate)
            }
            let suspects = byPartial.values.filter { $0.count > 1 }.flatMap { $0 }
            let full = try await hashAll(suspects.map(\.path), partial: false)
            var byHash: [String: [Candidate]] = [:]
            for candidate in suspects {
                guard let digest = full[candidate.path] else { continue }
                byHash[digest, default: []].append(candidate)
            }

            let groups = byHash.filter { $0.value.count > 1 }
                .map { (digest: $0.key, copies: $0.value) }
                .sorted { $0.copies[0].bytes * Int64($0.copies.count) > $1.copies[0].bytes * Int64($1.copies.count) }
            return (groups, scanned)
        }

    static let duplicates = Feature(
        pane: .duplicates,
        emptyTitle: "No duplicates",
        emptyMessage: "No identical files were found in your folders.",
        notice: "Files are only grouped when their contents are byte-for-byte identical (SHA-256), "
              + "never just by name. “Select duplicates” keeps the oldest copy in each group; MoleUI "
              + "refuses to remove every copy of a file.",
        action: FindingAction(title: "Move to Trash", icon: "trash", destructive: true,
                              explanation: "The selected copies move to the Trash. At least one copy of "
                                         + "every file stays where it is.",
                              perform: { findings in
                                  // Re-check before acting: a file edited since the scan
                                  // is no longer the duplicate it was.
                                  var outcome = FindingOutcome(message: "")
                                  var safe: [Finding] = []
                                  for finding in findings {
                                      let path = finding.paths.first ?? ""
                                      let values = try? URL(fileURLWithPath: path)
                                          .resourceValues(forKeys: [.contentModificationDateKey])
                                      let stamp = values?.contentModificationDate?.timeIntervalSince1970
                                      if let stamp, String(Int(stamp)) == finding.info["mtime"] { safe.append(finding) }
                                      else { outcome.failures.append((finding.title, "changed since the scan — rescan")) }
                                  }
                                  let trashed = await FindingOutcome.trash(safe)
                                  outcome.succeeded = trashed.succeeded
                                  outcome.failures += trashed.failures
                                  outcome.message = trashed.message
                                  return outcome
                              }),
        autoSelect: (title: "Select duplicates", pick: { rows in
            var keep: [String: Finding] = [:]
            for row in rows {
                let key = row.info["hash"] ?? row.id
                if let current = keep[key], (current.date ?? .distantFuture) <= (row.date ?? .distantFuture) { continue }
                keep[key] = row
            }
            let kept = Set(keep.values.map(\.id))
            return Set(rows.map(\.id)).subtracting(kept)
        }),
        validate: { findings, selection in
            var copies: [String: (total: Int, picked: Int)] = [:]
            for finding in findings {
                let key = finding.info["hash"] ?? finding.id
                copies[key, default: (0, 0)].total += 1
                if selection.contains(finding.id) { copies[key, default: (0, 0)].picked += 1 }
            }
            let everyCopy = copies.values.filter { $0.total > 0 && $0.picked == $0.total }.count
            return everyCopy == 0 ? nil
                : "That would remove every copy of \(everyCopy) file\(everyCopy == 1 ? "" : "s"). "
                + "Leave at least one copy in each group unticked."
        },
        scan: {
            let minimum = Int64(Prefs.int(Prefs.duplicateMinMB, 1)) * 1_000_000
            let (groups, scanned) = try await findDuplicates(in: duplicateRoots, minimum: minimum)
            var findings: [Finding] = []
            for (digest, copies) in groups {
                let name = (copies[0].path as NSString).lastPathComponent
                let group = "\(name) — \(copies.count) copies · \(digest.prefix(6))"
                for copy in copies.sorted(by: { $0.created < $1.created }) {
                    findings.append(Finding(id: copy.path, title: (copy.path as NSString).lastPathComponent,
                                            detail: shortPath((copy.path as NSString).deletingLastPathComponent),
                                            paths: [copy.path], bytes: copy.bytes, date: copy.created,
                                            dateLabel: "created", group: group,
                                            blocked: Trash.rejection(for: copy.path),
                                            info: ["hash": digest,
                                                   "mtime": String(Int(copy.modified.timeIntervalSince1970))]))
                }
            }
            let wasted = groups.reduce(Int64(0)) { $0 + $1.copies[0].bytes * Int64($1.copies.count - 1) }
            return FindingScan(findings: findings, notes: [
                "\(groups.count) sets of identical files across \(scanned) checked — "
                + "\(formatBytesDecimal(wasted)) taken by extra copies."])
        }
    )
}

extension Features {
    /// Large & Old Files and Disk Hogs answer the same question — what is
    /// taking the space? — so they are one list: your own big files by age,
    /// then the known space-heavy folders with what removing each one means.
    static let largeFiles = Feature(
        pane: .largeFiles,
        emptyTitle: "Nothing large",
        emptyMessage: "No big files in your folders and no space-heavy locations worth a look.",
        notice: "Your own files above the size threshold, oldest first, then folders that are known "
              + "to grow large (caches, models, backups, VMs) with what removing each one means. "
              + "Files inside libraries such as Photos are never listed individually.",
        action: FindingAction(title: "Move to Trash", icon: "trash", destructive: true,
                              explanation: "Moved to the Trash, not deleted.",
                              perform: { await FindingOutcome.trash($0) }),
        scan: {
            async let files = largeFileScan()
            async let hogs = diskHogScan()
            let fileScan = try await files
            let hogScan = try await hogs
            return FindingScan(findings: fileScan.findings + hogScan.findings.map {
                                   var row = $0; row.group = "Folders · " + ($0.group ?? ""); return row
                               },
                               notes: fileScan.notes)
        }
    )
}
