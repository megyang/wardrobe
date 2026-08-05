import SwiftData
import XCTest
@testable import Wearwell

final class ShopTests: XCTestCase {
    @MainActor
    func testShoppingProfileBackupRoundTripExcludesFeedCache() async throws {
        let source = try makeContainer()
        let shoppingID = UUID()
        source.mainContext.insert(ShoppingProfile(
            id: shoppingID,
            preferences: ShoppingProfileDTO(country: "CA", currency: "CAD", sizes: ["tops": "M"], budgets: ["tops": 120])
        ))
        source.mainContext.insert(ShopFeedSnapshot(query: "Disposable cached picks", state: "complete"))
        try source.mainContext.save()

        let document = try await BackupService.makeDocument(context: source.mainContext)
        let decoded = try WearwellBackupDocument(fileWrapper: document.packageFileWrapper())
        let destination = try makeContainer()
        _ = try await BackupService.restore(decoded, context: destination.mainContext)

        let profiles = try destination.mainContext.fetch(FetchDescriptor<ShoppingProfile>())
        let snapshots = try destination.mainContext.fetch(FetchDescriptor<ShopFeedSnapshot>())
        XCTAssertEqual(profiles.first(where: { $0.id == shoppingID })?.preferences.currency, "CAD")
        XCTAssertEqual(profiles.first(where: { $0.id == shoppingID })?.preferences.sizes["tops"], "M")
        XCTAssertTrue(snapshots.isEmpty, "Shop feeds are disposable cache and must not be restored")
    }

    func testShoppingProfileNormalizesOnlySafeRetailerDomains() {
        XCTAssertEqual(ShoppingRetailer.normalizedDomain("https://www.aritzia.com/us/en"), "aritzia.com")
        XCTAssertEqual(ShoppingRetailer.normalizedDomain(" cantoncollective.com "), "cantoncollective.com")
        XCTAssertNil(ShoppingRetailer.normalizedDomain("http://example.com"))
        XCTAssertNil(ShoppingRetailer.normalizedDomain("https://user@example.com"))
        XCTAssertNil(ShoppingRetailer.normalizedDomain("127.0.0.1"))
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

    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WearwellSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
