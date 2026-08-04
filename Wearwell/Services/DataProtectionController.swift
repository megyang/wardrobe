import CloudKit
import SwiftData
import SwiftUI

enum CloudProtectionState: Equatable {
    case checking
    case available
    case unavailable(String)

    var title: String {
        switch self {
        case .checking: "Checking iCloud…"
        case .available: "iCloud is available"
        case .unavailable: "iCloud needs attention"
        }
    }

    var detail: String {
        switch self {
        case .checking: "Wearwell is checking your private iCloud database."
        case .available: "Wardrobe records and pictures sync privately through your Apple ID."
        case .unavailable(let message): message
        }
    }
}

@MainActor
final class DataProtectionController: ObservableObject {
    @Published private(set) var cloudState: CloudProtectionState = .checking
    @Published private(set) var migrationCurrent = 0
    @Published private(set) var migrationTotal = 0
    @Published private(set) var migrationError: String?
    @Published private(set) var migrationComplete = false

    static let cloudContainerIdentifier = "iCloud.com.wearwell.app"

    private let modelContainer: ModelContainer
    private var started = false

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    var isMigrating: Bool { migrationTotal > 0 && !migrationComplete }

    func start() async {
        guard !started else {
            await refreshCloudStatus()
            return
        }
        started = true
        await AssetStore.shared.configure(container: modelContainer)
        await refreshCloudStatus()
        await migrateLegacyAssets()
    }

    func refreshCloudStatus() async {
        cloudState = .checking
        do {
            switch try await CKContainer(identifier: Self.cloudContainerIdentifier).accountStatus() {
            case .available:
                cloudState = .available
            case .noAccount:
                cloudState = .unavailable("Sign in to iCloud in Settings to protect and restore your wardrobe.")
            case .restricted:
                cloudState = .unavailable("This device restricts iCloud access. Wearwell will keep working locally.")
            case .couldNotDetermine:
                cloudState = .unavailable("Wearwell could not determine the iCloud account status. It will retry later.")
            case .temporarilyUnavailable:
                cloudState = .unavailable("iCloud is temporarily unavailable. Local changes are safe and will sync later.")
            @unknown default:
                cloudState = .unavailable("The iCloud account status is unknown. Local changes remain available.")
            }
        } catch {
            cloudState = .unavailable("Could not contact iCloud: \(error.localizedDescription)")
        }
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

/// Observes CloudKit-delivered blobs and materializes any missing local cache
/// files. The query updates as remote records arrive.
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
