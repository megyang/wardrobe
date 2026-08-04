import PhotosUI
import SwiftData
import SwiftUI

struct InspirationView: View {
    @Binding var showSettings: Bool
    @EnvironmentObject private var companion: CompanionClient
    @Environment(\.modelContext) private var context
    @Query(sort: \InspirationLook.createdAt, order: .reverse) private var looks: [InspirationLook]
    @Query private var profiles: [StyleProfile]
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        let isImporting = importing
        ZStack {
            WearwellTheme.cream.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    EditorialHeader(
                        eyebrow: "Teach Luna your taste",
                        title: "Inspiration",
                        subtitle: "Add Pinterest screenshots or looks you love. Each image is analyzed once, then remembered in your private style profile."
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
        .toolbar { SettingsButton(isPresented: $showSettings) }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await importLooks(items) }
        }
    }

    private func inspirationCard(_ look: InspirationLook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssetImage(name: look.assetName, contentMode: .fill)
                .frame(height: 210).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
            HStack {
                StatusPill(text: statusTitle(look), color: look.state == "failed" ? .red : WearwellTheme.sage)
                Spacer()
                Button { toggleFavorite(look) } label: {
                    Image(systemName: look.isFavorite ? "heart.fill" : "heart").foregroundStyle(WearwellTheme.coral)
                }.buttonStyle(.plain).accessibilityLabel(look.isFavorite ? "Remove favorite emphasis" : "Emphasize this look")
            }
            if let analysis = look.analysis {
                Text(analysis.summary).font(.caption).foregroundStyle(WearwellTheme.muted).lineLimit(4)
            } else if let message = look.errorMessage {
                Text(message).font(.caption2).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { Task { await analyze(look) } }.font(.caption.weight(.semibold))
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
        default: "Analyzing"
        }
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
            try context.save()
            let currentLooks = looks.contains { $0.id == look.id } ? looks : looks + [look]
            _ = try StylePreferenceCache.refresh(looks: currentLooks, context: context)
        } catch {
            look.state = "failed"; look.errorMessage = error.localizedDescription; look.updatedAt = .now
            try? context.save()
        }
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
