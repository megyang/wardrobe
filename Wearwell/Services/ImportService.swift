import Foundation
import UIKit

enum ImportError: LocalizedError {
    case invalidURL, unsupportedPage, tooLarge, invalidImage
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid image or product-page URL."
        case .unsupportedPage: "This page does not expose a shareable product image. Try sharing the image itself."
        case .tooLarge: "That image is larger than 18 MB."
        case .invalidImage: "The selected file is not a supported image."
        }
    }
}

enum ImportService {
    static func image(from text: String) async throws -> (Data, URL) {
        guard let url = secureURL(from: text) else { throw ImportError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard data.count <= 18 * 1024 * 1024 else { throw ImportError.tooLarge }
        let mime = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type") ?? ""
        if mime.hasPrefix("image/"), UIImage(data: data) != nil { return (data, url) }
        guard let html = String(data: data, encoding: .utf8), let imageURL = openGraphImage(in: html, base: url) else { throw ImportError.unsupportedPage }
        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        guard imageData.count <= 18 * 1024 * 1024 else { throw ImportError.tooLarge }
        guard UIImage(data: imageData) != nil else { throw ImportError.invalidImage }
        return (imageData, url)
    }

    static func openGraphImage(in html: String, base: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+property=[\"']og:image[\"'][^>]+content=[\"']([^\"']+)[\"']"#,
            #"<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image[\"']"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            guard let resolved = URL(
                string: String(html[range]).replacingOccurrences(of: "&amp;", with: "&"),
                relativeTo: base
            )?.absoluteURL else { continue }
            return secureURL(resolved)
        }
        return nil
    }

    static func secureURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate) else { return nil }
        return secureURL(url)
    }

    private static func secureURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        guard scheme == "http" else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.scheme = "https"
        return components.url
    }
}

enum ShareInbox {
    static func consume() -> [(data: Data?, url: URL?)] {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AssetStore.appGroup)?.appending(path: "Inbox") else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            if file.pathExtension == "url", let text = try? String(contentsOf: file, encoding: .utf8) { return (nil, URL(string: text)) }
            return ((try? Data(contentsOf: file)), nil)
        }
    }
}
