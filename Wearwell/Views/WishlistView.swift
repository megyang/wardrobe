import PhotosUI
import SwiftData
import SwiftUI

struct WishlistView: View {
    @Binding var showSettings: Bool
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @Query(sort: \WishlistItem.createdAt, order: .reverse) private var candidates: [WishlistItem]
    @State private var photo: PhotosPickerItem?
    @State private var url = ""
    @State private var working = false
    @State private var error: String?
    @State private var selectedItem: WishlistItem?
    @State private var showResult = false

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    EditorialHeader(eyebrow: "Shop your wardrobe first", title: "Should I buy this?", subtitle: "Upload a possible purchase and Luna will build outfits with clothes you already own.")
                    VStack(alignment: .leading, spacing: 14) {
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

                    if working {
                        VStack(spacing: 8) {
                            ProgressView("Preparing the item…")
                            Text("After the item is ready, Luna will create 3–5 potential outfits.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding()
                    }
                    if hosted.status != .available {
                        Text("Sign in to hosted Wearwell in Settings to analyze a possible purchase.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error { Text(error).foregroundStyle(.red).font(.subheadline) }

                    if !candidates.isEmpty {
                        Text("Previous purchase tests").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        ForEach(candidates) { item in NavigationLink { WishlistDetailView(item: item) } label: { WishlistRow(item: item) }.buttonStyle(.plain) }
                    }
                }.padding()
            }
        }
        .toolbar { SettingsButton(isPresented: $showSettings) }
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
            if let selectedItem { WishlistDetailView(item: selectedItem, autoAssess: true) }
        }
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

    private func create(from data: Data, sourceURL: String?, managesWorkingState: Bool = true) async {
        guard hosted.status == .available else { error = "Sign in to hosted Wearwell first."; return }
        if managesWorkingState { working = true }
        error = nil
        do {
            guard let analysis = try await hosted.analyze(imageData: data, sourceURL: sourceURL).first else {
                throw HostedError.server("No clothing item was found.")
            }
            let source = try await AssetStore.shared.save(data, preferredExtension: "jpg")
            let catalogData = analysis.catalogImageBase64.flatMap { Data(base64Encoded: $0) } ?? data
            let catalog = try await AssetStore.shared.save(catalogData, preferredExtension: "png")
            let category = GarmentCategory(rawValue: analysis.category) ?? .tops
            let subcategory = analysis.subcategory.flatMap(GarmentSubcategory.init(rawValue:))
            let item = WishlistItem(
                label: analysis.label,
                category: category,
                subcategory: subcategory?.category == category ? subcategory : nil,
                color: analysis.color,
                details: analysis.description,
                sourceAssetName: source,
                catalogAssetName: catalog,
                sourceURL: sourceURL,
                fingerprint: analysis.fingerprint
            )
            context.insert(item)
            try context.save()
            selectedItem = item
            showResult = true
        } catch {
            self.error = error.localizedDescription
        }
        if managesWorkingState { working = false }
    }
}

private struct WishlistRow: View {
    let item: WishlistItem
    private var assessmentIsActive: Bool {
        item.assessmentState.map { ["submitting", "queued", "processing"].contains($0) } ?? false
    }
    var body: some View {
        HStack(spacing: 15) { CollageAssetImage(name: item.catalogAssetName).padding(6).frame(width: 92, height: 110).background(WearwellTheme.previewSurface).clipShape(RoundedRectangle(cornerRadius: 12)); VStack(alignment: .leading, spacing: 5) { Text(item.label).font(.headline); Text("\(item.color) · \(item.subcategory?.title ?? item.category.title)").font(.caption).foregroundStyle(.secondary); if assessmentIsActive { StatusPill(text: "CREATING OUTFITS", color: WearwellTheme.sage) } else if let verdict = item.verdict { StatusPill(text: verdict.rawValue.uppercased(), color: verdict == .buy ? WearwellTheme.sage : WearwellTheme.coral) } }; Spacer(); Image(systemName: "chevron.right") }.padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct AddWishlistItemView: View {
    @EnvironmentObject private var hosted: HostedClient
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
        guard hosted.status == .available else { error = "Sign in to hosted Wearwell first."; return }
        working = true
        do {
            guard let analysis = try await hosted.analyze(imageData: data, sourceURL: sourceURL).first else { throw HostedError.server("No clothing item was found.") }
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
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var assessment: PurchaseAssessmentDTO?
    @State private var working = false
    @State private var error: String?
    @State private var confirmDelete = false
    @AppStorage("savedOutfitViewMode") private var outfitViewMode = "gallery"
    private var assessmentIsActive: Bool { item.assessmentState.map { ["submitting", "queued", "processing"].contains($0) } ?? false }
    private var savedPurchaseOutfits: [Outfit] { outfits.filter { $0.wishlistItemID == item.id && $0.origin == .purchaseTest } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CollageAssetImage(name: item.catalogAssetName).padding(18).frame(height: 330).frame(maxWidth: .infinity).background(WearwellTheme.previewSurface).clipShape(RoundedRectangle(cornerRadius: 20))
                EditorialHeader(eyebrow: "Wishlist", title: item.label, subtitle: "\(item.color) · \(item.subcategory?.title ?? item.category.title)")
                Text(item.details).foregroundStyle(.secondary)
                Button { Task { await assess() } } label: { HStack { Spacer(); if working { ProgressView() } else { Label(assessmentIsActive ? "Outfits queued" : "Create 3–5 outfits + verdict", systemImage: "sparkles") }; Spacer() } }.buttonStyle(.borderedProminent).disabled(garments.count < 2 || hosted.status != .available || working || assessmentIsActive)
                if working || assessmentIsActive {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.assessmentStage ?? "Queued — safe to lock").font(.caption.weight(.semibold))
                        if let estimate = item.assessmentEstimatedSecondsRemaining {
                            Text("Estimated time remaining: about \(max(1, Int(ceil(Double(estimate) / 60)))) min").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("You can lock your phone or leave the app; the hosted service will keep working.").font(.caption2).foregroundStyle(.secondary)
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
        .task {
            if autoAssess, assessment == nil, item.verdict == nil, item.assessmentJobID == nil, !working { await assess() }
            while !Task.isCancelled {
                await refreshAssessment()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .confirmationDialog("Delete this candidate?", isPresented: $confirmDelete) { Button("Delete", role: .destructive) { Task { await AssetStore.shared.remove(named: item.sourceAssetName); await AssetStore.shared.remove(named: item.catalogAssetName) }; context.delete(item); try? context.save(); dismiss() } }
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
            let job = try await hosted.submitAssessment(candidate: item, garments: garments, styleProfile: styleProfiles.first, inspirations: inspirations)
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
        guard hosted.status == .available,
              let state = item.assessmentState, ["queued", "processing"].contains(state),
              let id = item.assessmentJobID else { return }
        do {
            let job = try await hosted.assessmentJob(id: id)
            apply(job)
            try context.save()
        } catch HostedError.jobNotFound {
            item.assessmentState = "failed"
            item.assessmentError = "This purchase test expired. Generate it again."
            try? context.save()
        } catch { /* the hosted will keep processing while temporarily unreachable */ }
    }

    private func apply(_ job: AssessmentJobDTO) {
        assessment = PurchaseAssessmentResults.apply(job, to: item, garments: garments, outfits: outfits, context: context)
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
