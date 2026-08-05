import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct WardrobeView: View {
    @Binding var showSettings: Bool
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]
    @Environment(\.modelContext) private var context
    @State private var search = ""
    @State private var category: GarmentCategory?
    @State private var subcategory: GarmentSubcategory?
    @State private var showAdd = false

    private var filtered: [Garment] {
        garments.filter { garment in
            (category == nil || garment.category == category) &&
            (subcategory == nil || garment.subcategory == subcategory) &&
            (search.isEmpty || [garment.label, garment.color, garment.subcategory?.title ?? "", garment.tags, garment.occasion].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    private var cutoutNames: [String] {
        garments.map { $0.catalogAssetName.isEmpty ? $0.sourceAssetName : $0.catalogAssetName }
            .filter { !$0.isEmpty }
    }

    private var cutoutPreparationKey: String {
        cutoutNames.sorted().joined(separator: "|")
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add clothes")
            }
            ToolbarItem(placement: .topBarTrailing) { SettingsButton(isPresented: $showSettings) }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                AddClothesView(showSettings: $showSettings)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showAdd = false } } }
            }.keyboardDismissToolbar()
        }
        .task(id: cutoutPreparationKey) {
            let names = cutoutNames
            await Task.detached(priority: .utility) {
                // Warm the persistent cache sequentially to avoid competing
                // Vision requests while visible cards load at user priority.
                for name in names { _ = AssetStore.collageImage(named: name) }
            }.value
        }
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
                        Button("All") { subcategory = nil }.buttonStyle(FilterButtonStyle(selected: subcategory == nil))
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
    @Query private var garments: [Garment]
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var showImageRegenerator = false
    @AppStorage("savedOutfitViewMode") private var savedOutfitViewMode = "gallery"

    private var savedOutfits: [Outfit] {
        outfits.filter { $0.belongsInOutfitLibrary && $0.contains(garmentID: garment.id) }
    }

    var body: some View {
        Form {
            Section {
                CollageAssetImage(name: garment.catalogAssetName.isEmpty ? garment.sourceAssetName : garment.catalogAssetName)
                    .padding(16).frame(height: 420).frame(maxWidth: .infinity).background(WearwellTheme.previewSurface)
                if let candidateName = garment.pendingRegenerationCatalogAssetName {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("New regenerated image").font(.headline)
                        CollageAssetImage(name: candidateName)
                            .padding(12).frame(height: 320).frame(maxWidth: .infinity).background(WearwellTheme.previewSurface)
                        Text("Compare it with your current image above. Nothing is replaced until you choose Use new image.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Keep current") { Task { await discardRegeneratedImage() } }.buttonStyle(.bordered)
                            Spacer()
                            Button("Use new image") { Task { await acceptRegeneratedImage() } }.buttonStyle(.borderedProminent)
                        }
                    }.padding(.vertical, 8)
                }
                Button { showImageRegenerator = true } label: {
                    Label("Regenerate image from new photos", systemImage: "arrow.triangle.2.circlepath.camera")
                }
                .disabled(garment.imageRegenerationJobID != nil || garment.pendingRegenerationCatalogAssetName != nil)
                if garment.imageRegenerationJobID != nil {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(garment.imageRegenerationStage ?? "Regenerating image…").font(.subheadline.weight(.semibold))
                            Text("You can leave this screen. Your current image remains until the replacement is ready.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if let regenerationError = garment.imageRegenerationError {
                    Text(regenerationError).font(.caption).foregroundStyle(.red)
                }
            }
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
                    Picker("Outfit view", selection: $savedOutfitViewMode) {
                        Label("Gallery", systemImage: "square.grid.2x2").tag("gallery")
                        Label("Names", systemImage: "list.bullet").tag("names")
                    }
                    .pickerStyle(.segmented)

                    if savedOutfitViewMode == "names" {
                        ForEach(savedOutfits) { outfit in
                            NavigationLink {
                                OutfitDetailView(outfit: outfit)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(outfit.title).font(.headline)
                                    Text("\(outfit.layout.count) pieces · \(outfit.origin == .aiStyle ? "AI Style" : "Manual")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 12)], spacing: 12) {
                            ForEach(savedOutfits) { outfit in
                                NavigationLink {
                                    OutfitDetailView(outfit: outfit)
                                } label: {
                                    CollagePreview(items: outfit.layout, garments: garments, candidate: nil)
                                        .aspectRatio(0.8, contentMode: .fit)
                                        .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                                        .overlay(alignment: .bottomTrailing) {
                                            Text("\(outfit.layout.count) pieces")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(WearwellTheme.ink)
                                                .padding(.horizontal, 8).padding(.vertical, 5)
                                                .background(.ultraThinMaterial, in: Capsule())
                                                .padding(8)
                                        }
                                        .accessibilityLabel(outfit.title)
                                }
                                .buttonStyle(.plain)
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
        .task(id: garment.imageRegenerationJobID) { await monitorImageRegeneration() }
        .sheet(isPresented: $showImageRegenerator) {
            GarmentImageRegenerationSheet(garment: garment)
        }
        .confirmationDialog("Delete this garment and its local images?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                Task {
                    await AssetStore.shared.remove(named: garment.sourceAssetName)
                    await AssetStore.shared.remove(named: garment.catalogAssetName)
                    if let pending = garment.pendingRegenerationSourceAssetName { await AssetStore.shared.remove(named: pending) }
                    if let pending = garment.pendingRegenerationCatalogAssetName { await AssetStore.shared.remove(named: pending) }
                    if let jobID = garment.imageRegenerationJobID { await companion.deleteAnalysisJob(id: jobID) }
                }
                context.delete(garment); try? context.save(); dismiss()
            }
        }
    }

    private func monitorImageRegeneration() async {
        guard let jobID = garment.imageRegenerationJobID else { return }
        while !Task.isCancelled, garment.imageRegenerationJobID == jobID {
            guard companion.status == .available else {
                garment.imageRegenerationStage = "Waiting for the Mac companion"
                try? context.save()
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            do {
                let job = try await companion.analysisJob(id: jobID)
                garment.imageRegenerationState = job.state
                garment.imageRegenerationStage = job.stage ?? (job.state == "queued" ? "Waiting to regenerate" : "Regenerating image")
                try? context.save()
                if job.state == "complete" {
                    try await installRegeneratedImage(from: job)
                    await companion.deleteAnalysisJob(id: jobID)
                    return
                }
                if job.state == "failed" { throw RegenerationError.failed(job.error ?? "The image could not be regenerated.") }
                try await Task.sleep(for: .seconds(2))
            } catch is CancellationError {
                return
            } catch let regenerationError as RegenerationError {
                await failRegeneration(regenerationError.localizedDescription, jobID: jobID)
                return
            } catch ClientError.jobNotFound {
                await failRegeneration("The regeneration job expired. Your current image was not changed.", jobID: jobID)
                return
            } catch {
                garment.imageRegenerationStage = "Waiting to reconnect"
                try? context.save()
                try? await Task.sleep(for: .seconds(5))
                continue
            }
        }
    }

    private func installRegeneratedImage(from job: AnalysisJobDTO) async throws {
        guard let analysis = job.result?.items.first,
              let encoded = analysis.catalogImageBase64,
              let rawCatalog = Data(base64Encoded: encoded) else {
            throw RegenerationError.failed("The replacement image was unavailable. Your current image was not changed.")
        }
        let catalogData = await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: rawCatalog) else { return rawCatalog }
            return AssetStore.preparedCollageImage(from: image).pngData() ?? rawCatalog
        }.value
        let newCatalogName = try await AssetStore.shared.save(catalogData, preferredExtension: "png")
        let oldPendingCatalogName = garment.pendingRegenerationCatalogAssetName
        let oldPendingAnalysisJSON = garment.pendingRegenerationAnalysisJSON
        garment.pendingRegenerationCatalogAssetName = newCatalogName
        garment.pendingRegenerationAnalysisJSON = try? JSONEncoder().encode(analysis)
        garment.imageRegenerationJobID = nil
        garment.imageRegenerationState = "ready"
        garment.imageRegenerationStage = "Replacement ready to review"
        garment.imageRegenerationError = nil
        do {
            try context.save()
        } catch {
            garment.pendingRegenerationCatalogAssetName = oldPendingCatalogName
            garment.pendingRegenerationAnalysisJSON = oldPendingAnalysisJSON
            garment.imageRegenerationJobID = job.id
            garment.imageRegenerationState = job.state
            garment.imageRegenerationStage = job.stage
            try? context.save()
            await AssetStore.shared.remove(named: newCatalogName)
            throw RegenerationError.failed("The replacement could not be saved. Your current image was not changed.")
        }
        if let oldPendingCatalogName, oldPendingCatalogName != newCatalogName { await AssetStore.shared.remove(named: oldPendingCatalogName) }
    }

    private func failRegeneration(_ message: String, jobID: String) async {
        if let pending = garment.pendingRegenerationSourceAssetName { await AssetStore.shared.remove(named: pending) }
        if let pending = garment.pendingRegenerationCatalogAssetName { await AssetStore.shared.remove(named: pending) }
        garment.pendingRegenerationSourceAssetName = nil
        garment.pendingRegenerationCatalogAssetName = nil
        garment.pendingRegenerationAnalysisJSON = nil
        garment.imageRegenerationJobID = nil
        garment.imageRegenerationState = "failed"
        garment.imageRegenerationStage = nil
        garment.imageRegenerationError = message
        try? context.save()
        await companion.deleteAnalysisJob(id: jobID)
    }

    private func discardRegeneratedImage() async {
        if let pending = garment.pendingRegenerationSourceAssetName { await AssetStore.shared.remove(named: pending) }
        if let pending = garment.pendingRegenerationCatalogAssetName { await AssetStore.shared.remove(named: pending) }
        garment.pendingRegenerationSourceAssetName = nil
        garment.pendingRegenerationCatalogAssetName = nil
        garment.pendingRegenerationAnalysisJSON = nil
        garment.imageRegenerationState = nil
        garment.imageRegenerationStage = nil
        garment.imageRegenerationError = nil
        try? context.save()
    }

    private func acceptRegeneratedImage() async {
        guard let newSourceName = garment.pendingRegenerationSourceAssetName,
              let newCatalogName = garment.pendingRegenerationCatalogAssetName,
              let analysisData = garment.pendingRegenerationAnalysisJSON,
              let analysis = try? JSONDecoder().decode(GarmentAnalysisDTO.self, from: analysisData) else { return }
        let oldSourceName = garment.sourceAssetName
        let oldCatalogName = garment.catalogAssetName
        garment.sourceAssetName = newSourceName
        garment.catalogAssetName = newCatalogName
        garment.observed = analysis.observed
        garment.unknownsJSON = (try? JSONEncoder().encode(analysis.unknowns)) ?? garment.unknownsJSON
        garment.confidence = analysis.confidence
        garment.fingerprint = analysis.fingerprint
        garment.modelVersion = analysis.modelVersion
        garment.pendingRegenerationSourceAssetName = nil
        garment.pendingRegenerationCatalogAssetName = nil
        garment.pendingRegenerationAnalysisJSON = nil
        garment.imageRegenerationState = nil
        garment.imageRegenerationStage = nil
        garment.imageRegenerationError = nil
        do {
            try context.save()
        } catch {
            garment.sourceAssetName = oldSourceName
            garment.catalogAssetName = oldCatalogName
            garment.pendingRegenerationSourceAssetName = newSourceName
            garment.pendingRegenerationCatalogAssetName = newCatalogName
            garment.pendingRegenerationAnalysisJSON = analysisData
            try? context.save()
            return
        }
        if !oldSourceName.isEmpty, oldSourceName != newSourceName { await AssetStore.shared.remove(named: oldSourceName) }
        if !oldCatalogName.isEmpty, oldCatalogName != newCatalogName { await AssetStore.shared.remove(named: oldCatalogName) }
    }
}

private struct GarmentImageRegenerationSheet: View {
    @Bindable var garment: Garment

    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var stagedPhotos: [StagedImportPhoto] = []
    @State private var showPreflight = false
    @State private var processing = false
    @State private var stage = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: "photo.stack.fill")
                    .font(.system(size: 42)).foregroundStyle(WearwellTheme.sage)
                    .frame(width: 84, height: 84).background(WearwellTheme.sage.opacity(0.12), in: Circle())
                VStack(spacing: 8) {
                    Text("Regenerate \(garment.label)").font(.title2.bold())
                    Text("Choose one photo or several views of this same item. You can crop only the photos that need it before Luna creates the replacement image.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }

                if processing {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(stage.isEmpty ? "Starting regeneration…" : stage).font(.subheadline.weight(.semibold))
                        Text("Your current image stays unchanged until the replacement is ready.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(20).frame(maxWidth: .infinity)
                    .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 12, matching: .images) {
                        Label("Choose new photos", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(companion.status != .available)
                    if companion.status != .available {
                        Text("Connect to the Mac companion before regenerating this image.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                }

                if let error {
                    Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding().background(WearwellTheme.cream)
            .navigationTitle("Replace generated image").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .interactiveDismissDisabled(processing)
            .onChange(of: pickerItems) { _, items in Task { await loadSelection(items) } }
            .sheet(isPresented: $showPreflight, onDismiss: { if !processing { stagedPhotos = [] } }) {
                PhotoImportPreflight(photos: $stagedPhotos, mode: .sameItem) {
                    let photos = stagedPhotos
                    showPreflight = false
                    Task { await regenerate(using: photos) }
                }
            }
        }
    }

    private func loadSelection(_ items: [PhotosPickerItem]) async {
        let loaded = await withTaskGroup(of: (Int, StagedImportPhoto)?.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self), UIImage(data: data) != nil else { return nil }
                    return (index, StagedImportPhoto(data: CropUtilities.preparedUploadData(data) ?? data))
                }
            }
            var result: [(Int, StagedImportPhoto)] = []
            for await value in group { if let value { result.append(value) } }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        pickerItems = []
        guard !loaded.isEmpty else { return }
        stagedPhotos = loaded
        showPreflight = true
    }

    private func regenerate(using photos: [StagedImportPhoto]) async {
        guard !photos.isEmpty, companion.status == .available else { return }
        processing = true; error = nil; stage = "Uploading new views"
        defer { processing = false }

        var pendingSourceName: String?
        do {
            pendingSourceName = try await AssetStore.shared.save(photos[0].data, preferredExtension: "jpg")
            let job = try await companion.submitAnalysis(imageData: photos.map(\.data), sameItem: true)
            garment.pendingRegenerationSourceAssetName = pendingSourceName
            garment.imageRegenerationJobID = job.id
            garment.imageRegenerationState = job.state
            garment.imageRegenerationStage = job.stage ?? "Queued for regeneration"
            garment.imageRegenerationError = nil
            try context.save()
            dismiss()
        } catch {
            if let pendingSourceName { await AssetStore.shared.remove(named: pendingSourceName) }
            self.error = error.localizedDescription
        }
    }
}

private enum RegenerationError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let message) = self { message } else { nil }
    }
}
