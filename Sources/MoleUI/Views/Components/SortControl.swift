import SwiftUI

/// How a list of sized things is ordered. Shared by every pane that shows sizes,
/// so "Largest first" means the same thing in Clean as it does in Analyze.
///
/// Named `ListSort` rather than `SortOrder` on purpose: Foundation already has a
/// `SortOrder`, and a module-level type of the same name would shadow it
/// silently for every file in the target.
enum ListSort: String, CaseIterable, Identifiable {
    case sizeDescending = "size-desc"
    case sizeAscending  = "size-asc"
    case nameAscending  = "name-asc"
    case nameDescending = "name-desc"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sizeDescending: return "Largest first"
        case .sizeAscending:  return "Smallest first"
        case .nameAscending:  return "Name A–Z"
        case .nameDescending: return "Name Z–A"
        }
    }

    var systemImage: String {
        switch self {
        case .sizeDescending: return "arrow.down.to.line"
        case .sizeAscending:  return "arrow.up.to.line"
        case .nameAscending:  return "textformat.abc"
        case .nameDescending: return "textformat.abc.dottedunderline"
        }
    }

    /// Ordering is fully determined: whichever key is not being sorted on breaks
    /// ties. Without that, everything Mole reports at the same size — and in a
    /// file list that is thousands of rows at "4KB" — would land in whatever
    /// order `sorted(by:)` happened to produce, and shuffle on every rescan.
    func sort<T>(_ items: [T],
                 name: (T) -> String,
                 bytes: (T) -> Int64) -> [T] {
        items.sorted { first, second in
            switch self {
            case .sizeDescending, .sizeAscending:
                let (left, right) = (bytes(first), bytes(second))
                if left != right {
                    return self == .sizeDescending ? left > right : left < right
                }
                return name(first).localizedStandardCompare(name(second)) == .orderedAscending

            case .nameAscending, .nameDescending:
                // localizedStandardCompare is Finder's ordering: case-insensitive
                // and numeric, so "file10" sorts after "file9".
                let order = name(first).localizedStandardCompare(name(second))
                if order != .orderedSame {
                    return self == .nameAscending
                        ? order == .orderedAscending
                        : order == .orderedDescending
                }
                return bytes(first) > bytes(second)
            }
        }
    }

    // MARK: - Persistence

    /// Panes keep their own choice, and keep it across launches — picking
    /// "Largest first" every time you open the app is the kind of small
    /// re-doing this whole change exists to remove.
    static func stored(_ key: String) -> ListSort {
        UserDefaults.standard.string(forKey: "sort." + key)
            .flatMap(ListSort.init(rawValue:)) ?? .sizeDescending
    }

    func store(_ key: String) {
        UserDefaults.standard.set(rawValue, forKey: "sort." + key)
    }
}

/// The sort picker itself — styled as a `GhostButton` so it reads as one of the
/// pane's header controls rather than a system popup.
struct SortMenu: View {
    @Binding var order: ListSort
    var help = "Order every list in this pane"

    var body: some View {
        Menu {
            ForEach(ListSort.allCases) { option in
                Button {
                    order = option
                } label: {
                    // The collapsed label already names the active order; the
                    // open menu marks it too, so there is no moment where the
                    // menu looks like nothing is selected.
                    Label(option.label,
                          systemImage: option == order ? "checkmark" : option.systemImage)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .medium))
                Text(order.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Mole.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Mole.surfaceHigh, in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
    }
}
