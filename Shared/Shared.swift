import Foundation
import SwiftUI
import Darwin

/// Paths shared by the app and the widget extension.
enum SharedPaths {
    /// The user's real home folder, even from inside the sandboxed widget
    /// (where `NSHomeDirectory()` points at the container).
    static let home: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    static let support = home.appendingPathComponent("Library/Application Support/Reclaim", isDirectory: true)
}

/// What the app last measured, written after each scan so the widget can show it.
struct ReclaimSnapshot: Codable, Equatable {
    var updated: Date = .now
    var lastScan: Date?
    var reclaimableBytes: Int64 = 0
    var accentHex: String = "#2F7CF6"
    var vividWidget: Bool = true

    static var url: URL { SharedPaths.support.appendingPathComponent("snapshot.json") }

    static func load() -> ReclaimSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReclaimSnapshot.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(at: SharedPaths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.url, options: .atomic)
        }
    }
}

/// Capacity of the startup volume.
struct VolumeStats: Equatable {
    var total: Int64
    var free: Int64
    var used: Int64 { max(0, total - free) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func startup() -> VolumeStats {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return VolumeStats(total: 0, free: 0) }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let free = important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0)
        return VolumeStats(total: total, free: free)
    }
}

enum ByteText {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
