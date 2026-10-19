import Foundation

/// Free space on the startup disk over time, sampled while Reclaim runs (at most once an hour).
@MainActor @Observable
final class SpaceHistory {
    static let shared = SpaceHistory()

    struct Sample: Codable, Identifiable, Hashable {
        var date: Date
        var free: Int64
        var total: Int64
        var id: Date { date }
    }

    private(set) var samples: [Sample] = []
    private var url: URL { SharedPaths.support.appendingPathComponent("space-history.json") }

    init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            samples = (try? decoder.decode([Sample].self, from: data)) ?? []
        }
    }

    /// Records the current reading if the last one is over an hour old (or `force`).
    func record(_ volume: VolumeStats, force: Bool = false) {
        guard volume.total > 0 else { return }
        if !force, let last = samples.last, Date().timeIntervalSince(last.date) < 3600 { return }
        samples.append(Sample(date: .now, free: volume.free, total: volume.total))
        let cutoff = Date().addingTimeInterval(-120 * 86_400)
        samples.removeAll { $0.date < cutoff }
        save()
    }

    /// One reading per day (the day's last) for the past `days` days.
    func daily(days: Int = 30) -> [Sample] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: .now)) ?? .distantPast
        var byDay: [Date: Sample] = [:]
        for s in samples where s.date >= start {
            byDay[cal.startOfDay(for: s.date)] = s
        }
        return byDay.keys.sorted().map { day in
            var s = byDay[day]!
            s.date = day
            return s
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: SharedPaths.support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(samples) { try? data.write(to: url, options: .atomic) }
    }
}
