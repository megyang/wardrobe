import PhotosUI
import SwiftData
import SwiftUI

struct OutfitStudioView: View {
    @Binding var showSettings: Bool
    @Query(sort: \Outfit.updatedAt, order: .reverse) private var outfits: [Outfit]
    @Query private var garments: [Garment]
    @Query private var candidates: [WishlistItem]
    @AppStorage("savedOutfitViewMode") private var savedOutfitViewMode = "gallery"
    private var savedOutfits: [Outfit] { outfits.filter(\.belongsInOutfitLibrary) }

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    EditorialHeader(eyebrow: "Mix what you own", title: "Outfit Studio", subtitle: "Collage freely, or let Luna find a starting point.")
                    NavigationLink { CollageEditorView() } label: {
                        ModeCard(icon: "hand.draw", title: "Manual collage", detail: "Choose, layer, resize, rotate, and arrange your clothes. Works offline.", color: WearwellTheme.sage)
                    }.buttonStyle(.plain)
                    NavigationLink { AIStyleView() } label: {
                        ModeCard(icon: "sparkles", title: "AI Style", detail: "Let AI select owned pieces by ID, then arrange them yourself in the collage editor.", color: WearwellTheme.coral)
                    }.buttonStyle(.plain)
                    if !savedOutfits.isEmpty {
                        HStack(alignment: .center) {
                            Text("Saved outfits").font(.title2.bold())
                            Spacer()
                            Picker("Saved outfit view", selection: $savedOutfitViewMode) {
                                Label("Gallery", systemImage: "square.grid.2x2").tag("gallery")
                                Label("Names", systemImage: "list.bullet").tag("names")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 205)
                        }
                        .padding(.top, 8)

                        if savedOutfitViewMode == "names" {
                            ForEach(savedOutfits) { outfit in
                                NavigationLink { OutfitDetailView(outfit: outfit) } label: { OutfitRow(outfit: outfit) }
                                    .buttonStyle(.plain)
                            }
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                                ForEach(savedOutfits) { outfit in
                                    NavigationLink { OutfitDetailView(outfit: outfit) } label: {
                                        OutfitGalleryCard(outfit: outfit, garments: garments, candidate: candidate(for: outfit))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }.padding()
            }
        }.toolbar { SettingsButton(isPresented: $showSettings) }
    }

    private func candidate(for outfit: Outfit) -> WishlistItem? {
        guard let id = outfit.wishlistItemID else { return nil }
        return candidates.first { $0.id == id }
    }
}

private struct ModeCard: View {
    let icon, title, detail: String
    let color: Color
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.title).foregroundStyle(color).frame(width: 60, height: 60).background(color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(.title2, design: .serif, weight: .semibold)); Text(detail).font(.subheadline).foregroundStyle(WearwellTheme.muted) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(20).background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 20)).shadow(color: .black.opacity(0.05), radius: 18, y: 8)
    }
}

private struct OutfitRow: View {
    let outfit: Outfit
    var body: some View {
        HStack {
            Image(systemName: outfit.origin == .manual ? "hand.draw" : outfit.origin == .aiStyle ? "sparkles" : "bag")
                .foregroundStyle(WearwellTheme.sage).frame(width: 44, height: 44).background(WearwellTheme.sage.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading) { Text(outfit.title).font(.headline); Text("\(outfit.layout.count) pieces · \(outfit.originRaw)").font(.caption).foregroundStyle(.secondary) }
            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }.padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct OutfitGalleryCard: View {
    let outfit: Outfit
    let garments: [Garment]
    let candidate: WishlistItem?

    var body: some View {
        CollagePreview(items: outfit.layout, garments: garments, candidate: candidate)
            .aspectRatio(0.8, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                Image(systemName: outfit.origin == .manual ? "hand.draw" : outfit.origin == .aiStyle ? "sparkles" : "bag")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WearwellTheme.sage)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(9)
            }
            .overlay(alignment: .bottomTrailing) {
                Text("\(outfit.layout.count) pieces")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WearwellTheme.ink)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(9)
            }
            .shadow(color: .black.opacity(0.06), radius: 14, y: 7)
            .accessibilityLabel("\(outfit.title), \(outfit.layout.count) pieces")
    }
}

struct AIStyleView: View {
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @Query private var styleProfiles: [StyleProfile]
    @Query private var inspirations: [InspirationLook]
    @Query(sort: \Outfit.updatedAt, order: .reverse) private var savedLibraryOutfits: [Outfit]
    @Query(sort: \StyleGeneration.createdAt, order: .reverse) private var generations: [StyleGeneration]
    private let anchorGarmentID: UUID?
    @State private var occasion = "Everyday"
    @State private var weather = ""
    @State private var mood = ""
    @State private var request = ""
    @State private var anchorID: UUID?
    @State private var suggestions: [OutfitSuggestionDTO] = []
    @State private var feedbackByCombination: [String: OutfitFeedbackDTO] = [:]
    @State private var working = false
    @State private var error: String?

    init(anchorGarmentID: UUID? = nil) {
        self.anchorGarmentID = anchorGarmentID
        _anchorID = State(initialValue: anchorGarmentID)
    }

    private var anchoredGarment: Garment? {
        guard let anchorGarmentID else { return nil }
        return garments.first { $0.id == anchorGarmentID }
    }

    private var activeGeneration: StyleGeneration? {
        generations.first { ["submitting", "queued", "processing"].contains($0.state) }
    }

    var body: some View {
        Form {
            Section {
                EditorialHeader(eyebrow: "Luna stylist", title: "AI Style", subtitle: "Luna selects wardrobe IDs only. No outfit image is generated; you arrange the chosen pieces yourself.")
            }
            Section("Direction") {
                Picker("Occasion", selection: $occasion) { ForEach(["Everyday", "Work", "Dinner", "Weekend", "Travel", "Event"], id: \.self) { Text($0) } }
                TextField("Weather, e.g. warm and rainy", text: $weather)
                TextField("Mood or colors", text: $mood)
                TextField("Anything else", text: $request, axis: .vertical)
                if let anchoredGarment {
                    LabeledContent("Anchor piece", value: anchoredGarment.label)
                } else {
                    Picker("Anchor piece", selection: $anchorID) { Text("None").tag(nil as UUID?); ForEach(garments) { Text($0.label).tag($0.id as UUID?) } }
                }
            }
            Section {
                Button { Task { await generate() } } label: { HStack { Spacer(); if working { ProgressView() } else { Label("Recommend outfits", systemImage: "sparkles") }; Spacer() } }
                    .disabled(garments.count < 2 || working || activeGeneration != nil || hosted.status != .available)
                if let generation = activeGeneration {
                    DurableGenerationProgress(stage: generation.stage, estimatedSecondsRemaining: generation.estimatedSecondsRemaining)
                }
                if hosted.status != .available { Text("Sign in to hosted Wearwell in Settings to use Luna. Manual collage remains available.").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            }
            if !suggestions.isEmpty {
                Section("Selected pieces — tap to arrange") {
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink {
                                CollageEditorView(origin: .aiStyle, title: suggestion.title, rationale: suggestion.rationale, items: layout(for: suggestion))
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(suggestion.title).font(.headline)
                                    Text(suggestion.rationale).font(.caption).foregroundStyle(.secondary)
                                    Label("Open \(suggestion.garmentIDs.count) pieces in manual editor", systemImage: "hand.draw").font(.caption2).foregroundStyle(WearwellTheme.sage)
                                }
                            }
                            feedbackControls(for: suggestion)
                        }
                    }
                }
            }
        }
        .navigationTitle("AI Style").navigationBarTitleDisplayMode(.inline)
        .task {
            refreshFeedback()
            if suggestions.isEmpty, let latest = generations.first(where: { $0.state == "complete" }) {
                suggestions = latest.suggestions
            }
            while !Task.isCancelled {
                await refreshGenerations()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func generate() async {
        working = true; error = nil
        let summary = [occasion, weather, mood, request].filter { !$0.isEmpty }.joined(separator: " · ")
        let generation = StyleGeneration(requestSummary: summary.isEmpty ? "Everyday" : summary)
        context.insert(generation)
        try? context.save()
        do {
            let recentOutfits = generations
                .filter { $0.id != generation.id && $0.state == "complete" }
                .prefix(6)
                .flatMap(\.suggestions)
            let savedExamples = savedLibraryOutfits.compactMap(SavedOutfitExampleDTO.init)
            let job = try await hosted.submitStyle(
                garments: garments, occasion: occasion, weather: weather, mood: mood,
                anchorID: anchorID, request: request, styleProfile: styleProfiles.first,
                inspirations: inspirations, recentOutfits: recentOutfits,
                outfitFeedback: OutfitFeedbackStore.all(), savedOutfits: savedExamples,
                outfitEdits: OutfitFeedbackStore.allEdits()
            )
            generation.remoteJobID = job.id
            apply(job, to: generation)
            try context.save()
        }
        catch {
            generation.state = "failed"
            generation.errorMessage = error.localizedDescription
            generation.updatedAt = .now
            self.error = error.localizedDescription
            try? context.save()
        }
        working = false
    }

    private func refreshGenerations() async {
        guard hosted.status == .available else { return }
        for generation in generations where ["queued", "processing"].contains(generation.state) {
            guard let id = generation.remoteJobID else { continue }
            do {
                let job = try await hosted.styleJob(id: id)
                apply(job, to: generation)
                try context.save()
            } catch HostedError.jobNotFound {
                generation.state = "failed"
                generation.errorMessage = "This outfit request expired. Generate it again."
                generation.updatedAt = .now
                try? context.save()
            } catch { /* keep the durable job pending while the phone or service is temporarily unreachable */ }
        }
    }

    private func apply(_ job: StyleJobDTO, to generation: StyleGeneration) {
        generation.state = job.state
        generation.stage = job.stage
        generation.estimatedSecondsRemaining = job.estimatedSecondsRemaining
        generation.errorMessage = job.error
        generation.updatedAt = .now
        if let result = job.result {
            let valid = OutfitValidator.validateAI(result.outfits, garments: garments)
            generation.suggestions = valid
            suggestions = valid
            if valid.isEmpty { error = "Luna couldn't create a valid outfit from the current wardrobe." }
        } else if job.state == "failed" {
            error = job.error
        }
    }
    private func layout(for suggestion: OutfitSuggestionDTO) -> [LayoutItem] {
        OutfitLayout.arranged(garmentIDs: suggestion.garmentIDs)
    }

    private func refreshFeedback() {
        feedbackByCombination = Dictionary(uniqueKeysWithValues: OutfitFeedbackStore.all().map { ($0.combinationKey, $0) })
    }

    @ViewBuilder
    private func feedbackControls(for suggestion: OutfitSuggestionDTO) -> some View {
        let key = OutfitFeedbackStore.combinationKey(for: suggestion.garmentIDs)
        let current = feedbackByCombination[key]
        HStack(spacing: 10) {
            Button {
                if current?.rating == .loved { OutfitFeedbackStore.clear(for: suggestion) }
                else { OutfitFeedbackStore.set(.loved, for: suggestion) }
                refreshFeedback()
            } label: {
                Label("Love", systemImage: current?.rating == .loved ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered)
            .tint(WearwellTheme.coral)

            Menu {
                ForEach(OutfitFeedbackStore.dislikeReasons, id: \.self) { reason in
                    Button(reason) {
                        OutfitFeedbackStore.set(.disliked, reason: reason, for: suggestion)
                        refreshFeedback()
                    }
                }
                if current?.rating == .disliked {
                    Divider()
                    Button("Clear rating") {
                        OutfitFeedbackStore.clear(for: suggestion)
                        refreshFeedback()
                    }
                }
            } label: {
                Label(current?.rating == .disliked ? (current?.reason ?? "Not for me") : "Not for me", systemImage: current?.rating == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }
            .buttonStyle(.bordered)
            .tint(current?.rating == .disliked ? WearwellTheme.coral : WearwellTheme.muted)
        }
        .font(.caption.weight(.semibold))
    }
}

private struct DurableGenerationProgress: View {
    let stage: String?
    let estimatedSecondsRemaining: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stage ?? "Queued — safe to lock").font(.caption.weight(.semibold))
            if let estimatedSecondsRemaining {
                Text("Estimated time remaining: about \(max(1, Int(ceil(Double(estimatedSecondsRemaining) / 60)))) min")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("You can lock your phone or leave the app; the hosted service will keep working.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct OutfitDetailView: View {
    @Bindable var outfit: Outfit
    @Query private var garments: [Garment]
    @Query private var candidates: [WishlistItem]
    @Query private var references: [ReferencePhoto]
    @Query private var visualizations: [Visualization]
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var personPicker: PhotosPickerItem?
    @State private var workingMode: VisualizationMode?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var privateSharePreview: Data?
    @State private var showPrivateShare = false

    private var candidate: WishlistItem? { candidates.first { $0.id == outfit.wishlistItemID } }
    private var renders: [Visualization] { visualizations.filter { $0.outfitID == outfit.id } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EditorialHeader(eyebrow: outfit.originRaw, title: outfit.title, subtitle: outfit.rationale.isEmpty ? "An editable outfit from your wardrobe." : outfit.rationale)
                CollagePreview(items: outfit.layout, garments: garments, candidate: candidate).frame(height: 430)
                NavigationLink {
                    CollageEditorView(outfit: outfit, wishlistItem: candidate)
                } label: {
                    Label("Edit outfit", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                HStack {
                    NavigationLink {
                        CollageEditorView(
                            origin: outfit.origin,
                            title: "\(outfit.title) copy",
                            rationale: outfit.rationale,
                            items: outfit.layout,
                            wishlistItem: candidate
                        )
                    } label: {
                        Label("Copy outfit", systemImage: "plus.square.on.square").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { Task { await exportCollage() } } label: {
                        Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button { Task { await preparePrivateShare() } } label: {
                    Label("Share privately with a friend", systemImage: "person.2.wave.2").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(hosted.status != .available)
                Text("Visualize").font(.title2.bold())
                HStack {
                    visualizationButton(.mannequin)
                    PhotosPicker(selection: $personPicker, matching: .images) { Label("On me", systemImage: "person.crop.rectangle") }.buttonStyle(.bordered).disabled(workingMode != nil || hosted.status != .available)
                }
                Text("AI visualizations are approximate and do not prove fit, drape, opacity, sizing, or garment accuracy.").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                ForEach(renders) { render in AssetImage(name: render.assetName).frame(maxWidth: .infinity).frame(height: 420).clipShape(RoundedRectangle(cornerRadius: 18)) }
                Button("Delete outfit", role: .destructive) { confirmDelete = true }.frame(maxWidth: .infinity)
            }.padding()
        }.background(WearwellTheme.cream).navigationBarTitleDisplayMode(.inline)
        .onChange(of: personPicker) { _, item in guard let item else { return }; Task { if let data = try? await item.loadTransferable(type: Data.self) { await render(mode: .onMe, reference: data) } } }
        .sheet(isPresented: $showShareSheet) { if let exportURL { ActivitySheet(items: [exportURL]) } }
        .sheet(isPresented: $showPrivateShare) {
            if let privateSharePreview { ShareOutfitView(outfit: outfit, preview: privateSharePreview) }
        }
        .confirmationDialog("Delete this outfit?", isPresented: $confirmDelete) { Button("Delete", role: .destructive) { Task { await deleteOutfit() } } }
    }

    private func visualizationButton(_ mode: VisualizationMode) -> some View {
        Button { Task { guard let url = Bundle.main.url(forResource: "mannequin-reference", withExtension: "png"), let data = try? Data(contentsOf: url) else { return }; await render(mode: mode, reference: data) } } label: { Label(workingMode == mode ? "Working…" : mode.title, systemImage: "figure.stand") }.buttonStyle(.bordered).disabled(workingMode != nil || hosted.status != .available)
    }
    private func render(mode: VisualizationMode, reference: Data) async {
        workingMode = mode; error = nil
        do {
            let names = outfit.layout.compactMap { item -> String? in
                if let id = item.garmentID, let garment = garments.first(where: { $0.id == id }) { return garment.catalogAssetName }
                if item.wishlistItemID == candidate?.id { return candidate?.catalogAssetName }
                return nil
            }
            var data: [Data] = []
            for name in names { if let value = try? await AssetStore.shared.data(named: name) { data.append(value) } }
            let image = try await hosted.render(mode: mode, reference: reference, garmentImages: data)
            let name = try await AssetStore.shared.save(image, preferredExtension: "png")
            context.insert(Visualization(outfitID: outfit.id, mode: mode, assetName: name)); try context.save()
        } catch { self.error = error.localizedDescription }
        workingMode = nil
    }

    private func exportCollage() async {
        guard let data = await collagePNG() else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appending(path: "Wearwell-\(outfit.id.uuidString).png")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url; showShareSheet = true
        } catch { self.error = error.localizedDescription }
    }

    private func preparePrivateShare() async {
        guard let data = await collagePNG() else { error = "Wearwell could not prepare this outfit preview."; return }
        privateSharePreview = data
        showPrivateShare = true
    }

    private func collagePNG() async -> Data? {
        let canvas = CGSize(width: 1200, height: 1500)
        var layers: [(LayoutItem, UIImage)] = []
        for item in outfit.layout.sorted(by: { $0.zIndex < $1.zIndex }) {
            let name: String?
            if let id = item.garmentID { name = garments.first(where: { $0.id == id })?.catalogAssetName }
            else if item.wishlistItemID == candidate?.id { name = candidate?.catalogAssetName }
            else { name = nil }
            if let name, let data = try? await AssetStore.shared.data(named: name), let image = UIImage(data: data) { layers.append((item, image)) }
        }
        let renderer = UIGraphicsImageRenderer(size: canvas)
        let image = renderer.image { context in
            UIColor(red: 1, green: 0.992, blue: 0.972, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: canvas))
            for (item, image) in layers {
                let center = CGPoint(x: item.x * canvas.width, y: item.y * canvas.height)
                let bounds = CGRect(x: -190 * item.scale, y: -230 * item.scale, width: 380 * item.scale, height: 460 * item.scale)
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: center.x, y: center.y)
                context.cgContext.rotate(by: item.rotation * .pi / 180)
                image.draw(in: bounds)
                context.cgContext.restoreGState()
            }
        }
        return image.pngData()
    }

    private func deleteOutfit() async {
        for render in renders { await AssetStore.shared.remove(named: render.assetName); context.delete(render) }
        context.delete(outfit); try? context.save(); dismiss()
    }
}

struct CollagePreview: View {
    let items: [LayoutItem]
    let garments: [Garment]
    let candidate: WishlistItem?
    var body: some View {
        GeometryReader { proxy in
            let previewScale = min(proxy.size.width / 320, proxy.size.height / 400)
            ZStack {
                WearwellTheme.paper
                ForEach(items.sorted { $0.zIndex < $1.zIndex }) { item in
                    if let name = name(for: item) {
                        CollageAssetImage(name: name)
                            .frame(width: 150 * previewScale, height: 180 * previewScale)
                            .scaleEffect(item.scale)
                            .rotationEffect(.degrees(item.rotation))
                            .position(x: item.x * proxy.size.width, y: item.y * proxy.size.height)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 24))
        }
    }
    private func name(for item: LayoutItem) -> String? {
        if let id = item.garmentID, let garment = garments.first(where: { $0.id == id }) { return garment.catalogAssetName }
        if item.wishlistItemID == candidate?.id { return candidate?.catalogAssetName }
        return nil
    }
}
