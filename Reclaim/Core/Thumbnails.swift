import SwiftUI
import QuickLookThumbnailing

/// Async, cached Quick Look thumbnails (images, videos, PDFs…).
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 1500 }

    func image(for url: URL, side: CGFloat) async -> NSImage? {
        let key = "\(url.path)#\(Int(side))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A square thumbnail that loads lazily, falling back to the Finder icon.
struct ThumbnailView: View {
    let url: URL
    var side: CGFloat = 96
    var cornerRadius: CGFloat = 8
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else if failed {
                Image(nsImage: FileIcons.icon(for: url)).resizable().scaledToFit().padding(side * 0.18)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            image = await ThumbnailCache.shared.image(for: url, side: side)
            failed = image == nil
        }
    }
}

/// Finder icon for a file or folder.
struct FileIconView: View {
    let url: URL
    var side: CGFloat = 28
    var body: some View {
        Image(nsImage: FileIcons.icon(for: url))
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
    }
}
