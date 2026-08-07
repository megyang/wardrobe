import SwiftData
import SwiftUI
import UIKit

private struct SendableImage: @unchecked Sendable {
    let value: UIImage?
}

enum KeyboardController {
    @MainActor
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct KeyboardDismissToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { KeyboardController.dismiss() }
                        .accessibilityLabel("Dismiss keyboard")
                }
            }
    }
}

extension View {
    func keyboardDismissToolbar() -> some View { modifier(KeyboardDismissToolbar()) }
}

/// Reorders as soon as a held card crosses another card, then commits when the
/// drag ends. This gives grids and lists direct hold-and-slide behavior without
/// an Edit mode or separate drag handle.
struct DirectReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct DirectStringReorderDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedID: String?
    let move: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

struct EditorialHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.caption2.weight(.bold)).tracking(1.6).foregroundStyle(WearwellTheme.sage)
            Text(title).font(.system(size: compact ? 29 : 35, weight: .semibold, design: .serif)).foregroundStyle(WearwellTheme.ink)
            Text(subtitle).font(compact ? .caption : .subheadline).foregroundStyle(WearwellTheme.muted).lineLimit(compact ? 2 : nil)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LunaStylingNote: View {
    let rationale: String

    private var containsScarfGuidance: Bool {
        rationale.localizedCaseInsensitiveContains("scarf styling") ||
            rationale.localizedCaseInsensitiveContains("how to wear the scarf") ||
            rationale.localizedCaseInsensitiveContains("another way") ||
            rationale.localizedCaseInsensitiveContains("scarf:")
    }

    var body: some View {
        if !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(WearwellTheme.coral)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(containsScarfGuidance ? "How to wear the scarf" : "Luna’s styling note")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(WearwellTheme.sage)
                    Text(rationale)
                        .font(.subheadline)
                        .foregroundStyle(WearwellTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .combine)
        }
    }
}

private func shortened(_ value: String, words maximum: Int) -> String {
    let words = value.split { $0.isWhitespace }
    let text = words.prefix(maximum).joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    return text.isEmpty ? "" : text + "."
}

private func compactScarfRationale(_ value: String) -> String {
    var sentences: [String] = []
    value.enumerateSubstrings(in: value.startIndex..<value.endIndex, options: .bySentences) { substring, _, _, _ in
        if let substring { sentences.append(substring.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    let primary = sentences.first { $0.localizedCaseInsensitiveContains("how to wear") || $0.localizedCaseInsensitiveContains("scarf styling") || $0.localizedCaseInsensitiveContains("scarf:") }
    let alternate = sentences.first { $0.localizedCaseInsensitiveContains("another way") || $0.localizedCaseInsensitiveContains("alternative:") }
    let general = sentences.first { sentence in sentence != primary && sentence != alternate }
    func instruction(_ sentence: String?) -> String {
        guard let sentence else { return "" }
        return sentence.replacingOccurrences(
            of: #"(?i)^(how to wear (the )?scarf|scarf styling|scarf|another way|alternative):\s*"#,
            with: "", options: .regularExpression
        )
    }
    return [
        general.map { shortened($0, words: 16) },
        primary.map { "Scarf: \(shortened(instruction($0), words: 12))" },
        alternate.map { "Alternative: \(shortened(instruction($0), words: 12))" }
    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
}

func visibleLunaRationale(_ rationale: String, garmentIDs: [UUID], garments: [Garment]) -> String {
    let selected = Set(garmentIDs)
    guard let scarf = garments.first(where: {
        selected.contains($0.id) &&
            ($0.subcategory == .scarf || $0.label.localizedCaseInsensitiveContains("scarf"))
    }) else { return rationale }

    let lowered = rationale.lowercased()
    let explicitlyStyled = lowered.contains("scarf") &&
        (lowered.contains("another way") || lowered.contains("alternative:")) && [
        "tie", "tied", "knot", "drape", "wrap", "loop", "wear", "worn", "style", "headscarf", "headband"
    ].contains { lowered.contains($0) }
    if explicitlyStyled { return compactScarfRationale(rationale) }

    let evidence = [scarf.label, scarf.details, scarf.observed].joined(separator: " ").lowercased()
    let alternate = evidence.range(of: #"\b(long|skinny|thin|narrow|slim)\b"#, options: .regularExpression) != nil
        ? "Alternative: low-ponytail ribbon with loose ends."
        : "Alternative: small side knot at the neck."
    let instruction = "Scarf: neck knot with long, uneven ends. \(alternate)"
    return compactScarfRationale([rationale.trimmingCharacters(in: .whitespacesAndNewlines), instruction]
        .filter { !$0.isEmpty }
        .joined(separator: " "))
}

struct AssetImage: View {
    let name: String
    var contentMode: ContentMode = .fit
    var body: some View {
        Group {
            if let image = AssetStore.image(named: name) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    WearwellTheme.cream
                    Image(systemName: "tshirt").font(.largeTitle).foregroundStyle(WearwellTheme.sage.opacity(0.45))
                }
            }
        }
    }
}

struct CollageAssetImage: View {
    let name: String
    @State private var cutout: UIImage?
    @State private var loadedName: String?

    init(name: String) {
        self.name = name
        let cached = AssetStore.cachedCollageImage(named: name)
        _cutout = State(initialValue: cached)
        _loadedName = State(initialValue: cached == nil ? nil : name)
    }

    var body: some View {
        Group {
            if loadedName == name, let cutout {
                Image(uiImage: cutout).resizable().scaledToFit()
            } else {
                // Never flash the unprocessed asset: generated backdrop colors
                // and checker grids are especially noticeable during scrolling.
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.18), value: loadedName)
        .task(id: name) {
            guard loadedName != name else { return }
            if let cached = AssetStore.cachedCollageImage(named: name) {
                cutout = cached
                loadedName = name
                return
            }
            let task = Task.detached(priority: .userInitiated) {
                SendableImage(value: AssetStore.collageImage(named: name))
            }
            let result = await withTaskCancellationHandler(
                operation: { await task.value },
                onCancel: { task.cancel() }
            )
            if !Task.isCancelled {
                cutout = result.value
                loadedName = name
            }
        }
    }
}

struct CatalogDataImage: View {
    let data: Data
    @State private var cutout: UIImage?

    var body: some View {
        Group {
            if let cutout {
                Image(uiImage: cutout).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: data) {
            cutout = nil
            let task = Task.detached(priority: .userInitiated) {
                guard let source = UIImage(data: data) else { return nil as Data? }
                return AssetStore.preparedCollageImage(from: source).pngData()
            }
            let previewData = await withTaskCancellationHandler(
                operation: { await task.value },
                onCancel: { task.cancel() }
            )
            if !Task.isCancelled { cutout = previewData.flatMap(UIImage.init(data:)) }
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = WearwellTheme.sage
    var body: some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 9).padding(.vertical, 6)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .foregroundStyle(WearwellTheme.ink)
    }
}

struct GarmentCard: View {
    let garment: Garment
    @Query private var subcategories: [WardrobeSubcategory]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollageAssetImage(name: garment.catalogAssetName.isEmpty ? garment.sourceAssetName : garment.catalogAssetName)
                .padding(10).frame(height: 210).frame(maxWidth: .infinity).background(WearwellTheme.previewSurface).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(garment.label).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(garment.color) · \(subcategories.title(for: garment.subcategoryRaw, fallback: garment.category))").font(.caption).foregroundStyle(WearwellTheme.muted).lineLimit(1)
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
