import Foundation
import SwiftData

enum StylePreferenceCache {
    static func refresh(looks: [InspirationLook], context: ModelContext) throws -> StyleProfile? {
        let profiles = try context.fetch(FetchDescriptor<StyleProfile>())
        let ready = looks.filter { $0.state == "ready" && $0.analysis != nil }
        let signature = ready
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString):\($0.updatedAt.timeIntervalSince1970):\($0.isFavorite)" }
            .joined(separator: "|")
        if let existing = profiles.first, existing.signature == signature { return existing }

        guard !ready.isEmpty else {
            for profile in profiles { context.delete(profile) }
            try context.save()
            return nil
        }

        let analyses = ready.compactMap(\.analysis)
        let weights = ready.map { $0.isFavorite ? 2.0 : 1.0 }
        let averaged = aggregateVector(analyses: analyses, weights: weights).values
        func top(_ values: (InspirationAnalysisDTO) -> [String], limit: Int = 6) -> [String] {
            var counts: [String: Double] = [:]
            for (index, analysis) in analyses.enumerated() {
                for value in values(analysis) {
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !normalized.isEmpty { counts[normalized, default: 0] += weights[index] }
                }
            }
            return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
        }

        let aesthetics = top { $0.aesthetics }
        let palette = top { $0.palette }
        let silhouettes = top { $0.silhouettes }
        let layering = top { $0.layering }
        let details = top { $0.details }
        let occasions = top { $0.occasions }
        let outfitFormula = top({ $0.outfitFormula ?? [] }, limit: 8)
        let proportions = top { $0.proportions ?? [] }
        let focalPoints = top({ $0.focalPoints ?? [] }, limit: 4)
        let stylingRules = top { $0.stylingRules ?? [] }
        let nextRevision = (profiles.map(\.revision).max() ?? 0) + 1
        let summaryParts = [
            aesthetics.isEmpty ? nil : "Aesthetic: \(aesthetics.prefix(3).joined(separator: ", "))",
            silhouettes.isEmpty ? nil : "Silhouettes: \(silhouettes.prefix(3).joined(separator: ", "))",
            palette.isEmpty ? nil : "Palette: \(palette.prefix(3).joined(separator: ", "))",
            layering.isEmpty ? nil : "Layering: \(layering.prefix(2).joined(separator: ", "))",
            outfitFormula.isEmpty ? nil : "Formula: \(outfitFormula.prefix(2).joined(separator: ", "))"
        ].compactMap { $0 }.joined(separator: ". ")
        let dto = StyleProfileDTO(
            revision: nextRevision, lookCount: analyses.count, summary: summaryParts,
            aesthetics: aesthetics, palette: palette, silhouettes: silhouettes,
            layering: layering, details: details, occasions: occasions,
            outfitFormula: outfitFormula, proportions: proportions, focalPoints: focalPoints,
            stylingRules: stylingRules,
            vector: StyleVectorDTO(values: averaged)
        )

        let result: StyleProfile
        if let existing = profiles.first {
            existing.signature = signature; existing.revision = nextRevision; existing.profile = dto; result = existing
            for duplicate in profiles.dropFirst() { context.delete(duplicate) }
        } else {
            result = StyleProfile(signature: signature, revision: nextRevision, profile: dto); context.insert(result)
        }
        try context.save()
        return result
    }

    static func aggregateVector(analyses: [InspirationAnalysisDTO], weights: [Double]) -> StyleVectorDTO {
        guard analyses.count == weights.count, !analyses.isEmpty else { return .zero }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return .zero }
        return StyleVectorDTO(values: (0..<12).map { index in
            zip(analyses, weights).reduce(0) { $0 + $1.0.vector.values[index] * $1.1 } / totalWeight
        })
    }

    static func relevantLooks(_ looks: [InspirationLook], query: String, limit: Int = 6) -> [InspirationLook] {
        let queryTokens = tokens(query)
        return looks.filter { $0.state == "ready" && $0.analysis != nil }.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            let left = relevance(lhs, queryTokens: queryTokens)
            let right = relevance(rhs, queryTokens: queryTokens)
            return left == right ? lhs.updatedAt > rhs.updatedAt : left > right
        }.prefix(limit).map { $0 }
    }

    private static func relevance(_ look: InspirationLook, queryTokens: Set<String>) -> Int {
        guard let analysis = look.analysis else { return 0 }
        var traits = analysis.aesthetics
        traits.append(contentsOf: analysis.palette)
        traits.append(contentsOf: analysis.silhouettes)
        traits.append(contentsOf: analysis.layering)
        traits.append(contentsOf: analysis.details)
        traits.append(contentsOf: analysis.occasions)
        traits.append(contentsOf: analysis.outfitFormula ?? [])
        traits.append(contentsOf: analysis.proportions ?? [])
        traits.append(contentsOf: analysis.focalPoints ?? [])
        traits.append(contentsOf: analysis.stylingRules ?? [])
        let overlap = traits.reduce(0) { $0 + tokens($1).intersection(queryTokens).count }
        return overlap
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }
}
