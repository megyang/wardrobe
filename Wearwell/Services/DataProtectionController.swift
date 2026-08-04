import SwiftData
import SwiftUI

enum DataProtectionState: Equatable {
    case checking
    case available
    case unavailable(String)

    var title: String {
        switch self {
        case .checking: "Preparing local storage…"
        case .available: "Local storage is ready"
        case .unavailable: "Local storage needs attention"
        }
    }

    var detail: String {
        switch self {
        case .checking: "Wearwell is preparing its protected on-device database."
        case .available: "Wardrobe records and pictures are stored privately on this iPhone."
        case .unavailable(let message): message
        }
    }
}

@MainActor
final class DataProtectionController: ObservableObject {
    @Published private(set) var storageState: DataProtectionState = .checking
    @Published private(set) var migrationCurrent = 0
    @Published private(set) var migrationTotal = 0
    @Published private(set) var migrationError: String?
    @Published private(set) var migrationComplete = false

    private let modelContainer: ModelContainer
    private var started = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var isMigrating: Bool { migrationTotal > 0 && !migrationComplete }

    func start() async {
        guard !started else {
            refreshStorageStatus()
            return
        }
        started = true
        await AssetStore.shared.configure(container: modelContainer)
        refreshStorageStatus()
        await migrateLegacyAssets()
    }

    func refreshStorageStatus() {
        storageState = .available
    }

    /// Rebuilds missing wardrobe rows from catalog images that are still safely
    /// stored in SwiftData. It never removes or replaces an existing garment.
    func recoverOrphanedCatalogItems() throws -> Int {
        let context = ModelContext(modelContainer)
        let garments = try context.fetch(FetchDescriptor<Garment>())
        let referencedNames = Set(garments.flatMap { [$0.sourceAssetName, $0.catalogAssetName] })
        let blobs = try context.fetch(FetchDescriptor<AssetBlob>(sortBy: [SortDescriptor(\.createdAt)]))
        let catalogBlobs = Dictionary(grouping: blobs, by: \.name)
            .compactMap { name, values -> AssetBlob? in
                guard name.lowercased().hasSuffix(".png"), !referencedNames.contains(name) else { return nil }
                return values.max { $0.updatedAt < $1.updatedAt }
            }
            .sorted { $0.name < $1.name }

        for (index, blob) in catalogBlobs.enumerated() {
            context.insert(Garment(
                label: "Recovered item \(index + 1)",
                category: .tops,
                color: "Needs review",
                details: "Recovered from the original catalog image after a storage configuration change.",
                confidence: 0,
                fingerprint: "recovered:\(blob.name)",
                sourceAssetName: blob.name,
                catalogAssetName: blob.name,
                tags: "recovered",
                modelVersion: "local-recovery"
            ))
        }
        if !catalogBlobs.isEmpty { try context.save() }
        return catalogBlobs.count
    }

    private func migrateLegacyAssets() async {
        let names = await AssetStore.shared.legacyAssetNames()
        migrationTotal = names.count
        migrationCurrent = 0
        migrationError = nil

        do {
            for name in names {
                _ = try await AssetStore.shared.persistCachedAsset(named: name)
                migrationCurrent += 1
            }
            migrationComplete = true
        } catch {
            migrationError = error.localizedDescription
            migrationComplete = false
        }
    }
}

/// Observes persisted blobs and materializes any missing local cache files.
struct AssetCacheHydrator: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AssetBlob.updatedAt) private var blobs: [AssetBlob]

    private var signature: Int {
        blobs.reduce(into: blobs.count) { value, blob in
            value ^= blob.name.hashValue
            value ^= blob.updatedAt.hashValue
        }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: signature) {
                for blob in blobs {
                    await AssetStore.shared.cache(name: blob.name, data: blob.data)
                }
                for values in Dictionary(grouping: blobs, by: \.name).values where values.count > 1 {
                    let ordered = values.sorted { $0.updatedAt > $1.updatedAt }
                    for duplicate in ordered.dropFirst() { context.delete(duplicate) }
                }
                if context.hasChanges { try? context.save() }
            }
    }
}
