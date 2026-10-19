import SwiftUI

/// Squarified treemap layout (Bruls, Huizing & van Wijk).
enum StorageMapLayout {
    /// One rectangle per value, in the same order. Values should be sorted descending and > 0.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max(0, $0) * scale }
        var remaining = rect
        var i = 0
        while i < areas.count {
            guard remaining.width > 0.5, remaining.height > 0.5 else { break }
            let side = Double(min(remaining.width, remaining.height))
            var j = i
            var rowSum = 0.0, rowMin = Double.infinity, rowMax = 0.0
            var worst = Double.infinity
            // Grow the row while it makes the worst aspect ratio better.
            while j < areas.count {
                let a = areas[j]
                guard a > 0 else { j += 1; continue }
                let s = rowSum + a, mn = min(rowMin, a), mx = max(rowMax, a)
                let ratio = max(side * side * mx / (s * s), (s * s) / (side * side * mn))
                if rowSum > 0, ratio > worst { break }
                worst = ratio; rowSum = s; rowMin = mn; rowMax = mx
                j += 1
            }
            guard rowSum > 0 else { break }
            if remaining.width >= remaining.height {
                // Vertical strip along the (shorter) left edge.
                let stripW = CGFloat(rowSum / Double(remaining.height))
                var y = remaining.minY
                for k in i..<j where areas[k] > 0 {
                    let h = CGFloat(areas[k]) / stripW
                    result[k] = CGRect(x: remaining.minX, y: y, width: stripW, height: h)
                    y += h
                }
                remaining = CGRect(x: remaining.minX + stripW, y: remaining.minY,
                                   width: max(0, remaining.width - stripW), height: remaining.height)
            } else {
                // Horizontal strip along the (shorter) top edge.
                let stripH = CGFloat(rowSum / Double(remaining.width))
                var x = remaining.minX
                for k in i..<j where areas[k] > 0 {
                    let w = CGFloat(areas[k]) / stripH
                    result[k] = CGRect(x: x, y: remaining.minY, width: w, height: stripH)
                    x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + stripH,
                                   width: remaining.width, height: max(0, remaining.height - stripH))
            }
            i = j
        }
        return result
    }
}

/// A laid-out tile of the current folder. `node` is nil for the merged overflow tile.
struct StorageMapTile: Identifiable {
    let id: String
    let node: MapNode?
    let name: String
    let size: Int64
    let rect: CGRect
    let color: Color
    /// Second-level preview of a folder's contents.
    var inner: [(rect: CGRect, color: Color)] = []
}

enum StorageMapPalette {
    static func color(for node: MapNode, index: Int) -> Color {
        if node.isAggregate { return Color(hue: 0, saturation: 0, brightness: 0.62) }
        if node.isDirectory {
            if node.isPackage || node.url.pathExtension.lowercased() == "app" {
                return Color(hue: 0.08, saturation: 0.42, brightness: 0.70)
            }
            let shades: [Double] = [0.80, 0.72, 0.86, 0.68, 0.76]
            return Color(hue: 0.60, saturation: 0.52, brightness: shades[index % shades.count])
        }
        return color(for: node.kind)
    }

    static func color(for kind: FS.Kind) -> Color {
        switch kind {
        case .video: return Color(hue: 0.77, saturation: 0.50, brightness: 0.78)
        case .audio: return Color(hue: 0.92, saturation: 0.48, brightness: 0.82)
        case .image: return Color(hue: 0.36, saturation: 0.48, brightness: 0.70)
        case .archive: return Color(hue: 0.07, saturation: 0.62, brightness: 0.88)
        case .diskImage: return Color(hue: 0.13, saturation: 0.62, brightness: 0.86)
        case .document: return Color(hue: 0.50, saturation: 0.48, brightness: 0.70)
        case .app: return Color(hue: 0.08, saturation: 0.42, brightness: 0.70)
        case .code: return Color(hue: 0.44, saturation: 0.45, brightness: 0.68)
        case .other: return Color(hue: 0.60, saturation: 0.08, brightness: 0.66)
        }
    }

    static func legend() -> [(String, Color)] {
        [("Folders", Color(hue: 0.60, saturation: 0.52, brightness: 0.80)),
         ("Apps & packages", color(for: .app)),
         ("Video", color(for: .video)), ("Audio", color(for: .audio)), ("Images", color(for: .image)),
         ("Archives", color(for: .archive)), ("Disk images", color(for: .diskImage)),
         ("Documents", color(for: .document)), ("Code", color(for: .code)), ("Other", color(for: .other))]
    }

    /// Builds the tiles for a folder: at most `limit` tiles, the rest merged.
    static func tiles(for folder: MapNode, in rect: CGRect, limit: Int = 300) -> [StorageMapTile] {
        let visible = folder.children.filter { $0.size > 0 }
        let shown = Array(visible.prefix(limit))
        let overflow = visible.dropFirst(limit)
        let overflowBytes = overflow.reduce(Int64(0)) { $0 + $1.size }
        var values = shown.map { Double($0.size) }
        if overflowBytes > 0 { values.append(Double(overflowBytes)) }
        let rects = StorageMapLayout.squarify(values, in: rect)

        var tiles: [StorageMapTile] = []
        for (i, node) in shown.enumerated() {
            let r = rects[i]
            guard r.width >= 1, r.height >= 1 else { continue }
            var tile = StorageMapTile(id: node.id, node: node, name: node.name, size: node.size, rect: r,
                                      color: color(for: node, index: i))
            if node.isDirectory, r.width > 90, r.height > 64 {
                let innerRect = CGRect(x: r.minX + 3, y: r.minY + 20, width: r.width - 6, height: r.height - 23)
                let kids = node.children.filter { $0.size > 0 }.prefix(40)
                let innerRects = StorageMapLayout.squarify(kids.map { Double($0.size) }, in: innerRect)
                tile.inner = zip(kids, innerRects).enumerated().compactMap { j, pair in
                    pair.1.width >= 2 && pair.1.height >= 2 ? (pair.1, color(for: pair.0, index: j + i + 1)) : nil
                }
            }
            tiles.append(tile)
        }
        if overflowBytes > 0, let r = rects.last, r.width >= 1, r.height >= 1 {
            tiles.append(StorageMapTile(id: folder.id + "#overflow", node: nil, name: "\(overflow.count.formatted()) more items",
                                        size: overflowBytes, rect: r, color: Color(hue: 0, saturation: 0, brightness: 0.62)))
        }
        return tiles
    }
}

/// The interactive treemap for the model's current folder.
struct StorageTreemapView: View {
    let model: StorageMapModel
    let folder: MapNode
    let onQuickLook: (URL) -> Void
    let onTrash: (MapNode) -> Void

    var body: some View {
        GeometryReader { geo in
            let _ = model.revision
            let tiles = StorageMapPalette.tiles(for: folder, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 1, dy: 1))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(tiles, in: &context)
                }
                ForEach(tiles) { tile in
                    hitArea(tile)
                }
            }
            .overlay {
                if tiles.isEmpty {
                    ContentUnavailableView("Nothing measurable here", systemImage: "square.dashed",
                                           description: Text("This folder is empty or everything in it is unreadable."))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func draw(_ tiles: [StorageMapTile], in context: inout GraphicsContext) {
        for tile in tiles {
            let r = tile.rect.insetBy(dx: 1, dy: 1)
            guard r.width > 0, r.height > 0 else { continue }
            let hovered = model.hoveredID == tile.id
            let collected = tile.node.map { model.isCollected($0) } ?? false
            let path = Path(roundedRect: r, cornerRadius: min(5, min(r.width, r.height) / 4))
            context.fill(path, with: .color(tile.color.opacity(hovered ? 1 : 0.88)))
            if hovered {
                context.fill(path, with: .color(.white.opacity(0.14)))
            }
            for inner in tile.inner {
                let ir = inner.rect.insetBy(dx: 0.75, dy: 0.75)
                guard ir.width > 0, ir.height > 0 else { continue }
                context.fill(Path(roundedRect: ir, cornerRadius: min(3, min(ir.width, ir.height) / 4)),
                             with: .color(inner.color.opacity(0.55)))
            }
            if collected {
                context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
            } else if hovered {
                context.stroke(path, with: .color(.white), lineWidth: 2)
            }
            drawLabel(tile, in: r, context: &context)
        }
    }

    private func drawLabel(_ tile: StorageMapTile, in r: CGRect, context: inout GraphicsContext) {
        let isFolder = tile.node?.isDirectory == true
        if isFolder, !tile.inner.isEmpty {
            // Folder header line above its preview.
            guard r.width > 50 else { return }
            let text = Text("\(tile.name)  \(Text(Fmt.bytes(tile.size)).foregroundStyle(.white.opacity(0.8)))")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
            context.draw(text, in: CGRect(x: r.minX + 6, y: r.minY + 3, width: r.width - 12, height: 15))
            return
        }
        guard r.width > 54, r.height > 30 else { return }
        let nameSize: CGFloat = r.width > 160 && r.height > 70 ? 13 : 11
        let name = Text(tile.name).font(.system(size: nameSize, weight: .semibold)).foregroundStyle(.white)
        let size = Text(Fmt.bytes(tile.size)).font(.system(size: nameSize - 1)).foregroundStyle(.white.opacity(0.85))
        let labelRect = r.insetBy(dx: 6, dy: 4)
        if r.height > 44 {
            context.draw(name, in: CGRect(x: labelRect.minX, y: labelRect.midY - nameSize - 1, width: labelRect.width, height: nameSize + 4))
            context.draw(size, in: CGRect(x: labelRect.minX, y: labelRect.midY + 2, width: labelRect.width, height: nameSize + 2))
        } else {
            context.draw(name, in: CGRect(x: labelRect.minX, y: labelRect.midY - (nameSize + 4) / 2, width: labelRect.width, height: nameSize + 4))
        }
    }

    @ViewBuilder
    private func hitArea(_ tile: StorageMapTile) -> some View {
        let r = tile.rect
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: max(1, r.width), height: max(1, r.height))
            .offset(x: r.minX, y: r.minY)
            .onHover { inside in
                if inside { model.hoveredID = tile.id } else if model.hoveredID == tile.id { model.hoveredID = nil }
            }
            .onTapGesture(count: 2) {
                if let node = tile.node {
                    if node.isDirectory { model.drill(into: node) } else if node.isActionable { onQuickLook(node.url) }
                }
            }
            .onTapGesture {
                if let node = tile.node, node.isDirectory { model.drill(into: node) }
            }
            .help(helpText(tile))
            .contextMenu {
                if let node = tile.node {
                    StorageMapActions(model: model, node: node, onQuickLook: onQuickLook, onTrash: onTrash)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(tile.name), \(Fmt.bytes(tile.size))")
            .accessibilityAddTraits(.isButton)
    }

    private func helpText(_ tile: StorageMapTile) -> String {
        guard let node = tile.node else { return "\(tile.name) — \(Fmt.bytes(tile.size))" }
        var parts = ["\(node.name) — \(Fmt.bytes(node.size))"]
        if node.isDirectory { parts.append(Fmt.count(node.fileCount, "file")) }
        if let share = node.parent.map({ $0.size > 0 ? Double(node.size) / Double($0.size) : 0 }) {
            parts.append("\(Fmt.percent(share)) of \(node.parent?.name ?? "folder")")
        }
        if node.isDirectory { parts.append("Click to open") } else if node.isActionable { parts.append("Right-click for actions") }
        return parts.joined(separator: " · ")
    }
}

/// Context-menu actions shared by tiles and list rows.
struct StorageMapActions: View {
    let model: StorageMapModel
    let node: MapNode
    let onQuickLook: (URL) -> Void
    let onTrash: (MapNode) -> Void

    var body: some View {
        if node.isAggregate {
            Text("Merged small items can't be acted on individually")
        } else {
            if node.isDirectory, !node.unreadable {
                Button("Open in Storage Map") { model.drill(into: node) }
            }
            Button("Open") { FS.open(node.url) }
            Button("Reveal in Finder") { FS.reveal([node.url]) }
            Button("Quick Look") { onQuickLook(node.url) }
            if node.isActionable {
                Divider()
                if model.isCollected(node) {
                    Button("Remove from Collector") { model.removeFromCollector(node) }
                } else {
                    Button("Add to Collector") { model.addToCollector(node) }
                }
                Button("Move to Trash…", role: .destructive) { onTrash(node) }
            }
        }
    }
}
