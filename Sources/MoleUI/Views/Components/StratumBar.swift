import SwiftUI

/// The signature element. Every size breakdown in the app — clean sections,
/// analyze entries, disk usage, per-core CPU — is drawn as a flat horizontal
/// stratum, like a cut through soil. Chosen over pie charts and rounded
/// progress pills so that one visual language covers all six panes and the eye
/// can compare any two rows anywhere in the app.
struct StratumBar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6
    var track: Color = Mole.surfaceHigh

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                Rectangle()
                    .fill(color)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
    }
}

/// Several strata stacked into one bar — used for a disk's used/purgeable split
/// and for the clean preview's category mix.
struct StratumStack: View {
    struct Segment: Identifiable {
        let id = UUID()
        var fraction: Double
        var color: Color
    }

    var segments: [Segment]
    var height: CGFloat = 6
    var track: Color = Mole.surfaceHigh

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(track)
                HStack(spacing: 1) {
                    ForEach(segments) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(0, segment.fraction) * geo.size.width)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 1.5))
    }
}

/// A labelled row: name on the left, stratum beneath, size right-aligned in
/// mono so every size in a list forms one readable column.
struct StratumRow: View {
    var title: String
    var size: String
    var fraction: Double
    var color: Color = Mole.amber
    var subtitle: String?
    var badge: String?
    var badgeColor: Color = Mole.brand

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Mole.text)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(badgeColor.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 3))
                }

                Spacer(minLength: 8)

                Text(size)
                    .font(Mole.mono(11))
                    .monospacedDigit()
                    .foregroundStyle(Mole.textDim)
            }

            StratumBar(fraction: fraction, color: color)

            if let subtitle {
                Text(subtitle)
                    .font(Mole.mono(10))
                    .foregroundStyle(Mole.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 3)
    }
}
