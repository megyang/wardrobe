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
    @Query(sort: \ShopFeedSnapshot.generatedAt, order: .reverse) private var shopFeeds: [ShopFeedSnapshot]
    @Query(sort: \StyleGeneration.createdAt, order: .reverse) private var styleGenerations: [StyleGeneration]
    @State private var selection = 0
    @State private var showSettings = false

    private var unreadStudioCount: Int {
        shopFeeds.filter { $0.isOutfitSpecific && $0.isUnread }.count + styleGenerations.filter(\.isUnread).count
    }
    private var unreadShopCount: Int { shopFeeds.filter { !$0.isOutfitSpecific && $0.isUnread }.count }
    private var unreadWardrobeCount: Int { importDrafts.filter(\.isUnread).count }
    private var unreadSavedCount: Int { wishlistItems.filter(\.isUnreadAssessment).count }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { WardrobeView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Wardrobe", systemImage: "square.grid.2x2") }.badge(unreadWardrobeCount).tag(0)
            NavigationStack { OutfitStudioView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Studio", systemImage: "sparkles.rectangle.stack") }.badge(unreadStudioCount).tag(1)
            NavigationStack { InspirationView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Inspire", systemImage: "heart.rectangle") }.tag(2)
            NavigationStack { WishlistView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Shop", systemImage: "bag") }.badge(unreadShopCount).tag(3)
            NavigationStack { SavedItemsView(showSettings: $showSettings) }
                .keyboardDismissToolbar()
                .tabItem { Label("Saved", systemImage: "heart.fill") }.badge(unreadSavedCount).tag(4)
        }
        .background(WearwellTheme.cream)
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() }.keyboardDismissToolbar() }
        .task { await expireOverdueImports() }
        .task {
            while !Task.isCancelled {
                await refreshBackgroundGenerations()
                await refreshPurchaseAssessments()
                let hasActiveWork = wishlistItems.contains { item in
                    item.assessmentState.map { ["queued", "processing"].contains($0) } ?? false
                } || shopFeeds.contains { ["queued", "processing"].contains($0.state) }
                    || styleGenerations.contains { ["queued", "processing"].contains($0.state) }
                    || importDrafts.contains { ["queued", "processing"].contains($0.state) }
                try? await Task.sleep(for: .seconds(hasActiveWork ? 3 : 30))
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
                    await refreshBackgroundGenerations()
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
                let wasComplete = item.assessmentState == "complete"
                PurchaseAssessmentResults.apply(job, to: item, garments: garments, outfits: outfits, context: context)
                if !wasComplete, job.state == "complete" { item.isUnreadAssessment = true }
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

    private func refreshBackgroundGenerations() async {
        guard companion.isPaired, companion.status == .available else { return }
        var changed = false
        for snapshot in shopFeeds where ["queued", "processing"].contains(snapshot.state) {
            guard let id = snapshot.jobID else { continue }
            do {
                let job = try await companion.shopDiscoveryJob(id: id)
                let wasComplete = snapshot.state == "complete"
                snapshot.state = job.state; snapshot.errorMessage = job.error
                snapshot.progressStage = job.stage; snapshot.estimatedSecondsRemaining = job.estimatedSecondsRemaining
                snapshot.progressUpdatedAt = .now
                if let feed = job.result {
                    snapshot.query = feed.query; snapshot.products = feed.products
                    snapshot.generatedAt = ISO8601DateFormatter().date(from: feed.generatedAt) ?? .now
                    snapshot.expiresAt = snapshot.generatedAt.addingTimeInterval(6 * 60 * 60)
                }
                if !wasComplete, job.state == "complete" { snapshot.isUnread = true }
                changed = true
            } catch { /* the originating screen can expose a detailed retry state */ }
        }
        for generation in styleGenerations where ["queued", "processing"].contains(generation.state) {
            guard let id = generation.remoteJobID else { continue }
            do {
                let job = try await companion.styleJob(id: id)
                let wasComplete = generation.state == "complete"
                generation.state = job.state; generation.stage = job.stage
                generation.estimatedSecondsRemaining = job.estimatedSecondsRemaining
                generation.errorMessage = job.error; generation.updatedAt = .now
                if let result = job.result { generation.suggestions = OutfitValidator.validateAI(result.outfits, garments: garments) }
                if !wasComplete, job.state == "complete" { generation.isUnread = true }
                changed = true
            } catch { /* leave the durable job pending while temporarily unreachable */ }
        }
        for draft in importDrafts where ["queued", "processing"].contains(draft.state) {
            guard let id = draft.remoteJobID else { continue }
            do {
                let job = try await companion.analysisJob(id: id)
                draft.state = job.state; draft.progressStage = job.stage
                draft.progressCompleted = job.progressCompleted; draft.progressTotal = job.progressTotal
                draft.queuePosition = job.queuePosition; draft.estimatedSecondsRemaining = job.estimatedSecondsRemaining
                draft.errorMessage = job.error; draft.updatedAt = .now
                if let items = job.result?.items {
                    draft.analyses = items; draft.state = "ready"; draft.isUnread = true
                    await companion.deleteAnalysisJob(id: id)
                }
                changed = true
            } catch { /* Add will offer retry details if the job expires */ }
        }
        if changed { try? context.save() }
    }
}

struct SettingsButton: View {
    @Binding var isPresented: Bool
    var body: some View { Button { isPresented = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Settings") }
}
