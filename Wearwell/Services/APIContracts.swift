import Foundation

struct AnalyzeResponse: Codable {
    let items: [GarmentAnalysisDTO]
}

struct AnalysisJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let progressCompleted: Int?
    let progressTotal: Int?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let processingStartedAt: String?
    let result: AnalyzeResponse?
    let error: String?
}

struct StyleJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let result: StyleResponse?
    let error: String?
}

struct AssessmentJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let result: PurchaseAssessmentDTO?
    let error: String?
}

struct CatalogEditJobDTO: Codable {
    let id: String
    let kind: String
    let state: String
    let createdAt: String
    let updatedAt: String
    let stage: String?
    let queuePosition: Int?
    let estimatedSecondsRemaining: Int?
    let result: RenderResponse?
    let error: String?
}

struct SavedOutfitExampleDTO: Codable {
    let id: UUID
    let title: String
    let rationale: String
    let origin: String
    let garmentIDs: [UUID]
    let layout: [LayoutItem]
    let updatedAt: Date

    init?(_ outfit: Outfit) {
        guard outfit.belongsInOutfitLibrary else { return nil }
        var seen = Set<UUID>()
        let ids = outfit.layout.compactMap(\.garmentID).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return nil }
        id = outfit.id
        title = outfit.title
        rationale = outfit.rationale
        origin = outfit.originRaw
        garmentIDs = ids
        layout = outfit.layout
        updatedAt = outfit.updatedAt
    }
}

struct ItemRecommendationDTO: Codable, Equatable {
    let garmentID: UUID
    let rationale: String
}

struct StyleResponse: Codable {
    let outfits: [OutfitSuggestionDTO]
}

struct RenderResponse: Codable {
    let imageBase64: String
}
