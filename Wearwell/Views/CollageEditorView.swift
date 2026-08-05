import SwiftData
import SwiftUI

struct CollageEditorView: View {
    let existingOutfit: Outfit?
    let origin: OutfitOrigin
    let initialTitle: String
    let initialRationale: String
    let initialItems: [LayoutItem]
    let wishlistItem: WishlistItem?

    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var items: [LayoutItem]
    @State private var showPicker = false
    @State private var pickerSearch = ""
    @State private var pickerCategory: GarmentCategory?
    @State private var pickerSubcategory: GarmentSubcategory?
    @State private var selectedID: UUID?
    @State private var preparing: Bool
    @State private var preparedCount = 0
    @State private var preparationTotal = 0
    @State private var preparationStartedAt = Date.now
    @State private var showRecommendationPicker = false
    @State private var recommendationCategory: GarmentCategory?
    @State private var recommending = false
    @State private var recommendationNotice: String?

    init(origin: OutfitOrigin = .manual, title: String = "New outfit", rationale: String = "", items: [LayoutItem] = [], wishlistItem: WishlistItem? = nil) {
        existingOutfit = nil
        self.origin = origin; initialTitle = title; initialRationale = rationale; initialItems = items; self.wishlistItem = wishlistItem
        _title = State(initialValue: title); _items = State(initialValue: items)
        _preparing = State(initialValue: !items.isEmpty)
    }

    init(outfit: Outfit, wishlistItem: WishlistItem? = nil) {
        existingOutfit = outfit
        origin = outfit.origin
        initialTitle = outfit.title
        initialRationale = outfit.rationale
        initialItems = outfit.layout
        self.wishlistItem = wishlistItem
        _title = State(initialValue: outfit.title)
        _items = State(initialValue: outfit.layout)
        _preparing = State(initialValue: !outfit.layout.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Outfit title", text: $title).font(.title2.bold()).padding()
            GeometryReader { proxy in
                ZStack {
                    WearwellTheme.paper
                    if items.isEmpty { ContentUnavailableView("Blank canvas", systemImage: "square.dashed", description: Text("Add clothes and arrange them freely.")) }
                    else if preparing {
                        CollagePreparationView(completed: preparedCount, total: preparationTotal, startedAt: preparationStartedAt)
                    } else {
                        ForEach(items.sorted { $0.zIndex < $1.zIndex }) { item in
                            if let imageName = imageName(for: item), let binding = itemBinding(for: item) {
                                CollagePiece(imageName: imageName, item: binding, canvas: proxy.size, selected: selectedID == item.id)
                                    .onTapGesture { selectedID = item.id }
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24)).padding(.horizontal)
                .background(WearwellTheme.cream)
            }
            .aspectRatio(0.8, contentMode: .fit)
            controls
        }
        .background(WearwellTheme.cream.ignoresSafeArea())
        .navigationTitle(existingOutfit == nil ? (origin == .manual ? "Manual collage" : "Edit collage") : "Edit outfit")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(existingOutfit == nil ? "Save" : "Save changes") { save() }
                    .disabled(items.isEmpty)
            }
        }
        .sheet(isPresented: $showPicker) { garmentPicker }
        .sheet(isPresented: $showRecommendationPicker) { recommendationPicker }
        .alert("Luna", isPresented: Binding(
            get: { recommendationNotice != nil },
            set: { if !$0 { recommendationNotice = nil } }
        )) {
            Button("OK") { recommendationNotice = nil }
        } message: {
            Text(recommendationNotice ?? "")
        }
        .task(id: preparationKey) { await prepareCollageImages() }
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                Button { showPicker = true } label: { Label("Add", systemImage: "plus") }
                Button { recommendationCategory = nil; showRecommendationPicker = true } label: {
                    if recommending { Label("Asking Luna", systemImage: "sparkles") }
                    else { Label("Ask Luna", systemImage: "sparkles") }
                }
                .disabled(recommending)
                Button { snapLayout() } label: { Label("Arrange", systemImage: "rectangle.3.group") }.disabled(items.isEmpty)
                Button { duplicateSelected() } label: { Label("Duplicate piece", systemImage: "plus.square.on.square") }.disabled(selectedID == nil)
                Button(role: .destructive) { items.removeAll { $0.id == selectedID }; selectedID = nil } label: { Image(systemName: "trash") }.disabled(selectedID == nil)
            }
            .font(.caption.weight(.semibold)).padding()
        }
        .frame(maxWidth: .infinity).background(.ultraThinMaterial)
    }

    private var garmentPicker: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    pickerFilters
                    if filteredGarments.isEmpty && !showsWishlistCandidate {
                        EmptyState(
                            icon: "magnifyingglass",
                            title: "No clothes found",
                            message: "Try another search or category."
                        )
                        .frame(minHeight: 280)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                            ForEach(filteredGarments) { garment in
                                Button { add(garment); showPicker = false } label: { GarmentCard(garment: garment) }.buttonStyle(.plain)
                            }
                            if let candidate = wishlistItem, showsWishlistCandidate {
                                Button { add(candidate); showPicker = false } label: {
                                    VStack(alignment: .leading) { AssetImage(name: candidate.catalogAssetName).frame(height: 155); Text(candidate.label).font(.subheadline.bold()); StatusPill(text: "Considering", color: WearwellTheme.coral) }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Add to outfit")
            .searchable(text: $pickerSearch, prompt: "Search clothes")
            .toolbar { Button("Done") { showPicker = false } }
        }
        .keyboardDismissToolbar()
    }

    private var recommendationPicker: some View {
        NavigationStack {
            List {
                if let category = recommendationCategory {
                    Section("Choose a type") {
                        Button {
                            requestRecommendation(category: category, subcategory: nil)
                        } label: {
                            Label("All \(category.title)", systemImage: "square.grid.2x2")
                        }
                        ForEach(GarmentSubcategory.options(for: category)) { subcategory in
                            Button {
                                requestRecommendation(category: category, subcategory: subcategory)
                            } label: {
                                Text(subcategory.title)
                            }
                        }
                    }
                } else {
                    Section("Choose a category") {
                        ForEach(GarmentCategory.allCases) { category in
                            Button { recommendationCategory = category } label: {
                                HStack {
                                    Text(category.title)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(recommendationCategory?.title ?? "Ask Luna")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if recommendationCategory != nil {
                        Button { recommendationCategory = nil } label: {
                            Label("Categories", systemImage: "chevron.left")
                        }
                    } else {
                        Button("Cancel") { showRecommendationPicker = false }
                    }
                }
            }
        }
    }

    private var filteredGarments: [Garment] {
        garments.filter { garment in
            (pickerCategory == nil || garment.category == pickerCategory) &&
            (pickerSubcategory == nil || garment.subcategory == pickerSubcategory) &&
            matchesPickerSearch(label: garment.label, color: garment.color, category: garment.category, subcategory: garment.subcategory)
        }
    }

    private var showsWishlistCandidate: Bool {
        guard let candidate = wishlistItem else { return false }
        return (pickerCategory == nil || candidate.category == pickerCategory) &&
            (pickerSubcategory == nil || candidate.subcategory == pickerSubcategory) &&
            matchesPickerSearch(label: candidate.label, color: candidate.color, category: candidate.category, subcategory: candidate.subcategory)
    }

    private func matchesPickerSearch(label: String, color: String, category: GarmentCategory, subcategory: GarmentSubcategory?) -> Bool {
        guard !pickerSearch.isEmpty else { return true }
        return [label, color, category.title, subcategory?.title ?? ""]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(pickerSearch)
    }

    private var pickerFilters: some View {
        VStack(alignment: .leading, spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("All") { pickerCategory = nil; pickerSubcategory = nil }
                        .buttonStyle(FilterButtonStyle(selected: pickerCategory == nil))
                    ForEach(GarmentCategory.allCases) { category in
                        Button(category.title) { pickerCategory = category; pickerSubcategory = nil }
                            .buttonStyle(FilterButtonStyle(selected: pickerCategory == category))
                    }
                }
            }
            if let pickerCategory, !GarmentSubcategory.options(for: pickerCategory).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        Button("All types") { pickerSubcategory = nil }
                            .buttonStyle(FilterButtonStyle(selected: pickerSubcategory == nil))
                        ForEach(GarmentSubcategory.options(for: pickerCategory)) { subcategory in
                            Button(subcategory.filterTitle) { pickerSubcategory = subcategory }
                                .buttonStyle(FilterButtonStyle(selected: pickerSubcategory == subcategory))
                        }
                    }
                }
            }
        }
    }

    private func imageName(for item: LayoutItem) -> String? {
        if let id = item.garmentID, let garment = garments.first(where: { $0.id == id }) { return garment.catalogAssetName.isEmpty ? garment.sourceAssetName : garment.catalogAssetName }
        if item.wishlistItemID == wishlistItem?.id { return wishlistItem?.catalogAssetName }
        return nil
    }
    private var preparationKey: String {
        items.compactMap(imageName(for:)).sorted().joined(separator: "|")
    }
    private func prepareCollageImages() async {
        let names = Array(Set(items.compactMap(imageName(for:))))
        guard !names.isEmpty else { preparing = false; preparedCount = 0; preparationTotal = 0; return }
        preparationStartedAt = .now; preparedCount = 0; preparationTotal = names.count; preparing = true
        await withTaskGroup(of: Void.self) { group in
            for name in names {
                group.addTask { _ = AssetStore.collageImage(named: name) }
            }
            for await _ in group {
                if Task.isCancelled { return }
                preparedCount += 1
            }
        }
        if !Task.isCancelled { preparing = false }
    }
    private func add(_ garment: Garment) { let z = (items.map(\.zIndex).max() ?? 0) + 1; items.append(LayoutItem(garmentID: garment.id, x: 0.5, y: 0.5, zIndex: z)) }
    private func add(_ candidate: WishlistItem) { let z = (items.map(\.zIndex).max() ?? 0) + 1; items.append(LayoutItem(wishlistItemID: candidate.id, x: 0.5, y: 0.5, zIndex: z)) }
    private func requestRecommendation(category: GarmentCategory, subcategory: GarmentSubcategory?) {
        showRecommendationPicker = false
        Task { await recommend(category: category, subcategory: subcategory) }
    }
    private func recommend(category: GarmentCategory, subcategory: GarmentSubcategory?) async {
        guard hosted.isAuthenticated else {
            recommendationNotice = "Reconnect your Wearwell account in Settings before asking Luna."
            return
        }
        let selectedIDs = Array(Set(items.compactMap(\.garmentID)))
        let eligible = garments.filter {
            $0.category == category && (subcategory == nil || $0.subcategory == subcategory) && !selectedIDs.contains($0.id)
        }
        let targetName = subcategory?.title ?? category.title
        guard !eligible.isEmpty else {
            recommendationNotice = "There are no unused \(targetName.lowercased()) in your wardrobe."
            return
        }
        recommending = true
        defer { recommending = false }
        do {
            let result = try await hosted.recommendItem(
                garments: garments, selectedGarmentIDs: selectedIDs,
                category: category, subcategory: subcategory
            )
            guard let garment = eligible.first(where: { $0.id == result.garmentID }) else { throw HostedError.invalidResponse }
            add(garment)
            selectedID = items.last?.id
            recommendationNotice = "Added \(garment.label). \(result.rationale)"
        } catch {
            recommendationNotice = error.localizedDescription
        }
    }
    private func itemBinding(for snapshot: LayoutItem) -> Binding<LayoutItem>? {
        guard items.contains(where: { $0.id == snapshot.id }) else { return nil }
        return Binding(
            get: { items.first(where: { $0.id == snapshot.id }) ?? snapshot },
            set: { updated in
                guard let index = items.firstIndex(where: { $0.id == snapshot.id }) else { return }
                items[index] = updated
            }
        )
    }
    private func duplicateSelected() { guard let selected = items.first(where: { $0.id == selectedID }) else { return }; var copy = selected; copy.id = UUID(); copy.x += 0.05; copy.y += 0.05; copy.zIndex = (items.map(\.zIndex).max() ?? 0) + 1; items.append(copy); selectedID = copy.id }
    private func snapLayout() { items = OutfitLayout.arranged(items) }
    private func save() {
        let savedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = savedTitle.isEmpty ? "Untitled outfit" : savedTitle
        if origin == .aiStyle {
            OutfitFeedbackStore.recordEdit(title: normalizedTitle, originalLayout: initialItems, finalLayout: items)
        }
        if let existingOutfit {
            existingOutfit.applyEdits(title: normalizedTitle, layout: items)
        } else {
            context.insert(Outfit(
                title: normalizedTitle,
                rationale: initialRationale,
                origin: origin,
                layout: items,
                wishlistItemID: wishlistItem?.id
            ))
        }
        try? context.save()
        dismiss()
    }
}

private struct CollagePreparationView: View {
    let completed: Int
    let total: Int
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
            let remaining = completed > 0
                ? max(1, Int(ceil((elapsed / Double(completed)) * Double(max(0, total - completed)))))
                : nil
            VStack(spacing: 12) {
                ProgressView(value: Double(completed), total: Double(max(1, total))).frame(width: 190)
                Text("Preparing outfit pieces").font(.headline)
                Text(total > 0 ? "\(completed) of \(total) ready" : "Starting…").font(.subheadline)
                Text(remaining.map { "About \($0)s remaining" } ?? "Usually takes 5–20 seconds")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct CollagePiece: View {
    let imageName: String
    @Binding var item: LayoutItem
    let canvas: CGSize
    let selected: Bool
    @State private var dragStart: CGPoint?
    @State private var scaleStart: Double?
    @State private var rotationStart: Double?
    var body: some View {
        CollageAssetImage(name: imageName).frame(width: 150, height: 180)
            .scaleEffect(item.scale).rotationEffect(.degrees(item.rotation))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? WearwellTheme.coral : .clear, lineWidth: 2) }
            .position(x: item.x * canvas.width, y: item.y * canvas.height)
            .gesture(DragGesture().onChanged { value in
                if dragStart == nil { dragStart = CGPoint(x: item.x, y: item.y) }
                guard let start = dragStart else { return }
                item.x = min(1, max(0, start.x + value.translation.width / canvas.width)); item.y = min(1, max(0, start.y + value.translation.height / canvas.height))
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in if scaleStart == nil { scaleStart = item.scale }; item.scale = min(2.2, max(0.35, (scaleStart ?? 1) * value.magnification)) }.onEnded { _ in scaleStart = nil })
            .simultaneousGesture(RotateGesture().onChanged { value in if rotationStart == nil { rotationStart = item.rotation }; item.rotation = (rotationStart ?? 0) + value.rotation.degrees }.onEnded { _ in rotationStart = nil })
            .accessibilityLabel("Outfit item").accessibilityHint("Drag, pinch, or rotate to arrange")
    }
}
