import Foundation
import Vision
import ImageIO
import CoreGraphics
import CoreServices

/// One image or video found by Photo Clutter.
struct PhotoItem: Identifiable, Hashable, Sendable {
    let entry: FileEntry
    /// Capture date (EXIF), falling back to creation or modification date.
    let date: Date
    var pixelWidth = 0
    var pixelHeight = 0
    /// Variance of the Laplacian on a ~512 px greyscale thumbnail. Higher is sharper.
    var sharpness: Double?

    var id: String { entry.path }
    var pixels: Int { pixelWidth * pixelHeight }
    var sharpnessScore: Int? { sharpness.map(PhotoAnalysis.score(forVariance:)) }
}

/// Two photos close enough in time to compare, and how different they look.
struct PhotoPair: Hashable, Sendable {
    let a: String
    let b: String
    let distance: Float
}

struct PhotoScanResult {
    var photos: [PhotoItem] = []
    var screenshots: [PhotoItem] = []
    var recordings: [PhotoItem] = []
    var pairs: [PhotoPair] = []
}

/// How alike two photos must look to be grouped (Vision feature-print distance).
enum PhotoSensitivity: String, CaseIterable, Identifiable {
    case strict, normal, loose
    var id: String { rawValue }
    var label: String {
        switch self {
        case .strict: return "Strict"
        case .normal: return "Normal"
        case .loose: return "Loose"
        }
    }
    var help: String {
        switch self {
        case .strict: return "Only near-identical shots"
        case .normal: return "Bursts and retakes of the same moment"
        case .loose: return "Similar scenes, even with some movement"
        }
    }
    var threshold: Float {
        switch self {
        case .strict: return PhotoAnalysis.strictThreshold
        case .normal: return PhotoAnalysis.normalThreshold
        case .loose: return PhotoAnalysis.looseThreshold
        }
    }
}

enum PhotoAnalysis {
    // Feature-print (revision 2) distance thresholds. On sample photos, crops, exposure changes and
    // small shifts of the same shot measured 0.08–0.56; unrelated photos never came closer than 0.6.
    static let strictThreshold: Float = 0.25
    static let normalThreshold: Float = 0.40
    static let looseThreshold: Float = 0.55
    /// Below this Laplacian variance a camera photo counts as blurry.
    /// Calibrated on sample photos: sharp shots scored 69–5,451, a 3 px Gaussian blur ≤ 11.
    static let blurVariance: Double = 50
    /// Only photos taken this close together are compared.
    static let timeWindow: TimeInterval = 2 * 3600
    /// …and only this many neighbours in capture order.
    static let neighbourWindow = 16
    static let thumbnailSide = 512

    private static let projectFolders: Set<String> = ["node_modules", ".git", "Pods", "DerivedData", "build", ".build", "dist",
                                                      "vendor", "Runner", "xcuserdata", "site-packages", "__pycache__"]

    /// Icons and artwork inside code projects (Android mipmaps, asset catalogs, build output) aren't photo clutter.
    static func isProjectAsset(_ url: URL) -> Bool {
        url.pathComponents.contains { c in
            projectFolders.contains(c) || c.hasPrefix("mipmap-") || c.hasPrefix("drawable")
                || c.hasSuffix(".xcassets") || c.hasSuffix(".imageset") || c.hasSuffix(".appiconset") || c.hasSuffix(".iconset")
        }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp",
                                               "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2"]
    /// Formats cameras produce; only these are checked for blur (PNG/GIF are usually graphics).
    static let cameraExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    private static let screenshotPrefixes: [String] = [
        "screenshot", "screen shot", "cleanshot", "bildschirmfoto", "capture d'écran", "capture d'ecran",
        "captura de pantalla", "captura de tela", "captura de ecrã", "captura d'ecrã", "captura de ecra", "pantallazo",
        "schermafbeelding", "schermata", "istantanea", "zrzut ekranu", "снимок экрана", "скриншот", "знімок екрана",
        "スクリーンショット", "截屏", "屏幕快照", "屏幕截图", "螢幕快照", "螢幕截圖", "스크린샷", "skærmbillede",
        "skjermbilde", "skärmavbild", "näyttökuva", "kuvakaappaus", "ekran resmi", "ekran görüntüsü", "snímek obrazovky",
        "snímka obrazovky", "képernyőfotó", "képernyőkép", "captură de ecran", "στιγμιότυπο οθόνης", "צילום מסך",
        "لقطة شاشة", "ภาพหน้าจอ", "ảnh chụp màn hình", "tangkapan layar", "cuplikan layar", "snimka zaslona",
        "posnetek zaslona", "tangkapan skrin", "captura de pantalla", "स्क्रीनशॉट",
    ]

    private static let recordingPrefixes: [String] = [
        "screen recording", "cleanshot", "bildschirmaufnahme", "enregistrement de l'écran", "enregistrement de l'ecran",
        "enregistrement d'écran", "enregistrement de l", "registrazione schermo", "registrazione dello schermo",
        "nagranie z ekranu", "grabación de pantalla", "grabacion de pantalla", "gravação de ecrã", "gravação da tela",
        "schermopname", "snemanje zaslona", "perekaman layar", "rakaman skrin", "snimka zaslona", "запись экрана",
        "запис екрана", "画面収録", "录屏", "屏幕录制", "螢幕錄製", "화면 기록", "skærmoptagelse", "skjermopptak",
        "skärminspelning", "näytön tallennus", "ekran kaydı", "záznam obrazovky", "nahrávání obrazovky",
        "képernyőfelvétel", "înregistrare ecran", "εγγραφή οθόνης", "הקלטת מסך", "تسجيل الشاشة", "บันทึกหน้าจอ",
        "ghi màn hình", "bản ghi màn hình", "gravació de pantalla", "skjermopptak", "स्क्रीन रिकॉर्डिंग",
    ]

    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "\u{2018}", with: "'")
    }

    static func isScreenshotName(_ name: String) -> Bool {
        let n = normalized(name)
        return screenshotPrefixes.contains { n.hasPrefix($0) }
    }

    static func isScreenRecordingName(_ name: String) -> Bool {
        let n = normalized(name)
        return recordingPrefixes.contains { n.hasPrefix($0) }
    }

    /// Spotlight's own screen-capture flag, when the file is indexed.
    static func spotlightSaysScreenCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return false }
        guard let value: CFTypeRef = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) else { return false }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    static func score(forVariance v: Double) -> Int {
        min(100, max(0, Int((v.squareRoot() * 4).rounded())))
    }

    // MARK: Per-image analysis

    struct Analysis {
        var width = 0
        var height = 0
        var captureDate: Date?
        var screenshotMetadata = false
        var print: VNFeaturePrintObservation?
        var variance: Double?
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    static func analyze(_ url: URL, wantSharpness: Bool) -> Analysis? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            var a = Analysis()
            if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                a.width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                a.height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                if let s = exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? tiff?[kCGImagePropertyTIFFDateTime] as? String {
                    a.captureDate = exifFormatter.date(from: s)
                }
                if let comment = exif?[kCGImagePropertyExifUserComment] as? String,
                   comment.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Screenshot") == .orderedSame {
                    a.screenshotMetadata = true
                }
            }
            guard let thumb = thumbnail(source) else { return a }
            a.print = featurePrint(thumb)
            if wantSharpness { a.variance = laplacianVariance(thumb) }
            return a
        }
    }

    static func thumbnail(_ source: CGImageSource, maxPixel: Int = thumbnailSide) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary)
    }

    static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        return request.results?.first
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do {
            try a.computeDistance(&d, to: b)
        } catch {
            return nil
        }
        return d
    }

    /// Variance of the 4-neighbour Laplacian over an 8-bit greyscale render of `image`.
    static func laplacianVariance(_ image: CGImage) -> Double? {
        let w = image.width, h = image.height
        guard w >= 8, h >= 8 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return pixels.withUnsafeBufferPointer { p -> Double in
            var sum = 0.0
            var sumSq = 0.0
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let i = row + x
                    let v = Int(p[i - w]) + Int(p[i + w]) + Int(p[i - 1]) + Int(p[i + 1]) - 4 * Int(p[i])
                    let dv = Double(v)
                    sum += dv
                    sumSq += dv * dv
                }
            }
            let n = Double((w - 2) * (h - 2))
            let mean = sum / n
            return max(0, sumSq / n - mean * mean)
        }
    }

    // MARK: Whole scan

    private struct Candidate {
        let url: URL
        let values: URLResourceValues
        var entry: FileEntry {
            FileEntry(url: url, size: FS.allocated(values), modified: values.contentModificationDate,
                      created: values.creationDate, isDirectory: false)
        }
        var fallbackDate: Date { values.creationDate ?? values.contentModificationDate ?? .distantPast }
    }

    private struct Analysed {
        let item: PhotoItem
        let print: VNFeaturePrintObservation?
        let isScreenshot: Bool
    }

    /// Walks `roots`, analyses every photo and returns categories plus look-alike candidate pairs.
    /// Returns nil when cancelled.
    static func run(roots: [URL], progress: ProgressReporter) async -> PhotoScanResult? {
        var result = PhotoScanResult()
        var candidates: [Candidate] = []
        var found = 0
        progress.report("Looking for photos…", force: true)

        // 1. Walk (package contents such as Photos libraries are skipped).
        FS.walkFiles(roots) { url, values in
            if isProjectAsset(url) { return true }
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent
            if imageExtensions.contains(ext) {
                found += 1
                let c = Candidate(url: url, values: values)
                if isScreenshotName(name) {
                    result.screenshots.append(PhotoItem(entry: c.entry, date: c.fallbackDate))
                } else {
                    candidates.append(c)
                }
            } else if videoExtensions.contains(ext) {
                let c = Candidate(url: url, values: values)
                if isScreenRecordingName(name) || (ext == "mov" && spotlightSaysScreenCapture(url)) {
                    found += 1
                    result.recordings.append(PhotoItem(entry: c.entry, date: c.fallbackDate))
                }
            }
            progress.report("Looking for photos… \(found.formatted()) found")
            return true
        }
        if Task.isCancelled { return nil }

        // 2. Analyse with bounded concurrency.
        let total = candidates.count
        let limit = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
        var analysed: [Analysed] = []
        analysed.reserveCapacity(total)
        var done = 0
        await withTaskGroup(of: Analysed?.self) { group in
            var iterator = candidates.makeIterator()
            func addNext() -> Bool {
                guard let c = iterator.next() else { return false }
                group.addTask(priority: .utility) {
                    if Task.isCancelled { return nil }
                    return analyseOne(c)
                }
                return true
            }
            for _ in 0..<limit { if !addNext() { break } }
            while let next = await group.next() {
                done += 1
                if let next { analysed.append(next) }
                progress.report("Analysing photos \(done.formatted()) of \(total.formatted())")
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                _ = addNext()
            }
        }
        if Task.isCancelled { return nil }

        // 3. Sort into screenshots and photos.
        var printsByID: [String: VNFeaturePrintObservation] = [:]
        for a in analysed {
            if a.isScreenshot {
                result.screenshots.append(a.item)
            } else {
                result.photos.append(a.item)
                if let p = a.print { printsByID[a.item.id] = p }
            }
        }

        // 4. Compare neighbours in capture order.
        progress.report("Comparing look-alikes…", force: true)
        let ordered = result.photos.filter { printsByID[$0.id] != nil }.sorted { $0.date < $1.date }
        for i in ordered.indices {
            if i & 63 == 0, Task.isCancelled { return nil }
            guard let pi = printsByID[ordered[i].id] else { continue }
            var j = i + 1
            while j < ordered.count, j <= i + neighbourWindow {
                if ordered[j].date.timeIntervalSince(ordered[i].date) > timeWindow { break }
                if let pj = printsByID[ordered[j].id], let d = distance(pi, pj), d <= looseThreshold {
                    result.pairs.append(PhotoPair(a: ordered[i].id, b: ordered[j].id, distance: d))
                }
                j += 1
            }
        }
        result.screenshots.sort { $0.date < $1.date }
        result.recordings.sort { $0.date < $1.date }
        return result
    }

    private static func analyseOne(_ c: Candidate) -> Analysed? {
        let ext = c.url.pathExtension.lowercased()
        guard let a = analyze(c.url, wantSharpness: cameraExtensions.contains(ext)) else { return nil }
        // Skip icons and tiny graphics.
        guard a.width == 0 || min(a.width, a.height) >= 200 else { return nil }
        let isScreenshot = a.screenshotMetadata || ((ext == "png" || ext == "heic" || ext == "jpg") && spotlightSaysScreenCapture(c.url))
        let item = PhotoItem(entry: c.entry, date: a.captureDate ?? c.fallbackDate, pixelWidth: a.width, pixelHeight: a.height,
                             sharpness: isScreenshot ? nil : a.variance)
        return Analysed(item: item, print: isScreenshot ? nil : a.print, isScreenshot: isScreenshot)
    }

    // MARK: Grouping

    /// Union-find over pairs within `threshold`. Groups are sorted by capture date.
    static func lookalikeGroups(photos: [PhotoItem], pairs: [PhotoPair], threshold: Float) -> [[PhotoItem]] {
        var index: [String: Int] = [:]
        for (i, p) in photos.enumerated() { index[p.id] = i }
        var parent = Array(photos.indices)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for pair in pairs where pair.distance <= threshold {
            guard let a = index[pair.a], let b = index[pair.b] else { continue }
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var buckets: [Int: [PhotoItem]] = [:]
        for i in photos.indices { buckets[find(i), default: []].append(photos[i]) }
        return buckets.values.filter { $0.count > 1 }.map { $0.sorted { $0.date < $1.date } }
    }

    /// The copy worth keeping: sharpest, then highest resolution, then largest file.
    static func bestKeeper(_ items: [PhotoItem]) -> PhotoItem? {
        items.max { a, b in
            (a.sharpness ?? 0, a.pixels, a.entry.size) < (b.sharpness ?? 0, b.pixels, b.entry.size)
        }
    }
}
