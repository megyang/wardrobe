import SwiftData
import XCTest
@testable import Wearwell

final class ShopTests: XCTestCase {
    func testExhaustedOutfitProductFeedLeavesStudioResults() {
        let product = DiscoveredProductDTO(
            id: "one", canonicalURL: "https://example.com/scarf", retailer: "Example", domain: "example.com",
            title: "Scarf", imageURL: "https://example.com/scarf.jpg", category: "accessories", colors: [],
            currentPrice: 30, originalPrice: nil, currency: "USD", verifiedAt: "2026-08-05T12:00:00Z",
            confidence: 0.9, rationale: "Completes the look", matchedWardrobeGap: "accessory"
        )
        let feed = ShopFeedSnapshot(query: "Complete this outfit", products: [product], state: "complete", originContext: "outfit")
        XCTAssertTrue(feed.belongsInStudioResults)

        feed.dismissedIDs = [product.id]

        XCTAssertFalse(feed.belongsInStudioResults)
    }

    @MainActor
    func testShoppingProfileBackupRoundTripExcludesFeedCache() async throws {
        let source = try makeContainer()
        let shoppingID = UUID()
        source.mainContext.insert(ShoppingProfile(
            id: shoppingID,
            preferences: ShoppingProfileDTO(country: "CA", currency: "CAD", sizes: ["tops": "M"], budgets: ["tops": 120])
        ))
        source.mainContext.insert(ShopFeedSnapshot(query: "Disposable cached picks", state: "complete"))
        let needID = UUID()
        source.mainContext.insert(PurchaseNeed(id: needID, title: "Capris", category: .bottoms, rationale: "A useful cropped proportion", searchQuery: "mid-rise capri pants", isLunaSuggested: true))
        try source.mainContext.save()

        let document = try await BackupService.makeDocument(context: source.mainContext)
        let decoded = try WearwellBackupDocument(fileWrapper: document.packageFileWrapper())
        let destination = try makeContainer()
        _ = try await BackupService.restore(decoded, context: destination.mainContext)

        let profiles = try destination.mainContext.fetch(FetchDescriptor<ShoppingProfile>())
        let snapshots = try destination.mainContext.fetch(FetchDescriptor<ShopFeedSnapshot>())
        let needs = try destination.mainContext.fetch(FetchDescriptor<PurchaseNeed>())
        XCTAssertEqual(profiles.first(where: { $0.id == shoppingID })?.preferences.currency, "CAD")
        XCTAssertEqual(profiles.first(where: { $0.id == shoppingID })?.preferences.sizes["tops"], "M")
        XCTAssertEqual(profiles.first(where: { $0.id == shoppingID })?.preferences.selectedAudience, .women)
        XCTAssertTrue(snapshots.isEmpty, "Shop feeds are disposable cache and must not be restored")
        XCTAssertEqual(needs.first(where: { $0.id == needID })?.title, "Capris")
        XCTAssertEqual(needs.first(where: { $0.id == needID })?.searchQuery, "mid-rise capri pants")
    }

    func testShoppingProfileNormalizesOnlySafeRetailerDomains() {
        XCTAssertEqual(ShoppingRetailer.normalizedDomain("https://www.aritzia.com/us/en"), "aritzia.com")
        XCTAssertEqual(ShoppingRetailer.normalizedDomain(" cantoncollective.com "), "cantoncollective.com")
        XCTAssertNil(ShoppingRetailer.normalizedDomain("http://example.com"))
        XCTAssertNil(ShoppingRetailer.normalizedDomain("https://user@example.com"))
        XCTAssertNil(ShoppingRetailer.normalizedDomain("127.0.0.1"))
        XCTAssertEqual(ShoppingRetailer.ucp.count, 20)
        XCTAssertEqual(ShoppingRetailer.web.count, 5)
        XCTAssertEqual(ShoppingRetailer.bundled.count, 25)
        XCTAssertEqual(ShoppingRetailer.ucp.suffix(3).map(\.domain), ["lewkin.com", "thecommense.com", "aelfriceden.com"])
    }

    func testExistingShoppingProfilesReceiveNewRetailerDefaultsOnce() throws {
        let oldJSON = #"{"country":"US","currency":"USD","sizes":{},"budgets":{},"preferredRetailers":["aritzia.com"],"customRetailerDomains":[],"excludedCategories":[],"excludedColors":[],"excludedMaterials":[],"dismissedProductIDs":[]}"#.data(using: .utf8)!
        var profile = try JSONDecoder().decode(ShoppingProfileDTO.self, from: oldJSON)
        XCTAssertEqual(profile.selectedAudience, .women, "Older profiles safely default to women's recommendations")
        XCTAssertTrue(ShoppingRetailer.applyBundledUpdates(to: &profile))
        XCTAssertTrue(profile.preferredRetailers.contains("aritzia.com"), "Customized existing choices are preserved")
        XCTAssertTrue(profile.preferredRetailers.contains("lewkin.com"))
        XCTAssertTrue(profile.preferredRetailers.contains("oakandfort.com"))
        XCTAssertFalse(ShoppingRetailer.applyBundledUpdates(to: &profile))
    }

    func testUnmodifiedOldDefaultsBecomeUCPOnly() {
        var profile = ShoppingProfileDTO(
            preferredRetailers: ["aritzia.com", "uniqlo.com", "hollisterco.com", "cantoncollective.com", "codibook.net", "cos.com", "oakandfort.com"],
            bundledRetailerVersion: 2
        )
        XCTAssertTrue(ShoppingRetailer.applyBundledUpdates(to: &profile))
        XCTAssertEqual(profile.preferredRetailers, ShoppingRetailer.ucp.map(\.domain))
        XCTAssertFalse(profile.preferredRetailers.contains("aritzia.com"))
    }

    func testMarkdownRequiresTwoRetailerPrices() {
        let product = DiscoveredProductDTO(
            id: "p", canonicalURL: "https://example.com/p", retailer: "Example", domain: "example.com",
            title: "Top", imageURL: "https://example.com/p.jpg", category: "tops", colors: [],
            currentPrice: 40, originalPrice: 60, currency: "USD", verifiedAt: "2026-08-05T12:00:00Z",
            confidence: 0.9, rationale: "Useful layer", matchedWardrobeGap: "layering top"
        )
        XCTAssertTrue(product.hasVerifiedMarkdown)
        let missingOriginal = DiscoveredProductDTO(
            id: "p2", canonicalURL: product.canonicalURL, retailer: product.retailer, domain: product.domain,
            title: product.title, imageURL: product.imageURL, category: product.category, colors: [],
            currentPrice: 40, originalPrice: nil, currency: "USD", verifiedAt: product.verifiedAt,
            confidence: 0.9, rationale: product.rationale, matchedWardrobeGap: product.matchedWardrobeGap
        )
        XCTAssertFalse(missingOriginal.hasVerifiedMarkdown)
    }

    func testPurchaseNeedKeepsBroadSearchIntent() {
        let need = PurchaseNeed(title: "Capris", category: .bottoms, subcategory: .pants, rationale: "Adds a cropped proportion", searchQuery: "mid-rise capri pants")
        XCTAssertEqual(need.title, "Capris")
        XCTAssertEqual(need.category, .bottoms)
        XCTAssertEqual(need.subcategory, .pants)
        XCTAssertEqual(need.searchQuery, "mid-rise capri pants")
        XCTAssertFalse(need.isCompleted)
    }

    func testOutfitProductFeedRemembersItsExactCollage() {
        let ids = [UUID(), UUID()]
        let feed = ShopFeedSnapshot(query: "Complete this outfit", originContext: "outfit", focusGarmentIDs: ids)
        XCTAssertTrue(feed.isOutfitSpecific)
        XCTAssertEqual(feed.focusGarmentIDs, ids)
        XCTAssertFalse(feed.isUnread)
    }

    func testOldCachedProductDecodesWithoutVisualProvenance() throws {
        let json = #"{"id":"old","canonicalURL":"https://example.com/p","retailer":"Example","domain":"example.com","title":"Top","imageURL":"https://example.com/p.jpg","category":"tops","colors":[],"currentPrice":40,"originalPrice":null,"currency":"USD","verifiedAt":"2026-08-05T12:00:00Z","confidence":0.8,"rationale":"Useful","matchedWardrobeGap":"layer"}"#.data(using: .utf8)!
        let product = try JSONDecoder().decode(DiscoveredProductDTO.self, from: json)
        XCTAssertNil(product.source)
        XCTAssertNil(product.visualNotes)
        XCTAssertEqual(product.id, "old")
    }

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WearwellSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
