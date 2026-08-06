import SwiftData
import SwiftUI

/// Documents the personal-local schema before Shop was introduced.
enum WearwellSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Garment.self, WishlistItem.self, Outfit.self, Visualization.self,
        ReferencePhoto.self, ImportDraft.self, InspirationLook.self,
        StyleProfile.self, StyleGeneration.self, AssetBlob.self
    ]
}

enum WearwellSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Garment.self, WishlistItem.self, Outfit.self, Visualization.self,
        ReferencePhoto.self, ImportDraft.self, InspirationLook.self,
        StyleProfile.self, StyleGeneration.self, AssetBlob.self,
        ShoppingProfile.self, ShopFeedSnapshot.self
    ]
}

enum WearwellSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Garment.self, WishlistItem.self, Outfit.self, Visualization.self,
        ReferencePhoto.self, ImportDraft.self, InspirationLook.self,
        StyleProfile.self, StyleGeneration.self, AssetBlob.self,
        ShoppingProfile.self, ShopFeedSnapshot.self, PurchaseNeed.self
    ]
}

enum WearwellSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static let models: [any PersistentModel.Type] = WearwellSchemaV3.models
}

@main
struct WearwellApp: App {
    private let container: ModelContainer = {
        let schema = Schema(versionedSchema: WearwellSchemaV4.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        // Existing personal-local installs used an unversioned SwiftData store.
        // Automatic lightweight migration can adopt it; a staged plan cannot.
        do { return try ModelContainer(for: schema, configurations: [configuration]) }
        catch { fatalError("Unable to create Wearwell store: \(error)") }
    }()

    @StateObject private var companion = CompanionClient()
    @StateObject private var protection: DataProtectionController
    @StateObject private var macBackups = MacBackupController()

    init() {
        let value = container
        _protection = StateObject(wrappedValue: DataProtectionController(modelContainer: value))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(companion)
                .environmentObject(protection)
                .environmentObject(macBackups)
                .tint(WearwellTheme.sage)
                .overlay(alignment: .topLeading) { AssetCacheHydrator() }
                .task {
                    await protection.start()
                    await companion.refreshStatus()
                }
        }
        .modelContainer(container)
    }
}

enum WearwellTheme {
    static let cream = Color(red: 0.973, green: 0.961, blue: 0.925)
    static let paper = Color(red: 1.0, green: 0.992, blue: 0.972)
    static let ink = Color(red: 0.14, green: 0.165, blue: 0.15)
    static let muted = Color(red: 0.41, green: 0.44, blue: 0.41)
    static let previewSurface = Color(red: 0.91, green: 0.92, blue: 0.92)
    static let sage = Color(red: 0.26, green: 0.41, blue: 0.34)
    static let coral = Color(red: 0.84, green: 0.43, blue: 0.33)
}
