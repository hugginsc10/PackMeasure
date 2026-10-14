import Foundation
import simd

/// A seeded floor component, bounded only by observed raised surfaces. Unknown depth
/// and image edges are never interpreted as walls. No rectangle or convex-hull fitting.
enum InteriorCornerDetector {
    enum Failure: Error, LocalizedError {
        case incomplete, small, complex
        var errorDescription: String? {
            switch self {
            case .incomplete: "Show the whole drawer from above with good depth on every edge, or use manual points."
            case .small: "Aim at the middle of a clear, level drawer floor."
            case .complex: "The boundary is too uncertain. Change your view or use manual points."
            }
        }
    }
    struct Pixel: Hashable { var x: Int; var y: Int }

    /// `surface` contains high-confidence world samples, nil for unknown pixels.
    /// `project` intersects a pixel-edge ray with the seeded horizontal floor.
    static func detect(width: Int, height: Int, surface: [SIMD3<Float>?], seed: Int,
                       project: (Float, Float) -> SIMD3<Float>?) throws -> [[SIMD3<Float>]] {
        guard width > 2, height > 2, surface.count == width * height,
              surface.indices.contains(seed), let origin = surface[seed] else { throw Failure.small }
        func isFloor(_ i: Int) -> Bool {
            guard let p = surface[i] else { return false }
            return abs(p.y - origin.y) <= 0.008 && simd_distance(p, origin) < 1.5
        }
        var component: Set<Int> = [seed], queue = [seed], cursor = 0
        while cursor < queue.count {
            let i = queue[cursor]; cursor += 1
            let x = i % width, y = i / width
            guard x > 0, y > 0, x < width - 1, y < height - 1 else { throw Failure.incomplete }
            for n in [i-1, i+1, i-width, i+width] {
                if isFloor(n), component.insert(n).inserted { queue.append(n) }
            }
        }
        guard component.count >= 40 else { throw Failure.small }
        var next: [Pixel: Pixel] = [:]
        func edge(_ a: Pixel, _ b: Pixel, neighbor: Int) throws {
            // A depth hole, drop-off, or distant background cannot close a drawer.
            guard let p = surface[neighbor], p.y > origin.y + 0.008,
                  p.y < origin.y + 0.5, simd_distance(p, origin) < 1.5 else { throw Failure.incomplete }
            guard next[a] == nil else { throw Failure.complex }
            next[a] = b
        }
        for i in component {
            let x = i % width, y = i / width
            if !component.contains(i-width) { try edge(.init(x:x,y:y), .init(x:x+1,y:y), neighbor:i-width) }
            if !component.contains(i+1) { try edge(.init(x:x+1,y:y), .init(x:x+1,y:y+1), neighbor:i+1) }
            if !component.contains(i+width) { try edge(.init(x:x+1,y:y+1), .init(x:x,y:y+1), neighbor:i+width) }
            if !component.contains(i-1) { try edge(.init(x:x,y:y+1), .init(x:x,y:y), neighbor:i-1) }
        }
        var loops: [[SIMD3<Float>]] = []
        while let start = next.keys.min(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            var pixel = start, loop: [SIMD3<Float>] = []
            repeat {
                guard let end = next.removeValue(forKey: pixel),
                      let p = project(Float(pixel.x), Float(pixel.y)),
                      p.x.isFinite, p.y.isFinite, p.z.isFinite else { throw Failure.complex }
                loop.append(p); pixel = end
            } while pixel != start
            loops.append(simplify(loop))
            guard loops.count <= 20 else { throw Failure.complex }
        }
        func points(_ loop: [SIMD3<Float>]) -> [InteriorPoint] {
            loop.map { .init(x: Double($0.x) * 1000, y: Double($0.z) * 1000) }
        }
        loops.sort { abs(InteriorGeometry.area(points($0))) > abs(InteriorGeometry.area(points($1))) }
        try InteriorGeometry.validate(loops.map(points))
        guard let outer = loops.first, outer.count >= 3 else { throw Failure.small }
        return loops
    }

    /// Closed RDP, split at the farthest vertex so a closed ring is not reduced to a point.
    static func simplify(_ ring: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard ring.count > 3 else { return ring }
        func line(_ p: [SIMD3<Float>]) -> [SIMD3<Float>] {
            guard p.count > 2 else { return p }
            let a = p[0], b = p[p.count-1], d = b-a
            var best: Float = 0, index = 0
            for i in 1..<(p.count-1) {
                let t = max(0, min(1, simd_dot(p[i]-a, d) / max(simd_length_squared(d), 1e-12)))
                let distance = simd_distance(p[i], a+t*d)
                if distance > best { best = distance; index = i }
            }
            if best <= 0.003 { return [a,b] }
            return Array(line(Array(p[...index])).dropLast()) + line(Array(p[index...]))
        }
        let split = ring.indices.max { simd_distance(ring[$0], ring[0]) < simd_distance(ring[$1], ring[0]) }!
        return Array(line(Array(ring[...split])).dropLast()) + Array(line(Array(ring[split...]) + [ring[0]]).dropLast())
    }
}
