import Foundation
import simd

struct InteriorPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    static func + (a: Self, b: Self) -> Self { .init(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: Self, b: Double) -> Self { .init(x: a.x * b, y: a.y * b) }
    var length: Double { hypot(x, y) }
}

struct InteriorMeasurement: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = "Drawer interior"
    var capturedAt = Date()
    /// Millimeters. Outer perimeter first; remaining loops are excluded obstacles.
    var contours: [[InteriorPoint]]
    var heightMM: Double
    var sideClearanceMM: Double = 2
    var topClearanceMM: Double = 2

    func insertContours() throws -> [[InteriorPoint]] {
        guard heightMM.isFinite, topClearanceMM.isFinite,
              heightMM > topClearanceMM, topClearanceMM >= 0 else {
            throw InteriorGeometryError.invalidHeight
        }
        return try InteriorGeometry.inset(contours, clearance: sideClearanceMM)
    }

    func svg() throws -> String {
        let loops = try insertContours()
        let points = loops.flatMap { $0 }
        let minX = points.map(\.x).min()!, minY = points.map(\.y).min()!
        let width = points.map(\.x).max()! - minX
        let depth = points.map(\.y).max()! - minY
        func number(_ n: Double) -> String {
            String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), n)
        }
        let path = loops.map { loop in
            loop.enumerated().map { index, p in
                "\(index == 0 ? "M" : "L")\(number(p.x - minX)),\(number(p.y - minY))"
            }.joined(separator: " ") + " Z"
        }.joined(separator: " ")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(number(width))mm" height="\(number(depth))mm" viewBox="0 0 \(number(width)) \(number(depth))">
        <title>Interior insert footprint — verify before printing</title>
        <desc>Units: mm. Draft extrusion height: \(number(heightMM - topClearanceMM)) mm. Side clearance: \(number(sideClearanceMM)) mm. LiDAR dimensions are estimates; verify narrowest dimensions, obstacles and closed-drawer clearance with physical measurements.</desc>
        <path d="\(path)" fill="black" fill-rule="evenodd"/>
        </svg>
        """
    }
}

enum InteriorGeometryError: Error, LocalizedError {
    case invalidOutline, invalidHeight, invalidClearance, nonPlanar, heightPoint
    var errorDescription: String? {
        switch self {
        case .invalidOutline: "Trace at least three distinct points in order around each boundary. Outlines must not cross or touch; obstacles must stay inside the outer perimeter."
        case .invalidHeight: "Usable height must be positive and greater than the top clearance."
        case .invalidClearance: "This clearance collapses or crosses part of the outline. Reduce clearance or retrace the narrow section."
        case .nonPlanar: "The perimeter points are not on one level floor. Retake points on the drawer floor, not the rim."
        case .heightPoint: "Aim directly above point 1, at the lowest usable top edge. Height must be 10–1,000 mm."
        }
    }
}

/// Piecewise-linear, level footprints, including concavities and disjoint holes.
/// Offsets that split, collapse, or self-intersect are rejected, never repaired silently.
enum InteriorGeometry {
    static func cross(_ a: InteriorPoint, _ b: InteriorPoint) -> Double { a.x * b.y - a.y * b.x }
    static func area(_ loop: [InteriorPoint]) -> Double {
        loop.indices.reduce(0) { $0 + cross(loop[$1], loop[($1 + 1) % loop.count]) } / 2
    }
    static func edges(_ loop: [InteriorPoint]) -> [(InteriorPoint, InteriorPoint)] {
        loop.indices.map { (loop[$0], loop[($0 + 1) % loop.count]) }
    }
    static func distance(_ p: InteriorPoint, _ a: InteriorPoint, _ b: InteriorPoint) -> Double {
        let d = b - a, v = p - a
        let t = max(0, min(1, (v.x * d.x + v.y * d.y) / (d.x * d.x + d.y * d.y)))
        return (p - (a + d * t)).length
    }
    static func intersects(_ a: InteriorPoint, _ b: InteriorPoint, _ c: InteriorPoint, _ d: InteriorPoint) -> Bool {
        if min(distance(a, c, d), distance(b, c, d), distance(c, a, b), distance(d, a, b)) < 0.001 { return true }
        return cross(b - a, c - a) * cross(b - a, d - a) < 0
            && cross(d - c, a - c) * cross(d - c, b - c) < 0
    }
    static func contains(_ p: InteriorPoint, in loop: [InteriorPoint]) -> Bool {
        var inside = false
        for (a, b) in edges(loop) where (a.y > p.y) != (b.y > p.y) {
            if p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
    static func validate(_ loops: [[InteriorPoint]]) throws {
        guard !loops.isEmpty, loops.count <= 20 else { throw InteriorGeometryError.invalidOutline }
        for loop in loops {
            guard (3...200).contains(loop.count), loop.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  abs(area(loop)) > 1 else { throw InteriorGeometryError.invalidOutline }
            let e = edges(loop)
            for i in e.indices {
                guard (e[i].1 - e[i].0).length >= 1 else { throw InteriorGeometryError.invalidOutline }
                // Adjacent edges must not double back on one another.
                let previous = loop[(i + loop.count - 1) % loop.count] - loop[i]
                let next = loop[(i + 1) % loop.count] - loop[i]
                if abs(cross(previous, next)) < 0.001 && previous.x * next.x + previous.y * next.y > 0 {
                    throw InteriorGeometryError.invalidOutline
                }
                for j in e.indices where j > i + 1 && !(i == 0 && j == e.count - 1) {
                    if intersects(e[i].0, e[i].1, e[j].0, e[j].1) { throw InteriorGeometryError.invalidOutline }
                }
            }
        }
        for i in loops.indices {
            for j in loops.indices where j > i {
                for (a, b) in edges(loops[i]) {
                    for (c, d) in edges(loops[j]) where intersects(a, b, c, d) {
                        throw InteriorGeometryError.invalidOutline
                    }
                }
                if i > 0 && (contains(loops[i][0], in: loops[j]) || contains(loops[j][0], in: loops[i])) {
                    throw InteriorGeometryError.invalidOutline
                }
            }
            if i > 0 && !contains(loops[i][0], in: loops[0]) { throw InteriorGeometryError.invalidOutline }
        }
    }
    static func inset(_ input: [[InteriorPoint]], clearance: Double) throws -> [[InteriorPoint]] {
        try validate(input)
        guard clearance.isFinite, clearance >= 0 else { throw InteriorGeometryError.invalidClearance }
        // CCW exterior, CW holes: left is always usable interior.
        let loops = input.enumerated().map { i, loop in
            (area(loop) > 0) == (i == 0) ? loop : Array(loop.reversed())
        }
        if clearance == 0 { return loops }
        let output = try loops.map { loop in
            try loop.indices.map { i -> InteriorPoint in
                let p = loop[i], before = loop[(i + loop.count - 1) % loop.count], after = loop[(i + 1) % loop.count]
                let a = (p - before) * (1 / (p - before).length)
                let b = (after - p) * (1 / (after - p).length)
                let n1 = InteriorPoint(x: -a.y, y: a.x), n2 = InteriorPoint(x: -b.y, y: b.x)
                let origin1 = p + n1 * clearance, origin2 = p + n2 * clearance
                let denominator = cross(a, b)
                if abs(denominator) < 1e-8 {
                    guard a.x * b.x + a.y * b.y > 0 else { throw InteriorGeometryError.invalidClearance }
                    return origin1
                }
                return origin1 + a * (cross(origin2 - origin1, b) / denominator)
            }
        }
        do { try validate(output) } catch { throw InteriorGeometryError.invalidClearance }
        for i in output.indices {
            guard (area(output[i]) > 0) == (area(loops[i]) > 0) else { throw InteriorGeometryError.invalidClearance }
            for (a, b) in edges(output[i]) {
                for p in [a, (a + b) * 0.5] {
                    guard contains(p, in: loops[0]), !loops.dropFirst().contains(where: { contains(p, in: $0) }) else {
                        throw InteriorGeometryError.invalidClearance
                    }
                }
                for boundary in loops {
                    for (c, d) in edges(boundary) {
                        let separation = min(distance(a, c, d), distance(b, c, d), distance(c, a, b), distance(d, a, b))
                        guard !intersects(a, b, c, d), separation >= clearance - 0.001 else {
                            throw InteriorGeometryError.invalidClearance
                        }
                    }
                }
            }
        }
        return output
    }

    static func project(_ worldLoops: [[SIMD3<Float>]], heightPoint: SIMD3<Float>) throws -> InteriorMeasurement {
        guard let first = worldLoops.first, first.count >= 3,
              worldLoops.flatMap({ $0 }).allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              heightPoint.x.isFinite, heightPoint.y.isFinite, heightPoint.z.isFinite else {
            throw InteriorGeometryError.invalidOutline
        }
        let origin = first[0]
        guard worldLoops.flatMap({ $0 }).allSatisfy({ abs($0.y - origin.y) <= 0.008 }) else {
            throw InteriorGeometryError.nonPlanar
        }
        let horizontal = SIMD2<Float>(first[1].x - origin.x, first[1].z - origin.z)
        guard simd_length(horizontal) >= 0.01 else { throw InteriorGeometryError.invalidOutline }
        let xAxis = simd_normalize(horizontal), yAxis = SIMD2<Float>(-xAxis.y, xAxis.x)
        let height = Double(heightPoint.y - origin.y) * 1000
        guard (10...1000).contains(height), simd_length(SIMD2<Float>(heightPoint.x - origin.x, heightPoint.z - origin.z)) <= 0.03 else {
            throw InteriorGeometryError.heightPoint
        }
        let contours = worldLoops.map { loop in
            loop.map { p in
                let delta = SIMD2<Float>(p.x - origin.x, p.z - origin.z)
                return InteriorPoint(x: Double(simd_dot(delta, xAxis)) * 1000, y: Double(simd_dot(delta, yAxis)) * 1000)
            }
        }
        try validate(contours)
        return InteriorMeasurement(contours: contours, heightMM: height)
    }
}

struct InteriorStore {
    var url: URL = URL.applicationSupportDirectory.appending(path: "PackMeasure/interiors.json")
    func load() throws -> [InteriorMeasurement] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([InteriorMeasurement].self, from: Data(contentsOf: url))
    }
    func save(_ records: [InteriorMeasurement]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: url, options: .atomic)
    }
}
