import PhotosUI
import SwiftData
import SwiftUI
import UIKit

private struct ReviewCandidate: Identifiable {
    let id = UUID()
    let draftID: UUID
    var analysis: GarmentAnalysisDTO
    var label: String
    var category: GarmentCategory
    var subcategory: GarmentSubcategory?
    var color: String
    var details: String
    var accepted = true
    var catalogData: Data?
    var sourceData: Data
    var sourceURL: String?
    var showsSource = false
    var showsEditor = false
}

enum PhotoImportMode: String, CaseIterable, Identifiable {
    case separateItems
    case sameItem
    var id: String { rawValue }
    var title: String { self == .separateItems ? "Different items" : "One item, multiple views" }
}

struct StagedImportPhoto: Identifiable {
    let id = UUID()
    var data: Data
}

struct AddClothesView: View {
    private static let importTimeout: TimeInterval = 24 * 60 * 60

    @Binding var showSettings: Bool
    @EnvironmentObject private var hosted: HostedClient
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var garments: [Garment]
    @Query(sort: \ImportDraft.createdAt) private var drafts: [ImportDraft]
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var photoImportMode: PhotoImportMode = .separateItems
    @State private var stagedImportMode: PhotoImportMode = .separateItems
    @State private var stagedPhotos: [StagedImportPhoto] = []
    @State private var showPhotoPreflight = false
    @State private var showCamera = false
    @State private var urlText = ""
    @State private var importingURL = false
    @State private var reviews: [ReviewCandidate] = []
    @State private var error: String?

    private var working: Bool { drafts.contains { ["pending", "submitting", "queued", "processing"].contains($0.state) } }

    var body: some View {
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    EditorialHeader(eyebrow: "Build your closet", title: "Add clothes", subtitle: "Wearwell sees only the images you explicitly choose.")
                    photoImportCard
                    Button { showCamera = true } label: { ImportCard(icon: "camera", title: "Take a photo", detail: "Photograph one item or a complete worn look.") }.buttonStyle(.plain)
                    urlImportCard
                    if working {
                        VStack(spacing: 8) {
                            ProgressView("Luna is identifying visible clothes…")
                            Text("Once an import says Queued, you can lock your phone. The hosted worker will keep working.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding()
                    }
                    if !drafts.isEmpty { jobSection }
                    if let error { Text(error).foregroundStyle(.red).font(.subheadline) }
                    if !reviews.isEmpty { reviewSection }
                }.padding()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .toolbar { SettingsButton(isPresented: $showSettings) }
        .onChange(of: pickerItems) { _, items in Task { await importItems(items) } }
        .sheet(isPresented: $showPhotoPreflight, onDismiss: { stagedPhotos = [] }) {
            PhotoImportPreflight(photos: $stagedPhotos, mode: stagedImportMode) {
                showPhotoPreflight = false
                let photos = stagedPhotos
                stagedPhotos = []
                Task { await processStagedPhotos(photos, mode: stagedImportMode) }
            }
        }
        .sheet(isPresented: $showCamera) { CameraPicker { image in showCamera = false; guard let data = image.jpegData(compressionQuality: 0.9) else { return }; Task { await analyze(data: data, sourceURL: nil) } } }
        .task {
            await consumeShareInbox()
            while !Task.isCancelled {
                await refreshDrafts()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refreshDrafts() } } }
    }

    private var photoImportCard: some View {
        let chooseTitle = photoImportMode == .separateItems ? "Choose photos" : "Choose views of this item"
        return VStack(alignment: .leading, spacing: 14) {
            Label("Add from your photos", systemImage: "photo.on.rectangle.angled").font(.headline)
            Picker("How should these photos be processed?", selection: $photoImportMode) {
                ForEach(PhotoImportMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            Text(photoImportMode == .separateItems
                 ? "Choose a large batch. Each photo is processed separately."
                 : "Choose several angles of the same piece. They’ll be analyzed together as one item.")
                .font(.caption).foregroundStyle(.secondary)
            PhotosPicker(selection: $pickerItems, maxSelectionCount: 12, matching: .images) {
                Label(chooseTitle, systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20).background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
    }

    private var urlImportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Paste an image or product-page URL", systemImage: "link").font(.headline)
            TextField("https://…", text: $urlText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit {
                    guard canImportURL else { return }
                    KeyboardController.dismiss()
                    Task { await importURL() }
                }
                .padding(12)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
            Button(importingURL ? "Importing…" : "Import link") {
                KeyboardController.dismiss()
                Task { await importURL() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canImportURL)
        }
        .padding(20)
        .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(drafts) { draft in
                HStack {
                    Image(systemName: draft.state == "ready" ? "checkmark.circle.fill" : draft.state == "failed" ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    VStack(alignment: .leading) {
                        Text(draft.progressStage ?? jobLabel(draft.state)).font(.subheadline.weight(.semibold))
                        if let completed = draft.progressCompleted, let total = draft.progressTotal, total > 0, draft.state == "processing" {
                            ProgressView(value: Double(completed), total: Double(total)).frame(maxWidth: 190)
                        }
                        if ["queued", "processing", "submitting"].contains(draft.state) {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(estimatedTimeRemaining(for: draft, at: timeline.date)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let message = draft.errorMessage { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if ["failed", "pending"].contains(draft.state) { Button("Retry") { Task { await submit(draft) } }.buttonStyle(.bordered) }
                }
            }
            if drafts.contains(where: isMissingJob) {
                Button("Clear unavailable imports", role: .destructive) {
                    Task {
                        for draft in drafts where isMissingJob(draft) { await discardDraft(draft) }
                    }
                }.font(.caption.weight(.semibold))
            }
        }.padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Confirm each item").font(.title2.bold())
            Text("Generated catalog images are derived previews. Edit anything Luna got wrong before saving.").font(.caption).foregroundStyle(.secondary)
            ForEach(reviews) { candidate in
                if let review = reviewBinding(for: candidate) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Toggle("Save", isOn: review.accepted).labelsHidden(); Spacer(); StatusPill(text: "\(Int(review.wrappedValue.analysis.confidence * 100))% confidence", color: review.wrappedValue.analysis.confidence > 0.7 ? WearwellTheme.sage : WearwellTheme.coral) }
                    ZStack {
                        WearwellTheme.previewSurface
                        if review.wrappedValue.showsSource, let image = UIImage(data: review.wrappedValue.sourceData) {
                            Image(uiImage: image).resizable().scaledToFit().padding(8)
                        } else if let data = review.wrappedValue.catalogData {
                            CatalogDataImage(data: data).padding(18)
                        } else if let image = UIImage(data: review.wrappedValue.sourceData) {
                            Image(uiImage: image).resizable().scaledToFit().padding(8)
                        }
                    }
                    .aspectRatio(4 / 5, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.07)))
                    if review.wrappedValue.catalogData != nil {
                        HStack {
                            Button(review.wrappedValue.showsSource ? "Show clean catalog image" : "Compare with source photo") { review.wrappedValue.showsSource.toggle() }
                            Spacer()
                            Button { review.wrappedValue.showsEditor = true } label: { Label("Edit cutout", systemImage: "eraser") }
                        }.font(.caption.weight(.semibold))
                    }
                    Group {
                        TextField("Name", text: review.label)
                        Picker("Category", selection: review.category) { ForEach(GarmentCategory.allCases) { Text($0.title).tag($0) } }
                            .onChange(of: review.wrappedValue.category) { _, category in
                                if review.wrappedValue.subcategory?.category != category { review.wrappedValue.subcategory = nil }
                            }
                        if !GarmentSubcategory.options(for: review.wrappedValue.category).isEmpty {
                            Picker("Type", selection: review.subcategory) {
                                Text("Unspecified").tag(nil as GarmentSubcategory?)
                                ForEach(GarmentSubcategory.options(for: review.wrappedValue.category)) { item in
                                    Text(item.title).tag(Optional(item))
                                }
                            }
                        }
                        TextField("Color", text: review.color)
                        TextField("Description", text: review.details, axis: .vertical)
                        Text("Observed: \(review.wrappedValue.analysis.observed)").font(.caption).foregroundStyle(.secondary)
                    }.disabled(!review.wrappedValue.accepted)
                }
                .padding().background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16)).opacity(review.wrappedValue.accepted ? 1 : 0.62)
                .sheet(isPresented: review.showsEditor) {
                    CatalogImageEditor(imageData: review.catalogData, sourceData: review.wrappedValue.sourceData)
                }
                }
            }
            Button { Task { await saveConfirmed() } } label: { Label("Save confirmed items", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(!reviews.contains(where: \.accepted))
        }
    }

    private func importItems(_ items: [PhotosPickerItem]) async {
        let loaded = await withTaskGroup(of: (Int, StagedImportPhoto)?.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    guard let data = try? await item.loadTransferable(type: Data.self), UIImage(data: data) != nil else { return nil }
                    return (index, StagedImportPhoto(data: CropUtilities.preparedUploadData(data) ?? data))
                }
            }
            var result: [(Int, StagedImportPhoto)] = []
            for await photo in group { if let photo { result.append(photo) } }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
        pickerItems = []
        guard !loaded.isEmpty else { return }
        stagedPhotos = loaded
        stagedImportMode = photoImportMode
        showPhotoPreflight = true
    }

    private func processStagedPhotos(_ photos: [StagedImportPhoto], mode: PhotoImportMode) async {
        if mode == .sameItem {
            await analyze(data: photos.map(\.data), sourceURL: nil, sameItem: true)
        } else {
            for photo in photos { await analyze(data: [photo.data], sourceURL: nil, sameItem: false) }
        }
    }
    private func reviewBinding(for snapshot: ReviewCandidate) -> Binding<ReviewCandidate>? {
        guard reviews.contains(where: { $0.id == snapshot.id }) else { return nil }
        return Binding(
            get: { reviews.first(where: { $0.id == snapshot.id }) ?? snapshot },
            set: { updated in
                guard let index = reviews.firstIndex(where: { $0.id == snapshot.id }) else { return }
                reviews[index] = updated
            }
        )
    }
    private func importURL() async {
        guard canImportURL else { return }
        importingURL = true
        error = nil
        defer { importingURL = false }
        do {
            let result = try await ImportService.image(from: urlText)
            await analyze(data: result.0, sourceURL: result.1.absoluteString)
            urlText = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var canImportURL: Bool {
        !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !importingURL
    }
    private func consumeShareInbox() async {
        for item in ShareInbox.consume() {
            if let data = item.data { await analyze(data: data, sourceURL: nil) }
            else if let url = item.url { do { let result = try await ImportService.image(from: url.absoluteString); await analyze(data: result.0, sourceURL: url.absoluteString) } catch { self.error = error.localizedDescription } }
        }
    }
    private func analyze(data: Data, sourceURL: String?) async {
        await analyze(data: [data], sourceURL: sourceURL, sameItem: false)
    }

    private func analyze(data: [Data], sourceURL: String?, sameItem: Bool) async {
        guard !data.isEmpty else { return }
        error = nil
        var sources: [String] = []
        do {
            for imageData in data { sources.append(try await AssetStore.shared.save(imageData, preferredExtension: "jpg")) }
            let draft = ImportDraft(sourceAssetName: sources[0], additionalSourceAssetNames: Array(sources.dropFirst()), combinesSourcePhotos: sameItem, sourceURL: sourceURL)
            context.insert(draft); try context.save()
            if hosted.status == .available { await submit(draft) }
            else { draft.errorMessage = "Waiting for the hosted service."; try? context.save() }
        } catch {
            for source in sources { await AssetStore.shared.remove(named: source) }
            self.error = error.localizedDescription
        }
    }
    private func saveConfirmed() async {
        let reviewedDraftIDs = Set(reviews.map(\.draftID))
        for review in reviews where review.accepted {
            let duplicate = garments.contains { $0.fingerprint == review.analysis.fingerprint && !review.analysis.fingerprint.isEmpty }
            if duplicate { continue }
            do {
                let source = try await AssetStore.shared.save(review.sourceData, preferredExtension: "jpg")
                let rawCatalog = review.catalogData ?? review.sourceData
                let cleanedCatalog = await preparedCatalogData(rawCatalog) ?? rawCatalog
                let catalog = try await AssetStore.shared.save(cleanedCatalog, preferredExtension: "png")
                context.insert(Garment(label: review.label, category: review.category, subcategory: review.subcategory, color: review.color, details: review.details, observed: review.analysis.observed, unknowns: review.analysis.unknowns, confidence: review.analysis.confidence, fingerprint: review.analysis.fingerprint, sourceAssetName: source, catalogAssetName: catalog, sourceURL: review.sourceURL, modelVersion: review.analysis.modelVersion))
            } catch { self.error = error.localizedDescription }
        }
        for draft in drafts where reviewedDraftIDs.contains(draft.id) {
            for name in draft.sourceAssetNames { await AssetStore.shared.remove(named: name) }
            context.delete(draft)
        }
        try? context.save(); reviews = []
    }

    private func submit(_ draft: ImportDraft) async {
        guard hosted.status == .available else { draft.state = "pending"; draft.errorMessage = "Waiting for the hosted service."; try? context.save(); return }
        do {
            if draft.state == "failed" || draft.remoteJobID == nil { draft.createdAt = .now }
            let data = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (index, name) in draft.sourceAssetNames.enumerated() {
                    group.addTask { (index, try await AssetStore.shared.data(named: name)) }
                }
                var values: [(Int, Data)] = []
                for try await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }.map(\.1)
            }
            draft.errorMessage = nil; draft.state = "submitting"; try context.save()
            let job = try await hosted.submitAnalysis(imageData: data, sourceURL: draft.sourceURL, sameItem: draft.combinesSourcePhotos)
            draft.remoteJobID = job.id; apply(job, to: draft); try context.save()
        } catch {
            draft.state = "pending"; draft.errorMessage = error.localizedDescription; draft.updatedAt = .now; try? context.save()
        }
    }

    private func refreshDrafts() async {
        for draft in drafts {
            if isOverdue(draft) {
                if let id = draft.remoteJobID { await hosted.deleteAnalysisJob(id: id) }
                markUnavailable(draft, message: "Import expired after waiting 24 hours. Tap Retry to submit it again.")
                try? context.save()
                continue
            }
            if draft.state == "pending", hosted.status == .available { await submit(draft); continue }
            guard ["queued", "processing"].contains(draft.state), let id = draft.remoteJobID else { continue }
            do {
                let job = try await hosted.analysisJob(id: id)
                apply(job, to: draft)
                if let items = job.result?.items {
                    draft.analyses = items; draft.state = "ready"; try context.save()
                    await hosted.deleteAnalysisJob(id: id)
                } else { try context.save() }
            } catch HostedError.jobNotFound {
                markUnavailable(draft, message: "Job not found or expired. Tap Retry to submit it again.")
                try? context.save()
            } catch {
                draft.errorMessage = error.localizedDescription; try? context.save()
            }
        }
        await hydrateReadyDrafts()
    }

    private func hydrateReadyDrafts() async {
        for draft in drafts where draft.state == "ready" {
            guard let sourceData = try? await AssetStore.shared.data(named: draft.sourceAssetName) else { continue }
            for item in draft.analyses where !reviews.contains(where: { $0.draftID == draft.id && $0.analysis.id == item.id }) {
                let category = GarmentCategory(rawValue: item.category) ?? .tops
                let subcategory = item.subcategory.flatMap(GarmentSubcategory.init(rawValue:))
                let catalogData = await preparedCatalogData(item.catalogImageBase64.flatMap { Data(base64Encoded: $0) })
                reviews.append(ReviewCandidate(draftID: draft.id, analysis: item, label: item.label, category: category, subcategory: subcategory?.category == category ? subcategory : nil, color: item.color, details: item.description, catalogData: catalogData, sourceData: sourceData, sourceURL: draft.sourceURL))
            }
        }
    }

    private func preparedCatalogData(_ data: Data?) async -> Data? {
        guard let data else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return data }
            return AssetStore.preparedCollageImage(from: image).pngData() ?? data
        }.value
    }

    private func jobLabel(_ state: String) -> String {
        switch state {
        case "submitting": "Submitting import"
        case "queued": "Queued — safe to lock"
        case "processing": "Processing on the hosted worker"
        case "ready": "Ready to review"
        case "failed": "Import failed"
        default: "Waiting to submit"
        }
    }

    private func apply(_ job: AnalysisJobDTO, to draft: ImportDraft) {
        draft.state = job.state
        draft.progressStage = job.stage
        draft.progressCompleted = job.progressCompleted
        draft.progressTotal = job.progressTotal
        draft.queuePosition = job.queuePosition
        draft.estimatedSecondsRemaining = job.estimatedSecondsRemaining
        draft.errorMessage = job.error
        draft.updatedAt = .now
    }

    private func estimatedTimeRemaining(for draft: ImportDraft, at now: Date) -> String {
        var parts: [String] = []
        if draft.state == "queued", let position = draft.queuePosition {
            parts.append(position == 1 ? "Next in line" : "#\(position) in line")
        }
        if let estimate = draft.estimatedSecondsRemaining {
            let sinceRefresh = max(0, Int(now.timeIntervalSince(draft.updatedAt ?? now)))
            parts.append("Estimated time remaining: about \(duration(max(0, estimate - sinceRefresh)))")
        } else {
            parts.append("Estimating time remaining…")
        }
        return parts.joined(separator: " · ")
    }

    private func duration(_ seconds: Int) -> String {
        if seconds < 45 { return seconds <= 5 ? "a few seconds" : "<1 min" }
        let minutes = Int(ceil(Double(seconds) / 60))
        return "\(minutes) min"
    }

    private func isMissingJob(_ draft: ImportDraft) -> Bool {
        draft.errorMessage?.localizedCaseInsensitiveContains("job not found") == true ||
        draft.errorMessage?.localizedCaseInsensitiveContains("job expired") == true
    }

    private func isOverdue(_ draft: ImportDraft, at now: Date = .now) -> Bool {
        ["submitting", "queued", "processing"].contains(draft.state) &&
        now.timeIntervalSince(draft.createdAt) >= Self.importTimeout
    }

    private func markUnavailable(_ draft: ImportDraft, message: String) {
        draft.state = "failed"
        draft.remoteJobID = nil
        draft.progressStage = "Import unavailable"
        draft.queuePosition = nil
        draft.estimatedSecondsRemaining = nil
        draft.errorMessage = message
        draft.updatedAt = .now
    }

    private func discardDraft(_ draft: ImportDraft) async {
        for name in draft.sourceAssetNames { await AssetStore.shared.remove(named: name) }
        reviews.removeAll { $0.draftID == draft.id }
        context.delete(draft); try? context.save()
    }
}

private struct ImportCard: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        HStack(spacing: 18) { Image(systemName: icon).font(.title).foregroundStyle(WearwellTheme.sage).frame(width: 58, height: 58).background(WearwellTheme.sage.opacity(0.12), in: Circle()); VStack(alignment: .leading) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right") }
            .padding(20).background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController { let picker = UIImagePickerController(); picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary; picker.delegate = context.coordinator; return picker }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage) -> Void
        init(completion: @escaping (UIImage) -> Void) { self.completion = completion }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) { if let image = info[.originalImage] as? UIImage { completion(image) }; picker.dismiss(animated: true) }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}

struct PhotoImportPreflight: View {
    @Binding var photos: [StagedImportPhoto]
    let mode: PhotoImportMode
    let process: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editingPhoto: StagedImportPhoto?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mode == .separateItems
                             ? "\(photos.count) photo\(photos.count == 1 ? "" : "s") ready"
                             : "\(photos.count) view\(photos.count == 1 ? "" : "s") of one item")
                            .font(.title2.bold())
                        Text("Cropping is optional. Crop only the photos that need it, or process the whole selection now.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(photos) { photo in
                            VStack(spacing: 7) {
                                if let image = UIImage(data: photo.data) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(height: 132).frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                                Button { editingPhoto = photo } label: {
                                    Label("Crop", systemImage: "crop").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered).font(.caption.weight(.semibold))
                            }
                        }
                    }
                    Button {
                        process()
                    } label: {
                        Label(mode == .separateItems ? "Process all photos" : "Process as one item", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Text(mode == .separateItems
                         ? "Each photo will remain its own import job."
                         : "All views will be used together to identify one piece of clothing.")
                        .frame(maxWidth: .infinity).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding()
            }
            .background(WearwellTheme.cream)
            .navigationTitle("Review photos").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: $editingPhoto) { photo in
                CropPhotoView(imageData: photo.data) { cropped in
                    guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
                    photos[index].data = cropped
                }
            }
        }
    }
}

private struct CropPhotoView: View {
    let imageData: Data
    let apply: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cropRect = CGRect(x: 0.06, y: 0.06, width: 0.88, height: 0.88)

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let image = UIImage(data: imageData) {
                    GeometryReader { proxy in
                        let fitted = aspectFitRect(image.size, in: proxy.size)
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFit().frame(width: fitted.width, height: fitted.height)
                                .position(x: fitted.midX, y: fitted.midY)
                            Path { path in
                                path.addRect(fitted)
                                path.addRect(absoluteCrop(in: fitted))
                            }
                            .fill(.black.opacity(0.48), style: FillStyle(eoFill: true))
                            Rectangle().stroke(.white, lineWidth: 2).frame(width: absoluteCrop(in: fitted).width, height: absoluteCrop(in: fitted).height)
                                .position(x: absoluteCrop(in: fitted).midX, y: absoluteCrop(in: fitted).midY)
                            ForEach(CropCorner.allCases) { corner in cropHandle(corner, in: fitted) }
                        }
                    }
                    .padding(.horizontal).frame(maxHeight: .infinity)
                    Text("Drag the corner handles to keep the part of the photo you want.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo.badge.exclamationmark")
                }
            }
            .background(Color.black.opacity(0.94).ignoresSafeArea())
            .navigationTitle("Crop photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if let data = CropUtilities.crop(imageData, to: cropRect) {
                            apply(CropUtilities.preparedUploadData(data) ?? data)
                        }
                        dismiss()
                    }.fontWeight(.semibold)
                }
            }
        }
    }

    private func cropHandle(_ corner: CropCorner, in imageRect: CGRect) -> some View {
        let point = corner.point(for: absoluteCrop(in: imageRect))
        return Circle().fill(.white).overlay(Circle().stroke(.black.opacity(0.3)))
            .frame(width: 28, height: 28).position(point)
            .gesture(DragGesture().onChanged { value in update(corner, to: value.location, in: imageRect) })
    }

    private func update(_ corner: CropCorner, to point: CGPoint, in imageRect: CGRect) {
        let minimum: CGFloat = 0.12
        let x = min(1, max(0, (point.x - imageRect.minX) / imageRect.width))
        let y = min(1, max(0, (point.y - imageRect.minY) / imageRect.height))
        let maxX = cropRect.maxX, maxY = cropRect.maxY
        switch corner {
        case .topLeft:
            cropRect = CGRect(x: min(x, maxX - minimum), y: min(y, maxY - minimum), width: maxX - min(x, maxX - minimum), height: maxY - min(y, maxY - minimum))
        case .topRight:
            let newMaxX = max(x, cropRect.minX + minimum)
            cropRect = CGRect(x: cropRect.minX, y: min(y, maxY - minimum), width: newMaxX - cropRect.minX, height: maxY - min(y, maxY - minimum))
        case .bottomLeft:
            let newMaxY = max(y, cropRect.minY + minimum)
            cropRect = CGRect(x: min(x, maxX - minimum), y: cropRect.minY, width: maxX - min(x, maxX - minimum), height: newMaxY - cropRect.minY)
        case .bottomRight:
            cropRect.size = CGSize(width: max(x, cropRect.minX + minimum) - cropRect.minX, height: max(y, cropRect.minY + minimum) - cropRect.minY)
        }
    }

    private func absoluteCrop(in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + cropRect.minX * rect.width, y: rect.minY + cropRect.minY * rect.height, width: cropRect.width * rect.width, height: cropRect.height * rect.height)
    }

    private func aspectFitRect(_ imageSize: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
}

private enum CropCorner: CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: Self { self }
    func point(for rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }
}

enum CropUtilities {
    static func preparedUploadData(_ data: Data) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let longest = max(source.size.width, source.size.height)
        let scale = min(1, 2200 / longest)
        let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        var quality: CGFloat = 0.86
        var encoded = image.jpegData(compressionQuality: quality)
        while let value = encoded, value.count > 1_300_000, quality > 0.42 {
            quality -= 0.08
            encoded = image.jpegData(compressionQuality: quality)
        }
        return encoded
    }

    static func crop(_ data: Data, to normalizedRect: CGRect) -> Data? {
        guard let source = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let upright = UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
        guard let cgImage = upright.cgImage else { return nil }
        let pixelRect = CGRect(
            x: normalizedRect.minX * CGFloat(cgImage.width),
            y: normalizedRect.minY * CGFloat(cgImage.height),
            width: normalizedRect.width * CGFloat(cgImage.width),
            height: normalizedRect.height * CGFloat(cgImage.height)
        ).integral
        guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.92)
    }
}
