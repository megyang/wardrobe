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

struct AddClothesView: View {
    private static let importTimeout: TimeInterval = 24 * 60 * 60

    @Binding var showSettings: Bool
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var garments: [Garment]
    @Query(sort: \ImportDraft.createdAt) private var drafts: [ImportDraft]
    @State private var pickerItems: [PhotosPickerItem] = []
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
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 12, matching: .images) { ImportCard(icon: "photo.on.rectangle.angled", title: "Choose photos", detail: "Detect every visible garment, then review each one.") }
                    Button { showCamera = true } label: { ImportCard(icon: "camera", title: "Take a photo", detail: "Photograph one item or a complete worn look.") }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Paste an image or product-page URL", systemImage: "link").font(.headline)
                        TextField("https://…", text: $urlText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .submitLabel(.go)
                            .onSubmit { guard canImportURL else { return }; Task { await importURL() } }
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        Button(importingURL ? "Importing…" : "Import link") { Task { await importURL() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canImportURL)
                    }.padding(20).background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                    if working {
                        VStack(spacing: 8) {
                            ProgressView("Luna is identifying visible clothes…")
                            Text("Once an import says Queued, you can lock your phone. The Mac will keep working.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding()
                    }
                    if !drafts.isEmpty { jobSection }
                    if let error { Text(error).foregroundStyle(.red).font(.subheadline) }
                    if !reviews.isEmpty { reviewSection }
                }.padding()
            }
        }
        .toolbar { SettingsButton(isPresented: $showSettings) }
        .onChange(of: pickerItems) { _, items in Task { await importItems(items) } }
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
        for item in items { if let data = try? await item.loadTransferable(type: Data.self) { await analyze(data: data, sourceURL: nil) } }
        pickerItems = []
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
        error = nil
        do {
            let source = try await AssetStore.shared.save(data, preferredExtension: "jpg")
            let draft = ImportDraft(sourceAssetName: source, sourceURL: sourceURL)
            context.insert(draft); try context.save()
            if companion.status == .available { await submit(draft) }
            else { draft.errorMessage = "Waiting for the paired Mac companion."; try? context.save() }
        } catch { self.error = error.localizedDescription }
    }
    private func saveConfirmed() async {
        let reviewedDraftIDs = Set(reviews.map(\.draftID))
        for review in reviews where review.accepted {
            let duplicate = garments.contains { $0.fingerprint == review.analysis.fingerprint && !review.analysis.fingerprint.isEmpty }
            if duplicate { continue }
            do {
                let source = try await AssetStore.shared.save(review.sourceData, preferredExtension: "jpg")
                let catalog = try await AssetStore.shared.save(review.catalogData ?? review.sourceData, preferredExtension: "png")
                context.insert(Garment(label: review.label, category: review.category, subcategory: review.subcategory, color: review.color, details: review.details, observed: review.analysis.observed, unknowns: review.analysis.unknowns, confidence: review.analysis.confidence, fingerprint: review.analysis.fingerprint, sourceAssetName: source, catalogAssetName: catalog, sourceURL: review.sourceURL, modelVersion: review.analysis.modelVersion))
            } catch { self.error = error.localizedDescription }
        }
        for draft in drafts where reviewedDraftIDs.contains(draft.id) {
            await AssetStore.shared.remove(named: draft.sourceAssetName)
            context.delete(draft)
        }
        try? context.save(); reviews = []
    }

    private func submit(_ draft: ImportDraft) async {
        guard companion.status == .available else { draft.state = "pending"; draft.errorMessage = "Waiting for the paired Mac companion."; try? context.save(); return }
        do {
            if draft.state == "failed" || draft.remoteJobID == nil { draft.createdAt = .now }
            let data = try await AssetStore.shared.data(named: draft.sourceAssetName)
            draft.errorMessage = nil; draft.state = "submitting"; try context.save()
            let job = try await companion.submitAnalysis(imageData: data, sourceURL: draft.sourceURL)
            draft.remoteJobID = job.id; apply(job, to: draft); try context.save()
        } catch {
            draft.state = "pending"; draft.errorMessage = error.localizedDescription; draft.updatedAt = .now; try? context.save()
        }
    }

    private func refreshDrafts() async {
        for draft in drafts {
            if isOverdue(draft) {
                if let id = draft.remoteJobID { await companion.deleteAnalysisJob(id: id) }
                markUnavailable(draft, message: "Import expired after waiting 24 hours. Tap Retry to submit it again.")
                try? context.save()
                continue
            }
            if draft.state == "pending", companion.status == .available { await submit(draft); continue }
            guard ["queued", "processing"].contains(draft.state), let id = draft.remoteJobID else { continue }
            do {
                let job = try await companion.analysisJob(id: id)
                apply(job, to: draft)
                if let items = job.result?.items {
                    draft.analyses = items; draft.state = "ready"; try context.save()
                    await companion.deleteAnalysisJob(id: id)
                } else { try context.save() }
            } catch ClientError.jobNotFound {
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
                reviews.append(ReviewCandidate(draftID: draft.id, analysis: item, label: item.label, category: category, subcategory: subcategory?.category == category ? subcategory : nil, color: item.color, details: item.description, catalogData: item.catalogImageBase64.flatMap { Data(base64Encoded: $0) }, sourceData: sourceData, sourceURL: draft.sourceURL))
            }
        }
    }

    private func jobLabel(_ state: String) -> String {
        switch state {
        case "submitting": "Submitting import"
        case "queued": "Queued — safe to lock"
        case "processing": "Processing on your Mac"
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
        await AssetStore.shared.remove(named: draft.sourceAssetName)
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
