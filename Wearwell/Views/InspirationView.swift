import PhotosUI
import SwiftData
import SwiftUI

struct InspirationView: View {
    @Binding var showSettings: Bool
    @Binding var showActivity: Bool
    var activityCount: Int
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Query(sort: \InspirationLook.createdAt, order: .reverse) private var looks: [InspirationLook]
    @Query private var profiles: [StyleProfile]
    @Query(sort: \ShopFeedSnapshot.generatedAt, order: .reverse) private var shoppingFeeds: [ShopFeedSnapshot]
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var error: String?
    @State private var retryCompleted = 0
    @State private var retryTotal = 0
    @State private var shopRequest: InspirationShopRequest?

    var body: some View {
        let isImporting = importing
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    EditorialHeader(
                        eyebrow: "Teach Luna your taste",
                        title: "Inspiration",
                        subtitle: "Add Pinterest screenshots or looks you love. Each image is analyzed once, then remembered in your private style profile.",
                        compact: !looks.isEmpty
                    )

                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 12, matching: .images) {
                        HStack {
                            Image(systemName: "photo.badge.plus")
                            Text(isImporting ? "Adding inspiration…" : "Choose inspiration looks").fontWeight(.semibold)
                            Spacer()
                            if isImporting { ProgressView() }
                        }
                        .padding(16).foregroundStyle(.white).background(WearwellTheme.sage, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(importing || companion.status != .available)

                    if companion.status != .available {
                        Text("Pair with the Mac companion to analyze new looks. Saved preferences remain available offline.")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }

                    if showsRetryControls {
                        Button {
                            Task { await retryFailedLooks() }
                        } label: {
                            Label(retryTitle, systemImage: "arrow.clockwise")
                                .fontWeight(.semibold).frame(maxWidth: .infinity)
                        }
                        .padding(14)
                        .foregroundStyle(WearwellTheme.sage)
                        .background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                        .disabled(importing || companion.status != .available)
                    }

                    if let profile = profiles.first?.profile {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Style profile", systemImage: "brain.head.profile").font(.headline)
                                Spacer()
                                StatusPill(text: "v\(profile.revision) · \(profile.lookCount) looks")
                            }
                            Text(profile.summary.isEmpty ? "Luna has saved your inspiration traits." : profile.summary)
                                .font(.subheadline).foregroundStyle(WearwellTheme.muted)
                            Text("This profile updates only when your inspiration library changes.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(16).background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 16))
                    }

                    if looks.isEmpty {
                        EmptyState(icon: "heart.rectangle", title: "No inspiration yet", message: "Upload a few outfits you genuinely like. Variety helps Luna learn the difference between a recurring preference and a one-off detail.")
                            .frame(minHeight: 280)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 14)], spacing: 14) {
                            ForEach(looks) { look in
                                inspirationCard(look)
                            }
                        }
                    }
                }.padding()
            }
        }
        .toolbar { SettingsButton(isPresented: $showSettings, showActivity: $showActivity, activityCount: activityCount) }
        .onAppear {
            for look in looks where look.isUnreadAnalysis { look.isUnreadAnalysis = false }
            try? context.save()
        }
        .safeAreaInset(edge: .bottom) {
            if showsRetryControls {
                Button {
                    Task { await retryFailedLooks() }
                } label: {
                    Label(retryTitle, systemImage: "arrow.clockwise")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .padding(14)
                .foregroundStyle(.white)
                .background(WearwellTheme.coral, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal).padding(.bottom, 6)
                .background(.ultraThinMaterial)
                .disabled(importing || companion.status != .available)
            }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await importLooks(items) }
        }
        .task {
            repairInterruptedLooks()
            await upgradeOutdatedLooksIfPossible()
        }
        .onChange(of: companion.status) { _, status in
            guard status == .available else { return }
            Task { await upgradeOutdatedLooksIfPossible() }
        }
        .sheet(item: $shopRequest) { request in
            NavigationStack {
                WishlistView(
                    showSettings: $showSettings, showActivity: $showActivity, activityCount: activityCount,
                    initialQuery: request.query, autoSearch: request.autoSearch,
                    focusInspirationIDs: [request.lookID]
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { shopRequest = nil }
                    }
                }
            }
        }
    }

    private func inspirationCard(_ look: InspirationLook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssetImage(name: look.assetName, contentMode: .fill)
                .frame(height: 210).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                if look.state == "failed" {
                    Button { Task { await analyze(look) } } label: {
                        StatusPill(text: "Tap to retry", color: .red)
                    }
                    .buttonStyle(.plain)
                    .disabled(companion.status != .available)
                } else {
                    StatusPill(text: statusTitle(look), color: WearwellTheme.sage)
                }
                Spacer()
                Button { toggleFavorite(look) } label: {
                    Image(systemName: look.isFavorite ? "heart.fill" : "heart").foregroundStyle(WearwellTheme.coral)
                }.buttonStyle(.plain).accessibilityLabel(look.isFavorite ? "Remove favorite emphasis" : "Emphasize this look")
            }
            if look.state == "ready" {
                if let feed = shoppingFeed(for: look) {
                    Button { reopen(feed, for: look) } label: {
                        Label(shoppingResultTitle(feed), systemImage: shoppingResultIcon(feed))
                            .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(feed.state == "failed" ? WearwellTheme.coral : WearwellTheme.sage)
                    .accessibilityHint("Shows recommendations matched to this inspiration photo")
                }
                Menu {
                    Button("Whole look", systemImage: "square.grid.2x2") { shop(look, target: .wholeLook) }
                    Button("Similar tops", systemImage: "tshirt") { shop(look, target: .tops) }
                    Button("Similar bottoms", systemImage: "figure.walk") { shop(look, target: .bottoms) }
                } label: {
                    Label("Shop similar", systemImage: "bag.badge.plus")
                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            if look.state == "failed" {
                if let message = look.errorMessage {
                    Text(message).font(.caption2).foregroundStyle(.red).lineLimit(3)
                }
                Button("Retry") { Task { await analyze(look) } }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(WearwellTheme.coral)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(companion.status != .available)
            } else if let analysis = look.analysis {
                Text(analysis.summary).font(.caption).foregroundStyle(WearwellTheme.muted).lineLimit(4)
            }
            Button("Delete", role: .destructive) { Task { await delete(look) } }
                .font(.caption2).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(10).background(WearwellTheme.paper, in: RoundedRectangle(cornerRadius: 18))
    }

    private func statusTitle(_ look: InspirationLook) -> String {
        switch look.state {
        case "ready": look.isFavorite ? "Favorite" : "Remembered"
        case "failed": "Needs retry"
        case "queued": "Queued"
        default: "Analyzing"
        }
    }

    private func shop(_ look: InspirationLook, target: InspirationShopTarget) {
        shopRequest = InspirationShopRequest(lookID: look.id, target: target)
    }

    private func shoppingFeed(for look: InspirationLook) -> ShopFeedSnapshot? {
        shoppingFeeds.first { $0.inspirationID == look.id }
    }

    private func reopen(_ feed: ShopFeedSnapshot, for look: InspirationLook) {
        shopRequest = InspirationShopRequest(lookID: look.id, query: feed.query, autoSearch: false)
    }

    private func shoppingResultTitle(_ feed: ShopFeedSnapshot) -> String {
        if ["queued", "processing"].contains(feed.state) { return "Shopping in progress · View" }
        if feed.state == "failed" { return "Shopping search failed · View" }
        let count = feed.visibleProducts.count
        return feed.isUnread ? "\(count) shopping results ready" : "View \(count) shopping results"
    }

    private func shoppingResultIcon(_ feed: ShopFeedSnapshot) -> String {
        if ["queued", "processing"].contains(feed.state) { return "clock.arrow.circlepath" }
        if feed.state == "failed" { return "exclamationmark.triangle" }
        return feed.isUnread ? "bag.badge.plus" : "bag"
    }

    private var retryTitle: String {
        importing && retryTotal > 0 ? "Retrying \(retryCompleted) of \(retryTotal)…" : "Retry all failed inspiration"
    }

    private var showsRetryControls: Bool {
        retryTotal > 0 || looks.contains(where: { $0.state == "failed" })
    }

    private func importLooks(_ items: [PhotosPickerItem]) async {
        importing = true; error = nil
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let assetName = try await AssetStore.shared.save(data, preferredExtension: "jpg")
                let look = InspirationLook(assetName: assetName)
                context.insert(look); try context.save()
                await analyze(look)
            } catch {
                self.error = error.localizedDescription
            }
        }
        importing = false
    }

    private func analyze(_ look: InspirationLook) async {
        look.state = "analyzing"; look.errorMessage = nil; look.updatedAt = .now; try? context.save()
        do {
            let data = try await AssetStore.shared.data(named: look.assetName)
            look.analysis = try await companion.analyzeInspiration(imageData: data)
            look.state = "ready"; look.errorMessage = nil; look.updatedAt = .now
            look.isUnreadAnalysis = false
            try context.save()
            let currentLooks = looks.contains { $0.id == look.id } ? looks : looks + [look]
            _ = try StylePreferenceCache.refresh(looks: currentLooks, context: context)
        } catch {
            look.state = "failed"
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                look.errorMessage = "Analysis was interrupted. Tap to retry."
            } else {
                look.errorMessage = error.localizedDescription
            }
            look.updatedAt = .now
            look.isUnreadAnalysis = false
            try? context.save()
        }
    }

    private func upgradeOutdatedLooksIfPossible() async {
        guard !importing, companion.status == .available else { return }
        let outdated = looks.filter { $0.state == "ready" && $0.analysis?.analysisVersion != "2" }
        guard !outdated.isEmpty else { return }
        importing = true; error = nil
        for look in outdated { await analyze(look) }
        importing = false
    }

    private func retryFailedLooks() async {
        guard !importing, companion.status == .available else { return }
        let failed = looks.filter { $0.state == "failed" }
        guard !failed.isEmpty else { return }
        importing = true; error = nil; retryCompleted = 0; retryTotal = failed.count
        for look in failed {
            look.state = "queued"; look.errorMessage = nil; look.updatedAt = .now
        }
        try? context.save()
        for look in failed {
            await analyze(look)
            retryCompleted += 1
        }
        importing = false; retryCompleted = 0; retryTotal = 0
    }

    private func repairInterruptedLooks() {
        let interrupted = looks.filter { ["analyzing", "queued"].contains($0.state) }
        guard !interrupted.isEmpty else { return }
        for look in interrupted {
            look.state = "failed"
            look.errorMessage = "Analysis was interrupted. Tap to retry."
            look.updatedAt = .now
        }
        try? context.save()
    }

    private func toggleFavorite(_ look: InspirationLook) {
        look.isFavorite.toggle(); look.updatedAt = .now
        try? context.save()
        _ = try? StylePreferenceCache.refresh(looks: looks, context: context)
    }

    private func delete(_ look: InspirationLook) async {
        await AssetStore.shared.remove(named: look.assetName)
        context.delete(look); try? context.save()
        _ = try? StylePreferenceCache.refresh(looks: looks.filter { $0.id != look.id }, context: context)
    }
}

private enum InspirationShopTarget {
    case wholeLook, tops, bottoms

    var query: String {
        switch self {
        case .wholeLook:
            "Find visually similar, purchasable pieces from this exact inspiration photo. Include the strongest tops, bottoms, layers, shoes, or accessories that reproduce its silhouette, proportions, palette, texture, and styling details."
        case .tops:
            "Find purchasable tops visually similar to the top or upper-body layers in this exact inspiration photo. Match silhouette, neckline, sleeve shape, material, color, print, and styling details. Return tops only."
        case .bottoms:
            "Find purchasable bottoms visually similar to the bottoms in this exact inspiration photo. Match silhouette, rise, length, material, color, print, and styling details. Return bottoms only."
        }
    }
}

private struct InspirationShopRequest: Identifiable {
    let id = UUID()
    let lookID: UUID
    let query: String
    let autoSearch: Bool

    init(lookID: UUID, target: InspirationShopTarget) {
        self.lookID = lookID
        query = target.query
        autoSearch = true
    }

    init(lookID: UUID, query: String, autoSearch: Bool) {
        self.lookID = lookID
        self.query = query
        self.autoSearch = autoSearch
    }
}
