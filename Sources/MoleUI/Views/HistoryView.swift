import SwiftUI

@MainActor
final class HistoryModel: ObservableObject {
    @Published var log: HistoryLog?
    @Published var loading = false
    @Published var error: String?

    func load() async {
        loading = true
        defer { loading = false }
        do {
            log = try await MoleCLI.shared.history()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct HistoryView: View {
    @StateObject private var model = HistoryModel()

    var body: some View {
        PaneScaffold(title: Pane.history.title, subtitle: Pane.history.subtitle) {
            GhostButton(title: "Refresh", systemImage: "arrow.clockwise") {
                Task { await model.load() }
            }
        } content: {
            content
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading && model.log == nil {
            StateMessage(icon: "hourglass", title: "Reading logs…", message: nil)
        } else if let error = model.error, model.log == nil {
            StateMessage(icon: "exclamationmark.triangle", title: "Could not read history",
                         message: error, tint: Mole.amber)
        } else if let log = model.log {
            let sessions = log.sessions ?? []
            let deletions = log.deletions ?? []

            if sessions.isEmpty && deletions.isEmpty {
                StateMessage(icon: "clock.arrow.circlepath", title: "No activity yet",
                             message: "Mole logs every clean, uninstall and purge to "
                                    + "~/Library/Logs/mole. Nothing has run yet.")
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if !sessions.isEmpty {
                            Card(title: "Sessions", trailing: "most recent first") {
                                VStack(spacing: 8) {
                                    ForEach(sessions) { session in
                                        sessionRow(session)
                                    }
                                }
                            }
                        }
                        if !deletions.isEmpty {
                            Card(title: "Deleted paths", trailing: "\(deletions.count) entries") {
                                VStack(spacing: 3) {
                                    ForEach(deletions) { deletion in
                                        deletionRow(deletion)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
    }

    private func sessionRow(_ session: HistoryLog.Session) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.command.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Mole.text)
                Text(session.startedAt)
                    .font(Mole.mono(9.5))
                    .foregroundStyle(Mole.textFaint)
            }
            .frame(width: 150, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if !session.size.isEmpty && session.size != "0B" {
                        Text(session.size)
                            .font(Mole.mono(13, weight: .medium))
                            .foregroundStyle(Mole.amber)
                    }
                    Text("\(session.items) items")
                        .font(.system(size: 11))
                        .foregroundStyle(Mole.textDim)
                    Spacer()
                }
                HStack(spacing: 8) {
                    counter("removed", session.actions.removed, Mole.textDim)
                    counter("trashed", session.actions.trashed, Mole.brand)
                    counter("skipped", session.actions.skipped, Mole.textFaint)
                    counter("rebuilt", session.actions.rebuilt, Mole.moss)
                    counter("failed", session.actions.failed, Mole.amber)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(Mole.surfaceHigh.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func counter(_ label: String, _ value: Int, _ color: Color) -> some View {
        if value > 0 {
            HStack(spacing: 3) {
                Text("\(value)")
                    .font(Mole.mono(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Mole.textFaint)
            }
        }
    }

    private func deletionRow(_ deletion: HistoryLog.Deletion) -> some View {
        HStack(spacing: 8) {
            Text(deletion.timestamp)
                .font(Mole.mono(9.5))
                .foregroundStyle(Mole.textFaint)
                .frame(width: 130, alignment: .leading)
            Text(deletion.mode)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(deletion.mode == "trash" ? Mole.brand : Mole.amber)
                .frame(width: 46, alignment: .leading)

            // `status` was decoded and never rendered, so a deletion that failed
            // was indistinguishable from one that succeeded — in the one view
            // whose whole purpose is telling you what actually happened.
            if !deletion.status.isEmpty, deletion.status != "ok",
               deletion.status != "success" {
                Text(deletion.status.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Mole.amber)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Mole.amber.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 3))
            }
            Text(deletion.path)
                .font(Mole.mono(10))
                .foregroundStyle(Mole.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(deletion.path)
            Spacer(minLength: 6)
            Text(deletion.sizeKB.map { formatBytesDecimal($0 * 1024) } ?? "—")
                .font(Mole.mono(9.5))
                .monospacedDigit()
                .foregroundStyle(Mole.textFaint)
        }
    }
}
