import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var monitor: StatusMonitor
    @AppStorage(Prefs.menuBarCPU) private var menuBarCPU = false
    @AppStorage(Prefs.liveInterval) private var liveInterval = 2
    @AppStorage(Prefs.largeFileMB) private var largeFileMB = 100
    @AppStorage(Prefs.unusedDays) private var unusedDays = 90
    @AppStorage(Prefs.duplicateMinMB) private var duplicateMinMB = 1
    @AppStorage(Prefs.cacheHours) private var cacheHours = 24
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var cleared = false
    @State private var moleVersion = "—"

    var body: some View {
        PaneScaffold(title: Pane.settings.title, subtitle: Pane.settings.subtitle) {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Card(title: "Battery & performance") {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Show CPU usage in the menu bar", isOn: $menuBarCPU)
                                .onChange(of: menuBarCPU) { _, _ in monitor.applyMenuBarPreference() }
                            hint("Off by default. On, MoleUI samples every 10 seconds even with the window "
                               + "closed; off, the menu bar costs nothing until you open its panel.")
                            picker("System Monitor refresh", $liveInterval,
                                   [(1, "Every second"), (2, "Every 2 seconds"), (5, "Every 5 seconds")])
                            hint("Live sampling only runs while a MoleUI window is actually visible. It stops "
                               + "when the window is hidden, covered or minimised, when the display sleeps, "
                               + "and when the Mac sleeps — and runs half as often in Low Power Mode.")
                            HStack(spacing: 6) {
                                Circle().fill(monitor.isRunning ? Mole.moss : Mole.textFaint).frame(width: 6, height: 6)
                                Text(monitor.isRunning
                                     ? "Collector running every \(monitor.targetInterval ?? 0)s"
                                     : "Collector stopped — using no CPU")
                                    .font(Mole.mono(10.5)).foregroundStyle(Mole.textDim)
                            }
                        }
                    }

                    Card(title: "Scans") {
                        VStack(alignment: .leading, spacing: 12) {
                            picker("Reuse a scan for", $cacheHours,
                                   [(1, "1 hour"), (6, "6 hours"), (24, "1 day"), (168, "1 week")])
                            hint("Panes show their last scan instantly, labelled with its age, until it is "
                               + "older than this. Anything that deletes always forces a fresh scan.")
                            HStack {
                                GhostButton(title: cleared ? "Cleared" : "Clear cached scans",
                                            systemImage: cleared ? "checkmark" : "trash") {
                                    ScanCache.clearAll()
                                    cleared = true
                                }
                                Spacer()
                            }
                            picker("Large file threshold", $largeFileMB,
                                   [(50, "50 MB"), (100, "100 MB"), (250, "250 MB"), (500, "500 MB"), (1000, "1 GB")])
                            picker("Unused after", $unusedDays,
                                   [(30, "30 days"), (60, "60 days"), (90, "90 days"), (180, "6 months"), (365, "1 year")])
                            picker("Ignore duplicates smaller than", $duplicateMinMB,
                                   [(1, "1 MB"), (10, "10 MB"), (100, "100 MB")])
                        }
                    }

                    Card(title: "General") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Open MoleUI at login", isOn: $launchAtLogin)
                                .onChange(of: launchAtLogin) { _, enabled in
                                    do {
                                        if enabled { try SMAppService.mainApp.register() }
                                        else { try SMAppService.mainApp.unregister() }
                                        loginError = nil
                                    } catch {
                                        loginError = error.localizedDescription
                                        launchAtLogin = SMAppService.mainApp.status == .enabled
                                    }
                                }
                            if let loginError { hint(loginError) }
                            HStack {
                                Text("Mole").font(.system(size: 11.5)).foregroundStyle(Mole.textDim)
                                Spacer()
                                Text(moleVersion).font(Mole.mono(10.5)).foregroundStyle(Mole.textFaint)
                            }
                            HStack {
                                Text("MoleUI").font(.system(size: 11.5)).foregroundStyle(Mole.textDim)
                                Spacer()
                                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                                    .font(Mole.mono(10.5)).foregroundStyle(Mole.textFaint)
                            }
                        }
                    }
                }
                .toggleStyle(.switch)
                .font(.system(size: 12))
                .foregroundStyle(Mole.text)
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .task {
            if let output = try? await MoleCLI.shared.run(["--version"]) {
                moleVersion = output.stdout.components(separatedBy: .newlines)
                    .first { !$0.isEmpty }?.trimmingCharacters(in: .whitespaces) ?? "—"
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Mole.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func picker(_ label: String, _ value: Binding<Int>, _ options: [(Int, String)]) -> some View {
        Picker(label, selection: value) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 380)
    }
}
