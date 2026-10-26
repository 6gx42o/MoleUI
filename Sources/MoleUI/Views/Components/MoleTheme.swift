import SwiftUI
import AppKit

/// "Burrow" palette — soil-dark by default, with a light counterpart so the app
/// follows the system appearance instead of fighting it.
///
/// One rule holds the whole thing together: **red appears nowhere except
/// destructive confirmation.** Warnings are amber, brand is purple, freed space
/// is amber. So when something turns red, it deletes.
enum Mole {

    private static func dynamic(dark: String, light: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    // Surfaces, dug in layers
    static let soil        = dynamic(dark: "14110F", light: "F7F4F0")
    static let surface     = dynamic(dark: "1E1A17", light: "FFFFFF")
    static let surfaceHigh = dynamic(dark: "29231E", light: "EFEAE4")
    static let border      = dynamic(dark: "362E27", light: "DFD7CD")

    // Ink
    static let text        = dynamic(dark: "F2EDE7", light: "1B1613")
    static let textDim     = dynamic(dark: "A2968B", light: "6B6058")
    static let textFaint   = dynamic(dark: "6B605A", light: "9A9089")

    // Meaning
    static let brand       = dynamic(dark: "8B5CF6", light: "7C3AED")  // echoes the CLI's PURPLE_BOLD
    static let amber       = dynamic(dark: "E0A756", light: "B87A19")  // reclaimable / freed
    static let moss        = dynamic(dark: "6BA368", light: "4A7C47")  // healthy / nothing to do
    static let danger      = dynamic(dark: "E5484D", light: "CE2C31")  // destructive only

    /// Health score → colour. Deliberately never red: a low score is a warning,
    /// not a deletion.
    static func health(_ score: Int) -> Color {
        switch score {
        case 80...:  return moss
        case 55..<80: return amber
        default:      return brand
        }
    }

    /// Load/usage ramp for gauges and per-core bars.
    static func load(_ percent: Double) -> Color {
        switch percent {
        case ..<60:  return moss
        case ..<85:  return amber
        default:     return brand
        }
    }

    // Type: SF Mono with tabular figures for every byte count and path, so
    // sizes line up into a scannable column.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static let rowHeight: CGFloat = 28
    static let gutter: CGFloat = 16
}

private extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green:   CGFloat((value >> 8) & 0xFF) / 255,
                  blue:    CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}

// Mole is not internally consistent about byte units, and the split is not
// "Go vs bash" — it is per command, which is why an earlier guess here was
// wrong in both directions. Measured against the real tool:
//
//   mo status   BINARY.  memory.total 25769803776 → its own "24.0 GB" (= GiB);
//                        disk 994610155520 → "926.3 GB" (= GiB).
//   mo analyze  DECIMAL. Its TUI renders 105671585330 as "105.7 GB" (= 105.67e9),
//                        not the 98.4 GiB a binary divisor would give.
//   mo clean    DECIMAL. bytes_to_human() branches on 1e9 / 1e6 / 1e3.
//   mo purge    DECIMAL. same helper.
//   mo history  DECIMAL, and its size_kb is KiB — bytes_to_human_kb multiplies
//                        by 1024 first, then formats decimally.
//
// The names below say which divisor they use so a call site cannot be wrong by
// accident; the doc comment says which command's numbers belong in each.

/// Binary (1024), one decimal — matching `mo status`, which prints
/// 25769803776 as "24.0 GB". **Only** for status values: memory, disks, trash,
/// process RSS. Nothing else in Mole renders binary.
func formatBytesBinary(_ bytes: Int64) -> String {
    format(bytes, divisor: 1024, fractionDigits: 1)
}

func formatBytesBinary(_ bytes: UInt64) -> String {
    formatBytesBinary(Int64(clamping: bytes))
}

/// Decimal (1000). For everything else. `fractionDigits` defaults to Mole's
/// bash convention (two at GB and above, one at MB) so computed totals read
/// identically to strings like "Potential space: 16.57GB". `mo analyze` prints
/// one decimal instead ("105.7 GB"), so that pane passes 1.
func formatBytesDecimal(_ bytes: Int64, fractionDigits: Int? = nil) -> String {
    format(bytes, divisor: 1000, fractionDigits: fractionDigits)
}

private func format(_ bytes: Int64, divisor: Double, fractionDigits: Int? = nil) -> String {
    guard bytes > 0 else { return "0B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var index = 0
    while value >= divisor, index < units.count - 1 {
        value /= divisor
        index += 1
    }
    // Decimal places match bytes_to_human() so our figures read identically to
    // Mole's own strings beside them: two at GB and above ("16.57GB"), one at
    // MB ("163.3MB"), none below. Printing "16.6GB" next to Mole's "16.57GB"
    // looks like a discrepancy even when the underlying number is the same.
    let digits = fractionDigits ?? (index <= 1 ? 0 : index == 2 ? 1 : 2)
    return String(format: "%.\(digits)f%@", value, units[index])
}
