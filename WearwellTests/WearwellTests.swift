import XCTest
import SwiftData
import UIKit
@testable import Wearwell

final class WearwellTests: XCTestCase {
    @MainActor
    func testBackupRoundTripIsNonDestructiveAndIdempotent() async throws {
        let source = try makeInMemoryContainer()
        let sourceContext = source.mainContext
        let image = Data("catalog-image".utf8)
        let id = UUID()
        sourceContext.insert(Garment(id: id, label: "Blue shirt", category: .tops, color: "Blue", sourceAssetName: "shirt.jpg", catalogAssetName: "shirt.jpg"))
        sourceContext.insert(AssetBlob(name: "shirt.jpg", data: image))
        try sourceContext.save()

        let document = try await BackupService.makeDocument(context: sourceContext)
        let wrapper = try document.packageFileWrapper()
        let decoded = try WearwellBackupDocument(fileWrapper: wrapper)

        let destination = try makeInMemoryContainer()
        let destinationContext = destination.mainContext
        destinationContext.insert(Garment(label: "Existing coat", category: .outerwear, color: "Black"))
        try destinationContext.save()

        let first = try await BackupService.restore(decoded, context: destinationContext)
        let second = try await BackupService.restore(decoded, context: destinationContext)
        let garments = try destinationContext.fetch(FetchDescriptor<Garment>())
        let blobs = try destinationContext.fetch(FetchDescriptor<AssetBlob>())

        XCTAssertEqual(first.recordsApplied, 1)
        XCTAssertEqual(first.assetsApplied, 1)
        XCTAssertEqual(second.assetsApplied, 0)
        XCTAssertEqual(second.assetsUnchanged, 1)
        XCTAssertEqual(garments.count, 2)
        XCTAssertEqual(garments.first(where: { $0.id == id })?.label, "Blue shirt")
        XCTAssertEqual(blobs.count, 1)
        XCTAssertEqual(blobs.first?.data, image)
    }

    @MainActor
    func testBackupRejectsDamagedAssetBeforeRestore() async throws {
        let source = try makeInMemoryContainer()
        let context = source.mainContext
        context.insert(AssetBlob(name: "look.png", data: Data("valid".utf8)))
        try context.save()
        let document = try await BackupService.makeDocument(context: context)
        let wrapper = try document.packageFileWrapper()
        let assetsWrapper: FileWrapper? = wrapper.fileWrappers?["assets"]
        let asset: FileWrapper? = assetsWrapper?.fileWrappers?["look.png"]
        if let asset { assetsWrapper?.removeFileWrapper(asset) }
        let damaged = FileWrapper(regularFileWithContents: Data("damaged".utf8))
        damaged.preferredFilename = "look.png"
        assetsWrapper?.addFileWrapper(damaged)

        XCTAssertThrowsError(try WearwellBackupDocument(fileWrapper: wrapper))
    }

    func testBackupAssetNamesRejectPathTraversal() {
        XCTAssertTrue(BackupService.isSafeAssetName("A1B2C3.png"))
        XCTAssertFalse(BackupService.isSafeAssetName("../secret.png"))
        XCTAssertFalse(BackupService.isSafeAssetName("folder/image.png"))
    }

    func testStyleVectorAggregationWeightsFavoriteLooksWithoutReanalysis() {
        let high = InspirationAnalysisDTO(
            summary: "Layered vintage", aesthetics: ["vintage"], palette: [], silhouettes: [], layering: ["fitted under loose"], details: [], occasions: [],
            vector: StyleVectorDTO(values: Array(repeating: 1, count: 12)), analysisVersion: "1", modelVersion: "test"
        )
        let low = InspirationAnalysisDTO(
            summary: "Minimal", aesthetics: ["minimal"], palette: [], silhouettes: [], layering: [], details: [], occasions: [],
            vector: .zero, analysisVersion: "1", modelVersion: "test"
        )

        let result = StylePreferenceCache.aggregateVector(analyses: [high, low], weights: [2, 1])
        XCTAssertEqual(result.layered, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(result.vintage, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testFavoriteInspirationAlwaysLeadsRetrieval() {
        let analysis = InspirationAnalysisDTO(
            summary: "Look", aesthetics: [], palette: [], silhouettes: [], layering: [], details: [], occasions: [],
            vector: .zero, analysisVersion: "2", modelVersion: "test"
        )
        let favorite = InspirationLook(assetName: "favorite.jpg", state: "ready")
        favorite.analysis = analysis; favorite.isFavorite = true
        let keywordMatch = InspirationLook(assetName: "match.jpg", state: "ready")
        keywordMatch.analysis = InspirationAnalysisDTO(
            summary: "Match", aesthetics: ["office tailored office"], palette: [], silhouettes: [], layering: [], details: [], occasions: ["office"],
            vector: .zero, analysisVersion: "2", modelVersion: "test"
        )

        XCTAssertEqual(StylePreferenceCache.relevantLooks([keywordMatch, favorite], query: "office", limit: 1).first?.id, favorite.id)
    }

    func testVersionOneInspirationStillDecodesForOneTimeUpgrade() throws {
        let json = #"{"summary":"Old look","aesthetics":[],"palette":[],"silhouettes":[],"layering":[],"details":[],"occasions":[],"vector":{"minimal":0,"maximal":0,"relaxed":0,"tailored":0,"romantic":0,"edgy":0,"sporty":0,"vintage":0,"classic":0,"experimental":0,"layered":0,"colorful":0},"analysisVersion":"1","modelVersion":"test"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(InspirationAnalysisDTO.self, from: json)

        XCTAssertEqual(decoded.analysisVersion, "1")
        XCTAssertNil(decoded.outfitFormula)
        XCTAssertNil(decoded.proportions)
    }

    func testLayoutRoundTripPreservesGeometry() throws {
        let original = LayoutItem(garmentID: UUID(), x: 0.23, y: 0.71, scale: 1.4, rotation: -12, zIndex: 4)
        let data = try JSONEncoder().encode([original])
        XCTAssertEqual(try JSONDecoder().decode([LayoutItem].self, from: data), [original])
    }

    func testAutomaticOutfitLayoutKeepsPiecesSeparated() {
        for count in 2...9 {
            let items = OutfitLayout.arranged(garmentIDs: (0..<count).map { _ in UUID() })
            let frames = items.map { item in
                CGRect(
                    x: item.x * 320 - 75 * item.scale,
                    y: item.y * 400 - 90 * item.scale,
                    width: 150 * item.scale,
                    height: 180 * item.scale
                )
            }

            for first in frames.indices {
                for second in frames.indices where second > first {
                    XCTAssertFalse(frames[first].intersects(frames[second]), "Pieces overlap for count \(count)")
                }
            }
        }
    }

    func testAIValidationRejectsUnknownItems() {
        let owned = UUID(), outside = UUID()
        let garment = Garment(id: owned, label: "Top", category: .tops, color: "Blue")
        let suggestions = [
            OutfitSuggestionDTO(title: "Valid", rationale: "", garmentIDs: [owned]),
            OutfitSuggestionDTO(title: "Invalid", rationale: "", garmentIDs: [owned, outside])
        ]
        XCTAssertEqual(OutfitValidator.validateAI(suggestions, garments: [garment]).map(\.title), ["Valid"])
    }

    func testAIValidationRequiresSelectedAnchor() {
        let anchor = Garment(label: "Anchor", category: .tops, color: "Blue")
        let bottom = Garment(label: "Bottom", category: .bottoms, color: "Black")
        let suggestions = [
            OutfitSuggestionDTO(title: "Anchored", rationale: "", garmentIDs: [anchor.id, bottom.id]),
            OutfitSuggestionDTO(title: "Missing anchor", rationale: "", garmentIDs: [bottom.id])
        ]

        XCTAssertEqual(
            OutfitValidator.validateAI(suggestions, garments: [anchor, bottom], anchorID: anchor.id).map(\.title),
            ["Anchored"]
        )
    }

    func testAIValidationRejectsDuplicateGarmentIDs() {
        let top = Garment(label: "Top", category: .tops, color: "Blue")
        let duplicate = OutfitSuggestionDTO(title: "Duplicate", rationale: "", garmentIDs: [top.id, top.id])

        XCTAssertTrue(OutfitValidator.validateAI([duplicate], garments: [top]).isEmpty)
    }

    func testOutfitFindsGarmentInSavedLayout() {
        let garmentID = UUID()
        let outfit = Outfit(title: "Saved", origin: .manual, layout: [LayoutItem(garmentID: garmentID)])

        XCTAssertTrue(outfit.contains(garmentID: garmentID))
        XCTAssertFalse(outfit.contains(garmentID: UUID()))
    }

    func testOutfitEditsUpdateTheSameSavedRecord() {
        let originalID = UUID()
        let firstItem = LayoutItem(garmentID: UUID())
        let replacement = LayoutItem(garmentID: UUID(), x: 0.2, y: 0.7, scale: 1.3)
        let outfit = Outfit(id: originalID, title: "Original", rationale: "Keep me", origin: .aiStyle, layout: [firstItem])
        let editDate = Date(timeIntervalSince1970: 1234)

        outfit.applyEdits(title: "Renamed", layout: [replacement], at: editDate)

        XCTAssertEqual(outfit.id, originalID)
        XCTAssertEqual(outfit.title, "Renamed")
        XCTAssertEqual(outfit.layout, [replacement])
        XCTAssertEqual(outfit.rationale, "Keep me")
        XCTAssertEqual(outfit.origin, .aiStyle)
        XCTAssertEqual(outfit.updatedAt, editDate)
    }

    func testPurchaseValidationUsesOwnedIDsOnly() {
        let owned = UUID(), outside = UUID()
        let garment = Garment(id: owned, label: "Bottom", category: .bottoms, color: "Black")
        let assessment = PurchaseAssessmentDTO(verdict: .maybe, summary: "", outfits: [
            OutfitSuggestionDTO(title: "Owned", rationale: "", garmentIDs: [owned]),
            OutfitSuggestionDTO(title: "Invented", rationale: "", garmentIDs: [outside])
        ])
        let candidate = WishlistItem(label: "Possible top", category: .tops, color: "Blue")
        XCTAssertEqual(OutfitValidator.validatePurchase(assessment, garments: [garment], candidate: candidate).outfits.map(\.title), ["Owned"])
    }

    @MainActor
    func testBackgroundPurchaseResultIsSavedOnce() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let candidate = WishlistItem(label: "Possible top", category: .tops, color: "Blue")
        let bottom = Garment(label: "Black pants", category: .bottoms, color: "Black")
        context.insert(candidate)
        context.insert(bottom)
        let result = PurchaseAssessmentDTO(
            verdict: .buy,
            summary: "Works with your wardrobe.",
            outfits: [OutfitSuggestionDTO(title: "Easy pairing", rationale: "Balanced colors", garmentIDs: [bottom.id])]
        )
        let job = AssessmentJobDTO(
            id: "assessment-1", kind: "assess", state: "completed", createdAt: "now", updatedAt: "now",
            stage: "Complete", queuePosition: nil, estimatedSecondsRemaining: 0, result: result, error: nil
        )

        PurchaseAssessmentResults.apply(job, to: candidate, garments: [bottom], outfits: [], context: context)
        PurchaseAssessmentResults.apply(job, to: candidate, garments: [bottom], outfits: [], context: context)
        try context.save()

        XCTAssertEqual(candidate.verdict, .buy)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Outfit>()).count, 1)
    }

    func testOutfitValidationAllowsDressWithBottomButRejectsDuplicateSlots() {
        let dress = Garment(label: "Dress", category: .dresses, color: "Blue")
        let bottom = Garment(label: "Pants", category: .bottoms, subcategory: .pants, color: "Black")
        let secondBottom = Garment(label: "Skirt", category: .bottoms, color: "Gray")
        let top = Garment(label: "Plain fitted long sleeve", category: .tops, subcategory: .longSleeve, color: "White")
        let valid = OutfitSuggestionDTO(title: "Layered", rationale: "", garmentIDs: [dress.id, bottom.id, top.id], layering: [
            LayeringStepDTO(garmentID: top.id.uuidString, placement: .under),
            LayeringStepDTO(garmentID: dress.id.uuidString, placement: .main)
        ])
        let invalid = OutfitSuggestionDTO(title: "Two bottoms", rationale: "", garmentIDs: [bottom.id, secondBottom.id])
        XCTAssertEqual(OutfitValidator.validateAI([valid, invalid], garments: [dress, bottom, secondBottom, top]).map(\.title), ["Layered"])
    }

    func testOutfitValidationAllowsTwoTopsOnlyWithExplicitLayering() {
        let base = Garment(label: "Plain fitted long sleeve", category: .tops, subcategory: .longSleeve, color: "White")
        let tank = Garment(label: "Tank", category: .tops, subcategory: .tankTop, color: "Black")
        let layered = OutfitSuggestionDTO(title: "Intentional layer", rationale: "", garmentIDs: [base.id, tank.id], layering: [
            LayeringStepDTO(garmentID: base.id.uuidString, placement: .under),
            LayeringStepDTO(garmentID: tank.id.uuidString, placement: .main)
        ])
        let unplanned = OutfitSuggestionDTO(title: "Unplanned", rationale: "", garmentIDs: [base.id, tank.id])

        XCTAssertEqual(OutfitValidator.validateAI([layered, unplanned], garments: [base, tank]).map(\.title), ["Intentional layer"])
    }

    func testPurchaseTestOutfitsStayOutOfSavedOutfitLibrary() {
        let candidateID = UUID()
        let purchaseTest = Outfit(
            title: "Should I buy this?", origin: .purchaseTest,
            layout: [LayoutItem(wishlistItemID: candidateID)], wishlistItemID: candidateID
        )
        let saved = Outfit(title: "Saved look", origin: .aiStyle, layout: [LayoutItem(garmentID: UUID())])

        XCTAssertFalse(purchaseTest.belongsInOutfitLibrary)
        XCTAssertTrue(saved.belongsInOutfitLibrary)
    }

    func testOpenGraphImageExtraction() {
        let html = #"<meta property="og:image" content="/coat.jpg">"#
        XCTAssertEqual(ImportService.openGraphImage(in: html, base: URL(string: "https://shop.example/item")!)?.absoluteString, "https://shop.example/coat.jpg")
    }

    func testImportURLsAreUpgradedToHTTPS() {
        XCTAssertEqual(ImportService.secureURL(from: "http://shop.example/item")?.absoluteString, "https://shop.example/item")
        XCTAssertEqual(ImportService.secureURL(from: " shop.example/item\n")?.absoluteString, "https://shop.example/item")
        XCTAssertNil(ImportService.secureURL(from: "ftp://shop.example/item"))
    }

    func testCompanionEndpointRejectsInvalidDiscoveryNamesWithoutCrashing() throws {
        XCTAssertThrowsError(try CompanionEndpoint.url(host: "Megdy’s Mac", port: 8791))
        XCTAssertThrowsError(try CompanionEndpoint.url(host: "mac.local", port: 0))
        XCTAssertEqual(
            try CompanionEndpoint.url(host: " mac.local\n", port: 8791).absoluteString,
            "https://mac.local:8791/"
        )
    }

    func testOpenGraphImageIsUpgradedToHTTPS() {
        let html = #"<meta property="og:image" content="http://cdn.example/coat.jpg">"#
        XCTAssertEqual(ImportService.openGraphImage(in: html, base: URL(string: "https://shop.example/item")!)?.absoluteString, "https://cdn.example/coat.jpg")
    }

    func testImportDraftPersistsRemoteJobAndResults() throws {
        let item = GarmentAnalysisDTO(label: "Blue shirt", category: "tops", subcategory: "blouse", color: "Blue", confidence: 0.91, description: "Cotton shirt", observed: "Blue button front", unknowns: [], fingerprint: "blue-shirt", catalogImageBase64: nil, modelVersion: "gpt-5.6-luna")
        let draft = ImportDraft(sourceAssetName: "source.jpg", state: "queued", remoteJobID: "job-123")
        draft.analyses = [item]
        draft.state = "ready"
        XCTAssertEqual(draft.remoteJobID, "job-123")
        XCTAssertEqual(draft.analyses.first?.label, "Blue shirt")
        XCTAssertEqual(draft.analyses.first?.subcategory, "blouse")
        XCTAssertEqual(draft.state, "ready")
    }

    func testSubcategoriesStayWithinTheirParentCategory() {
        let garment = Garment(label: "Tank", category: .tops, subcategory: .tankTop, color: "White")
        XCTAssertEqual(garment.subcategory, .tankTop)
        garment.category = .bottoms
        XCTAssertNil(garment.subcategory)
        XCTAssertEqual(GarmentSubcategory.options(for: .outerwear), [.coverup, .sweater, .jacket, .coat])
        XCTAssertTrue(GarmentSubcategory.options(for: .bottoms).contains(.miniSkirt))
        XCTAssertTrue(GarmentSubcategory.options(for: .bottoms).contains(.midiSkirt))
        XCTAssertTrue(GarmentSubcategory.options(for: .bottoms).contains(.maxiSkirt))
        XCTAssertFalse(GarmentSubcategory.options(for: .bottoms).contains(.skirt))
        XCTAssertEqual(GarmentSubcategory(rawValue: "skirt"), .skirt)
    }

    func testEveryMainCategoryOffersItsExistingSubcategories() {
        XCTAssertEqual(GarmentCategory.allCases.map(\.rawValue), ["tops", "bottoms", "outerwear", "dresses", "shoes", "accessories"])
        XCTAssertTrue(GarmentSubcategory.options(for: .tops).contains(.blouse))
        XCTAssertTrue(GarmentSubcategory.options(for: .bottoms).contains(.pants))
        XCTAssertTrue(GarmentSubcategory.options(for: .outerwear).contains(.coat))
        XCTAssertTrue(GarmentSubcategory.options(for: .accessories).contains(.hat))
        XCTAssertTrue(GarmentSubcategory.options(for: .dresses).isEmpty)
        XCTAssertTrue(GarmentSubcategory.options(for: .shoes).isEmpty)
    }

    func testAlphaCropPreservesAWhiteGarment() {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format)
        let source = renderer.image { context in
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.white.setFill()
            context.cgContext.fill(CGRect(x: 25, y: 20, width: 50, height: 60))
        }

        let cutout = AlphaBoundsCropper.crop(source)

        XCTAssertLessThan(cutout.size.width, source.size.width)
        XCTAssertLessThan(cutout.size.height, source.size.height)
        XCTAssertEqual(cutout.size, CGSize(width: 54, height: 64))
    }

    func testChromaBackdropRefinerClearsEnclosedLaceHole() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40), format: format).image { context in
            UIColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor.white.setFill()
            context.fill(CGRect(x: 8, y: 8, width: 24, height: 24))
            UIColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(x: 17, y: 17, width: 6, height: 6))
        }

        guard let refined = ChromaBackdropRefiner.refine(source) else {
            return XCTFail("Expected the solid chroma background to be detected")
        }
        XCTAssertLessThan(alpha(in: refined, at: CGPoint(x: 20, y: 20)), 8)
        XCTAssertGreaterThan(alpha(in: refined, at: CGPoint(x: 12, y: 12)), 247)
    }

    func testMagentaChromaPreservesMintGarment() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 80), format: format).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            UIColor(red: 0.75, green: 0.94, blue: 0.88, alpha: 1).setFill()
            context.fill(CGRect(x: 12, y: 10, width: 36, height: 60))
        }

        guard let refined = ChromaBackdropRefiner.refine(source) else {
            return XCTFail("Expected the magenta chroma background to be detected")
        }
        XCTAssertLessThan(alpha(in: refined, at: CGPoint(x: 3, y: 3)), 8)
        XCTAssertGreaterThan(alpha(in: refined, at: CGPoint(x: 30, y: 40)), 247)
    }

    func testChromaBackdropRefinerRemovesGreenEdgeSpill() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48), format: format).image { context in
            UIColor(red: 0.02, green: 0.98, blue: 0.02, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            UIColor(red: 0.55, green: 0.92, blue: 0.55, alpha: 1).setFill()
            context.fill(CGRect(x: 9, y: 9, width: 30, height: 30))
            UIColor.white.setFill()
            context.fill(CGRect(x: 12, y: 12, width: 24, height: 24))
        }

        guard let refined = ChromaBackdropRefiner.refine(source) else {
            return XCTFail("Expected the green chroma background to be detected")
        }
        let edge = rgba(in: refined, at: CGPoint(x: 10, y: 24))
        XCTAssertLessThanOrEqual(Int(edge.green), Int(max(edge.red, edge.blue)) + 14)
        XCTAssertGreaterThan(alpha(in: refined, at: CGPoint(x: 20, y: 20)), 247)
    }

    func testExistingTransparentShirtIsNotRecroppedToItsPrintedGraphic() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let shirt = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { context in
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.white.setFill()
            context.fill(CGRect(x: 20, y: 10, width: 60, height: 80))
            UIColor.red.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 44, y: 40, width: 12, height: 14))
        }

        let prepared = AssetStore.preparedCollageImage(from: shirt)

        XCTAssertTrue(ImageTransparencyDetector.hasMeaningfulTransparency(shirt))
        XCTAssertEqual(prepared.size, CGSize(width: 64, height: 84))
    }

    func testTinyPrintedGraphicIsRejectedAsAForegroundCutout() {
        XCTAssertFalse(ForegroundCropValidator.isPlausible(
            CGSize(width: 90, height: 85),
            relativeTo: CGSize(width: 1000, height: 1250)
        ))
        XCTAssertTrue(ForegroundCropValidator.isPlausible(
            CGSize(width: 700, height: 900),
            relativeTo: CGSize(width: 1000, height: 1250)
        ))
    }

    func testEmbeddedCheckerboardIsRemovedWithoutLosingPaleShirt() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 120), format: format).image { context in
            for y in stride(from: 0, to: 120, by: 8) {
                for x in stride(from: 0, to: 100, by: 8) {
                    ((x / 8 + y / 8).isMultiple(of: 2) ? UIColor.white : UIColor(white: 0.92, alpha: 1)).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
            UIColor(red: 0.82, green: 0.95, blue: 0.95, alpha: 1).setFill()
            context.fill(CGRect(x: 20, y: 15, width: 60, height: 90))
            UIColor.red.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 43, y: 48, width: 14, height: 14))
        }

        guard let refined = EmbeddedCheckerboardRefiner.refine(source) else {
            return XCTFail("Expected the embedded checkerboard to be detected")
        }
        XCTAssertLessThan(alpha(in: refined, at: CGPoint(x: 4, y: 4)), 8)
        XCTAssertGreaterThan(alpha(in: refined, at: CGPoint(x: 25, y: 25)), 247)
        XCTAssertGreaterThan(AlphaBoundsCropper.crop(refined).size.width, 50)
    }

    func testEmbeddedCheckerboardDoesNotEraseWhiteShirt() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 144), format: format).image { context in
            for y in stride(from: 0, to: 144, by: 8) {
                for x in stride(from: 0, to: 120, by: 8) {
                    ((x / 8 + y / 8).isMultiple(of: 2) ? UIColor.white : UIColor(white: 0.92, alpha: 1)).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
            UIColor.white.setFill()
            context.fill(CGRect(x: 24, y: 16, width: 72, height: 112))
            UIColor.red.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 52, y: 58, width: 16, height: 18))
        }

        guard let refined = EmbeddedCheckerboardRefiner.refine(source) else {
            return XCTFail("Expected the embedded checkerboard to be detected")
        }
        XCTAssertLessThan(alpha(in: refined, at: CGPoint(x: 4, y: 4)), 8)
        XCTAssertGreaterThan(alpha(in: refined, at: CGPoint(x: 32, y: 32)), 247)
        XCTAssertGreaterThan(alpha(in: refined, at: CGPoint(x: 60, y: 100)), 247)
        XCTAssertGreaterThan(AlphaBoundsCropper.crop(refined).size.width, 65)
    }

    func testPartiallyTransparentCheckerboardIsFullyRemoved() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 144), format: format).image { context in
            for y in stride(from: 0, to: 144, by: 8) {
                for x in stride(from: 0, to: 120, by: 8) {
                    ((x / 8 + y / 8).isMultiple(of: 2) ? UIColor.white : UIColor(white: 0.92, alpha: 1)).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
            context.cgContext.clear(CGRect(x: 0, y: 32, width: 14, height: 20))
            context.cgContext.clear(CGRect(x: 92, y: 0, width: 18, height: 12))
            context.cgContext.clear(CGRect(x: 104, y: 88, width: 16, height: 24))
            UIColor.white.setFill()
            context.fill(CGRect(x: 24, y: 16, width: 72, height: 112))
            UIColor.blue.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 52, y: 58, width: 16, height: 18))
        }

        XCTAssertTrue(ImageTransparencyDetector.hasMeaningfulTransparency(source))
        guard let refined = EmbeddedCheckerboardRefiner.refine(source) else {
            return XCTFail("Expected the remaining checkerboard to be detected")
        }
        XCTAssertLessThan(alpha(in: refined, at: CGPoint(x: 4, y: 4)), 8)
        XCTAssertLessThan(alpha(in: refined, at: CGPoint(x: 112, y: 132)), 8)
        XCTAssertGreaterThan(alpha(in: refined, at: CGPoint(x: 32, y: 32)), 247)
        XCTAssertGreaterThan(AlphaBoundsCropper.crop(refined).size.width, 65)
    }

    func testCheckerboardWithOneFlattenedBorderStillRoutesToCleanup() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 144), format: format).image { context in
            for y in stride(from: 0, to: 144, by: 8) {
                for x in stride(from: 0, to: 120, by: 8) {
                    ((x / 8 + y / 8).isMultiple(of: 2) ? UIColor.white : UIColor(white: 0.94, alpha: 1)).setFill()
                    context.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 8))
            UIColor.brown.setFill()
            context.fill(CGRect(x: 28, y: 18, width: 64, height: 108))
        }

        XCTAssertNotNil(EmbeddedCheckerboardRefiner.refine(source))
    }

    private func alpha(in image: UIImage, at point: CGPoint) -> UInt8 {
        rgba(in: image, at: point).alpha
    }

    private func rgba(in image: UIImage, at point: CGPoint) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        guard let cgImage = image.cgImage else { return (0, 0, 0, 0) }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0, 0) }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = max(0, min(width - 1, Int(point.x)))
        let y = max(0, min(height - 1, Int(point.y)))
        let offset = y * bytesPerRow + x * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }

    @MainActor
    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: WearwellSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
