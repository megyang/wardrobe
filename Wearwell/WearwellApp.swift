import SwiftData
import SwiftUI

/// First explicit schema baseline. The existing unversioned store also used
/// SwiftData's 1.0.0 schema version, so adding cloud-safe fields remains a
/// lightweight in-place upgrade instead of moving the user's database.
enum WearwellSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        Garment.self, WishlistItem.self, Outfit.self, Visualization.self,
        ReferencePhoto.self, ImportDraft.self, InspirationLook.self,
        StyleProfile.self, StyleGeneration.self, AssetBlob.self
    ]
}

@main
struct WearwellApp: App {
    private let container: ModelContainer = {
        let schema = Schema(versionedSchema: WearwellSchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do { return try ModelContainer(for: schema, configurations: [configuration]) }
        catch { fatalError("Unable to create Wearwell store: \(error)") }
    }()

    @StateObject private var hosted = HostedClient()
    @StateObject private var auth = HostedAuthController()
    @StateObject private var protection: DataProtectionController

    init() {
        let value = container
        _protection = StateObject(wrappedValue: DataProtectionController(modelContainer: value))
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(hosted)
                .environmentObject(auth)
                .environmentObject(protection)
                .tint(WearwellTheme.sage)
                .overlay(alignment: .topLeading) { AssetCacheHydrator() }
                .task {
                    await protection.start()
                    await hosted.refreshStatus()
                }
                .onOpenURL { url in try? auth.handleCallback(url) }
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
