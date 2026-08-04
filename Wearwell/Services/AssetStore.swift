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
    nonisolated static func cachedCollageImage(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        return collageCache.values.object(forKey: collageCacheKey(for: name))
    }

    nonisolated static func collageImage(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let key = collageCacheKey(for: name)
        if let cached = collageCache.values.object(forKey: key) { return cached }
        guard let source = image(named: name) else { return nil }
        let cutout = preparedCollageImage(from: source)
        collageCache.values.setObject(cutout, forKey: key)
        return cutout
    }

    nonisolated static func preparedCollageImage(from source: UIImage) -> UIImage {
        if let checkerboardCutout = EmbeddedCheckerboardRefiner.refine(source) {
            return AlphaBoundsCropper.crop(checkerboardCutout)
        }
        // Catalog images that already contain real transparency are finished
        // cutouts. Running Vision again can select a printed logo as the subject
        // and crop a full shirt down to that graphic.
        if ImageTransparencyDetector.hasMeaningfulTransparency(source) {
            return AlphaBoundsCropper.crop(source)
        }
        // If subject lifting fails, preserve the original image. Showing a backdrop
        // is preferable to destructively erasing a light-colored garment.
        return ForegroundSubjectExtractor.extract(from: source) ?? source
    }

    private nonisolated static func collageCacheKey(for name: String) -> NSString {
        "sticker-v7-\(name)" as NSString
    }
}

enum EmbeddedCheckerboardRefiner {
    private struct ColorBin {
        var count = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0

        var average: (red: Double, green: Double, blue: Double) {
            (red / Double(count), green / Double(count), blue / Double(count))
        }
    }

    /// Some generated PNGs contain a rendered transparency grid instead of an
    /// alpha channel. Detect the two alternating light border colors and key them
    /// out before asking Vision to identify a foreground subject.
    static func refine(_ source: UIImage) -> UIImage? {
        guard !ImageTransparencyDetector.hasMeaningfulTransparency(source),
              let cgImage = source.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 8, height > 8 else { return nil }
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
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let thickness = max(2, min(width, height) / 30)
        var bins: [Int: ColorBin] = [:]
        var borderPixels = 0
        for y in 0..<height {
            for x in 0..<width where x < thickness || x >= width - thickness || y < thickness || y >= height - thickness {
                let offset = y * bytesPerRow + x * 4
                guard pixels[offset + 3] > 245 else { continue }
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                let key = (r / 8 << 10) | (g / 8 << 5) | (b / 8)
                var bin = bins[key, default: ColorBin()]
                bin.count += 1; bin.red += Double(r); bin.green += Double(g); bin.blue += Double(b)
                bins[key] = bin; borderPixels += 1
            }
        }

        let candidates = bins.values.sorted { $0.count > $1.count }.prefix(8)
        var backdrop: [(red: Double, green: Double, blue: Double)]?
        for firstIndex in candidates.indices {
            for secondIndex in candidates.indices where secondIndex > firstIndex {
                let first = candidates[firstIndex]
                let second = candidates[secondIndex]
                guard first.count * 12 >= borderPixels,
                      second.count * 12 >= borderPixels,
                      (first.count + second.count) * 5 >= borderPixels * 2 else { continue }
                let a = first.average
                let b = second.average
                let aSpread = max(a.red, max(a.green, a.blue)) - min(a.red, min(a.green, a.blue))
                let bSpread = max(b.red, max(b.green, b.blue)) - min(b.red, min(b.green, b.blue))
                let brightnessDifference = abs((a.red + a.green + a.blue) - (b.red + b.green + b.blue)) / 3
                guard min(a.red, min(a.green, a.blue)) > 205,
                      min(b.red, min(b.green, b.blue)) > 205,
                      aSpread < 18, bSpread < 18,
                      brightnessDifference >= 4, brightnessDifference <= 36 else { continue }
                backdrop = [a, b]
                break
            }
            if backdrop != nil { break }
        }
        guard let backdrop else { return nil }

        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            let distance = backdrop.map { color in
                sqrt(pow(red - color.red, 2) + pow(green - color.green, 2) + pow(blue - color.blue, 2))
            }.min() ?? 255
            let foregroundAlpha = max(0, min(1, (distance - 8) / 12))
            for component in 0..<4 {
                pixels[offset + component] = UInt8(Double(pixels[offset + component]) * foregroundAlpha)
            }
        }
        guard let refined = context.makeImage() else { return nil }
        return UIImage(cgImage: refined)
    }
}

enum ImageTransparencyDetector {
    static func hasMeaningfulTransparency(_ source: UIImage) -> Bool {
        guard let cgImage = source.cgImage else { return false }
        let alphaInfo = cgImage.alphaInfo
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(alphaInfo) else { return false }

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
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let requiredTransparentPixels = max(8, width * height / 1000)
        var transparentPixels = 0
        for pixel in 0..<(width * height) where pixels[pixel * 4 + 3] < 245 {
            transparentPixels += 1
            if transparentPixels >= requiredTransparentPixels { return true }
        }
        return false
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
                  let masked = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: foreground.extent)
            else { return nil }

            let cutout = AlphaBoundsCropper.crop(GreenBackdropRefiner.refine(
                source: normalized,
                masked: UIImage(cgImage: masked)
            ))
            guard ForegroundCropValidator.isPlausible(cutout.size, relativeTo: normalized.size) else {
                return nil
            }
            return cutout
        } catch {
            return nil
        }
    }
}

enum ForegroundCropValidator {
    /// Catalog garments are generated large and centered. A tiny Vision result is
    /// usually a logo or printed graphic, not the garment itself.
    static func isPlausible(_ cutout: CGSize, relativeTo source: CGSize) -> Bool {
        guard source.width > 0, source.height > 0 else { return false }
        let widthRatio = cutout.width / source.width
        let heightRatio = cutout.height / source.height
        let areaRatio = (cutout.width * cutout.height) / (source.width * source.height)
        return widthRatio >= 0.3 && heightRatio >= 0.3 && areaRatio >= 0.12
    }
}

enum GreenBackdropRefiner {
    /// Vision can classify the gaps in lace as part of the foreground instance.
    /// When image generation has supplied a dominant green backdrop, remove that
    /// chroma anywhere it appears, including enclosed holes and narrow openings.
    static func refine(source: UIImage, masked: UIImage) -> UIImage {
        guard let backdrop = dominantBorderGreen(in: source) else { return masked }
        guard let maskedImage = masked.cgImage else { return masked }
        let width = maskedImage.width
        let height = maskedImage.height
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
        ) else { return masked }
        context.draw(maskedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            guard pixels[offset + 3] > 0 else { continue }
            let existingAlpha = Double(pixels[offset + 3]) / 255
            let red = Double(pixels[offset]) / existingAlpha
            let green = Double(pixels[offset + 1]) / existingAlpha
            let blue = Double(pixels[offset + 2]) / existingAlpha
            let distance = sqrt(
                pow(red - backdrop.red, 2) +
                pow(green - backdrop.green, 2) +
                pow(blue - backdrop.blue, 2)
            )
            let backgroundAlpha = max(0, min(1, (distance - 24) / 54))
            for component in 0..<4 {
                pixels[offset + component] = UInt8(Double(pixels[offset + component]) * backgroundAlpha)
            }
        }
        guard let refined = context.makeImage() else { return masked }
        return UIImage(cgImage: refined)
    }

    private static func dominantBorderGreen(in source: UIImage) -> (red: Double, green: Double, blue: Double)? {
        guard let cgImage = source.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 1, height > 1 else { return nil }
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
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let thickness = max(1, min(width, height) / 40)
        var count = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
        for y in 0..<height {
            for x in 0..<width where x < thickness || x >= width - thickness || y < thickness || y >= height - thickness {
                let offset = y * bytesPerRow + x * 4
                guard pixels[offset + 3] > 16 else { continue }
                let r = Double(pixels[offset])
                let g = Double(pixels[offset + 1])
                let b = Double(pixels[offset + 2])
                guard g > r * 1.15, g > b * 1.12, g - min(r, b) > 28 else { continue }
                red += r; green += g; blue += b; count += 1
            }
        }

        let borderCount = max(1, 2 * thickness * (width + height - 2 * thickness))
        guard count * 5 >= borderCount else { return nil }
        return (red / Double(count), green / Double(count), blue / Double(count))
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
