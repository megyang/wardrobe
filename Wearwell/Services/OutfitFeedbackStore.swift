import Foundation

enum OutfitFeedbackRating: String, Codable {
    case loved
    case disliked
}

struct OutfitFeedbackDTO: Codable, Identifiable {
    let id: UUID
    let combinationKey: String
    let rating: OutfitFeedbackRating
    let reason: String?
    let title: String
    let rationale: String
    let garmentIDs: [UUID]
    let updatedAt: Date
}

struct OutfitEditFeedbackDTO: Codable, Identifiable {
    let id: UUID
    let title: String
    let originalGarmentIDs: [UUID]
    let finalGarmentIDs: [UUID]
    let originalLayout: [LayoutItem]
    let finalLayout: [LayoutItem]
    let addedGarmentIDs: [UUID]
    let removedGarmentIDs: [UUID]
    let updatedAt: Date
}

@MainActor
enum OutfitFeedbackStore {
    private static let defaultsKey = "wearwell.outfitFeedback.v1"
    private static let editsDefaultsKey = "wearwell.outfitEdits.v1"

    static let dislikeReasons = [
        "Wrong bottom",
        "Bad layering",
        "Too busy",
        "Colors clash",
        "Wrong proportions",
        "Doesn't match my style"
    ]

    static func combinationKey(for garmentIDs: [UUID]) -> String {
        garmentIDs.map { $0.uuidString.lowercased() }.sorted().joined(separator: "|")
    }

    static func all() -> [OutfitFeedbackDTO] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return ((try? JSONDecoder().decode([OutfitFeedbackDTO].self, from: data)) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func feedback(for suggestion: OutfitSuggestionDTO) -> OutfitFeedbackDTO? {
        let key = combinationKey(for: suggestion.garmentIDs)
        return all().first { $0.combinationKey == key }
    }

    @discardableResult
    static func set(_ rating: OutfitFeedbackRating, reason: String? = nil, for suggestion: OutfitSuggestionDTO) -> OutfitFeedbackDTO {
        let key = combinationKey(for: suggestion.garmentIDs)
        var values = all().filter { $0.combinationKey != key }
        let value = OutfitFeedbackDTO(
            id: UUID(), combinationKey: key, rating: rating, reason: reason,
            title: suggestion.title, rationale: suggestion.rationale,
            garmentIDs: suggestion.garmentIDs, updatedAt: .now
        )
        values.insert(value, at: 0)
        save(Array(values.prefix(200)))
        return value
    }

    static func clear(for suggestion: OutfitSuggestionDTO) {
        let key = combinationKey(for: suggestion.garmentIDs)
        save(all().filter { $0.combinationKey != key })
    }

    static func allEdits() -> [OutfitEditFeedbackDTO] {
        guard let data = UserDefaults.standard.data(forKey: editsDefaultsKey) else { return [] }
        return ((try? JSONDecoder().decode([OutfitEditFeedbackDTO].self, from: data)) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func recordEdit(title: String, originalLayout: [LayoutItem], finalLayout: [LayoutItem]) {
        let encoder = JSONEncoder()
        guard (try? encoder.encode(originalLayout)) != (try? encoder.encode(finalLayout)) else { return }
        let originalIDs = uniqueGarmentIDs(in: originalLayout)
        let finalIDs = uniqueGarmentIDs(in: finalLayout)
        let originalSet = Set(originalIDs); let finalSet = Set(finalIDs)
        let edit = OutfitEditFeedbackDTO(
            id: UUID(), title: title,
            originalGarmentIDs: originalIDs, finalGarmentIDs: finalIDs,
            originalLayout: originalLayout, finalLayout: finalLayout,
            addedGarmentIDs: finalIDs.filter { !originalSet.contains($0) },
            removedGarmentIDs: originalIDs.filter { !finalSet.contains($0) },
            updatedAt: .now
        )
        var values = allEdits()
        values.insert(edit, at: 0)
        guard let data = try? encoder.encode(Array(values.prefix(100))) else { return }
        UserDefaults.standard.set(data, forKey: editsDefaultsKey)
    }

    private static func save(_ values: [OutfitFeedbackDTO]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private static func uniqueGarmentIDs(in layout: [LayoutItem]) -> [UUID] {
        var seen = Set<UUID>()
        return layout.compactMap(\.garmentID).filter { seen.insert($0).inserted }
    }
}
