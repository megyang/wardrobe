import SwiftUI
import UIKit

struct EditorialHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased()).font(.caption2.weight(.bold)).tracking(1.6).foregroundStyle(WearwellTheme.sage)
            Text(title).font(.system(size: 35, weight: .semibold, design: .serif)).foregroundStyle(WearwellTheme.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(WearwellTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AssetImage: View {
    let name: String
    var contentMode: ContentMode = .fit
    var body: some View {
        Group {
            if let image = AssetStore.image(named: name) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                ZStack {
                    WearwellTheme.cream
                    Image(systemName: "tshirt").font(.largeTitle).foregroundStyle(WearwellTheme.sage.opacity(0.45))
                }
            }
        }
    }
}

struct CollageAssetImage: View {
    let name: String
    @State private var cutout: UIImage?
    var body: some View {
        Group {
            if let cutout {
                Image(uiImage: cutout).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: name) {
            cutout = nil
            let data = await Task.detached(priority: .userInitiated) {
                AssetStore.collageImage(named: name)?.pngData()
            }.value
            if !Task.isCancelled { cutout = data.flatMap(UIImage.init(data:)) }
        }
    }
}

struct CatalogDataImage: View {
    let data: Data
    @State private var cutout: UIImage?

    var body: some View {
        Group {
            if let cutout {
                Image(uiImage: cutout).resizable().scaledToFit()
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: data) {
            cutout = nil
            let previewData = await Task.detached(priority: .userInitiated) {
                guard let source = UIImage(data: data) else { return nil as Data? }
                return (ForegroundSubjectExtractor.extract(from: source) ?? source).pngData()
            }.value
            if !Task.isCancelled { cutout = previewData.flatMap(UIImage.init(data:)) }
        }
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = WearwellTheme.sage
    var body: some View {
        Text(text).font(.caption2.weight(.bold)).padding(.horizontal, 9).padding(.vertical, 6)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .foregroundStyle(WearwellTheme.ink)
    }
}

struct GarmentCard: View {
    let garment: Garment
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CollageAssetImage(name: garment.catalogAssetName.isEmpty ? garment.sourceAssetName : garment.catalogAssetName)
                .padding(10).frame(height: 210).frame(maxWidth: .infinity).background(WearwellTheme.previewSurface).clipShape(RoundedRectangle(cornerRadius: 16))
            Text(garment.label).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(garment.color) · \(garment.subcategory?.title ?? garment.category.title)").font(.caption).foregroundStyle(WearwellTheme.muted).lineLimit(1)
        }
    }
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
