import WidgetKit
import SwiftUI

@main
struct ReclaimWidgetBundle: WidgetBundle {
    var body: some Widget {
        StorageWidget()
    }
}

struct StorageEntry: TimelineEntry {
    let date: Date
    let volume: VolumeStats
    let snapshot: ReclaimSnapshot

    var accent: Color { Color(hex: snapshot.accentHex) }

    static var preview: StorageEntry {
        var s = ReclaimSnapshot()
        s.lastScan = .now.addingTimeInterval(-3600)
        s.reclaimableBytes = 12_400_000_000
        return StorageEntry(date: .now, volume: VolumeStats(total: 494_000_000_000, free: 128_000_000_000), snapshot: s)
    }
}

struct StorageProvider: TimelineProvider {
    func placeholder(in context: Context) -> StorageEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (StorageEntry) -> Void) {
        completion(context.isPreview ? .preview : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StorageEntry>) -> Void) {
        let next = Date().addingTimeInterval(20 * 60)
        completion(Timeline(entries: [current()], policy: .after(next)))
    }

    private func current() -> StorageEntry {
        StorageEntry(date: .now, volume: VolumeStats.startup(), snapshot: ReclaimSnapshot.load() ?? ReclaimSnapshot())
    }
}

struct StorageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReclaimStorage", provider: StorageProvider()) { entry in
            StorageWidgetView(entry: entry)
        }
        .configurationDisplayName("Reclaim")
        .description("Free space, what the last scan found, and a one-click Smart Scan.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct StorageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StorageEntry

    private var vivid: Bool { entry.snapshot.vividWidget }
    private var primary: Color { vivid ? .white : .primary }
    private var secondary: Color { vivid ? .white.opacity(0.75) : .secondary }

    var body: some View {
        Group {
            if family == .systemMedium { medium } else { small }
        }
        .containerBackground(for: .widget) {
            if vivid {
                LinearGradient(colors: [entry.accent, entry.accent.mix(with: .black, by: 0.35)], startPoint: .top, endPoint: .bottom)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .widgetURL(URL(string: "reclaim://home"))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "internaldrive").font(.caption.weight(.semibold))
                Text("Macintosh HD").font(.caption.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(secondary)
            Spacer(minLength: 0)
            ring(size: 58)
            Spacer(minLength: 0)
            reclaimLine.font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            ring(size: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text("Macintosh HD").font(.caption.weight(.semibold)).foregroundStyle(secondary)
                Text("\(ByteText.string(entry.volume.free)) free").font(.title3.weight(.bold)).foregroundStyle(primary)
                    .minimumScaleFactor(0.7).lineLimit(1)
                Text("of \(ByteText.string(entry.volume.total))").font(.caption).foregroundStyle(secondary)
                reclaimLine.font(.caption)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Link(destination: URL(string: "reclaim://scan")!) {
                        Label("Scan", systemImage: "sparkle.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(vivid ? Color.white.opacity(0.22) : entry.accent.opacity(0.18)))
                            .foregroundStyle(vivid ? Color.white : entry.accent)
                    }
                    Link(destination: URL(string: "reclaim://guided")!) {
                        Text("Review").font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().strokeBorder(vivid ? Color.white.opacity(0.4) : entry.accent.opacity(0.4)))
                            .foregroundStyle(vivid ? Color.white : entry.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var reclaimLine: some View {
        Group {
            if entry.snapshot.lastScan != nil {
                if entry.snapshot.reclaimableBytes > 0 {
                    Text("\(ByteText.string(entry.snapshot.reclaimableBytes)) to review")
                } else {
                    Text("Nothing to reclaim")
                }
            } else {
                Text("Not scanned yet")
            }
        }
        .foregroundStyle(secondary)
        .lineLimit(1)
    }

    private func ring(size: CGFloat) -> some View {
        let used = entry.volume.usedFraction
        return ZStack {
            Circle().stroke(vivid ? Color.white.opacity(0.22) : Color.secondary.opacity(0.18), lineWidth: size * 0.12)
            Circle()
                .trim(from: 0, to: used)
                .stroke(vivid ? Color.white : entry.accent, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((used * 100).rounded()))%").font(.system(size: size * 0.24, weight: .bold, design: .rounded)).foregroundStyle(primary)
                Text("used").font(.system(size: size * 0.12)).foregroundStyle(secondary)
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview(as: .systemMedium) {
    StorageWidget()
} timeline: {
    StorageEntry.preview
}
