import SwiftData
import SwiftUI

struct ShopProductCard: View {
    let product: DiscoveredProductDTO
    let test: () -> Void
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: URL(string: product.imageURL)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: ContentUnavailableView("Image unavailable", systemImage: "photo")
                default: ProgressView()
                }
            }
            .frame(maxWidth: .infinity).frame(height: 260)
            .background(WearwellTheme.previewSurface, in: RoundedRectangle(cornerRadius: 14))

            HStack(alignment: .firstTextBaseline) {
                Text(product.retailer.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(WearwellTheme.sage)
                Spacer()
                Text("\(Int((product.confidence * 100).rounded()))% verified").font(.caption2).foregroundStyle(.secondary)
            }
            Text(product.title).font(.headline)
            price
            Text(product.rationale).font(.subheadline)
            if !product.matchedWardrobeGap.isEmpty {
                Label(product.matchedWardrobeGap, systemImage: "hanger").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Test with my wardrobe", action: test).buttonStyle(.borderedProminent)
                Button { if let url = URL(string: product.canonicalURL) { openURL(url) } } label: { Image(systemName: "safari") }
                    .buttonStyle(.bordered).accessibilityLabel("View at retailer")
                Spacer()
                Button(role: .destructive, action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss recommendation")
            }
            Text("Verified \(verifiedDateText) · Price and availability can change at the retailer.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private var price: some View {
        if let current = product.currentPrice, let currency = product.currency {
            HStack(spacing: 7) {
                Text(current, format: .currency(code: currency)).font(.headline)
                if product.hasVerifiedMarkdown, let original = product.originalPrice {
                    Text(original, format: .currency(code: currency)).strikethrough().font(.subheadline).foregroundStyle(.secondary)
                    Text("SALE").font(.caption2.bold()).foregroundStyle(WearwellTheme.coral)
                }
            }
        } else {
            Text("Check current price").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var verifiedDateText: String {
        guard let date = ISO8601DateFormatter().date(from: product.verifiedAt) else { return "recently" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct ShoppingPreferencesView: View {
    @Bindable var profile: ShoppingProfile
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var customDomain = ""

    var body: some View {
        Form {
            Section("Region") {
                TextField("Country code", text: textBinding(\.country)).textInputAutocapitalization(.characters)
                TextField("Currency", text: textBinding(\.currency)).textInputAutocapitalization(.characters)
            }
            Section("Sizes and maximum prices") {
                ForEach(GarmentCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.title).font(.subheadline.weight(.semibold))
                        HStack {
                            TextField("Size", text: dictionaryTextBinding(\.sizes, key: category.rawValue))
                            TextField("Max price", text: budgetBinding(category.rawValue)).keyboardType(.decimalPad)
                        }
                    }
                }
            }
            Section("Stores") {
                ForEach(ShoppingRetailer.bundled) { retailer in
                    Toggle(retailer.name, isOn: retailerBinding(retailer.domain))
                }
                HStack {
                    TextField("Add niche store domain", text: $customDomain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") { addDomain() }.disabled(ShoppingRetailer.normalizedDomain(customDomain) == nil)
                }
                ForEach(profile.preferences.customRetailerDomains, id: \.self) { domain in
                    HStack { Text(domain); Spacer(); Button(role: .destructive) { removeDomain(domain) } label: { Image(systemName: "trash") } }
                }
            }
            Section("Avoid") {
                TextField("Categories, comma separated", text: listBinding(\.excludedCategories))
                TextField("Colors, comma separated", text: listBinding(\.excludedColors))
                TextField("Materials, comma separated", text: listBinding(\.excludedMaterials))
            }
            Section {
                Text("Wearwell searches only these stores. A niche site may return fewer results when its product pages do not expose standard metadata.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shopping profile")
        .toolbar { Button("Done") { dismiss() } }
    }

    private func update(_ operation: (inout ShoppingProfileDTO) -> Void) {
        var value = profile.preferences; operation(&value); profile.preferences = value; try? context.save()
    }

    private func textBinding(_ keyPath: WritableKeyPath<ShoppingProfileDTO, String>) -> Binding<String> {
        Binding(get: { profile.preferences[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value.uppercased() } })
    }

    private func dictionaryTextBinding(_ keyPath: WritableKeyPath<ShoppingProfileDTO, [String: String]>, key: String) -> Binding<String> {
        Binding(get: { profile.preferences[keyPath: keyPath][key] ?? "" }, set: { value in
            update { if value.isEmpty { $0[keyPath: keyPath].removeValue(forKey: key) } else { $0[keyPath: keyPath][key] = value } }
        })
    }

    private func budgetBinding(_ key: String) -> Binding<String> {
        Binding(get: { profile.preferences.budgets[key].map { String(format: "%.0f", $0) } ?? "" }, set: { value in
            update { if let number = Double(value), number > 0 { $0.budgets[key] = number } else { $0.budgets.removeValue(forKey: key) } }
        })
    }

    private func retailerBinding(_ domain: String) -> Binding<Bool> {
        Binding(get: { profile.preferences.preferredRetailers.contains(domain) }, set: { enabled in
            update { value in
                if enabled, !value.preferredRetailers.contains(domain) { value.preferredRetailers.append(domain) }
                else if !enabled { value.preferredRetailers.removeAll { $0 == domain } }
            }
        })
    }

    private func listBinding(_ keyPath: WritableKeyPath<ShoppingProfileDTO, [String]>) -> Binding<String> {
        Binding(get: { profile.preferences[keyPath: keyPath].joined(separator: ", ") }, set: { text in
            update { $0[keyPath: keyPath] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        })
    }

    private func addDomain() {
        guard let domain = ShoppingRetailer.normalizedDomain(customDomain) else { return }
        update { if !$0.customRetailerDomains.contains(domain) { $0.customRetailerDomains.append(domain) } }
        customDomain = ""
    }

    private func removeDomain(_ domain: String) { update { $0.customRetailerDomains.removeAll { $0 == domain } } }
}
