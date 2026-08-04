import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
    private let group = "group.com.wearwell.private"

    override func isContentValid() -> Bool { true }

    override func didSelectPost() {
        Task {
            await storeFirstAttachment()
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    override func configurationItems() -> [Any]! { [] }

    private func storeFirstAttachment() async {
        guard let item = extensionContext?.inputItems.compactMap({ $0 as? NSExtensionItem }).first,
              let provider = item.attachments?.first,
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appending(path: "Inbox", directoryHint: .isDirectory) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await imageData(from: provider) {
            try? data.write(to: root.appending(path: "\(UUID().uuidString).jpg"), options: [Data.WritingOptions.atomic, Data.WritingOptions.completeFileProtection])
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                  let value = await sharedURL(from: provider) {
            try? value.absoluteString.write(to: root.appending(path: "\(UUID().uuidString).url"), atomically: true, encoding: String.Encoding.utf8)
        }
    }

    private func imageData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
        }
    }

    private func sharedURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in continuation.resume(returning: item as? URL) }
        }
    }
}
