import SwiftData
import SwiftUI

struct RootTabView: View {
    private static let importTimeout: TimeInterval = 24 * 60 * 60

    @EnvironmentObject private var companion: CompanionClient
    @EnvironmentObject private var macBackups: MacBackupController
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query private var importDrafts: [ImportDraft]
    @Query private var wishlistItems: [WishlistItem]
    @Query private var garments: [Garment]
    @Query private var outfits: [Outfit]
    @State private var selection = 0
    @State private var showSettings = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { WardrobeView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Wardrobe", systemImage: "square.grid.2x2") }.tag(0)
            NavigationStack { OutfitStudioView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Studio", systemImage: "sparkles.rectangle.stack") }.tag(1)
            NavigationStack { InspirationView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Inspire", systemImage: "heart.rectangle") }.tag(2)
            NavigationStack { WishlistView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Shop", systemImage: "bag") }.tag(3)
            NavigationStack { AddClothesView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Add", systemImage: "plus.circle.fill") }.tag(4)
        }
        .background(WearwellTheme.cream)
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() }.keyboardDismissToolbar() }
        .task { await expireOverdueImports() }
        .task {
            while !Task.isCancelled {
                await refreshPurchaseAssessments()
                let hasActiveAssessment = wishlistItems.contains { item in
                    item.assessmentState.map { ["queued", "processing"].contains($0) } ?? false
                }
                try? await Task.sleep(for: .seconds(hasActiveAssessment ? 3 : 30))
            }
        }
        .task {
            while !Task.isCancelled {
                await macBackups.backupIfDue(context: context, companion: companion)
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await expireOverdueImports()
                    await refreshPurchaseAssessments()
                    await macBackups.backupIfDue(context: context, companion: companion)
                }
            } else if phase == .background {
                Task { await macBackups.backupIfDue(context: context, companion: companion) }
            }
        }
    }

    private func expireOverdueImports(at now: Date = .now) async {
        for draft in importDrafts where
            ["submitting", "queued", "processing"].contains(draft.state) &&
            now.timeIntervalSince(draft.createdAt) >= Self.importTimeout {
            if let id = draft.remoteJobID { await companion.deleteAnalysisJob(id: id) }
            draft.state = "failed"
            draft.remoteJobID = nil
            draft.progressStage = "Import unavailable"
            draft.queuePosition = nil
            draft.estimatedSecondsRemaining = nil
            draft.errorMessage = "Import expired after waiting 24 hours. Open Add and tap Retry."
            draft.updatedAt = .now
        }
        try? context.save()
    }

    private func refreshPurchaseAssessments() async {
        guard companion.isPaired else { return }
        var changed = false
        for item in wishlistItems {
            guard let state = item.assessmentState,
                  ["queued", "processing"].contains(state),
                  let id = item.assessmentJobID else { continue }
            do {
                let job = try await companion.assessmentJob(id: id)
                PurchaseAssessmentResults.apply(job, to: item, garments: garments, outfits: outfits, context: context)
                changed = true
            } catch ClientError.jobNotFound {
                item.assessmentState = "failed"
                item.assessmentError = "This purchase test expired. Generate it again."
                changed = true
            } catch {
                // The Mac keeps processing; foreground activation retries automatically.
            }
        }
        if changed { try? context.save() }
    }
}

struct SettingsButton: View {
    @Binding var isPresented: Bool
    var body: some View { Button { isPresented = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Settings") }
}
