import SwiftUI
import UIKit

struct RoomWireframeView: UIViewRepresentable {
    let walls: [MeasuredRoom.Wall]
    @Binding var selected: Int?
    let reset: Int
    let zoomRequest: Int
    let labelMode: FloorplanLabelMode
    var omittedWallIDs: Set<UUID> = []

    func makeUIView(context: Context) -> RoomWireframeDrawing { RoomWireframeDrawing() }

    func updateUIView(_ view: RoomWireframeDrawing, context: Context) {
        view.walls = walls
        view.omittedWallIDs = omittedWallIDs
        view.selected = selected
        view.labelMode = labelMode
        view.onSelect = { selected = $0 }
        if view.reset != reset { view.reset = reset; view.fit() }
        if view.zoomRequest != zoomRequest {
            view.zoom *= zoomRequest > view.zoomRequest ? 1.4 : 1 / 1.4
            view.zoomRequest = zoomRequest
            view.zoom = min(4, max(0.6, view.zoom))
        }
        view.setNeedsDisplay()
    }
}

final class RoomWireframeDrawing: UIView {
    var walls: [MeasuredRoom.Wall] = []
    var omittedWallIDs: Set<UUID> = []
    var selected: Int?
    var labelMode: FloorplanLabelMode = .lengths
    var onSelect: ((Int?) -> Void)?
    var reset = 0
    var zoomRequest = 0
    var zoom: CGFloat = 1
    private var yaw = RoomWireframeGeometry.initialYaw
    private var pitch = RoomWireframeGeometry.initialPitch
    private let font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    var geometry: RoomWireframeGeometry {
        RoomWireframeGeometry(walls: walls, size: bounds.size, yaw: yaw, pitch: pitch, zoom: zoom)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(rotate(_:))))
        addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectWall(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(restoreView))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
        isAccessibilityElement = true
        accessibilityLabel = "3D room outline"
        accessibilityHint = "Drag to rotate, pinch to zoom. Use Choose a wall below to hear individual dimensions."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Rotate left", target: self, selector: #selector(rotateLeft)),
            UIAccessibilityCustomAction(name: "Rotate right", target: self, selector: #selector(rotateRight)),
            UIAccessibilityCustomAction(name: "Fit room", target: self, selector: #selector(accessibleFit))
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func fit() {
        yaw = RoomWireframeGeometry.initialYaw
        pitch = RoomWireframeGeometry.initialPitch
        zoom = 1
        setNeedsDisplay()
    }

    @objc private func restoreView() { fit() }
    @objc private func accessibleFit() -> Bool { fit(); return true }
    @objc private func rotateLeft() -> Bool { yaw -= .pi / 8; setNeedsDisplay(); return true }
    @objc private func rotateRight() -> Bool { yaw += .pi / 8; setNeedsDisplay(); return true }

    @objc private func rotate(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: self)
        yaw += Float(delta.x) * 0.008
        pitch = min(1.15, max(0.15, pitch + Float(delta.y) * 0.006))
        gesture.setTranslation(.zero, in: self)
        setNeedsDisplay()
    }

    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        zoom = min(4, max(0.6, zoom * gesture.scale))
        gesture.scale = 1
        setNeedsDisplay()
    }

    @objc private func selectWall(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        let geometry = geometry
        let height = heightAnnotation(in: geometry)
        if let height, height.rect.contains(point) { onSelect?(height.index); return }
        onSelect?(labels(in: geometry, reserved: height?.rect).first { $0.rect.contains(point) }?.index
                  ?? geometry.nearestWall(to: point))
    }

    private func labelText(_ index: Int) -> String {
        labelMode == .lengths ? "\(index + 1) · \(labelMode.text(for: walls[index], index: index))" : "Wall \(index + 1)"
    }

    private func badgeSize(_ text: String) -> CGSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(size.width) + 14, height: 26)
    }

    private func labels(in geometry: RoomWireframeGeometry, reserved: CGRect?) -> [(index: Int, rect: CGRect, anchor: CGPoint)] {
        geometry.labels(sizes: walls.indices.map { badgeSize(labelText($0)) }, selected: selected,
                        viewport: bounds, avoiding: reserved)
    }

    private struct HeightAnnotation {
        let index: Int
        let bottom: CGPoint
        let top: CGPoint
        let rect: CGRect
        let text: String
    }

    private func heightAnnotation(in geometry: RoomWireframeGeometry) -> HeightAnnotation? {
        // The unselected ruler belongs to an actual tallest wall, not a guessed ceiling.
        let index = selected ?? walls.indices.filter { walls[$0].isValid && !omittedWallIDs.contains(walls[$0].id) }.max { walls[$0].height < walls[$1].height }
        guard let index, let face = geometry.faces.first(where: { $0.index == index }) else { return nil }
        let edge = face.corners[0].x > face.corners[1].x ? (0, 3) : (1, 2)
        let x = face.corners[edge.0].x + 16
        let bottom = CGPoint(x: x, y: face.corners[edge.0].y)
        let top = CGPoint(x: x, y: face.corners[edge.1].y)
        let text = String(format: "H %.1f ft", walls[index].height * 3.28084)
        let size = badgeSize(text)
        let rect = CGRect(x: min(bounds.maxX - size.width - 6, max(6, x + 6)),
                          y: min(bounds.maxY - size.height - 6, max(6, top.y - size.height / 2)),
                          width: size.width, height: size.height)
        return HeightAnnotation(index: index, bottom: bottom, top: top, rect: rect, text: text)
    }

    override func draw(_ rect: CGRect) {
        let geometry = geometry
        let dots = UIBezierPath()
        for x in stride(from: CGFloat(12), through: bounds.width, by: 28) {
            for y in stride(from: CGFloat(12), through: bounds.height, by: 28) {
                dots.append(UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 1, height: 1)))
            }
        }
        UIColor.white.withAlphaComponent(0.09).setFill(); dots.fill()
        for face in geometry.faces {
            let color = wallColor(face.index)
            let omitted = omittedWallIDs.contains(walls[face.index].id)
            let path = UIBezierPath()
            path.move(to: face.corners[0])
            face.corners.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            color.withAlphaComponent(omitted ? 0 : face.index == selected ? 0.13 : 0.025).setFill(); path.fill()
            if omitted { path.setLineDash([6, 5], count: 2, phase: 0) }
            color.withAlphaComponent(face.index == selected ? 1 : 0.65).setStroke()
            path.lineWidth = face.index == selected ? 3 : 1.5
            path.lineJoinStyle = .round; path.stroke()
            // Strong floor perimeter distinguishes the footprint from the wall tops.
            line(face.corners[0], face.corners[1], color: color, width: face.index == selected ? 4 : 2.5, dashed: omitted)
        }
        let height = heightAnnotation(in: geometry)
        if let height {
            let color = wallColor(height.index)
            line(height.bottom, height.top, color: color, width: 1)
            for p in [height.bottom, height.top] {
                line(CGPoint(x: p.x - 4, y: p.y), CGPoint(x: p.x + 4, y: p.y), color: color, width: 1)
            }
            badge(height.text, rect: height.rect, color: color)
        }
        for label in labels(in: geometry, reserved: height?.rect) {
            line(label.anchor, CGPoint(x: label.rect.midX, y: label.rect.midY),
                 color: wallColor(label.index).withAlphaComponent(0.5), width: 1)
            badge(labelText(label.index), rect: label.rect, color: wallColor(label.index))
        }
        accessibilityValue = "\(walls.count) captured walls. " + (selected.flatMap { index in
            walls.indices.contains(index) ? "Wall \(index + 1), length \(MeasuredRoom.dimension(walls[index].length)), height \(MeasuredRoom.dimension(walls[index].height))" : nil
        } ?? "Maximum captured wall height \(MeasuredRoom.dimension(walls.filter(\.isValid).map(\.height).max() ?? 0)).")
    }

    private func wallColor(_ index: Int) -> UIColor {
        omittedWallIDs.contains(walls[index].id) ? (index == selected ? .lightGray : .darkGray) : index == selected ? UIColor(MeasureStyle.violet) : walls[index].confidence == "low" ? .systemOrange : UIColor(MeasureStyle.accent)
    }

    private func line(_ start: CGPoint, _ end: CGPoint, color: UIColor, width: CGFloat, dashed: Bool = false) {
        let path = UIBezierPath(); path.move(to: start); path.addLine(to: end)
        if dashed { path.setLineDash([6, 5], count: 2, phase: 0) }
        color.setStroke(); path.lineWidth = width; path.stroke()
    }

    private func badge(_ text: String, rect: CGRect, color: UIColor) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 7)
        UIColor(MeasureStyle.background).withAlphaComponent(0.96).setFill(); path.fill()
        color.withAlphaComponent(0.6).setStroke(); path.lineWidth = 0.75; path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}
