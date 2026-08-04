import Foundation
import CoreImage
import SwiftData
import UIKit
import Vision

private final class CollageImageCache: @unchecked Sendable {
    let values = NSCache<NSString, UIImage>()
}

actor AssetStore {
    static let shared = AssetStore()
    static let appGroup = "group.com.wearwell.private"
    private nonisolated static let collageCache = CollageImageCache()

    private let directory: URL
    private var container: ModelContainer?

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = root.appending(path: "WearwellAssets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
    }

    func configure(container: ModelContainer) {
        self.container = container
    }

    func save(_ data: Data, preferredExtension: String = "jpg") throws -> String {
        let name = "\(UUID().uuidString).\(preferredExtension)"
        let url = directory.appending(path: name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        if let container {
            let context = ModelContext(container)
            context.insert(AssetBlob(name: name, data: data))
            try context.save()
        }
        return name
    }

    func data(named name: String) throws -> Data {
        let url = directory.appending(path: name)
        if let cached = try? Data(contentsOf: url) { return cached }
        guard let container else { throw CocoaError(.fileNoSuchFile) }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<AssetBlob>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        guard let blob = try context.fetch(descriptor).first else { throw CocoaError(.fileNoSuchFile) }
        try blob.data.write(to: url, options: [.atomic, .completeFileProtection])
        return blob.data
    }

    func remove(named name: String?) {
        guard let name, !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: name))
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<AssetBlob>(predicate: #Predicate { $0.name == name })
        if let blobs = try? context.fetch(descriptor) {
            for blob in blobs { context.delete(blob) }
            try? context.save()
        }
    }

    func legacyAssetNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.isFileURL && !$0.hasDirectoryPath }
            .map(\.lastPathComponent)
            .sorted() ?? []
    }

    func persistCachedAsset(named name: String) throws -> Bool {
        guard let container else { return false }
        let context = ModelContext(container)
        var descriptor = FetchDescriptor<AssetBlob>(predicate: #Predicate { $0.name == name })
        descriptor.fetchLimit = 1
        if try context.fetch(descriptor).first != nil { return false }
        let value = try Data(contentsOf: directory.appending(path: name))
        context.insert(AssetBlob(name: name, data: value))
        try context.save()
        return true
    }

    func cache(name: String, data: Data) {
        let url = directory.appending(path: name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
    nonisolated static func image(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return UIImage(contentsOfFile: root.appending(path: "WearwellAssets/\(name)").path)
    }

    /// Produces a sticker-style foreground cutout. Vision handles arbitrary scenes
    /// and backdrop colors without treating white garments as background.
    nonisolated static func collageImage(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let key = "sticker-v3-\(name)" as NSString
        if let cached = collageCache.values.object(forKey: key) { return cached }
        guard let source = image(named: name) else { return nil }
        // If subject lifting fails, preserve the original image. Showing a backdrop
        // is preferable to destructively erasing a light-colored garment.
        let cutout = ForegroundSubjectExtractor.extract(from: source) ?? source
        collageCache.values.setObject(cutout, forKey: key)
        return cutout
    }
}

enum ForegroundSubjectExtractor {
    static func extract(from source: UIImage) -> UIImage? {
        guard source.size.width > 0, source.size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let normalized = UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
        guard let cgImage = normalized.cgImage else { return nil }

        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
            let maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )

            let foreground = CIImage(cgImage: cgImage)
            let mask = CIImage(cvPixelBuffer: maskBuffer)
            let transparent = CIImage(color: .clear).cropped(to: foreground.extent)
            guard let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
            blend.setValue(foreground, forKey: kCIInputImageKey)
            blend.setValue(transparent, forKey: kCIInputBackgroundImageKey)
            blend.setValue(mask, forKey: kCIInputMaskImageKey)
            guard let output = blend.outputImage,
                  let cutout = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: foreground.extent)
            else { return nil }

            return AlphaBoundsCropper.crop(UIImage(cgImage: cutout))
        } catch {
            return nil
        }
    }
}

enum AlphaBoundsCropper {
    /// Crops transparent padding without making any decision based on pixel color.
    /// White, cream, and other light foreground colors therefore remain untouched.
    static func crop(_ source: UIImage) -> UIImage {
        guard source.size.width > 0, source.size.height > 0 else { return source }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let normalized = UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
        guard let cgImage = normalized.cgImage else { return source }

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
        ) else { return normalized }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            if pixels[offset + 3] > 8 {
                let x = pixel % width
                let y = pixel / width
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else { return normalized }
        guard let rendered = context.makeImage() else { return normalized }
        let padding = 2
        let crop = CGRect(
            x: max(0, minX - padding),
            y: max(0, minY - padding),
            width: min(width - 1, maxX + padding) - max(0, minX - padding) + 1,
            height: min(height - 1, maxY + padding) - max(0, minY - padding) + 1
        )
        guard let cropped = rendered.cropping(to: crop) else { return UIImage(cgImage: rendered) }
        return UIImage(cgImage: cropped)
    }
}

enum OutfitValidator {
    static func validateAI(_ suggestions: [OutfitSuggestionDTO], garments: [Garment], anchorID: UUID? = nil) -> [OutfitSuggestionDTO] {
        suggestions.filter { suggestion in
            isValid(suggestion, garments: garments) && (anchorID.map { suggestion.garmentIDs.contains($0) } ?? true)
        }
    }

    static func validatePurchase(_ assessment: PurchaseAssessmentDTO, garments: [Garment], candidateCategory: GarmentCategory) -> PurchaseAssessmentDTO {
        let valid = assessment.outfits.filter { isValid($0, garments: garments, candidateCategory: candidateCategory) }
        return PurchaseAssessmentDTO(verdict: assessment.verdict, summary: assessment.summary, outfits: valid)
    }

    private static func isValid(_ suggestion: OutfitSuggestionDTO, garments: [Garment], candidateCategory: GarmentCategory? = nil) -> Bool {
        guard !suggestion.garmentIDs.isEmpty else { return false }
        guard Set(suggestion.garmentIDs).count == suggestion.garmentIDs.count else { return false }
        let categories = Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0.category) })
        guard Set(suggestion.garmentIDs).isSubset(of: Set(categories.keys)) else { return false }
        var counts: [GarmentCategory: Int] = [:]
        if let candidateCategory, [.tops, .bottoms, .dresses].contains(candidateCategory) { counts[candidateCategory] = 1 }
        var torsoIDs = candidateCategory.map { [.tops, .dresses].contains($0) ? ["__candidate__"] : [] } ?? []
        for id in suggestion.garmentIDs {
            guard let category = categories[id] else { return false }
            counts[category, default: 0] += 1
            if [.tops, .dresses].contains(category) { torsoIDs.append(id.uuidString.lowercased()) }
        }
        guard counts[.bottoms, default: 0] <= 1,
              counts[.dresses, default: 0] <= 1,
              counts[.tops, default: 0] <= 2,
              torsoIDs.count <= 2 else { return false }
        let layering = suggestion.layering ?? []
        guard torsoIDs.count == 2 else { return layering.isEmpty }
        guard layering.count == 2 else { return false }
        let plannedIDs = layering.map { $0.garmentID.lowercased() }
        guard Set(plannedIDs).count == 2, torsoIDs.allSatisfy(plannedIDs.contains) else { return false }
        let placements = Set(layering.map(\.placement))
        guard placements.contains(.under), placements.contains(.main) || placements.contains(.over) else { return false }
        return true
    }
}
