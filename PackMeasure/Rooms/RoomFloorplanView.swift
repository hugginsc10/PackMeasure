import SwiftUI
import UIKit

/// Projects saved metric geometry without changing the underlying measurements.
struct FloorplanGeometry {
    let segments: [(start: CGPoint, end: CGPoint)]

    init(walls: [MeasuredRoom.Wall], size: CGSize) {
        let points = walls.flatMap { [$0.start, $0.end] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else {
            segments = []; return
        }
        let scale = max(0, min((size.width - 64) / CGFloat(max(0.1, maxX - minX)),
                              (size.height - 64) / CGFloat(max(0.1, maxY - minY))))
        func project(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: size.width / 2 + CGFloat(p.x - (minX + maxX) / 2) * scale,
                    y: size.height / 2 + CGFloat(p.y - (minY + maxY) / 2) * scale)
        }
        segments = walls.map { (project($0.start), project($0.end)) }
    }

    private init(segments: [(start: CGPoint, end: CGPoint)]) { self.segments = segments }

    func transformed(zoom: CGFloat, offset: CGPoint) -> FloorplanGeometry {
        func transform(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * zoom - offset.x, y: point.y * zoom - offset.y)
        }
        return FloorplanGeometry(segments: segments.map { (transform($0.start), transform($0.end)) })
    }

    func nearestWall(to point: CGPoint, tolerance: CGFloat) -> Int? {
        segments.indices.min(by: { distance(point, to: segments[$0]) < distance(point, to: segments[$1]) })
            .flatMap { distance(point, to: segments[$0]) <= tolerance ? $0 : nil }
    }

    private func distance(_ p: CGPoint, to line: (start: CGPoint, end: CGPoint)) -> CGFloat {
        let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
        let squared = dx * dx + dy * dy
        let t = squared > 0 ? min(1, max(0, ((p.x - line.start.x) * dx + (p.y - line.start.y) * dy) / squared)) : 0
        return hypot(p.x - line.start.x - t * dx, p.y - line.start.y - t * dy)
    }

    /// Constant screen-size badges, with selected wall taking precedence.
    func labels(zoom: CGFloat, selected: Int?) -> [(index: Int, rect: CGRect)] {
        let zoom = max(1, zoom)
        let order = segments.indices.sorted { a, b in
            if a == b { return false }
            if a == selected { return true }
            if b == selected { return false }
            return a < b
        }
        var result: [(index: Int, rect: CGRect)] = []
        for index in order {
            let line = segments[index]
            let width = CGFloat(String(index + 1).count * 9 + 14) / zoom
            let dx = line.end.x - line.start.x, dy = line.end.y - line.start.y
            let length = max(0.001, hypot(dx, dy))
            let rect = CGRect(x: (line.start.x + line.end.x) / 2 - dy / length * 26 / zoom - width / 2,
                              y: (line.start.y + line.end.y) / 2 + dx / length * 26 / zoom - 12 / zoom,
                              width: width, height: 24 / zoom)
            if !result.contains(where: { $0.rect.insetBy(dx: -4 / zoom, dy: -4 / zoom).intersects(rect) }) {
                result.append((index, rect))
            }
        }
        return result
    }
}

struct RoomFloorplanPreview: View {
    let walls: [MeasuredRoom.Wall]
    var body: some View {
        Canvas { context, size in
            for (index, line) in FloorplanGeometry(walls: walls, size: size).segments.enumerated() {
                var path = Path(); path.move(to: line.start); path.addLine(to: line.end)
                context.stroke(path, with: .color(walls[index].confidence == "low" ? .orange : MeasureStyle.accent), lineWidth: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

struct RoomFloorplanView: View {
    let room: MeasuredRoom
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?
    @State private var reset = 0
    @State private var zoomRequest = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    MeasureEyebrow(text: "Plan view")
                    Spacer()
                    Text("Pinch · Pan · Select").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 12)
                FloorplanScrollView(walls: room.walls, selected: $selected, reset: reset, zoomRequest: zoomRequest)
                    .clipped()
                    .accessibilityLabel("Interactive scanned floorplan")
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Button("Zoom out", systemImage: "minus.magnifyingglass") { zoomRequest -= 1 }
                            .labelStyle(.iconOnly)
                        Button("Zoom in", systemImage: "plus.magnifyingglass") { zoomRequest += 1 }
                            .labelStyle(.iconOnly)
                        Spacer()
                        Button("Fit floorplan") { reset += 1 }
                    }
                    .buttonStyle(.bordered)
                    HStack {
                        Menu {
                            ForEach(room.walls.indices, id: \.self) { index in
                                Button("Wall \(index + 1) — \(MeasuredRoom.dimension(room.walls[index].length))") { selected = index }
                            }
                        } label: {
                            Label(selected.map { "Wall \($0 + 1)" } ?? "Choose a wall", systemImage: "line.3.horizontal.decrease")
                        }
                        Spacer()
                        if !room.walls.isEmpty {
                            Button("Previous wall", systemImage: "chevron.left") { step(-1) }.labelStyle(.iconOnly)
                            Button("Next wall", systemImage: "chevron.right") { step(1) }.labelStyle(.iconOnly)
                        }
                    }
                    if let selected, room.walls.indices.contains(selected) {
                        let wall = room.walls[selected]
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) {
                                MeasureMetric(title: "Length", value: MeasuredRoom.dimension(wall.length))
                                MeasureMetric(title: "Height", value: MeasuredRoom.dimension(wall.height))
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                MeasureMetric(title: "Length", value: MeasuredRoom.dimension(wall.length))
                                MeasureMetric(title: "Height", value: MeasuredRoom.dimension(wall.height))
                            }
                        }
                        Text("\(wall.confidence.capitalized) capture confidence").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 16) {
                            MeasureMetric(title: "Length", value: "—")
                            MeasureMetric(title: "Height", value: "—")
                        }
                        Text("Select a wall to see its dimensions.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .background(MeasureStyle.panel, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            }
            .background(MeasureStyle.background)
            .navigationTitle("Floorplan").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }

            }
        }
    }

    private func step(_ delta: Int) {
        guard !room.walls.isEmpty else { return }
        selected = selected.map { ($0 + delta + room.walls.count) % room.walls.count } ?? 0
    }
}

private struct FloorplanScrollView: UIViewRepresentable {
    let walls: [MeasuredRoom.Wall]
    @Binding var selected: Int?
    let reset: Int
    let zoomRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> FloorplanScrollContainer {
        let view = FloorplanScrollContainer()
        view.delegate = context.coordinator
        view.drawing.walls = walls
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap); view.addGestureRecognizer(doubleTap)
        return view
    }
    func updateUIView(_ view: FloorplanScrollContainer, context: Context) {
        context.coordinator.parent = self
        view.drawing.selected = selected
        if view.reset != reset { view.reset = reset; view.fit() }
        if view.zoomRequest != zoomRequest {
            let factor: CGFloat = zoomRequest > view.zoomRequest ? 2 : 0.5
            view.zoomRequest = zoomRequest
            let scale = min(8, max(1, view.zoomScale * factor))
            let center = CGPoint(x: (view.contentOffset.x + view.bounds.width / 2) / view.zoomScale,
                                 y: (view.contentOffset.y + view.bounds.height / 2) / view.zoomScale)
            let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
            view.zoom(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                 width: size.width, height: size.height), animated: true)
        }
        view.drawing.setNeedsDisplay()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: FloorplanScrollView
        init(_ parent: FloorplanScrollView) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? FloorplanScrollContainer)?.plane }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let view = scrollView as? FloorplanScrollContainer else { return }
            view.refreshDrawing()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? FloorplanScrollContainer)?.refreshDrawing()
        }
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? FloorplanScrollContainer else { return }
            let point = gesture.location(in: view.drawing)
            let geometry = view.drawing.geometry
            parent.selected = geometry.labels(zoom: 1, selected: parent.selected)
                .first(where: { $0.rect.contains(point) })?.index
                ?? geometry.nearestWall(to: point, tolerance: 22)
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? FloorplanScrollContainer else { return }
            if view.zoomScale > 3 { view.setZoomScale(1, animated: true); return }
            let point = gesture.location(in: view.plane)
            let scale = min(8, view.zoomScale * 2)
            let size = CGSize(width: view.bounds.width / scale, height: view.bounds.height / scale)
            view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                 width: size.width, height: size.height), animated: true)
        }
    }
}

private final class FloorplanScrollContainer: UIScrollView {
    let plane = UIView()
    let drawing = FloorplanDrawing()
    var reset = 0
    var zoomRequest = 0
    private var viewport = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1; maximumZoomScale = 8
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        addSubview(plane)
        addSubview(drawing)
        drawing.isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != viewport, bounds.width > 0, bounds.height > 0 else { return }
        viewport = bounds.size
        setZoomScale(1, animated: false)
        plane.frame = CGRect(origin: .zero, size: viewport)
        contentSize = viewport
        contentOffset = .zero
        refreshDrawing()
    }
    // Draw in viewport coordinates so strokes and badges stay sharp at every zoom.
    func refreshDrawing() {
        drawing.frame = CGRect(origin: contentOffset, size: bounds.size)
        drawing.zoom = zoomScale
        drawing.offset = contentOffset
        drawing.setNeedsDisplay()
    }
    func fit() {
        setZoomScale(1, animated: false)
        contentOffset = .zero
    }
}

private final class FloorplanDrawing: UIView {
    var walls: [MeasuredRoom.Wall] = []
    var selected: Int?
    var zoom: CGFloat = 1
    var offset: CGPoint = .zero
    var geometry: FloorplanGeometry {
        FloorplanGeometry(walls: walls, size: bounds.size).transformed(zoom: zoom, offset: offset)
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        let geometry = geometry
        let dots = UIBezierPath()
        for x in stride(from: CGFloat(12), through: bounds.width, by: 28) {
            for y in stride(from: CGFloat(12), through: bounds.height, by: 28) {
                dots.append(UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 1, height: 1)))
            }
        }
        UIColor.white.withAlphaComponent(0.09).setFill(); dots.fill()
        for (index, line) in geometry.segments.enumerated() {
            let path = UIBezierPath(); path.move(to: line.start); path.addLine(to: line.end)
            let color: UIColor = index == selected ? UIColor(MeasureStyle.violet) : walls[index].confidence == "low" ? .systemOrange : UIColor(MeasureStyle.accent)
            color.setStroke(); path.lineWidth = (index == selected ? 6 : 3)
            path.lineCapStyle = .round; path.stroke()
        }
        for label in geometry.labels(zoom: 1, selected: selected) {
            if label.index == selected {
                UIColor(MeasureStyle.violet).setFill()
                UIBezierPath(roundedRect: label.rect, cornerRadius: 7).fill()
            }
            let text = "\(label.index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: label.index == selected ? UIColor(MeasureStyle.background) : UIColor.white
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: label.rect.midX - size.width / 2, y: label.rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
