import SwiftUI

struct RootView: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var monitor: StatusMonitor

    var body: some View {
        splitView
            // The sidebar footer's live numbers are the only thing this window
            // needs continuously, and a 5s sample is plenty for a footer. The
            // demand only counts while the window is actually visible — see
            // WindowVisibilityReader — so a hidden, minimised or covered window
            // costs nothing.
            .task { monitor.demand(.window, every: 5) }
            .onDisappear { monitor.demand(.window, every: nil) }
            .background(WindowVisibilityReader { monitor.setWindowVisible($0) })
    }

    private var splitView: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 224, max: 260)
        } detail: {
            PaneBounds {
                Group {
                    if MoleCLI.shared.isInstalled || !router.pane.needsMole {
                        detail(router.pane)
                    } else {
                        NotInstalledView()
                    }
                }
                // A fresh identity per pane, so two panes built from the same
                // view type never share (and leak) each other's state.
                .id(router.pane)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Mole.soil)
        }
    }

    @ViewBuilder
    private func detail(_ pane: Pane) -> some View {
        switch pane {
        case .smartScan:         SmartScanView()
        case .clean:             CleanView()
        case .leftovers:         FindingsPane(feature: Features.leftovers)
        case .trashBins:         FindingsPane(feature: Features.trashBins)
        case .history:           HistoryView()
        case .malware:           FindingsPane(feature: Features.malware)
        case .privacy:           FindingsPane(feature: Features.privacy)
        case .wifi:              FindingsPane(feature: Features.savedWiFi)
        case .permissions:       FindingsPane(feature: Features.permissions)
        case .maintenance:       MaintenanceView()
        case .dashboard:         DashboardView()
        case .uninstall:         UninstallView()
        case .extensions:        FindingsPane(feature: Features.extensions)
        case .updater:           FindingsPane(feature: Features.updater)
        case .analyze:           AnalyzeView()
        case .largeFiles:        FindingsPane(feature: Features.largeFiles)
        case .duplicates:        FindingsPane(feature: Features.duplicates)
        case .shredder:          ShredderView()
        case .settings:          SettingsView()
        }
    }
}

extension Pane {
    /// Panes that are thin wrappers over a `mo` command. The rest are native
    /// and work whether or not Mole is installed.
    var needsMole: Bool {
        switch self {
        case .clean, .history, .dashboard, .uninstall, .analyze:
            return true
        default:
            return false
        }
    }
}

/// Reports whether the hosting window can actually be seen: on screen, not
/// minimised, not fully covered by other windows, app not hidden. AppKit's
/// occlusion state already folds all of those together.
struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) { view.onChange = onChange }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { onChange?(false); return }
            let center = NotificationCenter.default
            // Occlusion is the signal that matters, but at launch the window can
            // be ordered in without a later occlusion change reaching us — the
            // reader reported "hidden" once and the collector never started.
            // Becoming key or main, and the app activating, re-check too.
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.didBecomeMainNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in self?.report()
                })
            }
            observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                object: nil, queue: .main) { [weak self] _ in
                self?.report()
            })
            // And once more after the window has finished appearing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.report() }
            // At willClose the window still reports itself visible.
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification,
                                                object: window, queue: .main) { [weak self] _ in
                self?.onChange?(false)
            })
            report()
        }

        private func report() {
            guard let window else { onChange?(false); return }
            onChange?(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

private struct Sidebar: View {
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var monitor: StatusMonitor
    @AppStorage("sidebar.collapsed") private var collapsedRaw = ""

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: ",").map(String.init))
    }

    private func toggle(_ section: Pane.Section) {
        var set = collapsed
        if set.contains(section.rawValue) { set.remove(section.rawValue) } else { set.insert(section.rawValue) }
        collapsedRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Mole.brand)
                Text("Mole")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Mole.text)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 26)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Pane.Section.allCases, id: \.self) { section in
                        if section != .top {
                            Button { toggle(section) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: collapsed.contains(section.rawValue)
                                          ? "chevron.right" : "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                    Text(section.rawValue.uppercased())
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .tracking(0.7)
                                    Spacer()
                                }
                                .foregroundStyle(Mole.textFaint)
                                .padding(.horizontal, 18)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if !collapsed.contains(section.rawValue) {
                            ForEach(Pane.allCases.filter { $0.section == section }) { pane in
                                SidebarRow(pane: pane, selected: router.pane == pane) {
                                    router.pane = pane
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Divider().overlay(Mole.border)
            SidebarRow(pane: .settings, selected: router.pane == .settings) { router.pane = .settings }
                .padding(.top, 4)

            // Live footer: the machine's pulse stays visible from every pane.
            if let snapshot = monitor.snapshot {
                HStack(spacing: 10) {
                    footerStat("CPU", snapshot.cpu.usage)
                    footerStat("MEM", snapshot.memory.usedPercent)
                    if let disk = (snapshot.disks ?? []).first(where: { $0.mount == "/" }) {
                        footerStat("DISK", disk.usedPercent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Mole.soil)
    }

    private func footerStat(_ label: String, _ percent: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Mole.textFaint)
                Text(String(format: "%.0f%%", percent))
                    .font(Mole.mono(9))
                    .monospacedDigit()
                    .foregroundStyle(Mole.textDim)
            }
            StratumBar(fraction: percent / 100, color: Mole.load(percent), height: 3)
        }
    }
}

private struct SidebarRow: View {
    var pane: Pane
    var selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: pane.icon)
                    .font(.system(size: 11.5))
                    .frame(width: 17)
                    .foregroundStyle(pane.tint)
                Text(pane.title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Mole.text : Mole.textDim)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Mole.surfaceHigh
                                   : (hovering ? Mole.surface : .clear))
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(pane.subtitle)
    }
}

private struct NotInstalledView: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 14) {
            StateMessage(
                icon: "shippingbox",
                title: "Mole isn’t installed",
                message: "This app is a front end for the `mo` command line tool. "
                       + "Install it, then reopen this window.",
                tint: Mole.amber
            )
            HStack(spacing: 8) {
                Text("brew install mole")
                    .font(Mole.mono(12))
                    .foregroundStyle(Mole.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Mole.surfaceHigh, in: RoundedRectangle(cornerRadius: 5))
                GhostButton(title: copied ? "Copied" : "Copy",
                            systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install mole", forType: .string)
                    copied = true
                }
            }
            .offset(y: -40)
        }
    }
}

/// Shared page scaffold: title, subtitle, actions, then content.
struct PaneScaffold<Content: View, Actions: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var actions: Actions
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Mole.text)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Mole.textDim)
                }
                Spacer()
                HStack(spacing: 8) { actions }
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 16)

            content
        }
    }
}

/// Pins a pane to exactly the space the detail column offers.
///
/// Relying on flexible frames alone was not enough: with a big enough list the
/// pane's *ideal* height still won out, the split view sized itself to that, and
/// the whole thing rendered off the top of the window — sidebar included. A
/// GeometryReader accepts the proposed size and reports it, so clamping to
/// `geo.size` both anchors a definite height for everything below and stops any
/// residual overflow from painting outside the window.
struct PaneBounds<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            content
                .frame(width: geo.size.width,
                       height: geo.size.height,
                       alignment: .topLeading)
        }
        .clipped()
    }
}
