import SwiftUI

/// Filled area sparkline.
///
/// `ceiling` fixes the y-domain. Percentage series pass 100 so the trace sits
/// where the number actually is — auto-scaling to the series max makes a steady
/// 73% memory load draw as a full block, implying a machine at its limit.
/// Unbounded series (network MB/s) leave it nil and scale to their own peak.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var ceiling: Double?

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(ceiling ?? values.max() ?? 0, 0.001)
            let step = values.count > 1 ? geo.size.width / CGFloat(values.count - 1) : geo.size.width

            let line = Path { path in
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * step
                    let y = geo.size.height * (1 - CGFloat(value / maxValue))
                    index == 0 ? path.move(to: CGPoint(x: x, y: y))
                               : path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Same trace, closed down to the baseline, for the fill underneath.
            let area = Path { path in
                path.addPath(line)
                path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                path.addLine(to: CGPoint(x: 0, y: geo.size.height))
                path.closeSubpath()
            }

            ZStack {
                area.fill(color.opacity(0.12))
                line.strokedPath(.init(lineWidth: 1.5, lineJoin: .round))
                    .foregroundStyle(color)
            }
        }
        .drawingGroup()
    }
}

/// Health score ring. The one circular element in the app — it earns the
/// exception by being a single 0–100 scalar, which a stratum reads poorly.
struct HealthRing: View {
    var score: Int
    var caption: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Mole.surfaceHigh, lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(Mole.health(score), style: .init(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: score)

            VStack(spacing: 0) {
                Text("\(score)")
                    .font(Mole.mono(26, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Mole.text)
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(Mole.textDim)
                    .lineLimit(1)
            }
        }
    }
}

/// Standard panel. Everything in the app sits in one of these.
///
/// Cards holding a scrolling list must be told they may shrink — see
/// `.scrollableCardContent()`. Without it a ScrollView reports its full content
/// height as the Card's *ideal* height, the Card becomes thousands of points
/// tall, and the whole NavigationSplitView is laid out off the top of the window
/// (taking the sidebar with it).
struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Mole.textDim)
                    }
                    Spacer()
                    if let trailing {
                        Text(trailing)
                            .font(Mole.mono(10))
                            .foregroundStyle(Mole.textFaint)
                    }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Mole.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Mole.border, lineWidth: 1))
    }
}

extension View {
    /// Marks a scrolling region as fully flexible: `minHeight: 0` is the part
    /// that matters — it lets the enclosing stack compress the scroll view
    /// instead of honouring its content height as a floor.
    func scrollableCardContent() -> some View {
        frame(minHeight: 0, maxHeight: .infinity)
    }
}

/// Big number + label, the dashboard's unit of measurement.
struct Metric: View {
    var label: String
    var value: String
    var detail: String?
    var fraction: Double?
    var color: Color = Mole.brand

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(Mole.textDim)

            Text(value)
                .font(Mole.mono(19, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Mole.text)

            if let fraction {
                StratumBar(fraction: fraction, color: color, height: 4)
            }
            if let detail {
                Text(detail)
                    .font(Mole.mono(10))
                    .foregroundStyle(Mole.textFaint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Primary action button. `destructive` is the only place red is allowed.
struct ActionButton: View {
    var title: String
    var systemImage: String?
    var destructive = false
    var loading = false
    var disabled = false
    var action: () -> Void

    private var tint: Color { destructive ? Mole.danger : Mole.brand }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(tint.opacity(disabled || loading ? 0.4 : 1),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
    }
}

/// Quiet secondary button.
struct GhostButton: View {
    var title: String
    var systemImage: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .medium))
                }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Mole.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Mole.surfaceHigh, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

/// "Scanned 12m ago" — shown whenever a pane is displaying a result restored
/// from `ScanCache` rather than one it just produced. A cached number that does
/// not say how old it is looks live, which is the one way this cache could
/// mislead, so every pane that restores one shows this beside its Rescan button.
struct ScanAge: View {
    var date: Date

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9))
            Text("Scanned \(ScanCache.ageLabel(date))")
                .font(.system(size: 10.5))
        }
        .foregroundStyle(Mole.textFaint)
        .help("Showing the last scan. Rescan to measure again.")
    }
}

/// Centred placeholder used for empty, loading and error states.
struct StateMessage: View {
    var icon: String
    var title: String
    var message: String?
    var tint: Color = Mole.textFaint
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Mole.text)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Mole.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let action {
                ActionButton(title: action.title, action: action.run)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

/// Inline notice. Amber by default — never red, since nothing here deletes.
struct Notice: View {
    var icon: String = "info.circle"
    var text: String
    var tint: Color = Mole.amber
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Mole.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let trailing { trailing }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.2), lineWidth: 1))
    }
}

/// Confirmation gate for anything that deletes. `mo clean` does **not** prompt
/// when stdin is not a TTY, so this sheet is the only thing standing between a
/// click and the deletion — it always names the total.
struct ConfirmSheet: View {
    var title: String
    var summary: String
    var detail: String
    var confirmTitle: String
    /// False for actions that change rather than delete (resetting a
    /// permission, running an update) — those stay purple, so red keeps meaning
    /// exactly one thing.
    var destructive = true
    var onConfirm: () -> Void
    var onCancel: () -> Void

    private var tint: Color { destructive ? Mole.danger : Mole.brand }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: destructive ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Mole.text)
            }

            Text(summary)
                .font(Mole.mono(17, weight: .medium))
                .foregroundStyle(tint)

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Mole.textDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                GhostButton(title: "Cancel", action: onCancel)
                ActionButton(title: confirmTitle,
                             systemImage: destructive ? "trash" : "checkmark",
                             destructive: destructive, action: onConfirm)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Mole.surface)
    }
}
