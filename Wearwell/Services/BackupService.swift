import CryptoKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct WearwellBackupManifest: Codable {
    static let currentVersion = 1

    var version: Int
    var createdAt: Date
    var garments: [GarmentRecord]
    var wishlistItems: [WishlistRecord]
    var outfits: [OutfitRecord]
    var visualizations: [VisualizationRecord]
    var referencePhotos: [ReferencePhotoRecord]
    var inspirationLooks: [InspirationLookRecord]
    var styleProfiles: [StyleProfileRecord]
    var shoppingProfiles: [ShoppingProfileRecord]? = nil
    var purchaseNeeds: [PurchaseNeedRecord]? = nil
    var assets: [AssetRecord]

    struct GarmentRecord: Codable {
        var id: UUID; var label: String; var categoryRaw: String; var subcategoryRaw: String?
        var color: String; var details: String; var observed: String; var unknownsJSON: Data
        var confidence: Double; var fingerprint: String; var sourceAssetName: String; var catalogAssetName: String
        var sourceURL: String?; var tags: String; var season: String; var occasion: String
        var isFavorite: Bool; var createdAt: Date; var modelVersion: String; var promptVersion: String
    }

    struct WishlistRecord: Codable {
        var id: UUID; var label: String; var categoryRaw: String; var subcategoryRaw: String?
        var color: String; var details: String; var sourceAssetName: String; var catalogAssetName: String
        var sourceURL: String?; var fingerprint: String; var verdictRaw: String?; var verdictSummary: String
        var createdAt: Date; var purchasedAt: Date?
    }

    struct OutfitRecord: Codable {
        var id: UUID; var title: String; var notes: String; var rationale: String; var originRaw: String
        var layoutJSON: Data; var boardAssetName: String?; var wishlistItemID: UUID?; var createdAt: Date; var updatedAt: Date
    }

    struct VisualizationRecord: Codable {
        var id: UUID; var outfitID: UUID; var modeRaw: String; var assetName: String; var createdAt: Date; var modelVersion: String
    }

    struct ReferencePhotoRecord: Codable {
        var id: UUID; var label: String; var assetName: String; var isDefault: Bool; var createdAt: Date
    }

    struct InspirationLookRecord: Codable {
        var id: UUID; var assetName: String; var sourceURL: String?; var state: String; var analysisJSON: Data?
        var errorMessage: String?; var isFavorite: Bool; var createdAt: Date; var updatedAt: Date
    }

    struct StyleProfileRecord: Codable {
        var id: UUID; var signature: String; var revision: Int; var profileJSON: Data; var updatedAt: Date
    }

    struct ShoppingProfileRecord: Codable {
        var id: UUID; var profileJSON: Data; var updatedAt: Date
    }

    struct PurchaseNeedRecord: Codable {
        var id: UUID; var title: String; var categoryRaw: String; var subcategoryRaw: String?
        var rationale: String; var searchQuery: String; var isLunaSuggested: Bool
        var isCompleted: Bool; var createdAt: Date; var updatedAt: Date
    }

    struct AssetRecord: Codable {
        var name: String
        var byteCount: Int
        var sha256: String
    }
}

struct WearwellBackupArchive {
    var manifest: WearwellBackupManifest
    var assets: [String: Data]
}

struct MacBackupPlan {
    let manifest: WearwellBackupManifest
    let manifestData: Data
}

struct WearwellBackupDocument: FileDocument {
    static let contentType = UTType(exportedAs: "com.wearwell.backup", conformingTo: .package)
    static var readableContentTypes: [UTType] { [contentType] }

    let archive: WearwellBackupArchive

    init(archive: WearwellBackupArchive) {
        self.archive = archive
    }

    init(configuration: ReadConfiguration) throws {
        try self.init(fileWrapper: configuration.file)
    }

    init(fileWrapper: FileWrapper) throws {
        guard let root = fileWrapper.fileWrappers,
              let manifestData = root["manifest.json"]?.regularFileContents,
              let assetWrappers = root["assets"]?.fileWrappers
        else { throw BackupError.invalidPackage("The backup package is missing manifest.json or its assets folder.") }

        let manifest: WearwellBackupManifest
        do { manifest = try JSONDecoder.wearwell.decode(WearwellBackupManifest.self, from: manifestData) }
        catch { throw BackupError.invalidPackage("The backup manifest could not be read.") }
        guard manifest.version == WearwellBackupManifest.currentVersion else {
            throw BackupError.unsupportedVersion(manifest.version)
        }

        var values: [String: Data] = [:]
        for entry in manifest.assets {
            guard BackupService.isSafeAssetName(entry.name), values[entry.name] == nil,
                  let data = assetWrappers[entry.name]?.regularFileContents,
                  data.count == entry.byteCount,
                  BackupService.sha256(data) == entry.sha256
            else { throw BackupError.invalidPackage("An image in the backup is missing, duplicated, or damaged.") }
            values[entry.name] = data
        }
        archive = WearwellBackupArchive(manifest: manifest, assets: values)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try packageFileWrapper()
    }

    func packageFileWrapper() throws -> FileWrapper {
        let encoder = JSONEncoder.wearwell
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = FileWrapper(regularFileWithContents: try encoder.encode(archive.manifest))
        manifest.preferredFilename = "manifest.json"
        let assetFiles = archive.assets.mapValues { FileWrapper(regularFileWithContents: $0) }
        let assets = FileWrapper(directoryWithFileWrappers: assetFiles)
        assets.preferredFilename = "assets"
        return FileWrapper(directoryWithFileWrappers: ["manifest.json": manifest, "assets": assets])
    }
}

enum BackupError: LocalizedError {
    case invalidPackage(String)
    case unsupportedVersion(Int)
    case missingAsset(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let message): message
        case .unsupportedVersion(let version): "This backup uses unsupported format version \(version)."
        case .missingAsset(let name): "The image \(name) is missing and the backup was not created."
        }
    }
}

struct BackupRestoreResult: Equatable {
    var recordsApplied: Int
    var assetsApplied: Int
    var assetsUnchanged: Int

    var summary: String {
        "Restored \(recordsApplied) records and \(assetsApplied) images. \(assetsUnchanged) images were already current."
    }
}

@MainActor
enum BackupService {
    static func makeDocument(context: ModelContext) async throws -> WearwellBackupDocument {
        let plan = try await makeMacBackupPlan(context: context)
        var assetData: [String: Data] = [:]
        for asset in plan.manifest.assets {
            assetData[asset.name] = try await data(for: asset, context: context)
        }
        return WearwellBackupDocument(archive: .init(manifest: plan.manifest, assets: assetData))
    }

    /// Builds the small snapshot manifest without retaining every wardrobe image
    /// in memory. The companion requests only hashes it has not stored before.
    static func makeMacBackupPlan(context: ModelContext) async throws -> MacBackupPlan {
        let garments = try context.fetch(FetchDescriptor<Garment>())
        let wishlist = try context.fetch(FetchDescriptor<WishlistItem>())
        let outfits = try context.fetch(FetchDescriptor<Outfit>())
        let visualizations = try context.fetch(FetchDescriptor<Visualization>())
        let references = try context.fetch(FetchDescriptor<ReferencePhoto>())
        let inspiration = try context.fetch(FetchDescriptor<InspirationLook>())
        let profiles = try context.fetch(FetchDescriptor<StyleProfile>())
        let shoppingProfiles = try context.fetch(FetchDescriptor<ShoppingProfile>())
        let purchaseNeeds = try context.fetch(FetchDescriptor<PurchaseNeed>())
        let blobs = try context.fetch(FetchDescriptor<AssetBlob>())

        var assetRecords: [String: WearwellBackupManifest.AssetRecord] = [:]
        for blob in blobs.sorted(by: { $0.updatedAt < $1.updatedAt }) where isSafeAssetName(blob.name) {
            let value = blob.data
            assetRecords[blob.name] = .init(name: blob.name, byteCount: value.count, sha256: sha256(value))
        }
        var referenced = Set<String>()
        for item in garments { referenced.insert(item.sourceAssetName); referenced.insert(item.catalogAssetName) }
        for item in wishlist { referenced.insert(item.sourceAssetName); referenced.insert(item.catalogAssetName) }
        for item in outfits { if let name = item.boardAssetName { referenced.insert(name) } }
        for item in visualizations { referenced.insert(item.assetName) }
        for item in references { referenced.insert(item.assetName) }
        for item in inspiration { referenced.insert(item.assetName) }
        referenced.remove("")
        for name in referenced where assetRecords[name] == nil {
            guard let value = try? await AssetStore.shared.data(named: name) else { throw BackupError.missingAsset(name) }
            assetRecords[name] = .init(name: name, byteCount: value.count, sha256: sha256(value))
        }

        let manifest = WearwellBackupManifest(
            version: WearwellBackupManifest.currentVersion,
            createdAt: .now,
            garments: garments.map { .init(id: $0.id, label: $0.label, categoryRaw: $0.categoryRaw, subcategoryRaw: $0.subcategoryRaw, color: $0.color, details: $0.details, observed: $0.observed, unknownsJSON: $0.unknownsJSON, confidence: $0.confidence, fingerprint: $0.fingerprint, sourceAssetName: $0.sourceAssetName, catalogAssetName: $0.catalogAssetName, sourceURL: $0.sourceURL, tags: $0.tags, season: $0.season, occasion: $0.occasion, isFavorite: $0.isFavorite, createdAt: $0.createdAt, modelVersion: $0.modelVersion, promptVersion: $0.promptVersion) },
            wishlistItems: wishlist.map { .init(id: $0.id, label: $0.label, categoryRaw: $0.categoryRaw, subcategoryRaw: $0.subcategoryRaw, color: $0.color, details: $0.details, sourceAssetName: $0.sourceAssetName, catalogAssetName: $0.catalogAssetName, sourceURL: $0.sourceURL, fingerprint: $0.fingerprint, verdictRaw: $0.verdictRaw, verdictSummary: $0.verdictSummary, createdAt: $0.createdAt, purchasedAt: $0.purchasedAt) },
            outfits: outfits.map { .init(id: $0.id, title: $0.title, notes: $0.notes, rationale: $0.rationale, originRaw: $0.originRaw, layoutJSON: $0.layoutJSON, boardAssetName: $0.boardAssetName, wishlistItemID: $0.wishlistItemID, createdAt: $0.createdAt, updatedAt: $0.updatedAt) },
            visualizations: visualizations.map { .init(id: $0.id, outfitID: $0.outfitID, modeRaw: $0.modeRaw, assetName: $0.assetName, createdAt: $0.createdAt, modelVersion: $0.modelVersion) },
            referencePhotos: references.map { .init(id: $0.id, label: $0.label, assetName: $0.assetName, isDefault: $0.isDefault, createdAt: $0.createdAt) },
            inspirationLooks: inspiration.map { .init(id: $0.id, assetName: $0.assetName, sourceURL: $0.sourceURL, state: $0.state, analysisJSON: $0.analysisJSON, errorMessage: $0.errorMessage, isFavorite: $0.isFavorite, createdAt: $0.createdAt, updatedAt: $0.updatedAt) },
            styleProfiles: profiles.map { .init(id: $0.id, signature: $0.signature, revision: $0.revision, profileJSON: $0.profileJSON, updatedAt: $0.updatedAt) },
            shoppingProfiles: shoppingProfiles.map { .init(id: $0.id, profileJSON: $0.profileJSON, updatedAt: $0.updatedAt) },
            purchaseNeeds: purchaseNeeds.map { .init(id: $0.id, title: $0.title, categoryRaw: $0.categoryRaw, subcategoryRaw: $0.subcategoryRaw, rationale: $0.rationale, searchQuery: $0.searchQuery, isLunaSuggested: $0.isLunaSuggested, isCompleted: $0.isCompleted, createdAt: $0.createdAt, updatedAt: $0.updatedAt) },
            assets: assetRecords.values.sorted { $0.name < $1.name }
        )
        let encoder = JSONEncoder.wearwell
        encoder.outputFormatting = [.sortedKeys]
        return MacBackupPlan(manifest: manifest, manifestData: try encoder.encode(manifest))
    }

    static func data(for asset: WearwellBackupManifest.AssetRecord, context: ModelContext) async throws -> Data {
        if let value = try? await AssetStore.shared.data(named: asset.name),
           value.count == asset.byteCount, sha256(value) == asset.sha256 { return value }
        let name = asset.name
        let descriptor = FetchDescriptor<AssetBlob>(predicate: #Predicate { $0.name == name }, sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        guard let value = try context.fetch(descriptor).first?.data,
              value.count == asset.byteCount, sha256(value) == asset.sha256
        else { throw BackupError.missingAsset(asset.name) }
        return value
    }

    static func restore(_ document: WearwellBackupDocument, context: ModelContext) async throws -> BackupRestoreResult {
        let manifest = document.archive.manifest
        guard manifest.version == WearwellBackupManifest.currentVersion else { throw BackupError.unsupportedVersion(manifest.version) }
        // Decode every transformable value before changing the context.
        guard manifest.garments.allSatisfy({ (try? JSONDecoder().decode([String].self, from: $0.unknownsJSON)) != nil }),
              manifest.outfits.allSatisfy({ (try? JSONDecoder().decode([LayoutItem].self, from: $0.layoutJSON)) != nil }),
              manifest.styleProfiles.allSatisfy({ (try? JSONDecoder().decode(StyleProfileDTO.self, from: $0.profileJSON)) != nil }),
              (manifest.shoppingProfiles ?? []).allSatisfy({ (try? JSONDecoder().decode(ShoppingProfileDTO.self, from: $0.profileJSON)) != nil })
        else { throw BackupError.invalidPackage("The backup contains invalid wardrobe records.") }

        var applied = 0
        for record in manifest.garments {
            let item = try fetch(id: record.id, from: context) ?? Garment(id: record.id, label: record.label, category: GarmentCategory(rawValue: record.categoryRaw) ?? .tops, color: record.color)
            if item.modelContext == nil { context.insert(item) }
            item.label = record.label; item.categoryRaw = record.categoryRaw; item.subcategoryRaw = record.subcategoryRaw; item.color = record.color
            item.details = record.details; item.observed = record.observed; item.unknownsJSON = record.unknownsJSON; item.confidence = record.confidence
            item.fingerprint = record.fingerprint; item.sourceAssetName = record.sourceAssetName; item.catalogAssetName = record.catalogAssetName
            item.sourceURL = record.sourceURL; item.tags = record.tags; item.season = record.season; item.occasion = record.occasion
            item.isFavorite = record.isFavorite; item.createdAt = record.createdAt; item.modelVersion = record.modelVersion; item.promptVersion = record.promptVersion
            applied += 1
        }
        for record in manifest.wishlistItems {
            let item = try fetch(id: record.id, from: context) ?? WishlistItem(id: record.id, label: record.label, category: GarmentCategory(rawValue: record.categoryRaw) ?? .tops, color: record.color)
            if item.modelContext == nil { context.insert(item) }
            item.label = record.label; item.categoryRaw = record.categoryRaw; item.subcategoryRaw = record.subcategoryRaw; item.color = record.color
            item.details = record.details; item.sourceAssetName = record.sourceAssetName; item.catalogAssetName = record.catalogAssetName
            item.sourceURL = record.sourceURL; item.fingerprint = record.fingerprint; item.verdictRaw = record.verdictRaw
            item.verdictSummary = record.verdictSummary; item.createdAt = record.createdAt; item.purchasedAt = record.purchasedAt
            applied += 1
        }
        for record in manifest.outfits {
            let item = try fetch(id: record.id, from: context) ?? Outfit(id: record.id, title: record.title, origin: OutfitOrigin(rawValue: record.originRaw) ?? .manual, layout: [])
            if item.modelContext == nil { context.insert(item) }
            item.title = record.title; item.notes = record.notes; item.rationale = record.rationale; item.originRaw = record.originRaw
            item.layoutJSON = record.layoutJSON; item.boardAssetName = record.boardAssetName; item.wishlistItemID = record.wishlistItemID
            item.createdAt = record.createdAt; item.updatedAt = record.updatedAt; applied += 1
        }
        for record in manifest.visualizations {
            let item = try fetch(id: record.id, from: context) ?? Visualization(id: record.id, outfitID: record.outfitID, mode: VisualizationMode(rawValue: record.modeRaw) ?? .collage, assetName: record.assetName)
            if item.modelContext == nil { context.insert(item) }
            item.outfitID = record.outfitID; item.modeRaw = record.modeRaw; item.assetName = record.assetName
            item.createdAt = record.createdAt; item.modelVersion = record.modelVersion; applied += 1
        }
        for record in manifest.referencePhotos {
            let item = try fetch(id: record.id, from: context) ?? ReferencePhoto(id: record.id, label: record.label, assetName: record.assetName)
            if item.modelContext == nil { context.insert(item) }
            item.label = record.label; item.assetName = record.assetName; item.isDefault = record.isDefault; item.createdAt = record.createdAt; applied += 1
        }
        for record in manifest.inspirationLooks {
            let item = try fetch(id: record.id, from: context) ?? InspirationLook(assetName: record.assetName, sourceURL: record.sourceURL, state: record.state)
            if item.modelContext == nil { item.id = record.id; context.insert(item) }
            item.assetName = record.assetName; item.sourceURL = record.sourceURL; item.state = record.state; item.analysisJSON = record.analysisJSON
            item.errorMessage = record.errorMessage; item.isFavorite = record.isFavorite; item.createdAt = record.createdAt; item.updatedAt = record.updatedAt; applied += 1
        }
        for record in manifest.styleProfiles {
            let profile = try JSONDecoder().decode(StyleProfileDTO.self, from: record.profileJSON)
            let item = try fetch(id: record.id, from: context) ?? StyleProfile(signature: record.signature, revision: record.revision, profile: profile)
            if item.modelContext == nil { item.id = record.id; context.insert(item) }
            item.signature = record.signature; item.revision = record.revision; item.profileJSON = record.profileJSON; item.updatedAt = record.updatedAt; applied += 1
        }
        for record in manifest.shoppingProfiles ?? [] {
            let preferences = try JSONDecoder().decode(ShoppingProfileDTO.self, from: record.profileJSON)
            let item = try fetch(id: record.id, from: context) ?? ShoppingProfile(id: record.id, preferences: preferences, updatedAt: record.updatedAt)
            if item.modelContext == nil { context.insert(item) }
            item.profileJSON = record.profileJSON; item.updatedAt = record.updatedAt; applied += 1
        }
        for record in manifest.purchaseNeeds ?? [] {
            let item = try fetch(id: record.id, from: context) ?? PurchaseNeed(id: record.id, title: record.title)
            if item.modelContext == nil { context.insert(item) }
            item.title = record.title; item.categoryRaw = record.categoryRaw; item.subcategoryRaw = record.subcategoryRaw
            item.rationale = record.rationale; item.searchQuery = record.searchQuery; item.isLunaSuggested = record.isLunaSuggested
            item.isCompleted = record.isCompleted; item.createdAt = record.createdAt; item.updatedAt = record.updatedAt; applied += 1
        }

        let existingBlobs = try context.fetch(FetchDescriptor<AssetBlob>())
        let grouped = Dictionary(grouping: existingBlobs, by: \.name)
        var assetApplied = 0, assetUnchanged = 0
        for (name, data) in document.archive.assets {
            if let first = grouped[name]?.first {
                if first.data == data { assetUnchanged += 1 }
                else { first.data = data; first.updatedAt = .now; assetApplied += 1 }
                for duplicate in grouped[name]?.dropFirst() ?? [] { context.delete(duplicate) }
            } else {
                context.insert(AssetBlob(name: name, data: data)); assetApplied += 1
            }
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
        for (name, data) in document.archive.assets { await AssetStore.shared.cache(name: name, data: data) }
        return BackupRestoreResult(recordsApplied: applied, assetsApplied: assetApplied, assetsUnchanged: assetUnchanged)
    }

    nonisolated static func isSafeAssetName(_ name: String) -> Bool {
        !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent && !name.contains("/") && !name.contains("\\")
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func fetch<T: PersistentModel>(id: UUID, from context: ModelContext) throws -> T? where T: AnyObject {
        // All durable Wearwell models expose a UUID named `id`; typed overloads below
        // keep SwiftData predicates concrete and CloudKit-compatible.
        if T.self == Garment.self { return try fetchGarment(id, context) as? T }
        if T.self == WishlistItem.self { return try fetchWishlist(id, context) as? T }
        if T.self == Outfit.self { return try fetchOutfit(id, context) as? T }
        if T.self == Visualization.self { return try fetchVisualization(id, context) as? T }
        if T.self == ReferencePhoto.self { return try fetchReference(id, context) as? T }
        if T.self == InspirationLook.self { return try fetchInspiration(id, context) as? T }
        if T.self == StyleProfile.self { return try fetchProfile(id, context) as? T }
        if T.self == ShoppingProfile.self { return try fetchShoppingProfile(id, context) as? T }
        if T.self == PurchaseNeed.self { return try fetchPurchaseNeed(id, context) as? T }
        return nil
    }

    private static func fetchGarment(_ id: UUID, _ context: ModelContext) throws -> Garment? { var d = FetchDescriptor<Garment>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchWishlist(_ id: UUID, _ context: ModelContext) throws -> WishlistItem? { var d = FetchDescriptor<WishlistItem>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchOutfit(_ id: UUID, _ context: ModelContext) throws -> Outfit? { var d = FetchDescriptor<Outfit>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchVisualization(_ id: UUID, _ context: ModelContext) throws -> Visualization? { var d = FetchDescriptor<Visualization>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchReference(_ id: UUID, _ context: ModelContext) throws -> ReferencePhoto? { var d = FetchDescriptor<ReferencePhoto>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchInspiration(_ id: UUID, _ context: ModelContext) throws -> InspirationLook? { var d = FetchDescriptor<InspirationLook>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchProfile(_ id: UUID, _ context: ModelContext) throws -> StyleProfile? { var d = FetchDescriptor<StyleProfile>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchShoppingProfile(_ id: UUID, _ context: ModelContext) throws -> ShoppingProfile? { var d = FetchDescriptor<ShoppingProfile>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
    private static func fetchPurchaseNeed(_ id: UUID, _ context: ModelContext) throws -> PurchaseNeed? { var d = FetchDescriptor<PurchaseNeed>(predicate: #Predicate { $0.id == id }); d.fetchLimit = 1; return try context.fetch(d).first }
}

private extension JSONEncoder {
    static var wearwell: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        return value
    }
}

private extension JSONDecoder {
    static var wearwell: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
