import PhotosUI
import SwiftData
import SwiftUI

struct WishlistView: View {
    @Binding var showSettings: Bool
    @Binding var showActivity: Bool
    var activityCount: Int
    let initialQuery: String
    let autoSearch: Bool
    let shopOnly: Bool
    let focusGarmentIDs: [UUID]
    let focusInspirationIDs: [UUID]
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Query private var garments: [Garment]
    @Query private var styleProfiles: [StyleProfile]
    @Query(sort: \InspirationLook.updatedAt, order: .reverse) private var inspirations: [InspirationLook]
    @Query(sort: \ShoppingProfile.updatedAt, order: .reverse) private var shoppingProfiles: [ShoppingProfile]
    @Query(sort: \ShopFeedSnapshot.generatedAt, order: .reverse) private var feedSnapshots: [ShopFeedSnapshot]
    @Query private var savedProducts: [WishlistItem]
    @Query private var outfits: [Outfit]
    @State private var photo: PhotosPickerItem?
    @State private var url = ""
    @State private var working = false
    @State private var error: String?
    @State private var selectedItem: WishlistItem?
    @State private var selectedItemAutoAssess = true
    @State private var showResult = false
    @State private var shopQuery = ""
    @State private var shopWorking = false
    @State private var shopError: String?
    @State private var showShoppingPreferences = false
    @State private var didAutoRefresh = false
    @State private var shopStage = ""
    @State private var shopEstimateSeconds: Int?
    @State private var shopEstimateUpdatedAt = Date.now
    @State private var shopMode = "discover"
    @State private var savingProductIDs: Set<String> = []
    @State private var testingProductIDs: Set<String> = []
    @State private var saveNotice: String?

    init(
        showSettings: Binding<Bool>, showActivity: Binding<Bool> = .constant(false), activityCount: Int = 0,
        initialQuery: String = "", autoSearch: Bool = false,
        shopOnly: Bool = false, focusGarmentIDs: [UUID] = [], focusInspirationIDs: [UUID] = []
    ) {
        _showSettings = showSettings
        _showActivity = showActivity
        self.activityCount = activityCount
        self.initialQuery = initialQuery
        self.autoSearch = autoSearch
        self.shopOnly = shopOnly
        self.focusGarmentIDs = focusGarmentIDs
        self.focusInspirationIDs = focusInspirationIDs
        _shopQuery = State(initialValue: initialQuery)
    }

    private var shoppingProfile: ShoppingProfile? { shoppingProfiles.first }
    private var isInspirationShop: Bool { !focusInspirationIDs.isEmpty }
    private var isFocusedShop: Bool { shopOnly || isInspirationShop }
    private var searchOrigin: String {
        if shopOnly { return "outfit" }
        if let id = focusInspirationIDs.first { return "inspiration:\(id.uuidString)" }
        return "wardrobe"
    }
    private var focusedInspiration: InspirationLook? {
        let ids = Set(focusInspirationIDs)
        return inspirations.first { ids.contains($0.id) }
    }
    private var inspirationSearchLabel: String {
        let value = initialQuery.lowercased()
        if value.contains("tops only") { return "Tops from this photo" }
        if value.contains("bottoms only") { return "Bottoms from this photo" }
        return "Pieces from this whole look"
    }
    private var focusedSourceOutfit: Outfit? {
        let ids = Set(focusGarmentIDs)
        return outfits.first { $0.belongsInOutfitLibrary && Set($0.layout.compactMap(\.garmentID)) == ids }
    }
    private var focusedOutfitLayout: [LayoutItem] {
        if let focusedSourceOutfit { return focusedSourceOutfit.layout }
        return focusGarmentIDs.enumerated().map { index, id in
            LayoutItem(
                garmentID: id,
                x: index.isMultiple(of: 2) ? 0.28 : 0.72,
                y: 0.25 + Double(index / 2) * 0.32,
                scale: 0.7,
                zIndex: Double(index)
            )
        }
    }
    private var relevantFeeds: [ShopFeedSnapshot] {
        if shopOnly {
            return feedSnapshots.filter { $0.isOutfitSpecific && $0.query == initialQuery }
        }
        if isInspirationShop {
            return feedSnapshots.filter { $0.originContext == searchOrigin && $0.query == initialQuery }
        }
        return feedSnapshots.filter { $0.originContext == "wardrobe" }
    }
    private var activeFeed: ShopFeedSnapshot? { relevantFeeds.first { ["queued", "processing"].contains($0.state) } }
    private var latestFeed: ShopFeedSnapshot? { relevantFeeds.first { $0.state == "complete" } }
    private var displayedFeed: ShopFeedSnapshot? {
        if let activeFeed, !activeFeed.products.isEmpty { return activeFeed }
        if isFocusedShop, activeFeed != nil { return nil }
        return latestFeed
    }
    private var recommendationFeeds: [ShopFeedSnapshot] {
        feedSnapshots.filter {
            $0.originContext != "wardrobe" &&
            (["queued", "processing", "failed"].contains($0.state) || !$0.visibleProducts.isEmpty)
        }
    }

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    EditorialHeader(
                        eyebrow: shopOnly ? "For this exact outfit" : (isInspirationShop ? "From this inspiration" : "Shop your wardrobe first"),
                        title: shopOnly ? "Pieces to complete the look" : (isInspirationShop ? "Shop similar pieces" : "Shop"),
                        subtitle: shopOnly ? "Luna is matching real products to the clothes already on your collage." : (isInspirationShop ? "Luna compares real product images with the inspiration photo, not just its description." : "Test something you found or let Luna search selected stores for pieces that add real value to your wardrobe.")
                    )
                    if !isFocusedShop, !recommendationFeeds.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Recent Luna results").font(.title3.bold())
                                Spacer()
                                Text("Always available here").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(recommendationFeeds.prefix(6)) { feed in
                                NavigationLink { recommendationDestination(feed) } label: {
                                    RecommendationFeedRow(feed: feed, garments: garments, inspirations: inspirations)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let focusedInspiration {
                        ZStack(alignment: .bottomLeading) {
                            AssetImage(name: focusedInspiration.assetName, contentMode: .fill)
                                .frame(height: 190).frame(maxWidth: .infinity).clipped()
                            Label("Matching this inspiration photo", systemImage: "viewfinder")
                                .font(.caption.weight(.semibold)).foregroundStyle(.white)
                                .padding(10).background(.black.opacity(0.58), in: Capsule()).padding(12)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .accessibilityElement(children: .combine)
                    }
                    if shopOnly, !focusedOutfitLayout.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(focusedSourceOutfit.map { "Recommended for \($0.title)" } ?? "Recommended for this outfit")
                                .font(.headline)
                            CollagePreview(items: focusedOutfitLayout, garments: garments, candidate: nil)
                                .aspectRatio(1.15, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    if !isFocusedShop {
                        Picker("Shop mode", selection: $shopMode) {
                            Label("Discover", systemImage: "sparkles").tag("discover")
                            Label("Check an item", systemImage: "checkmark.seal").tag("check")
                        }.pickerStyle(.segmented)
                    }
                    if !isFocusedShop, shopMode == "check" { VStack(alignment: .leading, spacing: 14) {
                        Text("Should I buy this?").font(.title3.bold())
                        Text("Submit any product, then build outfits with clothes you already own.").font(.subheadline).foregroundStyle(.secondary)
                        PhotosPicker(selection: $photo, matching: .images) {
                            Label("Choose product image", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(working)

                        Text("or paste a product link").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        TextField("https://…", text: $url)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { guard canImportURL else { return }; Task { await loadURL() } }
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        Button(working ? "Preparing…" : "Import product link") { Task { await loadURL() } }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                            .disabled(!canImportURL)
                    }
                    .padding(20)
                    .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                    }

                    if shopMode == "check", working {
                        VStack(spacing: 8) {
                            ProgressView("Preparing the item…")
                            Text("After the item is ready, Luna will create 3–5 potential outfits.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding()
                    }
                    if shopMode == "check", companion.status != .available {
                        Text("Pair with the Mac companion in Settings to analyze a possible purchase.").font(.caption).foregroundStyle(.secondary)
                    }
                    if shopMode == "check", let error { Text(error).foregroundStyle(.red).font(.subheadline) }

                    if isFocusedShop || shopMode == "discover" {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(isInspirationShop ? "Match this photo" : "Find something for me").font(.title3.bold())
                                Text(isInspirationShop ? "Only strong visual matches will be shown." : "Searches only stores in your shopping profile.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { showShoppingPreferences = true } label: { Image(systemName: "slider.horizontal.3") }
                                .accessibilityLabel("Shopping preferences")
                        }
                        if isInspirationShop {
                            Label(inspirationSearchLabel, systemImage: "viewfinder")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        } else {
                            TextField("e.g. a sheer layering top under $70", text: $shopQuery, axis: .vertical)
                                .lineLimit(1...3)
                                .submitLabel(.search)
                                .onSubmit { Task { await startShopSearch() } }
                                .padding(12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        }
                        HStack {
                            Button { Task { await startShopSearch() } } label: {
                                Label(shopWorking ? "Searching…" : (isInspirationShop ? "Search this photo" : "Search stores"), systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(shopWorking || companion.status != .available || shoppingProfile == nil)
                            Button { Task { await startShopSearch(forcePersonalized: true) } } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .disabled(shopWorking || companion.status != .available || shoppingProfile == nil)
                            .accessibilityLabel("Refresh personalized picks")
                        }
                        if shopWorking || activeFeed != nil {
                            ShopProcessingStatus(
                                stage: shopStage.isEmpty ? (activeFeed?.stageText ?? "Searching and verifying product pages…") : shopStage,
                                estimatedSeconds: shopEstimateSeconds,
                                estimateUpdatedAt: shopEstimateUpdatedAt
                            )
                        }
                        if let shopError { Text(shopError).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(20)
                    .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))

                    if let feed = displayedFeed {
                        HStack(alignment: .firstTextBaseline) {
                            Text(isInspirationShop ? inspirationSearchLabel : (feed.query.isEmpty ? "Personalized picks" : feed.query)).font(.title2.bold()).lineLimit(2)
                            Spacer()
                            Text(feed.generatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        if feed.expiresAt <= .now {
                            Text("Showing the last successful search while a fresh one is prepared.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        LazyVStack(spacing: 14) {
                            ForEach(feed.products.filter { !feed.dismissedIDs.contains($0.id) }) { product in
                                ShopProductCard(
                                    product: product,
                                    test: { Task { await test(product, from: feed) } },
                                    dismiss: { dismiss(product, from: feed) },
                                    save: { Task { await save(product, from: feed) } },
                                    hideRetailer: { hideRetailer(product.domain) },
                                    isSaving: savingProductIDs.contains(product.id),
                                    isSaved: savedProducts.contains { SavedRecommendationContext.matches($0, product: product) },
                                    testState: testState(for: product)
                                )
                            }
                        }
                        if activeFeed?.id == feed.id {
                            ProgressView("Finding more visually matched pieces…")
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                    } else if !shopWorking && activeFeed == nil {
                        EmptyState(icon: "bag.badge.plus", title: "No shop picks yet", message: "Pair the Mac and search for a piece, or refresh for recommendations based on your style profile.")
                            .frame(minHeight: 180)
                    }
                    }

                }.padding()
            }
            .refreshable { await startShopSearch(forcePersonalized: true) }
        }
        .toolbar { if !isFocusedShop { SettingsButton(isPresented: $showSettings, showActivity: $showActivity, activityCount: activityCount) } }
        .sheet(isPresented: $showShoppingPreferences) {
            if let shoppingProfile { NavigationStack { ShoppingPreferencesView(profile: shoppingProfile) } }
        }
        .alert("Saved", isPresented: Binding(get: { saveNotice != nil }, set: { if !$0 { saveNotice = nil } })) {
            if selectedItem != nil {
                Button("View in Saved") { selectedItemAutoAssess = false; showResult = true; saveNotice = nil }
            }
            Button("Keep browsing", role: .cancel) { saveNotice = nil }
        } message: { Text(saveNotice ?? "") }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    error = "That image could not be loaded."
                    return
                }
                await create(from: data, sourceURL: nil)
                photo = nil
            }
        }
        .navigationDestination(isPresented: $showResult) {
            if let selectedItem { WishlistDetailView(item: selectedItem, autoAssess: selectedItemAutoAssess) }
        }
        .task {
            for feed in relevantFeeds where feed.isUnread { feed.isUnread = false }
            try? context.save()
            let profile = ensureShoppingProfile()
            guard !didAutoRefresh else { return }
            didAutoRefresh = true
            if autoSearch, !initialQuery.isEmpty, activeFeed == nil, companion.status == .available {
                await startShopSearch(profileOverride: profile)
            } else if activeFeed == nil, latestFeed?.isFresh != true, companion.status == .available {
                await startShopSearch(forcePersonalized: true, profileOverride: profile)
            }
        }
        .task {
            while !Task.isCancelled {
                await refreshShopJob()
                try? await Task.sleep(for: .seconds(activeFeed == nil ? 15 : 3))
            }
        }
    }

    @ViewBuilder private func recommendationDestination(_ feed: ShopFeedSnapshot) -> some View {
        WishlistView(
            showSettings: $showSettings, showActivity: $showActivity, activityCount: activityCount,
            initialQuery: feed.query, autoSearch: false,
            shopOnly: feed.isOutfitSpecific, focusGarmentIDs: feed.focusGarmentIDs,
            focusInspirationIDs: feed.inspirationID.map { [$0] } ?? []
        )
    }

    private var canImportURL: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !working
    }

    private func loadURL() async {
        guard canImportURL else { return }
        working = true
        error = nil
        do {
            let result = try await ImportService.image(from: url)
            await create(from: result.0, sourceURL: result.1.absoluteString, managesWorkingState: false)
            if error == nil { url = "" }
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }

    private func create(from data: Data, sourceURL: String?, discovery: DiscoveredProductDTO? = nil, managesWorkingState: Bool = true) async {
        guard companion.status == .available else { error = "Pair the Mac companion first."; return }
        if managesWorkingState { working = true }
        error = nil
        do {
            guard let analysis = try await companion.analyze(imageData: data, sourceURL: sourceURL).first else {
                throw ClientError.server("No clothing item was found.")
            }
            let source = try await AssetStore.shared.save(data, preferredExtension: "jpg")
            let catalogData = analysis.catalogImageBase64.flatMap { Data(base64Encoded: $0) } ?? data
            let catalog = try await AssetStore.shared.save(catalogData, preferredExtension: "png")
            let category = GarmentCategory(rawValue: analysis.category) ?? .tops
            let subcategory = analysis.subcategory.flatMap(GarmentSubcategory.init(rawValue:))
            var details = analysis.description
            if let discovery {
                let price = discovery.currentPrice.map { value in
                    let amount = value.formatted(.currency(code: discovery.currency ?? "USD"))
                    return discovery.originalPrice.map { "\(amount), originally \($0.formatted(.currency(code: discovery.currency ?? "USD")))" } ?? amount
                } ?? "Price unavailable"
                let provenance = [
                    "Source: \(discovery.source ?? "verified web")",
                    discovery.sourceProductID.map { "Product ID: \($0)" },
                    discovery.visualNotes.map { "Visual match: \($0)" }
                ].compactMap { $0 }.joined(separator: ". ")
                details += "\n\nDiscovered at \(discovery.retailer). \(price). Verified \(discovery.verifiedAt). Recommendation: \(discovery.rationale). \(provenance)"
            }
            let item = WishlistItem(
                label: analysis.label,
                category: category,
                subcategory: subcategory?.category == category ? subcategory : nil,
                color: analysis.color,
                details: details,
                sourceAssetName: source,
                catalogAssetName: catalog,
                sourceURL: sourceURL,
                fingerprint: analysis.fingerprint
            )
            context.insert(item)
            try context.save()
            selectedItem = item
            selectedItemAutoAssess = true
            showResult = true
        } catch {
            self.error = error.localizedDescription
        }
        if managesWorkingState { working = false }
    }

    @MainActor private func ensureShoppingProfile() -> ShoppingProfile {
        if let shoppingProfile {
            var preferences = shoppingProfile.preferences
            if ShoppingRetailer.applyBundledUpdates(to: &preferences) {
                shoppingProfile.preferences = preferences
                try? context.save()
            }
            return shoppingProfile
        }
        let profile = ShoppingProfile()
        context.insert(profile)
        try? context.save()
        return profile
    }

    private func startShopSearch(forcePersonalized: Bool = false, profileOverride: ShoppingProfile? = nil) async {
        guard activeFeed == nil, let shoppingProfile = profileOverride ?? shoppingProfile, companion.status == .available else { return }
        let query = isFocusedShop
            ? initialQuery
            : (forcePersonalized || shopQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Personalized pieces that add value to my wardrobe, prioritizing useful verified markdowns"
                : shopQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        shopWorking = true; shopError = nil
        let snapshot = ShopFeedSnapshot(
            query: query, originContext: searchOrigin,
            focusGarmentIDs: focusGarmentIDs
        )
        context.insert(snapshot); try? context.save()
        shopStage = "Starting Luna's product search"
        shopEstimateSeconds = 120
        shopEstimateUpdatedAt = .now
        do {
            let job = try await companion.submitShopDiscovery(
                query: query, garments: garments, styleProfile: styleProfiles.first,
                inspirations: inspirations, shoppingProfile: shoppingProfile.preferences,
                focusGarmentIDs: focusGarmentIDs, focusInspirationIDs: focusInspirationIDs,
                resultLimit: shopOnly ? 6 : (isInspirationShop ? 12 : 60)
            )
            snapshot.jobID = job.id; snapshot.state = job.state
            updateProgress(from: job)
            snapshot.progressStage = shopStage
            snapshot.estimatedSecondsRemaining = shopEstimateSeconds
            snapshot.progressUpdatedAt = shopEstimateUpdatedAt
            try context.save()
        } catch {
            snapshot.state = "failed"; snapshot.errorMessage = error.localizedDescription
            shopError = error.localizedDescription; try? context.save()
        }
        shopWorking = false
    }

    private func refreshShopJob() async {
        guard companion.status == .available, let snapshot = activeFeed, let id = snapshot.jobID else { return }
        do {
            let job = try await companion.shopDiscoveryJob(id: id)
            snapshot.state = job.state; snapshot.errorMessage = job.error
            updateProgress(from: job)
            snapshot.progressStage = shopStage
            snapshot.estimatedSecondsRemaining = shopEstimateSeconds
            snapshot.progressUpdatedAt = shopEstimateUpdatedAt
            if let feed = job.result {
                let dismissed = shoppingProfile?.preferences.dismissedProductIDs ?? []
                snapshot.query = feed.query
                snapshot.products = feed.products.filter { !dismissed.contains($0.id) }
                snapshot.generatedAt = ISO8601DateFormatter().date(from: feed.generatedAt) ?? .now
                snapshot.expiresAt = snapshot.generatedAt.addingTimeInterval(6 * 60 * 60)
                if job.state == "complete" || (job.state == "failed" && !feed.products.isEmpty) {
                    snapshot.state = "complete"
                    snapshot.isUnread = false
                    if job.state == "failed" {
                        shopError = job.error ?? "Some later recommendations could not be prepared. Showing the completed pages."
                    }
                    for old in feedSnapshots.dropFirst(8) { context.delete(old) }
                }
            } else if job.state == "failed" {
                shopError = job.error ?? "Product discovery failed. Your last successful picks are still available."
            }
            try context.save()
        } catch ClientError.jobNotFound {
            snapshot.state = "failed"; snapshot.errorMessage = "This product search expired. Refresh to try again."
            shopError = snapshot.errorMessage; try? context.save()
        } catch { /* keep the local job active while the Mac is temporarily unavailable */ }
    }

    private func updateProgress(from job: ShopDiscoveryJobDTO) {
        shopStage = job.stage ?? (job.state == "queued" ? "Queued for Luna" : "Finding products")
        shopEstimateSeconds = job.estimatedSecondsRemaining
        shopEstimateUpdatedAt = .now
    }

    private func dismiss(_ product: DiscoveredProductDTO, from feed: ShopFeedSnapshot) {
        var ids = feed.dismissedIDs; ids.insert(product.id); feed.dismissedIDs = ids
        if let shoppingProfile {
            var preferences = shoppingProfile.preferences
            if !preferences.dismissedProductIDs.contains(product.id) { preferences.dismissedProductIDs.append(product.id) }
            preferences.dismissedProductIDs = Array(preferences.dismissedProductIDs.suffix(300))
            shoppingProfile.preferences = preferences
        }
        try? context.save()
    }

    private func hideRetailer(_ domain: String) {
        guard let normalized = ShoppingRetailer.normalizedDomain(domain), let shoppingProfile else { return }
        var preferences = shoppingProfile.preferences
        var hidden = preferences.hiddenRetailerDomains
        if !hidden.contains(normalized) { hidden.append(normalized) }
        preferences.hiddenRetailerDomains = hidden
        preferences.preferredRetailers.removeAll { ShoppingRetailer.normalizedDomain($0) == normalized }
        preferences.customRetailerDomains.removeAll { ShoppingRetailer.normalizedDomain($0) == normalized }
        shoppingProfile.preferences = preferences
        for snapshot in feedSnapshots {
            snapshot.products = snapshot.products.filter { ShoppingRetailer.normalizedDomain($0.domain) != normalized }
        }
        try? context.save()
    }

    @MainActor private func save(_ product: DiscoveredProductDTO, from feed: ShopFeedSnapshot) async {
        guard !savingProductIDs.contains(product.id) else { return }
        if let existing = savedProducts.first(where: { SavedRecommendationContext.matches($0, product: product) }) {
            selectedItem = existing
            dismiss(product, from: feed)
            saveNotice = "This product was already in Saved."
            return
        }
        savingProductIDs.insert(product.id)
        defer { savingProductIDs.remove(product.id) }
        do {
            let item = try await SavedRecommendationContext.makeItem(product: product, feed: feed)
            context.insert(item)
            if let source = SavedRecommendationContext.sourceOutfit(for: item, feed: feed, title: sourceOutfitTitle(for: feed)) {
                context.insert(source)
            }
            dismiss(product, from: feed)
            try context.save()
            selectedItem = item
            selectedItemAutoAssess = false
            saveNotice = feed.isOutfitSpecific ? "Saved with its original outfit under Saved products." : "Saved under Saved products."
        } catch { saveNotice = "This product couldn't be saved: \(error.localizedDescription)" }
    }

    private func testState(for product: DiscoveredProductDTO) -> ShopProductTestState {
        if testingProductIDs.contains(product.id) { return .queueing }
        if let item = savedProducts.first(where: { SavedRecommendationContext.matches($0, product: product) }) {
            return item.assessmentState.map { ["submitting", "queued", "processing"].contains($0) } == true ? .queued : .saved
        }
        return .idle
    }

    @MainActor private func test(_ product: DiscoveredProductDTO, from feed: ShopFeedSnapshot) async {
        guard !testingProductIDs.contains(product.id) else { return }
        guard companion.isPaired else {
            shopError = "Pair the Mac companion before queueing a wardrobe test."
            return
        }
        if savedProducts.contains(where: { SavedRecommendationContext.matches($0, product: product) }) { return }
        testingProductIDs.insert(product.id)
        shopError = nil
        var item: WishlistItem?
        do {
            let candidate = try await SavedRecommendationContext.makeItem(product: product, feed: feed)
            candidate.assessmentState = "submitting"
            candidate.assessmentStage = "Queueing wardrobe test"
            context.insert(candidate)
            if let source = SavedRecommendationContext.sourceOutfit(for: candidate, feed: feed, title: sourceOutfitTitle(for: feed)) {
                context.insert(source)
            }
            try context.save()
            item = candidate

            let job = try await companion.submitAssessment(
                candidate: candidate, garments: garments,
                styleProfile: styleProfiles.first, inspirations: inspirations
            )
            candidate.assessmentJobID = job.id
            _ = PurchaseAssessmentResults.apply(job, to: candidate, garments: garments, outfits: [], context: context)
            if job.state == "complete" { candidate.isUnreadAssessment = true }
            try context.save()
        } catch {
            item?.assessmentState = "failed"
            item?.assessmentError = error.localizedDescription
            shopError = "\(product.title) could not be queued: \(error.localizedDescription)"
            try? context.save()
        }
        testingProductIDs.remove(product.id)
    }

    private func sourceOutfitTitle(for feed: ShopFeedSnapshot) -> String? {
        let focus = Set(feed.focusGarmentIDs)
        return outfits.first {
            $0.belongsInOutfitLibrary && Set($0.layout.compactMap(\.garmentID)) == focus
        }?.title
    }
}

struct SavedItemsView: View {
    @Binding var showSettings: Bool
    @Binding var showActivity: Bool
    var activityCount: Int
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Query(sort: \WishlistItem.createdAt, order: .reverse) private var candidates: [WishlistItem]
    @Query(sort: \PurchaseNeed.createdAt, order: .reverse) private var needs: [PurchaseNeed]
    @Query private var garments: [Garment]
    @Query private var styleProfiles: [StyleProfile]
    @Query private var inspirations: [InspirationLook]
    @Query private var outfits: [Outfit]
    @State private var newNeed = ""
    @State private var recommending = false
    @State private var error: String?
    @State private var savedMode = "products"

    private var activeNeeds: [PurchaseNeed] { needs.filter { !$0.isCompleted } }

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    EditorialHeader(
                        eyebrow: "Saved for later", title: "Saved",
                        subtitle: "Keep broad wardrobe needs separate from specific products you're considering."
                    )
                    Picker("Saved section", selection: $savedMode) {
                        Label("Products", systemImage: "heart").tag("products")
                        Label("Lookout", systemImage: "binoculars").tag("lookout")
                    }.pickerStyle(.segmented)
                    if savedMode == "lookout" {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("On the lookout").font(.title2.bold())
                        Text("Save a general need—like capris—and Luna will remember it when finding specific pieces.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            TextField("e.g. capris or a lightweight cover-up", text: $newNeed)
                                .textInputAutocapitalization(.sentences)
                                .submitLabel(.done)
                                .onSubmit(addNeed)
                                .padding(11).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            Button(action: addNeed) { Image(systemName: "plus") }
                                .buttonStyle(.borderedProminent).disabled(trimmedNeed.isEmpty)
                        }
                        Button { Task { await askLuna() } } label: {
                            Label(recommending ? "Luna is checking…" : "Ask Luna what I'm missing", systemImage: "sparkles")
                        }
                        .buttonStyle(.bordered).disabled(recommending || companion.status != .available || garments.isEmpty)
                        if let error { Text(error).font(.caption).foregroundStyle(.red) }
                        if activeNeeds.isEmpty {
                            Text("Nothing on your list yet.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
                        } else {
                            ForEach(activeNeeds) { need in needCard(need) }
                        }
                    }
                    .padding(20).background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                    }

                    if savedMode == "products" {
                    Text("Saved products").font(.title2.bold())
                    if candidates.isEmpty {
                        EmptyState(icon: "heart", title: "No saved products", message: "Save a recommendation in Shop or check a product you're considering.")
                            .frame(minHeight: 180)
                    } else {
                        ForEach(inspirations) { look in
                            let related = candidates.filter { SavedRecommendationContext.inspirationID(from: $0.fingerprint) == look.id }
                            if !related.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack(alignment: .bottomLeading) {
                                        AssetImage(name: look.assetName, contentMode: .fill)
                                            .frame(height: 145).frame(maxWidth: .infinity).clipped()
                                        Text("Saved from this inspiration")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                                            .padding(8).background(.black.opacity(0.58), in: Capsule()).padding(10)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    ForEach(related) { item in
                                        NavigationLink { WishlistDetailView(item: item) } label: {
                                            WishlistRow(item: item, sourceLabel: "From this inspiration")
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        ForEach(candidates.filter { SavedRecommendationContext.inspirationID(from: $0.fingerprint) == nil }) { item in
                            NavigationLink { WishlistDetailView(item: item) } label: {
                                WishlistRow(item: item, sourceLabel: sourceOutfit(for: item) == nil ? nil : "Saved with an outfit")
                            }.buttonStyle(.plain)
                        }
                    }
                    }
                }.padding()
            }
        }
        .toolbar { SettingsButton(isPresented: $showSettings, showActivity: $showActivity, activityCount: activityCount) }
    }

    private var trimmedNeed: String { newNeed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func sourceOutfit(for item: WishlistItem) -> Outfit? {
        outfits.first { $0.wishlistItemID == item.id && $0.notes == SavedRecommendationContext.outfitMarker }
    }
    private func addNeed() {
        let value = trimmedNeed
        guard !value.isEmpty, !activeNeeds.contains(where: { $0.title.localizedCaseInsensitiveCompare(value) == .orderedSame }) else { return }
        context.insert(PurchaseNeed(title: value)); try? context.save(); newNeed = ""
    }
    private func needCard(_ need: PurchaseNeed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(need.title).font(.headline)
                    if need.isLunaSuggested { Text("LUNA SUGGESTED").font(.caption2.bold()).foregroundStyle(WearwellTheme.sage) }
                }
                Spacer()
                Menu {
                    Button("Mark found", systemImage: "checkmark") { need.isCompleted = true; need.updatedAt = .now; try? context.save() }
                    Button("Delete", systemImage: "trash", role: .destructive) { context.delete(need); try? context.save() }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More options for \(need.title)")
            }
            if !need.rationale.isEmpty { Text(need.rationale).font(.subheadline).foregroundStyle(.secondary) }
            NavigationLink {
                WishlistView(showSettings: $showSettings, showActivity: $showActivity, activityCount: activityCount, initialQuery: need.searchQuery, autoSearch: true)
            } label: {
                Label("Find specific pieces", systemImage: "magnifyingglass")
            }.buttonStyle(.borderedProminent)
        }
        .padding(14).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
    }
    private func askLuna() async {
        recommending = true; error = nil
        defer { recommending = false }
        do {
            let gaps = try await companion.recommendWardrobeGaps(
                garments: garments, selectedGarmentIDs: [], existingNeeds: needs,
                styleProfile: styleProfiles.first, inspirations: inspirations
            )
            let existing = Set(activeNeeds.map { $0.title.lowercased() })
            for gap in gaps where !existing.contains(gap.title.lowercased()) {
                context.insert(PurchaseNeed(
                    title: gap.title, category: GarmentCategory(rawValue: gap.category),
                    subcategory: gap.subcategory == "none" ? nil : GarmentSubcategory(rawValue: gap.subcategory),
                    rationale: gap.rationale, searchQuery: gap.searchQuery, isLunaSuggested: true
                ))
            }
            try context.save()
        } catch { self.error = error.localizedDescription }
    }
}

private extension ShopFeedSnapshot {
    var stageText: String {
        if state == "queued" { return "Queued product search…" }
        return products.isEmpty ? "Searching selected catalogs…" : "Finding more visually matched pieces…"
    }
}

private struct RecommendationFeedRow: View {
    let feed: ShopFeedSnapshot
    let garments: [Garment]
    let inspirations: [InspirationLook]

    private var sourceInspiration: InspirationLook? {
        guard let id = feed.inspirationID else { return nil }
        return inspirations.first { $0.id == id }
    }

    private var focusedGarments: [Garment] {
        let ids = Set(feed.focusGarmentIDs)
        return garments.filter { ids.contains($0.id) }
    }

    private var title: String {
        if feed.isOutfitSpecific { return "Products for an outfit" }
        if feed.isInspirationSpecific { return "Products from inspiration" }
        return "Shopping recommendations"
    }

    private var status: String {
        if ["queued", "processing"].contains(feed.state) { return feed.progressStage ?? "Luna is still working" }
        if feed.state == "failed" { return feed.errorMessage ?? "Search needs attention" }
        return "\(feed.visibleProducts.count) result\(feed.visibleProducts.count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let sourceInspiration {
                    AssetImage(name: sourceInspiration.assetName, contentMode: .fill)
                } else if let garment = focusedGarments.first {
                    CollageAssetImage(name: garment.catalogAssetName.isEmpty ? garment.sourceAssetName : garment.catalogAssetName)
                        .padding(5)
                } else {
                    Image(systemName: "bag").foregroundStyle(WearwellTheme.sage)
                }
            }
            .frame(width: 58, height: 68)
            .background(WearwellTheme.previewSurface)
            .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if feed.isUnread { Circle().fill(WearwellTheme.coral).frame(width: 7, height: 7) }
                }
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if ["queued", "processing"].contains(feed.state) { ProgressView() }
            else { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ShopProcessingStatus: View {
    let stage: String
    let estimatedSeconds: Int?
    let estimateUpdatedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = Int(max(0, timeline.date.timeIntervalSince(estimateUpdatedAt)))
            let remaining = estimatedSeconds.map { max(0, $0 - elapsed) }
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text(stage).font(.subheadline.weight(.semibold))
                    Text(remaining.map(estimateText) ?? "Luna is still working—results will appear here as they’re ready.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func estimateText(_ seconds: Int) -> String {
        if seconds <= 0 { return "Finishing up—results should appear shortly." }
        if seconds < 60 { return "About \(seconds) seconds remaining." }
        let minutes = Int(ceil(Double(seconds) / 60))
        return "About \(minutes) minute\(minutes == 1 ? "" : "s") remaining."
    }
}

private struct WishlistRow: View {
    let item: WishlistItem
    var sourceLabel: String? = nil
    private var assessmentIsActive: Bool {
        item.assessmentState.map { ["submitting", "queued", "processing"].contains($0) } ?? false
    }
    var body: some View {
        HStack(spacing: 15) { CollageAssetImage(name: item.catalogAssetName).padding(6).frame(width: 92, height: 110).background(WearwellTheme.previewSurface).clipShape(RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 5) { Text(item.label).font(.headline); Text("\(item.color) · \(item.subcategory?.title ?? item.category.title)").font(.caption).foregroundStyle(.secondary); if let sourceLabel { Label(sourceLabel, systemImage: "link").font(.caption2.weight(.semibold)).foregroundStyle(WearwellTheme.sage) }; if assessmentIsActive { StatusPill(text: "CREATING OUTFITS", color: WearwellTheme.sage) } else if let verdict = item.verdict { StatusPill(text: verdict.rawValue.uppercased(), color: verdict == .buy ? WearwellTheme.sage : WearwellTheme.coral) } else { Text("Tap to generate outfits").font(.caption2).foregroundStyle(.secondary) } }; Spacer(); Image(systemName: "chevron.right") }.padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct AddWishlistItemView: View {
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var url = ""
    @State private var working = false
    @State private var error: String?
    var body: some View {
        Form {
            Section { EditorialHeader(eyebrow: "Considering", title: "Should I buy this?", subtitle: "The item stays separate from your owned wardrobe.") }
            Section("Import candidate") {
                PhotosPicker(selection: $photo, matching: .images) { Label("Choose a photo", systemImage: "photo") }
                TextField("Or paste a product URL", text: $url).keyboardType(.URL).textInputAutocapitalization(.never)
                Button("Import URL") { Task { await loadURL() } }.disabled(url.isEmpty || working)
            }
            if working { ProgressView("Preparing candidate…") }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("New candidate").toolbar { Button("Cancel") { dismiss() } }
        .onChange(of: photo) { _, item in guard let item else { return }; Task { if let data = try? await item.loadTransferable(type: Data.self) { await create(from: data, sourceURL: nil) } } }
    }
    private func loadURL() async { do { let result = try await ImportService.image(from: url); await create(from: result.0, sourceURL: result.1.absoluteString) } catch { self.error = error.localizedDescription } }
    private func create(from data: Data, sourceURL: String?) async {
        guard companion.status == .available else { error = "Pair the Mac companion first."; return }
        working = true
        do {
            guard let analysis = try await companion.analyze(imageData: data, sourceURL: sourceURL).first else { throw ClientError.server("No clothing item was found.") }
            let source = try await AssetStore.shared.save(data, preferredExtension: "jpg")
            let catalogData = analysis.catalogImageBase64.flatMap { Data(base64Encoded: $0) } ?? data
            let catalog = try await AssetStore.shared.save(catalogData, preferredExtension: "png")
            let category = GarmentCategory(rawValue: analysis.category) ?? .tops
            let subcategory = analysis.subcategory.flatMap(GarmentSubcategory.init(rawValue:))
            context.insert(WishlistItem(label: analysis.label, category: category, subcategory: subcategory?.category == category ? subcategory : nil, color: analysis.color, details: analysis.description, sourceAssetName: source, catalogAssetName: catalog, sourceURL: sourceURL, fingerprint: analysis.fingerprint)); try context.save(); dismiss()
        } catch { self.error = error.localizedDescription }
        working = false
    }
}

struct WishlistDetailView: View {
    @Bindable var item: WishlistItem
    var autoAssess = false
    @Query private var garments: [Garment]
    @Query private var outfits: [Outfit]
    @Query private var styleProfiles: [StyleProfile]
    @Query private var inspirations: [InspirationLook]
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var assessment: PurchaseAssessmentDTO?
    @State private var working = false
    @State private var error: String?
    @State private var confirmDelete = false
    @AppStorage("savedOutfitViewMode") private var outfitViewMode = "gallery"
    private var assessmentIsActive: Bool { item.assessmentState.map { ["submitting", "queued", "processing"].contains($0) } ?? false }
    private var savedPurchaseOutfits: [Outfit] {
        outfits.filter { $0.wishlistItemID == item.id && $0.origin == .purchaseTest && $0.notes != SavedRecommendationContext.outfitMarker }
    }
    private var sourceContextOutfit: Outfit? {
        outfits.first { $0.wishlistItemID == item.id && $0.notes == SavedRecommendationContext.outfitMarker }
    }
    private var sourceInspiration: InspirationLook? {
        guard let id = SavedRecommendationContext.inspirationID(from: item.fingerprint) else { return nil }
        return inspirations.first { $0.id == id }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CollageAssetImage(name: item.catalogAssetName).padding(18).frame(height: 330).frame(maxWidth: .infinity).background(WearwellTheme.previewSurface).clipShape(RoundedRectangle(cornerRadius: 20))
                EditorialHeader(eyebrow: "Wishlist", title: item.label, subtitle: "\(item.color) · \(item.subcategory?.title ?? item.category.title)")
                if let sourceInspiration {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommended from this inspiration").font(.headline)
                        AssetImage(name: sourceInspiration.assetName, contentMode: .fill)
                            .frame(height: 190).frame(maxWidth: .infinity).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                if let sourceContextOutfit {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved with this outfit").font(.headline)
                        Text("Luna originally recommended the product for this exact combination.")
                            .font(.caption).foregroundStyle(.secondary)
                        CollagePreview(items: sourceContextOutfit.layout, garments: garments, candidate: item)
                            .aspectRatio(0.85, contentMode: .fit)
                            .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                Text(item.details).foregroundStyle(.secondary)
                Button { Task { await assess() } } label: { HStack { Spacer(); if working { ProgressView() } else { Label(assessmentIsActive ? "Generating outfits…" : "Generate outfits with this item", systemImage: "sparkles") }; Spacer() } }.buttonStyle(.borderedProminent).disabled(garments.count < 2 || companion.status != .available || working || assessmentIsActive)
                if working || assessmentIsActive {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.assessmentStage ?? "Queued — safe to lock").font(.caption.weight(.semibold))
                        if let estimate = item.assessmentEstimatedSecondsRemaining {
                            Text("Estimated time remaining: about \(max(1, Int(ceil(Double(estimate) / 60)))) min").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("You can lock your phone or leave the app; the Mac companion will keep working.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let assessment { verdictView(assessment) }
                else if let verdict = item.verdict {
                    StatusPill(text: verdict.rawValue.uppercased(), color: verdict == .buy ? WearwellTheme.sage : WearwellTheme.coral)
                    Text(item.verdictSummary)
                    if !savedPurchaseOutfits.isEmpty {
                        outfitViewPicker
                        purchaseOutfitsView(savedPurchaseOutfits)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                if let assessmentError = item.assessmentError { Text(assessmentError).foregroundStyle(.red) }
                Button("Mark as purchased") { markPurchased() }.buttonStyle(.bordered).frame(maxWidth: .infinity).disabled(assessmentIsActive)
                Text("This is styling guidance—not financial advice or proof of fit, sizing, or quality.").font(.caption).foregroundStyle(.secondary)
                Button("Delete candidate", role: .destructive) { confirmDelete = true }.frame(maxWidth: .infinity)
            }.padding()
        }.background(WearwellTheme.cream).navigationBarTitleDisplayMode(.inline)
        .onAppear { item.isUnreadAssessment = false; try? context.save() }
        .task {
            if autoAssess, assessment == nil, item.verdict == nil, item.assessmentJobID == nil, !working { await assess() }
            while !Task.isCancelled {
                await refreshAssessment()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Delete this candidate?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await AssetStore.shared.remove(named: item.sourceAssetName)
                    await AssetStore.shared.remove(named: item.catalogAssetName)
                }
                for outfit in outfits where outfit.wishlistItemID == item.id { context.delete(outfit) }
                context.delete(item)
                try? context.save()
                dismiss()
            }
        }
    }
    private func verdictView(_ value: PurchaseAssessmentDTO) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusPill(text: value.verdict.rawValue.uppercased(), color: value.verdict == .buy ? WearwellTheme.sage : WearwellTheme.coral)
            Text(value.summary).font(.subheadline)
            if !value.outfits.isEmpty {
                outfitViewPicker
                purchaseSuggestionsView(value.outfits)
            }
        }
    }

    private var outfitViewPicker: some View {
        HStack {
            Text("Potential outfits").font(.headline)
            Spacer()
            Picker("Outfit view", selection: $outfitViewMode) {
                Label("Gallery", systemImage: "square.grid.2x2").tag("gallery")
                Label("Names", systemImage: "list.bullet").tag("names")
            }
            .pickerStyle(.segmented)
            .frame(width: 205)
        }
    }

    @ViewBuilder
    private func purchaseSuggestionsView(_ suggestions: [OutfitSuggestionDTO]) -> some View {
        if outfitViewMode == "names" {
            ForEach(suggestions) { suggestion in suggestionLink(suggestion, gallery: false) }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 14) {
                ForEach(suggestions) { suggestion in suggestionLink(suggestion, gallery: true) }
            }
        }
    }

    @ViewBuilder
    private func purchaseOutfitsView(_ values: [Outfit]) -> some View {
        if outfitViewMode == "names" {
            ForEach(values) { outfit in savedOutfitLink(outfit, gallery: false) }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 14) {
                ForEach(values) { outfit in savedOutfitLink(outfit, gallery: true) }
            }
        }
    }

    private func suggestionLink(_ suggestion: OutfitSuggestionDTO, gallery: Bool) -> some View {
        NavigationLink {
            CollageEditorView(origin: .purchaseTest, title: suggestion.title, rationale: suggestion.rationale, items: purchaseLayout(for: suggestion), wishlistItem: item)
        } label: {
            purchaseOutfitLabel(title: suggestion.title, rationale: suggestion.rationale, layout: purchaseLayout(for: suggestion), gallery: gallery)
        }.buttonStyle(.plain)
    }

    private func savedOutfitLink(_ outfit: Outfit, gallery: Bool) -> some View {
        NavigationLink { OutfitDetailView(outfit: outfit) } label: {
            purchaseOutfitLabel(title: outfit.title, rationale: outfit.rationale, layout: outfit.layout, gallery: gallery)
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func purchaseOutfitLabel(title: String, rationale: String, layout: [LayoutItem], gallery: Bool) -> some View {
        if gallery {
            CollagePreview(items: layout, garments: garments, candidate: item)
                .aspectRatio(0.8, contentMode: .fit)
                .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .topLeading) {
                    Image(systemName: "bag").font(.caption.weight(.semibold)).foregroundStyle(WearwellTheme.sage)
                        .padding(8).background(.ultraThinMaterial, in: Circle()).padding(9)
                }
                .shadow(color: .black.opacity(0.06), radius: 14, y: 7)
                .accessibilityLabel(title)
        } else {
            HStack(spacing: 12) {
                Image(systemName: "bag").foregroundStyle(WearwellTheme.sage)
                    .frame(width: 44, height: 44).background(WearwellTheme.sage.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(rationale).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func assess() async {
        guard !assessmentIsActive else { return }
        working = true
        error = nil
        item.assessmentState = "submitting"
        item.assessmentStage = "Submitting purchase test"
        item.assessmentError = nil
        try? context.save()
        do {
            let job = try await companion.submitAssessment(candidate: item, garments: garments, styleProfile: styleProfiles.first, inspirations: inspirations)
            item.assessmentJobID = job.id
            apply(job)
            try context.save()
        } catch {
            item.assessmentState = "failed"
            item.assessmentError = error.localizedDescription
            self.error = error.localizedDescription
            try? context.save()
        }
        working = false
    }

    private func refreshAssessment() async {
        guard companion.status == .available,
              let state = item.assessmentState, ["queued", "processing"].contains(state),
              let id = item.assessmentJobID else { return }
        do {
            let job = try await companion.assessmentJob(id: id)
            apply(job)
            try context.save()
        } catch ClientError.jobNotFound {
            item.assessmentState = "failed"
            item.assessmentError = "This purchase test expired. Generate it again."
            try? context.save()
        } catch { /* the companion will keep processing while temporarily unreachable */ }
    }

    private func apply(_ job: AssessmentJobDTO) {
        assessment = PurchaseAssessmentResults.apply(job, to: item, garments: garments, outfits: outfits, context: context)
        if job.state == "complete" { item.isUnreadAssessment = false }
    }
    private func purchaseLayout(for suggestion: OutfitSuggestionDTO) -> [LayoutItem] {
        PurchaseAssessmentResults.layout(for: suggestion, candidateID: item.id)
    }
    private func markPurchased() {
        let garment = Garment(label: item.label, category: item.category, subcategory: item.subcategory, color: item.color, details: item.details, confidence: 1, fingerprint: item.fingerprint, sourceAssetName: item.sourceAssetName, catalogAssetName: item.catalogAssetName, sourceURL: item.sourceURL, modelVersion: "gpt-5.6-luna")
        context.insert(garment)
        for outfit in outfits where outfit.wishlistItemID == item.id { outfit.layout = outfit.layout.map { value in var updated = value; if updated.wishlistItemID == item.id { updated.wishlistItemID = nil; updated.garmentID = garment.id }; return updated }; outfit.wishlistItemID = nil; outfit.updatedAt = .now }
        item.purchasedAt = .now; context.delete(item); try? context.save(); dismiss()
    }
}

@MainActor
enum PurchaseAssessmentResults {
    @discardableResult
    static func apply(
        _ job: AssessmentJobDTO,
        to item: WishlistItem,
        garments: [Garment],
        outfits: [Outfit],
        context: ModelContext
    ) -> PurchaseAssessmentDTO? {
        item.assessmentState = job.state
        item.assessmentStage = job.stage
        item.assessmentEstimatedSecondsRemaining = job.estimatedSecondsRemaining
        item.assessmentError = job.error
        guard let raw = job.result else { return nil }

        let value = OutfitValidator.validatePurchase(raw, garments: garments, candidate: item)
        item.verdict = value.verdict
        item.verdictSummary = value.summary
        let currentOutfits = (try? context.fetch(FetchDescriptor<Outfit>())) ?? outfits
        var savedKeys = Set(currentOutfits.filter { $0.wishlistItemID == item.id && $0.origin == .purchaseTest }.map { "\($0.title)|\($0.rationale)" })
        for suggestion in value.outfits {
            let key = "\(suggestion.title)|\(suggestion.rationale)"
            guard savedKeys.insert(key).inserted else { continue }
            context.insert(Outfit(
                title: suggestion.title,
                rationale: suggestion.rationale,
                origin: .purchaseTest,
                layout: layout(for: suggestion, candidateID: item.id),
                wishlistItemID: item.id
            ))
        }
        return value
    }

    static func layout(for suggestion: OutfitSuggestionDTO, candidateID: UUID) -> [LayoutItem] {
        var result = [LayoutItem(wishlistItemID: candidateID, x: 0.5, y: 0.18, scale: 0.82, zIndex: 0)]
        result += suggestion.garmentIDs.enumerated().map { index, id in
            LayoutItem(
                garmentID: id,
                x: index % 2 == 0 ? 0.3 : 0.7,
                y: min(0.45 + Double(index / 2) * 0.27, 0.84),
                scale: 0.75,
                zIndex: Double(index + 1)
            )
        }
        return result
    }
}
