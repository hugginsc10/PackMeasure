import CoreGraphics
import simd

/// An orthographic view of the saved footprint extruded by each wall's height.
/// Saved scans contain no wall elevation, so every wall starts at a common floor.
/// Walls remain independent: gaps, recesses and differing heights are not repaired.
struct RoomWireframeGeometry {
    struct Face {
        let index: Int
        let corners: [CGPoint] // floor start/end, top end/start
        let depth: Float

        var edges: [(CGPoint, CGPoint)] {
            corners.indices.map { (corners[$0], corners[($0 + 1) % corners.count]) }
        }
    }

    let faces: [Face] // back to front
    static let initialYaw: Float = -.pi / 4
    static let initialPitch: Float = .pi / 7

    init(walls: [MeasuredRoom.Wall], size: CGSize,
         yaw: Float = initialYaw, pitch: Float = initialPitch, zoom: CGFloat = 1) {
        let valid = walls.enumerated().filter { $0.element.isValid }
        guard let reference = valid.max(by: { $0.element.length < $1.element.length })?.element,
              size.width > 0, size.height > 0 else { faces = []; return }
        let axis = simd_normalize(reference.end - reference.start)
        let across = SIMD2<Float>(-axis.y, axis.x)
        func local(_ point: SIMD2<Float>) -> SIMD2<Float> {
            let delta = point - reference.start
            return SIMD2(simd_dot(delta, axis), simd_dot(delta, across))
        }
        let points = valid.flatMap { [local($0.element.start), local($0.element.end)] }
        let low = points.reduce(points[0]) { simd_min($0, $1) }
        let high = points.reduce(points[0]) { simd_max($0, $1) }
        let center = (low + high) / 2
        let maxHeight = valid.map(\.element.height).max()!
        // A rotation-invariant bound keeps the room from breathing as it turns.
        let footprintDiameter = CGFloat(simd_length(high - low))
        let diameter = CGFloat(sqrt(simd_length_squared(high - low) + maxHeight * maxHeight))
        let scale = max(0, min((size.width - 112) / max(0.1, footprintDiameter),
                               (size.height - 96) / max(0.1, diameter))) * zoom
        func project(_ point: SIMD2<Float>, height: Float) -> (CGPoint, Float) {
            let p = local(point) - center
            let x = cos(yaw) * p.x - sin(yaw) * p.y
            let z = sin(yaw) * p.x + cos(yaw) * p.y
            let y = height - maxHeight / 2
            let vertical = sin(pitch) * z - cos(pitch) * y
            let depth = cos(pitch) * z + sin(pitch) * y
            return (CGPoint(x: size.width / 2 + CGFloat(x) * scale,
                            y: size.height / 2 + CGFloat(vertical) * scale), depth)
        }
        faces = valid.map { index, wall in
            let corners = [project(wall.start, height: 0), project(wall.end, height: 0),
                           project(wall.end, height: wall.height), project(wall.start, height: wall.height)]
            return Face(index: index, corners: corners.map(\.0), depth: corners.map(\.1).reduce(0, +) / 4)
        }.sorted { $0.depth < $1.depth }
    }

    func nearestWall(to point: CGPoint, tolerance: CGFloat = 22) -> Int? {
        // Prefer the frontmost wall when projected edges coincide.
        var best: (index: Int, distance: CGFloat)?
        for face in faces.reversed() {
            let distance = face.edges.map { Self.distance(point, from: $0.0, to: $0.1) }.min()!
            if distance <= tolerance && (best == nil || distance < best!.distance - 0.5) {
                best = (face.index, distance)
            }
        }
        return best?.index
    }

    static func distance(_ p: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let squared = dx * dx + dy * dy
        let t = squared > 0 ? min(1, max(0, ((p.x - start.x) * dx + (p.y - start.y) * dy) / squared)) : 0
        return hypot(p.x - start.x - t * dx, p.y - start.y - t * dy)
    }

    /// Stable-size labels anchored to the floor perimeter, keeping the selected wall first.
    func labels(sizes: [CGSize], selected: Int?, viewport: CGRect,
                avoiding reserved: CGRect? = nil) -> [(index: Int, rect: CGRect, anchor: CGPoint)] {
        let order = faces.sorted {
            if $0.index == selected { return $1.index != selected }
            if $1.index == selected { return false }
            return $0.index < $1.index
        }
        var result: [(index: Int, rect: CGRect, anchor: CGPoint)] = []
        for face in order where sizes.indices.contains(face.index) {
            let a = face.corners[0], b = face.corners[1]
            let anchor = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let size = sizes[face.index]
            // Sideways candidates keep narrow, nearly edge-on closets legible
            // without sending their length badges back to the wall tops.
            let sideways = size.width / 2 + 12
            let offsets: [CGPoint] = [CGPoint(x: 0, y: -24), CGPoint(x: 0, y: 24),
                                      CGPoint(x: -sideways, y: -24), CGPoint(x: sideways, y: -24),
                                      CGPoint(x: -sideways, y: 24), CGPoint(x: sideways, y: 24),
                                      CGPoint(x: 0, y: -58), CGPoint(x: 0, y: 58)]
            for offset in offsets {
                let rect = CGRect(x: anchor.x + offset.x - size.width / 2, y: anchor.y + offset.y - size.height / 2,
                                  width: size.width, height: size.height)
                guard viewport.insetBy(dx: 4, dy: 4).contains(rect),
                      reserved.map({ !$0.insetBy(dx: -4, dy: -4).intersects(rect) }) ?? true,
                      !result.contains(where: { $0.rect.insetBy(dx: -4, dy: -4).intersects(rect) }) else { continue }
                result.append((face.index, rect, anchor))
                break
            }
        }
        return result
    }
}
