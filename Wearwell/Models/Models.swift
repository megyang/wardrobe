import Foundation
import SwiftData

enum GarmentCategory: String, Codable, CaseIterable, Identifiable {
    case tops, bottoms, outerwear, dresses, shoes, accessories
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum GarmentSubcategory: String, Codable, CaseIterable, Identifiable {
    case longSleeve = "long_sleeve"
    case tankTop = "tank_top"
    case tShirt = "t_shirt"
    case sleeveless
    case blouse
    case shorts
    case skirt
    case miniSkirt = "mini_skirt"
    case midiSkirt = "midi_skirt"
    case maxiSkirt = "maxi_skirt"
    case pants
    case coverup
    case sweater
    case jacket
    case coat
    case tights
    case hat
    case misc

    var id: String { rawValue }
    var category: GarmentCategory {
        switch self {
        case .longSleeve, .tankTop, .tShirt, .sleeveless, .blouse: .tops
        case .shorts, .skirt, .miniSkirt, .midiSkirt, .maxiSkirt, .pants: .bottoms
        case .coverup, .sweater, .jacket, .coat: .outerwear
        case .tights, .hat, .misc: .accessories
        }
    }
    var title: String {
        switch self {
        case .longSleeve: "Long sleeve"
        case .tankTop: "Tank top"
        case .tShirt: "T-shirt"
        case .sleeveless: "Sleeveless"
        case .blouse: "Blouse"
        case .shorts: "Shorts"
        case .skirt: "Skirt"
        case .miniSkirt: "Mini skirt"
        case .midiSkirt: "Midi skirt"
        case .maxiSkirt: "Maxi skirt"
        case .pants: "Pants"
        case .coverup: "Cover-up"
        case .sweater: "Sweater"
        case .jacket: "Jacket"
        case .coat: "Coat"
        case .tights: "Tights"
        case .hat: "Hat"
        case .misc: "Misc"
        }
    }
    var filterTitle: String {
        switch self {
        case .longSleeve: "Long sleeves"
        case .tankTop: "Tank tops"
        case .tShirt: "T-shirts"
        case .blouse: "Blouses"
        case .skirt: "Skirt"
        case .miniSkirt: "Mini skirts"
        case .midiSkirt: "Midi skirts"
        case .maxiSkirt: "Maxi skirts"
        case .coverup: "Cover-ups"
        case .sweater: "Sweaters"
        case .jacket: "Jackets"
        case .coat: "Coats"
        case .hat: "Hats"
        default: title
        }
    }
    static func options(for category: GarmentCategory) -> [GarmentSubcategory] {
        allCases.filter { $0.category == category && $0 != .skirt }
    }
}

enum OutfitOrigin: String, Codable, CaseIterable {
    case manual, aiStyle, purchaseTest
}

enum VisualizationMode: String, Codable, CaseIterable, Identifiable {
    case collage, mannequin, onMe
    var id: String { rawValue }
    var title: String { self == .onMe ? "On me" : rawValue.capitalized }
}

enum PurchaseVerdict: String, Codable, CaseIterable {
    case buy, maybe, skip
}

struct LayoutItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var garmentID: UUID?
    var wishlistItemID: UUID?
    var x: Double = 0.5
    var y: Double = 0.5
    var scale: Double = 1
    var rotation: Double = 0
    var zIndex: Double = 0

    init(garmentID: UUID? = nil, wishlistItemID: UUID? = nil, x: Double = 0.5, y: Double = 0.5, scale: Double = 1, rotation: Double = 0, zIndex: Double = 0) {
        self.garmentID = garmentID
        self.wishlistItemID = wishlistItemID
        self.x = x; self.y = y; self.scale = scale; self.rotation = rotation; self.zIndex = zIndex
    }
}

enum OutfitLayout {
    private static let horizontalSpan = 0.82
    private static let verticalSpan = 0.82
    private static let referenceCanvas = CGSize(width: 320, height: 400)
    private static let pieceSize = CGSize(width: 150, height: 180)

    static func arranged(garmentIDs: [UUID]) -> [LayoutItem] {
        arranged(garmentIDs.map { LayoutItem(garmentID: $0) })
    }

    static func arranged(_ source: [LayoutItem]) -> [LayoutItem] {
        guard !source.isEmpty else { return [] }

        let columns = min(3, max(1, Int(ceil(sqrt(Double(source.count))))))
        let rows = Int(ceil(Double(source.count) / Double(columns)))
        let horizontalStep = horizontalSpan / Double(columns)
        let verticalStep = verticalSpan / Double(rows)
        let scale = min(
            0.82,
            horizontalStep * Double(referenceCanvas.width / pieceSize.width) * 0.9,
            verticalStep * Double(referenceCanvas.height / pieceSize.height) * 0.9
        )

        return source.enumerated().map { index, value in
            let row = index / columns
            let column = index % columns
            let itemsInRow = min(columns, source.count - row * columns)
            var item = value
            item.x = 0.5 + (Double(column) - Double(itemsInRow - 1) / 2) * horizontalStep
            item.y = 0.5 + (Double(row) - Double(rows - 1) / 2) * verticalStep
            item.scale = scale
            item.rotation = 0
            item.zIndex = Double(index)
            return item
        }
    }
}

@Model final class Garment {
    var id: UUID
    var label: String
    var categoryRaw: String
    var subcategoryRaw: String?
    var color: String
    var details: String
    var observed: String
    var unknownsJSON: Data
    var confidence: Double
    var fingerprint: String
    var sourceAssetName: String
    var catalogAssetName: String
    var sourceURL: String?
    var tags: String
    var season: String
    var occasion: String
    var isFavorite: Bool
    var createdAt: Date
    var modelVersion: String
    var promptVersion: String
    var imageRegenerationJobID: String?
    var imageRegenerationState: String?
    var imageRegenerationStage: String?
    var imageRegenerationError: String?
    var pendingRegenerationSourceAssetName: String?
    var pendingRegenerationCatalogAssetName: String?
    var pendingRegenerationAnalysisJSON: Data?

    var category: GarmentCategory {
        get { GarmentCategory(rawValue: categoryRaw) ?? .tops }
        set {
            categoryRaw = newValue.rawValue
            if subcategory?.category != newValue { subcategoryRaw = nil }
        }
    }
    var subcategory: GarmentSubcategory? {
        get { subcategoryRaw.flatMap(GarmentSubcategory.init(rawValue:)) }
        set { subcategoryRaw = newValue?.category == category ? newValue?.rawValue : nil }
    }
    var unknowns: [String] { (try? JSONDecoder().decode([String].self, from: unknownsJSON)) ?? [] }

    init(id: UUID = UUID(), label: String, category: GarmentCategory, subcategory: GarmentSubcategory? = nil, color: String, details: String = "", observed: String = "", unknowns: [String] = [], confidence: Double = 1, fingerprint: String = "", sourceAssetName: String = "", catalogAssetName: String = "", sourceURL: String? = nil, tags: String = "", season: String = "", occasion: String = "", isFavorite: Bool = false, createdAt: Date = .now, modelVersion: String = "user", promptVersion: String = "1") {
        self.id = id; self.label = label; self.categoryRaw = category.rawValue
        self.subcategoryRaw = subcategory?.category == category ? subcategory?.rawValue : nil; self.color = color
        self.details = details; self.observed = observed
        self.unknownsJSON = (try? JSONEncoder().encode(unknowns)) ?? Data()
        self.confidence = confidence; self.fingerprint = fingerprint
        self.sourceAssetName = sourceAssetName; self.catalogAssetName = catalogAssetName
        self.sourceURL = sourceURL; self.tags = tags; self.season = season; self.occasion = occasion
        self.isFavorite = isFavorite; self.createdAt = createdAt
        self.modelVersion = modelVersion; self.promptVersion = promptVersion
    }
}

@Model final class WishlistItem {
    var id: UUID
    var label: String
    var categoryRaw: String
    var subcategoryRaw: String?
    var color: String
    var details: String
    var sourceAssetName: String
    var catalogAssetName: String
    var sourceURL: String?
    var fingerprint: String
    var verdictRaw: String?
    var verdictSummary: String
    var createdAt: Date
    var purchasedAt: Date?
    var assessmentJobID: String?
    var assessmentState: String?
    var assessmentStage: String?
    var assessmentEstimatedSecondsRemaining: Int?
    var assessmentError: String?
    var isUnreadAssessment: Bool = false

    var category: GarmentCategory {
        get { GarmentCategory(rawValue: categoryRaw) ?? .tops }
        set {
            categoryRaw = newValue.rawValue
            if subcategory?.category != newValue { subcategoryRaw = nil }
        }
    }
    var subcategory: GarmentSubcategory? {
        get { subcategoryRaw.flatMap(GarmentSubcategory.init(rawValue:)) }
        set { subcategoryRaw = newValue?.category == category ? newValue?.rawValue : nil }
    }
    var verdict: PurchaseVerdict? {
        get { verdictRaw.flatMap(PurchaseVerdict.init(rawValue:)) }
        set { verdictRaw = newValue?.rawValue }
    }

    init(id: UUID = UUID(), label: String, category: GarmentCategory, subcategory: GarmentSubcategory? = nil, color: String, details: String = "", sourceAssetName: String = "", catalogAssetName: String = "", sourceURL: String? = nil, fingerprint: String = "") {
        self.id = id; self.label = label; self.categoryRaw = category.rawValue
        self.subcategoryRaw = subcategory?.category == category ? subcategory?.rawValue : nil; self.color = color
        self.details = details; self.sourceAssetName = sourceAssetName; self.catalogAssetName = catalogAssetName
        self.sourceURL = sourceURL; self.fingerprint = fingerprint; self.verdictSummary = ""; self.createdAt = .now
    }
}

@Model final class StyleGeneration {
    var id: UUID
    var remoteJobID: String?
    var state: String
    var stage: String?
    var estimatedSecondsRemaining: Int?
    var requestSummary: String
    var resultJSON: Data
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    var isUnread: Bool = false

    var suggestions: [OutfitSuggestionDTO] {
        get { (try? JSONDecoder().decode([OutfitSuggestionDTO].self, from: resultJSON)) ?? [] }
        set { resultJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(requestSummary: String, state: String = "submitting") {
        id = UUID()
        self.state = state
        self.requestSummary = requestSummary
        resultJSON = Data()
        createdAt = .now
        updatedAt = .now
    }
}

@Model final class Outfit {
    var id: UUID
    var title: String
    var notes: String
    var rationale: String
    var originRaw: String
    var layoutJSON: Data
    var boardAssetName: String?
    var wishlistItemID: UUID?
    var createdAt: Date
    var updatedAt: Date

    var origin: OutfitOrigin {
        get { OutfitOrigin(rawValue: originRaw) ?? .manual }
        set { originRaw = newValue.rawValue }
    }
    var layout: [LayoutItem] {
        get { (try? JSONDecoder().decode([LayoutItem].self, from: layoutJSON)) ?? [] }
        set { layoutJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Purchase-test combinations are scoped to their candidate in Buy? and are
    /// not part of the user's normal saved-outfit library.
    var belongsInOutfitLibrary: Bool {
        origin != .purchaseTest && wishlistItemID == nil
    }

    func contains(garmentID: UUID) -> Bool {
        layout.contains { $0.garmentID == garmentID }
    }

    func applyEdits(title: String, layout: [LayoutItem], at date: Date = .now) {
        self.title = title
        self.layout = layout
        updatedAt = date
    }

    init(id: UUID = UUID(), title: String, notes: String = "", rationale: String = "", origin: OutfitOrigin, layout: [LayoutItem], wishlistItemID: UUID? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.rationale = rationale
        self.originRaw = origin.rawValue; self.layoutJSON = (try? JSONEncoder().encode(layout)) ?? Data()
        self.wishlistItemID = wishlistItemID; self.createdAt = .now; self.updatedAt = .now
    }
}

@Model final class Visualization {
    var id: UUID
    var outfitID: UUID
    var modeRaw: String
    var assetName: String
    var createdAt: Date
    var modelVersion: String
    init(id: UUID = UUID(), outfitID: UUID, mode: VisualizationMode, assetName: String, createdAt: Date = .now, modelVersion: String = "gpt-5.6-luna") {
        self.id = id; self.outfitID = outfitID; modeRaw = mode.rawValue; self.assetName = assetName; self.createdAt = createdAt; self.modelVersion = modelVersion
    }
}

@Model final class ReferencePhoto {
    var id: UUID
    var label: String
    var assetName: String
    var isDefault: Bool
    var createdAt: Date
    init(id: UUID = UUID(), label: String, assetName: String, isDefault: Bool = true, createdAt: Date = .now) {
        self.id = id; self.label = label; self.assetName = assetName; self.isDefault = isDefault; self.createdAt = createdAt
    }
}

struct StyleVectorDTO: Codable, Equatable {
    let minimal, maximal, relaxed, tailored: Double
    let romantic, edgy, sporty, vintage: Double
    let classic, experimental, layered, colorful: Double

    static let zero = StyleVectorDTO(
        minimal: 0, maximal: 0, relaxed: 0, tailored: 0,
        romantic: 0, edgy: 0, sporty: 0, vintage: 0,
        classic: 0, experimental: 0, layered: 0, colorful: 0
    )

    var values: [Double] {
        [minimal, maximal, relaxed, tailored, romantic, edgy, sporty, vintage, classic, experimental, layered, colorful]
    }

    init(values: [Double]) {
        let padded = values + Array(repeating: 0, count: max(0, 12 - values.count))
        minimal = padded[0]; maximal = padded[1]; relaxed = padded[2]; tailored = padded[3]
        romantic = padded[4]; edgy = padded[5]; sporty = padded[6]; vintage = padded[7]
        classic = padded[8]; experimental = padded[9]; layered = padded[10]; colorful = padded[11]
    }

    init(minimal: Double, maximal: Double, relaxed: Double, tailored: Double, romantic: Double, edgy: Double, sporty: Double, vintage: Double, classic: Double, experimental: Double, layered: Double, colorful: Double) {
        self.minimal = minimal; self.maximal = maximal; self.relaxed = relaxed; self.tailored = tailored
        self.romantic = romantic; self.edgy = edgy; self.sporty = sporty; self.vintage = vintage
        self.classic = classic; self.experimental = experimental; self.layered = layered; self.colorful = colorful
    }
}

struct InspirationAnalysisDTO: Codable, Equatable {
    let summary: String
    let aesthetics, palette, silhouettes, layering, details, occasions: [String]
    var outfitFormula: [String]? = nil
    var proportions: [String]? = nil
    var focalPoints: [String]? = nil
    var stylingRules: [String]? = nil
    let vector: StyleVectorDTO
    let analysisVersion, modelVersion: String
}

struct StyleProfileDTO: Codable, Equatable {
    let revision: Int
    let lookCount: Int
    let summary: String
    let aesthetics, palette, silhouettes, layering, details, occasions: [String]
    var outfitFormula: [String]? = nil
    var proportions: [String]? = nil
    var focalPoints: [String]? = nil
    var stylingRules: [String]? = nil
    let vector: StyleVectorDTO
}

@Model final class InspirationLook {
    var id: UUID
    var assetName: String
    var sourceURL: String?
    var state: String
    var analysisJSON: Data?
    var errorMessage: String?
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date

    var analysis: InspirationAnalysisDTO? {
        get { analysisJSON.flatMap { try? JSONDecoder().decode(InspirationAnalysisDTO.self, from: $0) } }
        set { analysisJSON = try? JSONEncoder().encode(newValue); updatedAt = .now }
    }

    init(assetName: String, sourceURL: String? = nil, state: String = "analyzing") {
        id = UUID(); self.assetName = assetName; self.sourceURL = sourceURL; self.state = state
        isFavorite = false; createdAt = .now; updatedAt = .now
    }
}

/// SwiftData-backed source of truth for every image. `WearwellAssets` remains a
/// rebuildable local cache so existing synchronous image rendering stays fast.
@Model final class AssetBlob {
    var id: UUID
    var name: String
    @Attribute(.externalStorage) var data: Data
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, data: Data, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.data = data
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class StyleProfile {
    var id: UUID
    var signature: String
    var revision: Int
    var profileJSON: Data
    var updatedAt: Date

    var profile: StyleProfileDTO? {
        get { try? JSONDecoder().decode(StyleProfileDTO.self, from: profileJSON) }
        set { profileJSON = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }

    init(signature: String, revision: Int, profile: StyleProfileDTO) {
        id = UUID(); self.signature = signature; self.revision = revision
        profileJSON = (try? JSONEncoder().encode(profile)) ?? Data(); updatedAt = .now
    }
}

@Model final class ImportDraft {
    var id: UUID
    var sourceAssetName: String
    var sourceURL: String?
    var additionalSourceAssetNamesJSON: Data = Data()
    var combinesSourcePhotos: Bool = false
    var createdAt: Date
    var state: String
    var remoteJobID: String?
    var resultJSON: Data?
    var errorMessage: String?
    var updatedAt: Date?
    var progressStage: String?
    var progressCompleted: Int?
    var progressTotal: Int?
    var queuePosition: Int?
    var estimatedSecondsRemaining: Int?
    var isUnread: Bool = false

    var analyses: [GarmentAnalysisDTO] {
        get { resultJSON.flatMap { try? JSONDecoder().decode([GarmentAnalysisDTO].self, from: $0) } ?? [] }
        set { resultJSON = try? JSONEncoder().encode(newValue); updatedAt = .now }
    }

    var sourceAssetNames: [String] {
        get {
            let additional = (try? JSONDecoder().decode([String].self, from: additionalSourceAssetNamesJSON)) ?? []
            return [sourceAssetName] + additional
        }
        set {
            guard let first = newValue.first else { return }
            sourceAssetName = first
            additionalSourceAssetNamesJSON = (try? JSONEncoder().encode(Array(newValue.dropFirst()))) ?? Data()
        }
    }

    init(sourceAssetName: String, additionalSourceAssetNames: [String] = [], combinesSourcePhotos: Bool = false, sourceURL: String? = nil, state: String = "pending", remoteJobID: String? = nil) {
        id = UUID(); self.sourceAssetName = sourceAssetName; self.sourceURL = sourceURL; createdAt = .now; self.state = state
        additionalSourceAssetNamesJSON = (try? JSONEncoder().encode(additionalSourceAssetNames)) ?? Data()
        self.combinesSourcePhotos = combinesSourcePhotos
        self.remoteJobID = remoteJobID; updatedAt = .now
    }
}

struct GarmentAnalysisDTO: Codable, Identifiable {
    var id: UUID = UUID()
    let label: String
    let category: String
    var subcategory: String? = nil
    let color: String
    let confidence: Double
    let description: String
    let observed: String
    let unknowns: [String]
    let fingerprint: String
    let catalogImageBase64: String?
    let modelVersion: String
}

struct OutfitSuggestionDTO: Codable, Identifiable {
    var id: UUID = UUID()
    let title: String
    let rationale: String
    let garmentIDs: [UUID]
    var layering: [LayeringStepDTO]? = nil
}

struct LayeringStepDTO: Codable, Equatable {
    enum Placement: String, Codable { case under, main, over }
    let garmentID: String
    let placement: Placement
}

struct PurchaseAssessmentDTO: Codable {
    let verdict: PurchaseVerdict
    let summary: String
    let outfits: [OutfitSuggestionDTO]
}
