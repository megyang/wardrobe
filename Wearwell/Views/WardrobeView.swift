import SwiftData
import SwiftUI

struct WardrobeView: View {
    @Binding var showSettings: Bool
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var category: GarmentCategory?
    @State private var subcategory: GarmentSubcategory?

    private var filtered: [Garment] {
        garments.filter { garment in
            (category == nil || garment.category == category) &&
            (subcategory == nil || garment.subcategory == subcategory) &&
            (search.isEmpty || [garment.label, garment.color, garment.subcategory?.title ?? "", garment.tags, garment.occasion].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    EditorialHeader(eyebrow: "Your collection", title: "Wardrobe", subtitle: "Everything you own, ready to remix.")
                    categoryStrip
                    if garments.isEmpty {
                        EmptyState(icon: "tshirt", title: "Your wardrobe is waiting", message: "Use Add to catalog clothes from a photo, camera, or link.")
                            .frame(minHeight: 380)
                    } else if filtered.isEmpty {
                        EmptyState(icon: "magnifyingglass", title: "No matches", message: "Try another search or category.").frame(minHeight: 300)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                            ForEach(filtered) { garment in
                                NavigationLink { GarmentDetailView(garment: garment) } label: { GarmentCard(garment: garment) }.buttonStyle(.plain)
                            }
                        }
                    }
                }.padding()
            }
        }
        .searchable(text: $search, prompt: "Search clothes")
        .toolbar { SettingsButton(isPresented: $showSettings) }
    }

    private var categoryStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("All") { category = nil; subcategory = nil }.buttonStyle(FilterButtonStyle(selected: category == nil))
                    ForEach(GarmentCategory.allCases) { item in
                        Button(item.title) { category = item; subcategory = nil }.buttonStyle(FilterButtonStyle(selected: category == item))
                    }
                }
            }
            if let category, !GarmentSubcategory.options(for: category).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("All (category.title.lowercased())") { subcategory = nil }.buttonStyle(FilterButtonStyle(selected: subcategory == nil))
                        ForEach(GarmentSubcategory.options(for: category)) { item in
                            Button(item.filterTitle) { subcategory = item }.buttonStyle(FilterButtonStyle(selected: subcategory == item))
                        }
                    }
                }
            }
        }
    }
}

struct FilterButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption.weight(.semibold)).padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : WearwellTheme.ink)
            .background(selected ? WearwellTheme.sage : WearwellTheme.paper, in: Capsule()).opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct GarmentDetailView: View {
    @Bindable var garment: Garment
    @Query(sort: \Outfit.updatedAt, order: .reverse) private var outfits: [Outfit]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var savedOutfits: [Outfit] {
        outfits.filter { $0.contains(garmentID: garment.id) }
    }

    var body: some View {
        Form {
            Section { CollageAssetImage(name: garment.catalogAssetName.isEmpty ? garment.sourceAssetName : garment.catalogAssetName).padding(16).frame(height: 420).frame(maxWidth: .infinity).background(WearwellTheme.previewSurface) }
            Section {
                NavigationLink {
                    AIStyleView(anchorGarmentID: garment.id)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Generate an outfit with this piece").font(.headline)
                            Text("Luna will build editable collages using only clothes in your wardrobe.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(WearwellTheme.coral)
                    }
                }
            }
            Section("Saved outfits with this piece") {
                if savedOutfits.isEmpty {
                    Text("No saved outfits yet. Generate one with Luna or add this piece to a manual collage.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(savedOutfits) { outfit in
                        NavigationLink {
                            OutfitDetailView(outfit: outfit)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(outfit.title).font(.headline)
                                Text("\(outfit.layout.count) pieces · \(outfit.origin == .aiStyle ? "AI Style" : outfit.origin == .purchaseTest ? "Purchase test" : "Manual")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Details") {
                TextField("Name", text: $garment.label)
                Picker("Category", selection: $garment.categoryRaw) { ForEach(GarmentCategory.allCases) { Text($0.title).tag($0.rawValue) } }
                    .onChange(of: garment.categoryRaw) { _, categoryRaw in
                        guard let category = GarmentCategory(rawValue: categoryRaw), garment.subcategory?.category == category else {
                            garment.subcategoryRaw = nil; return
                        }
                    }
                if !GarmentSubcategory.options(for: garment.category).isEmpty {
                    Picker("Type", selection: $garment.subcategoryRaw) {
                        Text("Unspecified").tag(nil as String?)
                        ForEach(GarmentSubcategory.options(for: garment.category)) { item in
                            Text(item.title).tag(Optional(item.rawValue))
                        }
                    }
                }
                TextField("Color", text: $garment.color)
                TextField("Description", text: $garment.details, axis: .vertical)
                TextField("Tags", text: $garment.tags)
                Toggle("Favorite", isOn: $garment.isFavorite)
            }
            if !garment.observed.isEmpty { Section("Source-supported details") { Text(garment.observed); if !garment.unknowns.isEmpty { Text("Unknown: \(garment.unknowns.joined(separator: ", "))").foregroundStyle(.secondary) } } }
            Section { Button("Delete permanently", role: .destructive) { confirmDelete = true } }
        }
        .navigationTitle(garment.label).navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this garment and its local images?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task { await AssetStore.shared.remove(named: garment.sourceAssetName); await AssetStore.shared.remove(named: garment.catalogAssetName) }
                context.delete(garment); try? context.save(); dismiss()
            }
        }
    }
}
