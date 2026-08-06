import SwiftData
import SwiftUI

enum ActivityTarget: Hashable {
    case importDraft(UUID)
    case inspiration(UUID)
    case style(UUID)
    case shop(UUID)
    case assessment(UUID)
    case regeneration(UUID)
}

enum ActivityState: String {
    case active, complete, failed

    var icon: String {
        switch self {
        case .active: "clock.arrow.circlepath"
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .active: WearwellTheme.sage
        case .complete: WearwellTheme.sage
        case .failed: WearwellTheme.coral
        }
    }
}

struct ActivityEntry: Identifiable {
    let id: String
    let target: ActivityTarget
    let title: String
    let detail: String
    let state: ActivityState
    let date: Date
    let isUnread: Bool
    let estimatedSecondsRemaining: Int?
}

enum ActivityEntryBuilder {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    static func shouldInclude(state: ActivityState, date: Date, isUnread: Bool, now: Date = .now) -> Bool {
        state == .active || isUnread || now.timeIntervalSince(date) <= retention
    }

    static func normalized(_ state: String?) -> ActivityState {
        guard let state else { return .complete }
        if ["pending", "submitting", "queued", "processing", "analyzing"].contains(state) { return .active }
        if state == "failed" { return .failed }
        return .complete
    }
}

struct ActivityCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Binding var showSettings: Bool
    @Query(sort: \ImportDraft.createdAt, order: .reverse) private var drafts: [ImportDraft]
    @Query(sort: \InspirationLook.updatedAt, order: .reverse) private var inspirations: [InspirationLook]
    @Query(sort: \StyleGeneration.updatedAt, order: .reverse) private var generations: [StyleGeneration]
    @Query(sort: \ShopFeedSnapshot.generatedAt, order: .reverse) private var feeds: [ShopFeedSnapshot]
    @Query(sort: \WishlistItem.createdAt, order: .reverse) private var wishlist: [WishlistItem]
    @Query(sort: \Garment.createdAt, order: .reverse) private var garments: [Garment]

    private var entries: [ActivityEntry] {
        let now = Date.now
        var values: [ActivityEntry] = []
        values += drafts.map { draft in
            let state = ActivityEntryBuilder.normalized(draft.state)
            return ActivityEntry(id: "import-\(draft.id)", target: .importDraft(draft.id), title: "Clothing import", detail: draft.progressStage ?? (state == .complete ? "Ready to review" : draft.errorMessage ?? "Preparing clothes"), state: state, date: draft.updatedAt ?? draft.createdAt, isUnread: draft.isUnread, estimatedSecondsRemaining: draft.estimatedSecondsRemaining)
        }
        values += inspirations.map { look in
            let state = ActivityEntryBuilder.normalized(look.state)
            return ActivityEntry(id: "inspiration-\(look.id)", target: .inspiration(look.id), title: "Inspiration analysis", detail: state == .complete ? "Added to your style profile" : look.errorMessage ?? "Luna is learning this look", state: state, date: look.updatedAt, isUnread: look.isUnreadAnalysis, estimatedSecondsRemaining: nil)
        }
        values += generations.map { generation in
            let state = ActivityEntryBuilder.normalized(generation.state)
            return ActivityEntry(id: "style-\(generation.id)", target: .style(generation.id), title: "Outfit ideas", detail: generation.stage ?? generation.errorMessage ?? generation.requestSummary, state: state, date: generation.updatedAt, isUnread: generation.isUnread, estimatedSecondsRemaining: generation.estimatedSecondsRemaining)
        }
        values += feeds.map { feed in
            let state = ActivityEntryBuilder.normalized(feed.state)
            let title = feed.isOutfitSpecific ? "Products for an outfit" : (feed.isInspirationSpecific ? "Products from inspiration" : "Shopping recommendations")
            return ActivityEntry(id: "shop-\(feed.id)", target: .shop(feed.id), title: title, detail: feed.progressStage ?? feed.errorMessage ?? feed.query, state: state, date: feed.progressUpdatedAt ?? feed.generatedAt, isUnread: feed.isUnread, estimatedSecondsRemaining: feed.estimatedSecondsRemaining)
        }
        values += wishlist.compactMap { item -> ActivityEntry? in
            guard item.assessmentState != nil else { return nil }
            let state = ActivityEntryBuilder.normalized(item.assessmentState)
            return ActivityEntry(id: "assessment-\(item.id)", target: .assessment(item.id), title: "Purchase check", detail: item.assessmentStage ?? item.assessmentError ?? item.label, state: state, date: item.createdAt, isUnread: item.isUnreadAssessment, estimatedSecondsRemaining: item.assessmentEstimatedSecondsRemaining)
        }
        values += garments.compactMap { garment -> ActivityEntry? in
            guard garment.imageRegenerationState != nil else { return nil }
            let state = ActivityEntryBuilder.normalized(garment.imageRegenerationState)
            return ActivityEntry(id: "regeneration-\(garment.id)", target: .regeneration(garment.id), title: "Replacement clothing image", detail: garment.imageRegenerationStage ?? garment.imageRegenerationError ?? garment.label, state: state, date: garment.imageRegenerationUpdatedAt ?? garment.createdAt, isUnread: garment.isUnreadImageRegeneration, estimatedSecondsRemaining: nil)
        }
        return values.filter { ActivityEntryBuilder.shouldInclude(state: $0.state, date: $0.date, isUnread: $0.isUnread, now: now) }
            .sorted { lhs, rhs in
                if lhs.state == .active, rhs.state != .active { return true }
                if rhs.state == .active, lhs.state != .active { return false }
                if lhs.isUnread != rhs.isUnread { return lhs.isUnread }
                return lhs.date > rhs.date
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    EmptyState(icon: "bell", title: "Nothing new", message: "Luna's current work and recent results will appear here.")
                } else {
                    List {
                        ForEach(entries) { entry in
                            NavigationLink(value: entry.target) { ActivityRow(entry: entry) }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Activity")
            .navigationDestination(for: ActivityTarget.self) { target in destination(for: target) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Mark all read", systemImage: "checkmark.circle") { markAllRead() }
                        Button("Clear read items", systemImage: "trash") { clearReadItems() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    @ViewBuilder private func destination(for target: ActivityTarget) -> some View {
        switch target {
        case .importDraft:
            AddClothesView(showSettings: $showSettings)
        case .inspiration(let id):
            InspirationView(showSettings: $showSettings, showActivity: .constant(false), activityCount: 0).onAppear { markInspirationRead(id) }
        case .style:
            AIStyleView()
        case .shop(let id):
            if let feed = feeds.first(where: { $0.id == id }) { ActivityShopResultsView(feed: feed) }
            else { EmptyState(icon: "bag", title: "Result unavailable", message: "This shopping result has been removed.") }
        case .assessment(let id):
            if let item = wishlist.first(where: { $0.id == id }) { WishlistDetailView(item: item) }
            else { EmptyState(icon: "heart", title: "Item unavailable", message: "This saved item has been removed.") }
        case .regeneration(let id):
            if let garment = garments.first(where: { $0.id == id }) { GarmentDetailView(garment: garment).onAppear { garment.isUnreadImageRegeneration = false; try? context.save() } }
            else { EmptyState(icon: "tshirt", title: "Item unavailable", message: "This wardrobe item has been removed.") }
        }
    }

    private func markInspirationRead(_ id: UUID) {
        inspirations.first(where: { $0.id == id })?.isUnreadAnalysis = false
        try? context.save()
    }

    private func markAllRead() {
        drafts.forEach { $0.isUnread = false }; inspirations.forEach { $0.isUnreadAnalysis = false }
        generations.forEach { $0.isUnread = false }; feeds.forEach { $0.isUnread = false }
        wishlist.forEach { $0.isUnreadAssessment = false }; garments.forEach { $0.isUnreadImageRegeneration = false }
        try? context.save()
    }

    private func clearReadItems() {
        let cutoff = Date.now.addingTimeInterval(-ActivityEntryBuilder.retention)
        for generation in generations where !generation.isUnread && generation.updatedAt < cutoff { context.delete(generation) }
        for feed in feeds where !feed.isUnread && feed.generatedAt < cutoff { context.delete(feed) }
        try? context.save()
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.state.icon).foregroundStyle(entry.state.color).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(entry.title).font(.headline); if entry.isUnread { Circle().fill(WearwellTheme.coral).frame(width: 8, height: 8) } }
                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if entry.state == .active, let seconds = entry.estimatedSecondsRemaining {
                    Text("About \(max(1, Int(ceil(Double(seconds) / 60)))) min remaining").font(.caption2).foregroundStyle(WearwellTheme.sage)
                } else { Text(entry.date, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
            }
        }.padding(.vertical, 3)
    }
}

private struct ActivityShopResultsView: View {
    @Bindable var feed: ShopFeedSnapshot
    @Environment(\.modelContext) private var context

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                EditorialHeader(eyebrow: feed.isOutfitSpecific ? "For this outfit" : "Recent search", title: "Shopping results", subtitle: feed.query)
                if feed.products.isEmpty {
                    EmptyState(icon: "bag", title: feed.state == "failed" ? "Search failed" : "Still working", message: feed.errorMessage ?? feed.progressStage ?? "Luna is finding products.")
                } else {
                    ForEach(feed.products.filter { !feed.dismissedIDs.contains($0.id) }) { product in
                        ShopProductCard(product: product, test: nil, dismiss: { dismiss(product) })
                    }
                }
            }.padding()
        }
        .background(WearwellTheme.cream.ignoresSafeArea())
        .onAppear { feed.isUnread = false; try? context.save() }
    }

    private func dismiss(_ product: DiscoveredProductDTO) {
        var ids = feed.dismissedIDs; ids.insert(product.id); feed.dismissedIDs = ids; try? context.save()
    }
}
