import Foundation
import SwiftData

enum ShoppingAudience: String, Codable, CaseIterable, Identifiable {
    case women, unisex, men
    var id: String { rawValue }
    var title: String {
        switch self {
        case .women: "Women's"
        case .unisex: "Unisex"
        case .men: "Men's"
        }
    }
}

struct ShoppingProfileDTO: Codable, Equatable {
    var country: String = "US"
    var currency: String = "USD"
    var sizes: [String: String] = [:]
    var budgets: [String: Double] = [:]
    var preferredRetailers: [String] = ShoppingRetailer.ucp.map(\.domain)
    var customRetailerDomains: [String] = []
    var excludedCategories: [String] = []
    var excludedColors: [String] = []
    var excludedMaterials: [String] = []
    var clothingAudience: String? = ShoppingAudience.women.rawValue
    var dismissedProductIDs: [String] = []
    var bundledRetailerVersion: Int? = ShoppingRetailer.currentDefaultsVersion

    var retailerDomains: [String] {
        var seen = Set<String>()
        return (preferredRetailers + customRetailerDomains)
            .compactMap(ShoppingRetailer.normalizedDomain)
            .filter { seen.insert($0).inserted }
    }

    var selectedAudience: ShoppingAudience {
        get { ShoppingAudience(rawValue: clothingAudience ?? "") ?? .women }
        set { clothingAudience = newValue.rawValue }
    }
}

struct ShoppingRetailer: Identifiable, Equatable {
    enum Source: String { case ucp, web }
    let name: String
    let domain: String
    let source: Source
    var id: String { domain }

    static let ucp = [
        ShoppingRetailer(name: "Canton Collective", domain: "cantoncollective.com", source: .ucp),
        ShoppingRetailer(name: "OAK + FORT", domain: "oakandfort.com", source: .ucp),
        ShoppingRetailer(name: "Lisa Says Gah", domain: "lisasaysgah.com", source: .ucp),
        ShoppingRetailer(name: "Damson Madder", domain: "damsonmadder.com", source: .ucp),
        ShoppingRetailer(name: "Paloma Wool", domain: "palomawool.com", source: .ucp),
        ShoppingRetailer(name: "Frank And Oak", domain: "frankandoak.com", source: .ucp),
        ShoppingRetailer(name: "MESHKI", domain: "meshki.us", source: .ucp),
        ShoppingRetailer(name: "Peppermayo", domain: "peppermayo.com", source: .ucp),
        ShoppingRetailer(name: "Motel Rocks", domain: "motelrocks.com", source: .ucp),
        ShoppingRetailer(name: "Rouje", domain: "rouje.com", source: .ucp),
        ShoppingRetailer(name: "Beginning Boutique", domain: "beginningboutique.com", source: .ucp),
        ShoppingRetailer(name: "Everlane", domain: "everlane.com", source: .ucp),
        ShoppingRetailer(name: "Girlfriend Collective", domain: "girlfriend.com", source: .ucp),
        ShoppingRetailer(name: "Los Angeles Apparel", domain: "losangelesapparel.net", source: .ucp),
        ShoppingRetailer(name: "Big Bud Press", domain: "bigbudpress.com", source: .ucp),
        ShoppingRetailer(name: "Disturbia", domain: "disturbia.us", source: .ucp),
        ShoppingRetailer(name: "Lucy & Yak", domain: "lucyandyak.com", source: .ucp),
        ShoppingRetailer(name: "Lewkin", domain: "lewkin.com", source: .ucp),
        ShoppingRetailer(name: "Commense", domain: "thecommense.com", source: .ucp),
        ShoppingRetailer(name: "Aelfric Eden", domain: "aelfriceden.com", source: .ucp)
    ]

    static let web = [
        ShoppingRetailer(name: "Aritzia", domain: "aritzia.com", source: .web),
        ShoppingRetailer(name: "Uniqlo", domain: "uniqlo.com", source: .web),
        ShoppingRetailer(name: "Hollister", domain: "hollisterco.com", source: .web),
        ShoppingRetailer(name: "Codibook", domain: "codibook.net", source: .web),
        ShoppingRetailer(name: "COS", domain: "cos.com", source: .web)
    ]
    static let bundled = ucp + web
    static let currentDefaultsVersion = 3

    static func applyBundledUpdates(to profile: inout ShoppingProfileDTO) -> Bool {
        guard (profile.bundledRetailerVersion ?? 1) < currentDefaultsVersion else { return false }
        let previousDefaults = Set(["aritzia.com", "uniqlo.com", "hollisterco.com", "cantoncollective.com", "codibook.net", "cos.com", "oakandfort.com"])
        if Set(profile.preferredRetailers) == previousDefaults {
            profile.preferredRetailers = ucp.map(\.domain)
        } else {
            for domain in ucp.map(\.domain) where !profile.preferredRetailers.contains(domain) {
                profile.preferredRetailers.append(domain)
            }
        }
        profile.bundledRetailerVersion = currentDefaultsVersion
        return true
    }

    static func normalizedDomain(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty, host.contains("."), !host.contains(" "), !host.contains(":"),
              !host.split(separator: ".").allSatisfy({ Int($0) != nil }) else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct DiscoveredProductDTO: Codable, Identifiable, Equatable {
    let id: String
    let canonicalURL: String
    let retailer: String
    let domain: String
    let title: String
    let imageURL: String
    let category: String
    let colors: [String]
    let currentPrice: Double?
    let originalPrice: Double?
    let currency: String?
    let verifiedAt: String
    let confidence: Double
    let rationale: String
    let matchedWardrobeGap: String
    var source: String? = nil
    var sourceProductID: String? = nil
    var matchedInspirationIDs: [String]? = nil
    var compatibleGarmentIDs: [String]? = nil
    var visualNotes: String? = nil

    var hasVerifiedMarkdown: Bool {
        guard let currentPrice, let originalPrice else { return false }
        return currentPrice > 0 && originalPrice > currentPrice
    }
}

struct ShopFeedDTO: Codable, Equatable {
    let query: String
    let generatedAt: String
    let products: [DiscoveredProductDTO]
}

struct WardrobeGapDTO: Codable, Equatable {
    let title: String
    let category: String
    let subcategory: String
    let rationale: String
    let searchQuery: String
}

struct WardrobeGapResponseDTO: Codable, Equatable {
    let gaps: [WardrobeGapDTO]
}

@Model final class PurchaseNeed {
    var id: UUID
    var title: String
    var categoryRaw: String
    var subcategoryRaw: String?
    var rationale: String
    var searchQuery: String
    var isLunaSuggested: Bool
    var isCompleted: Bool
    var createdAt: Date
    var updatedAt: Date

    var category: GarmentCategory? {
        get { GarmentCategory(rawValue: categoryRaw) }
        set { categoryRaw = newValue?.rawValue ?? "" }
    }
    var subcategory: GarmentSubcategory? {
        get { subcategoryRaw.flatMap(GarmentSubcategory.init(rawValue:)) }
        set { subcategoryRaw = newValue?.rawValue }
    }

    init(
        id: UUID = UUID(), title: String, category: GarmentCategory? = nil,
        subcategory: GarmentSubcategory? = nil, rationale: String = "",
        searchQuery: String? = nil, isLunaSuggested: Bool = false,
        isCompleted: Bool = false, createdAt: Date = .now
    ) {
        self.id = id; self.title = title; categoryRaw = category?.rawValue ?? ""
        subcategoryRaw = subcategory?.rawValue; self.rationale = rationale
        self.searchQuery = searchQuery ?? title; self.isLunaSuggested = isLunaSuggested
        self.isCompleted = isCompleted; self.createdAt = createdAt; updatedAt = createdAt
    }
}

@Model final class ShoppingProfile {
    var id: UUID
    var profileJSON: Data
    var updatedAt: Date

    var preferences: ShoppingProfileDTO {
        get { (try? JSONDecoder().decode(ShoppingProfileDTO.self, from: profileJSON)) ?? ShoppingProfileDTO() }
        set { profileJSON = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }

    init(id: UUID = UUID(), preferences: ShoppingProfileDTO = ShoppingProfileDTO(), updatedAt: Date = .now) {
        self.id = id
        profileJSON = (try? JSONEncoder().encode(preferences)) ?? Data()
        self.updatedAt = updatedAt
    }
}

@Model final class ShopFeedSnapshot {
    var id: UUID
    var query: String
    var productsJSON: Data
    var dismissedIDsJSON: Data
    var generatedAt: Date
    var expiresAt: Date
    var jobID: String?
    var state: String
    var errorMessage: String?
    var originContext: String = "wardrobe"
    var focusGarmentIDsJSON: Data = Data()
    var isUnread: Bool = false
    var progressStage: String?
    var estimatedSecondsRemaining: Int?
    var progressUpdatedAt: Date?

    var products: [DiscoveredProductDTO] {
        get { (try? JSONDecoder().decode([DiscoveredProductDTO].self, from: productsJSON)) ?? [] }
        set { productsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var dismissedIDs: Set<String> {
        get { Set((try? JSONDecoder().decode([String].self, from: dismissedIDsJSON)) ?? []) }
        set { dismissedIDsJSON = (try? JSONEncoder().encode(Array(newValue).sorted())) ?? Data() }
    }

    var isFresh: Bool { state == "complete" && expiresAt > .now }

    var focusGarmentIDs: [UUID] {
        get { (try? JSONDecoder().decode([UUID].self, from: focusGarmentIDsJSON)) ?? [] }
        set { focusGarmentIDsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var isOutfitSpecific: Bool { originContext == "outfit" }

    init(
        id: UUID = UUID(), query: String, products: [DiscoveredProductDTO] = [],
        generatedAt: Date = .now, expiresAt: Date = .now.addingTimeInterval(6 * 60 * 60),
        jobID: String? = nil, state: String = "queued", errorMessage: String? = nil,
        originContext: String = "wardrobe", focusGarmentIDs: [UUID] = []
    ) {
        self.id = id; self.query = query
        productsJSON = (try? JSONEncoder().encode(products)) ?? Data()
        dismissedIDsJSON = Data()
        self.generatedAt = generatedAt; self.expiresAt = expiresAt
        self.jobID = jobID; self.state = state; self.errorMessage = errorMessage
        self.originContext = originContext
        focusGarmentIDsJSON = (try? JSONEncoder().encode(focusGarmentIDs)) ?? Data()
    }
}
