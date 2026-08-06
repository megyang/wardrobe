import SwiftData
import SwiftUI

enum ShopProductTestState: Equatable {
    case idle, queueing, queued, saved

    var label: String {
        switch self {
        case .idle: "Wardrobe test"
        case .queueing: "Queueing…"
        case .queued: "Queued"
        case .saved: "In Saved"
        }
    }

    var icon: String {
        switch self {
        case .idle: "sparkles"
        case .queueing: "clock"
        case .queued: "checkmark.circle.fill"
        case .saved: "bookmark.fill"
        }
    }
}

struct ShopProductCard: View {
    let product: DiscoveredProductDTO
    let test: (() -> Void)?
    let dismiss: () -> Void
    var save: (() -> Void)? = nil
    var isSaving = false
    var testState: ShopProductTestState = .idle
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: URL(string: product.imageURL)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFit()
                    case .failure: ContentUnavailableView("Image unavailable", systemImage: "photo")
                    default: ProgressView()
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 260)
                .background(WearwellTheme.previewSurface, in: RoundedRectangle(cornerRadius: 14))

                Button(role: .destructive, action: dismiss) {
                    Image(systemName: "xmark").font(.caption.bold())
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .padding(10)
                .accessibilityLabel("Delete recommendation")
            }

            HStack(alignment: .firstTextBaseline) {
                Text(product.retailer.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(WearwellTheme.sage)
                Spacer()
                Text("\(Int((product.confidence * 100).rounded()))% verified").font(.caption2).foregroundStyle(.secondary)
            }
            Text(product.title).font(.headline)
            price
            if !product.rationale.isEmpty { Text(product.rationale).font(.subheadline).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                if let save {
                    Button(action: save) {
                        HStack(spacing: 5) {
                            if isSaving { ProgressView() } else { Image(systemName: "heart") }
                            Text(isSaving ? "Saving…" : "Save")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                }
                if let test {
                    Button(action: test) {
                        HStack(spacing: 5) {
                            if testState == .queueing { ProgressView() }
                            else { Image(systemName: testState.icon) }
                            Text(testState.label)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(testState != .idle)
                }
                Button { if let url = URL(string: product.canonicalURL) { openURL(url) } } label: {
                    Image(systemName: "safari").frame(width: 24, height: 24)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Open in Safari")
            }
            .controlSize(.large)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
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
            Section("Clothing") {
                Picker("Audience", selection: audienceBinding) {
                    ForEach(ShoppingAudience.allCases) { audience in
                        Text(audience.title).tag(audience)
                    }
                }
                .pickerStyle(.segmented)
                Text("Shop searches and ranks clothing for the selected audience. Change this before refreshing or starting a search.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("UCP catalogs") {
                ForEach(ShoppingRetailer.ucp) { retailer in
                    Toggle(retailer.name, isOn: retailerBinding(retailer.domain))
                }
            }
            Section("Web-search stores") {
                ForEach(ShoppingRetailer.web) { retailer in
                    Toggle(retailer.name, isOn: retailerBinding(retailer.domain))
                }
                Text("These stores use verified web discovery and may return fewer products than UCP catalogs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Custom stores") {
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
                Text("Wearwell checks custom stores for UCP automatically, then falls back to verified web discovery. The bundled UCP integration uses Shopify's public development agent profile and must be replaced before a production release.")
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

    private var audienceBinding: Binding<ShoppingAudience> {
        Binding(
            get: { profile.preferences.selectedAudience },
            set: { audience in update { $0.selectedAudience = audience } }
        )
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
