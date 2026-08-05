import Foundation
import CoreImage
import CryptoKit
import ImageIO
import SwiftData
import UIKit
import Vision

private final class CollageImageCache: @unchecked Sendable {
    let values = NSCache<NSString, UIImage>()
    private let condition = NSCondition()
    private var preparing: Set<String> = []

    func load(key: NSString, operation: () -> UIImage?) -> UIImage? {
        if let cached = values.object(forKey: key) { return cached }
        let token = key as String
        condition.lock()
        while preparing.contains(token) {
            condition.wait()
            if let cached = values.object(forKey: key) {
                condition.unlock()
                return cached
            }
        }
        if let cached = values.object(forKey: key) {
            condition.unlock()
            return cached
        }
        preparing.insert(token)
        condition.unlock()

        let result = operation()
        if let result { values.setObject(result, forKey: key) }

        condition.lock()
        preparing.remove(token)
        condition.broadcast()
        condition.unlock()
        return result
    }
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

    /// A compact, immutable visual reference for Luna. Asset names are UUID-based
    /// and change whenever an edited image is saved, so this disk cache naturally
    /// refreshes only when the underlying garment/inspiration image changes.
    func visualReferenceData(named name: String) throws -> Data {
        guard !name.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = root.appending(path: "WearwellVisualReferences/visual-v1/\(digest).jpg")
        if let cached = try? Data(contentsOf: url), !cached.isEmpty { return cached }

        let source = try data(named: name)
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 384
              ] as CFDictionary),
              let encoded = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.72) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try encoded.write(to: url, options: [.atomic, .completeFileProtection])
        return encoded
    }

    func remove(named name: String?) {
        guard let name, !name.isEmpty else { return }
        try? FileManager.default.removeItem(at: directory.appending(path: name))
        Self.removeCachedCollageImage(named: name)
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: root.appending(path: "WearwellVisualReferences/visual-v1/\(digest).jpg"))
        guard let container else { return }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<AssetBlob>(predicate: #Predicate { $0.name == name })
        if let blobs = try? context.fetch(descriptor) {
            for blob in blobs { context.delete(blob) }
            try? context.save()
        }
    }

    func removeAllCachedAssets() {
        if let values = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for value in values { try? FileManager.default.removeItem(at: value) }
        }
        let visualRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "WearwellVisualReferences", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: visualRoot)
        Self.collageCache.values.removeAllObjects()
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
        let key = collageCacheKey(for: name)
        if let cached = collageCache.values.object(forKey: key) { return cached }
        guard let diskImage = UIImage(contentsOfFile: collageDiskURL(for: name).path) else { return nil }
        collageCache.values.setObject(diskImage, forKey: key)
        return diskImage
    }

    nonisolated static func collageImage(named name: String) -> UIImage? {
        guard !name.isEmpty else { return nil }
        let key = collageCacheKey(for: name)
        if let cached = cachedCollageImage(named: name) { return cached }
        return collageCache.load(key: key) {
            if let diskImage = UIImage(contentsOfFile: collageDiskURL(for: name).path) {
                return diskImage
            }
            guard let source = image(named: name) else { return nil }
            let cutout = preparedCollageImage(from: source)
            persistCollageImage(cutout, named: name)
            return cutout
        }
    }

    nonisolated static func preparedCollageImage(from source: UIImage) -> UIImage {
        if let checkerboardFallback = EmbeddedCheckerboardRefiner.refine(source) {
            // Vision is better at rejecting small compression differences in
            // rendered checker tiles. Keep the grid mask only as a fallback when
            // Vision cannot identify a plausible full-size garment.
            return ForegroundSubjectExtractor.extract(from: source)
                ?? AlphaBoundsCropper.crop(checkerboardFallback)
        }
        if let chromaCutout = ChromaBackdropRefiner.refine(source) {
            return AlphaBoundsCropper.crop(chromaCutout)
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

    private nonisolated static let collageCacheVersion = "sticker-v14"

    private nonisolated static func collageCacheKey(for name: String) -> NSString {
        "\(collageCacheVersion)-\(name)" as NSString
    }

    private nonisolated static func collageDiskURL(for name: String) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return root.appending(path: "WearwellCutouts/\(collageCacheVersion)/\(name).png")
    }

    private nonisolated static func persistCollageImage(_ image: UIImage, named name: String) {
        guard let data = image.pngData() else { return }
        let url = collageDiskURL(for: name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private nonisolated static func removeCachedCollageImage(named name: String) {
        collageCache.values.removeObject(forKey: collageCacheKey(for: name))
        try? FileManager.default.removeItem(at: collageDiskURL(for: name))
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
        // Do not skip images that already have some transparency. Older builds
        // erased only parts of rendered grids, leaving a mixture of clear holes
        // and opaque checker pixels that still need repairing.
        guard let cgImage = source.cgImage else { return nil }
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

        let topLabels = (0..<width).map { nearestBackdrop(to: pixelColor(at: $0 * 4, in: pixels), colors: backdrop) }
        let leftLabels = (0..<height).map { y in nearestBackdrop(to: pixelColor(at: y * bytesPerRow, in: pixels), colors: backdrop) }
        let horizontalRuns = runLengths(in: topLabels)
        let verticalRuns = runLengths(in: leftLabels)
        // Generators occasionally flatten the first row or column even though
        // the rest of the canvas contains a real checker grid. One alternating
        // border is sufficient to route the image through Vision.
        guard horizontalRuns.count >= 4 || verticalRuns.count >= 4 else { return nil }

        let runs = (horizontalRuns + verticalRuns).filter { $0 >= 2 }.sorted()
        guard !runs.isEmpty else { return nil }
        let tileSize = runs[runs.count / 2]
        let colorSeparation = colorDistance(backdrop[0], backdrop[1])
        let matchTolerance = max(3, min(10, colorSeparation * 0.3))
        let baseLabel = topLabels[0]
        var foregroundMask = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let expectedLabel = topLabels[x] ^ leftLabels[y] ^ baseLabel
                if colorDistance(pixelColor(at: offset, in: pixels), backdrop[expectedLabel]) > matchTolerance {
                    foregroundMask[y * width + x] = 255
                }
            }
        }

        guard let maskContext = CGContext(
            data: &foregroundMask,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let maskImage = maskContext.makeImage() else { return nil }

        let sourceImage = CIImage(cgImage: cgImage)
        let mask = CIImage(cgImage: maskImage)
        let radius = max(2, min(32, Double(tileSize) * 0.75))
        guard let expand = CIFilter(name: "CIMorphologyMaximum"),
              let contract = CIFilter(name: "CIMorphologyMinimum"),
              let blend = CIFilter(name: "CIBlendWithMask") else { return nil }
        expand.setValue(mask, forKey: kCIInputImageKey)
        expand.setValue(radius, forKey: kCIInputRadiusKey)
        guard let expanded = expand.outputImage else { return nil }
        contract.setValue(expanded, forKey: kCIInputImageKey)
        contract.setValue(radius, forKey: kCIInputRadiusKey)
        guard let closedMask = contract.outputImage?.cropped(to: sourceImage.extent) else { return nil }

        blend.setValue(sourceImage, forKey: kCIInputImageKey)
        blend.setValue(CIImage(color: .clear).cropped(to: sourceImage.extent), forKey: kCIInputBackgroundImageKey)
        blend.setValue(closedMask, forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage,
              let refined = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: sourceImage.extent)
        else { return nil }
        return UIImage(cgImage: refined)
    }

    private static func pixelColor(at offset: Int, in pixels: [UInt8]) -> (red: Double, green: Double, blue: Double) {
        (Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
    }

    private static func nearestBackdrop(
        to color: (red: Double, green: Double, blue: Double),
        colors: [(red: Double, green: Double, blue: Double)]
    ) -> Int {
        colorDistance(color, colors[0]) <= colorDistance(color, colors[1]) ? 0 : 1
    }

    private static func colorDistance(
        _ first: (red: Double, green: Double, blue: Double),
        _ second: (red: Double, green: Double, blue: Double)
    ) -> Double {
        sqrt(pow(first.red - second.red, 2) + pow(first.green - second.green, 2) + pow(first.blue - second.blue, 2))
    }

    private static func runLengths(in labels: [Int]) -> [Int] {
        guard let first = labels.first else { return [] }
        var current = first
        var length = 0
        var result: [Int] = []
        for label in labels {
            if label == current {
                length += 1
            } else {
                result.append(length)
                current = label
                length = 1
            }
        }
        result.append(length)
        return result
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

            let visionCutout = UIImage(cgImage: masked)
            let cutout = AlphaBoundsCropper.crop(
                ChromaBackdropRefiner.refine(source: normalized, masked: visionCutout) ?? visionCutout
            )
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

enum ChromaBackdropRefiner {
    /// Vision can classify the gaps in lace as part of the foreground instance.
    /// When image generation has supplied a dominant green backdrop, remove that
    /// chroma anywhere it appears, including enclosed holes and narrow openings.
    static func refine(_ source: UIImage) -> UIImage? {
        refine(source: source, masked: source)
    }

    static func refine(source: UIImage, masked: UIImage) -> UIImage? {
        guard let backdrop = dominantBorderChroma(in: source) else { return nil }
        guard let maskedImage = masked.cgImage else { return nil }
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
        ) else { return nil }
        context.draw(maskedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var coverages = [Double](repeating: 1, count: width * height)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            guard pixels[offset + 3] > 0 else {
                coverages[pixel] = 0
                continue
            }
            let existingAlpha = Double(pixels[offset + 3]) / 255
            let red = Double(pixels[offset]) / existingAlpha
            let green = Double(pixels[offset + 1]) / existingAlpha
            let blue = Double(pixels[offset + 2]) / existingAlpha
            let distance = sqrt(
                pow(red - backdrop.red, 2) +
                pow(green - backdrop.green, 2) +
                pow(blue - backdrop.blue, 2)
            )
            // Generated edges are antialiased blends of backdrop and garment.
            // Estimate coverage, then solve the blend equation to remove the
            // chroma spill instead of leaving a green or magenta fringe.
            let foregroundCoverage = max(0, min(1, (distance - 18) / 132))
            coverages[pixel] = foregroundCoverage
            guard foregroundCoverage < 1 else { continue }
            let combinedAlpha = existingAlpha * foregroundCoverage
            guard foregroundCoverage > 0.001, combinedAlpha > 0.001 else {
                pixels[offset] = 0; pixels[offset + 1] = 0
                pixels[offset + 2] = 0; pixels[offset + 3] = 0
                continue
            }
            let backgroundCoverage = 1 - foregroundCoverage
            let cleanedRed = max(0, min(255, (red - backgroundCoverage * backdrop.red) / foregroundCoverage))
            let cleanedGreen = max(0, min(255, (green - backgroundCoverage * backdrop.green) / foregroundCoverage))
            let cleanedBlue = max(0, min(255, (blue - backgroundCoverage * backdrop.blue) / foregroundCoverage))
            pixels[offset] = UInt8(cleanedRed * combinedAlpha)
            pixels[offset + 1] = UInt8(cleanedGreen * combinedAlpha)
            pixels[offset + 2] = UInt8(cleanedBlue * combinedAlpha)
            pixels[offset + 3] = UInt8(255 * combinedAlpha)
        }

        // Some antialiased edge pixels are opaque but retain a faint chroma
        // cast. Neutralize only the narrow ring next to keyed pixels, never the
        // interior color of a legitimately green or magenta garment.
        let greenBackdrop = backdrop.green > backdrop.red * 1.2 && backdrop.green > backdrop.blue * 1.2
        let magentaBackdrop = backdrop.red > backdrop.green * 1.2 && backdrop.blue > backdrop.green * 1.2
        if greenBackdrop || magentaBackdrop {
            let radius = 3
            for y in 0..<height {
                for x in 0..<width {
                    let pixel = y * width + x
                    guard coverages[pixel] >= 0.999 else { continue }
                    var bordersKeyedPixel = false
                    for neighborY in max(0, y - radius)...min(height - 1, y + radius) {
                        for neighborX in max(0, x - radius)...min(width - 1, x + radius)
                        where coverages[neighborY * width + neighborX] < 0.999 {
                            bordersKeyedPixel = true
                            break
                        }
                        if bordersKeyedPixel { break }
                    }
                    guard bordersKeyedPixel else { continue }
                    let offset = pixel * 4
                    let alpha = Double(pixels[offset + 3]) / 255
                    guard alpha > 0 else { continue }
                    var red = Double(pixels[offset]) / alpha
                    var green = Double(pixels[offset + 1]) / alpha
                    var blue = Double(pixels[offset + 2]) / alpha
                    if greenBackdrop, green > max(red, blue) + 12 {
                        green = max(red, blue) + 12
                    } else if magentaBackdrop {
                        let neutralCeiling = green + 12
                        red = min(red, neutralCeiling)
                        blue = min(blue, neutralCeiling)
                    }
                    pixels[offset] = UInt8(max(0, min(255, red * alpha)))
                    pixels[offset + 1] = UInt8(max(0, min(255, green * alpha)))
                    pixels[offset + 2] = UInt8(max(0, min(255, blue * alpha)))
                }
            }
        }
        guard let refined = context.makeImage() else { return nil }
        return UIImage(cgImage: refined)
    }

    private struct ColorBin {
        var count = 0
        var red = 0.0
        var green = 0.0
        var blue = 0.0
    }

    private static func dominantBorderChroma(in source: UIImage) -> (red: Double, green: Double, blue: Double)? {
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
        var bins: [Int: ColorBin] = [:]
        var borderCount = 0
        for y in 0..<height {
            for x in 0..<width where x < thickness || x >= width - thickness || y < thickness || y >= height - thickness {
                let offset = y * bytesPerRow + x * 4
                guard pixels[offset + 3] > 16 else { continue }
                borderCount += 1
                let r = Int(pixels[offset])
                let g = Int(pixels[offset + 1])
                let b = Int(pixels[offset + 2])
                guard max(r, max(g, b)) >= 170,
                      max(r, max(g, b)) - min(r, min(g, b)) >= 80 else { continue }
                let key = (r / 16 << 8) | (g / 16 << 4) | (b / 16)
                var bin = bins[key, default: ColorBin()]
                bin.count += 1
                bin.red += Double(r); bin.green += Double(g); bin.blue += Double(b)
                bins[key] = bin
            }
        }

        guard let dominant = bins.values.max(by: { $0.count < $1.count }),
              dominant.count * 3 >= max(1, borderCount) else { return nil }
        return (
            dominant.red / Double(dominant.count),
            dominant.green / Double(dominant.count),
            dominant.blue / Double(dominant.count)
        )
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
        return suggestions.filter { suggestion in
            isValid(suggestion, garments: garments) && (anchorID.map { suggestion.garmentIDs.contains($0) } ?? true)
        }
    }

    static func validatePurchase(_ assessment: PurchaseAssessmentDTO, garments: [Garment], candidate: WishlistItem) -> PurchaseAssessmentDTO {
        let valid = assessment.outfits.filter { isValid($0, garments: garments, candidate: candidate) }
        return PurchaseAssessmentDTO(verdict: assessment.verdict, summary: assessment.summary, outfits: valid)
    }

    private struct Piece {
        var id: String
        var category: GarmentCategory
    }

    private static func isValid(_ suggestion: OutfitSuggestionDTO, garments: [Garment], candidate: WishlistItem? = nil) -> Bool {
        guard !suggestion.garmentIDs.isEmpty else { return false }
        guard Set(suggestion.garmentIDs).count == suggestion.garmentIDs.count else { return false }
        let owned = Dictionary(uniqueKeysWithValues: garments.map { ($0.id, $0) })
        guard Set(suggestion.garmentIDs).isSubset(of: Set(owned.keys)) else { return false }
        var counts: [GarmentCategory: Int] = [:]
        var pieces: [Piece] = []
        if let candidate {
            counts[candidate.category] = 1
            pieces.append(Piece(id: "__candidate__", category: candidate.category))
        }
        for id in suggestion.garmentIDs {
            guard let garment = owned[id] else { return false }
            counts[garment.category, default: 0] += 1
            pieces.append(Piece(id: id.uuidString.lowercased(), category: garment.category))
        }
        guard counts[.bottoms, default: 0] <= 1,
              counts[.dresses, default: 0] <= 1,
              counts[.tops, default: 0] <= 2 else { return false }
        let torso = pieces.filter { [.tops, .dresses].contains($0.category) }
        guard torso.count <= 2 else { return false }
        let layering = suggestion.layering ?? []
        guard torso.count == 2 else { return layering.isEmpty }
        guard layering.count == 2 else { return false }
        let plannedIDs = layering.map { $0.garmentID.lowercased() }
        guard Set(plannedIDs).count == 2, torso.allSatisfy({ plannedIDs.contains($0.id) }),
              let underStep = layering.first(where: { $0.placement == .under }),
              let outerStep = layering.first(where: { [.main, .over].contains($0.placement) }),
              underStep.garmentID.lowercased() != outerStep.garmentID.lowercased(),
              torso.contains(where: { $0.id == underStep.garmentID.lowercased() }),
              torso.contains(where: { $0.id == outerStep.garmentID.lowercased() }) else { return false }
        return true
    }
}
