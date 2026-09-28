import Foundation
import simd

/// Geometry-only keyframes. No camera photographs are retained in diagnostics.
struct InteriorSweepObservation: Codable, Sendable {
    var timestamp: TimeInterval
    var camera: SIMD3<Float>
    var forward: SIMD3<Float>
    var floor: [SIMD2<Float>]
    var walls: [SIMD2<Float>]
    var front: [SIMD2<Float>]
    var overhead: [SIMD3<Float>]
}

struct InteriorSweepResult: Sendable {
    var loops: [[SIMD3<Float>]] = []
    var height: Float?
    var coverage: [SIMD3<Float>] = []
    var hint = "Sweep slowly across the base, sides and front edge."
    var views = 0
    var boundaryCount = 0
    var ready: Bool { !loops.isEmpty && views >= 3 }
}

/// A bounded map of observed floor and boundary samples, shared across camera views.
/// The raster only orders edges; dimensions come from supported fitted lines.
/// Unobserved borders never become walls, and no rectangular/convex hull is imposed.
struct InteriorSweep: Sendable {
    let seed: SIMD3<Float>
    private(set) var observations: [InteriorSweepObservation] = []
    private(set) var rejectedViews = 0
    static let cell: Float = 0.008
    static let radius: Float = 1.2

    struct Cell: Hashable, Sendable {
        var x: Int; var y: Int
        var neighbors: [Cell] { [.init(x:x-1,y:y), .init(x:x+1,y:y), .init(x:x,y:y-1), .init(x:x,y:y+1)] }
    }
    struct Sample { var p: SIMD2<Float>; var view: Int }
    struct Line {
        var normal: SIMD2<Float>; var offset: Float
        var low: Float; var high: Float
        var tangent: SIMD2<Float> { [normal.y, -normal.x] }
        func distance(_ p: SIMD2<Float>) -> Float { abs(simd_dot(normal, p) - offset) }
        func supports(_ p: SIMD2<Float>, margin: Float = 0.028) -> Bool {
            let t = simd_dot(tangent, p)
            return distance(p) <= margin && t >= low - margin && t <= high + margin
        }
    }

    mutating func add(_ observation: InteriorSweepObservation) -> InteriorSweepResult {
        guard observation.timestamp.isFinite, finite(observation.camera), finite(observation.forward),
              observation.floor.allSatisfy(finite), observation.walls.allSatisfy(finite),
              observation.front.allSatisfy(finite), observation.overhead.allSatisfy(finite) else {
            rejectedViews += 1; return reconstruct()
        }
        if let last = observations.last {
            guard observation.timestamp > last.timestamp,
                  observation.timestamp - last.timestamp >= 0.18 else { rejectedViews += 1; return reconstruct() }
            // A stationary stream must not count as independent geometric evidence.
            let moved = simd_distance(observation.camera, last.camera) >= 0.018
            let turned = simd_dot(simd_normalize(observation.forward), simd_normalize(last.forward)) < 0.9986
            guard moved || turned else { rejectedViews += 1; return reconstruct() }
        }
        guard observations.count < 40 else {
            var result = reconstruct()
            if !result.ready { result.hint = "Some edges are still hidden. Choose the base again from a clearer angle." }
            return result
        }
        func local(_ p: SIMD2<Float>) -> Bool { simd_distance(p, SIMD2(seed.x, seed.z)) <= Self.radius }
        func compact(_ points: [SIMD2<Float>], limit: Int) -> [SIMD2<Float>] {
            var seen=Set<Cell>(), result=[SIMD2<Float>]()
            for p in points where local(p) {
                if seen.insert(cell(p)).inserted { result.append(p) }
                if result.count==limit { break }
            }
            return result
        }
        var value = observation
        value.floor = compact(value.floor,limit:18000)
        value.walls = compact(value.walls,limit:8000)
        value.front = compact(value.front,limit:4000)
        value.overhead = Array(value.overhead.filter { local([$0.x,$0.z]) && $0.y > seed.y + 0.04 && $0.y < seed.y + 3 }.prefix(12000))
        guard !value.floor.isEmpty || !value.walls.isEmpty || !value.front.isEmpty || !value.overhead.isEmpty else {
            rejectedViews += 1; return reconstruct()
        }
        observations.append(value)
        return reconstruct()
    }

    func cell(_ p: SIMD2<Float>) -> Cell {
        .init(x: Int(floor((p.x-seed.x)/Self.cell)), y: Int(floor((p.y-seed.z)/Self.cell)))
    }
    func position(_ c: Cell, center: Bool = true) -> SIMD2<Float> {
        [seed.x + (Float(c.x) + (center ? 0.5 : 0))*Self.cell,
         seed.z + (Float(c.y) + (center ? 0.5 : 0))*Self.cell]
    }

    func reconstruct() -> InteriorSweepResult {
        var result = InteriorSweepResult(views: observations.count)
        // A one-cell footprint accounts for the depth pixel's finite sampling area.
        // Its displacement is removed when the boundary is intersected below.
        var floorCells = Set<Cell>()
        for frame in observations { for p in frame.floor {
            let c = cell(p)
            for dx in -1...1 { for dy in -1...1 { floorCells.insert(.init(x:c.x+dx,y:c.y+dy)) } }
        } }
        guard floorCells.count > 40 else { result.hint = "Show more of this compartment’s base."; return result }
        let origin = cell([seed.x,seed.z])
        guard floorCells.contains(origin) else { result.hint = "Keep the selected base in view."; return result }
        var component: Set<Cell> = [origin], queue = [origin], cursor = 0
        while cursor < queue.count {
            let c = queue[cursor]; cursor += 1
            for n in c.neighbors where floorCells.contains(n) {
                if component.insert(n).inserted { queue.append(n) }
            }
        }
        result.coverage = queue.enumerated().compactMap { i,c in
            guard i % max(1, queue.count / 220) == 0 else { return nil }
            let p = position(c); return SIMD3(p.x,seed.y,p.y)
        }
        func samples(_ key: KeyPath<InteriorSweepObservation, [SIMD2<Float>]>) -> [Sample] {
            var values: [Sample] = []
            for (view, frame) in observations.enumerated() {
                var cells = Set<Cell>()
                for p in frame[keyPath: key] where cells.insert(cell(p)).inserted { values.append(.init(p:p,view:view)) }
            }
            return values
        }
        let lines = Self.fitLines(samples(\.walls)) + Self.fitLines(samples(\.front))
        result.boundaryCount = lines.count
        guard lines.count >= 3 else {
            result.hint = lines.isEmpty ? "Sweep the base and the sides where they meet." : "Move a little sideways to see the remaining edges."
            return result
        }
        // Trace every observed floor component border, preserving concavities and holes.
        var next: [Cell:Cell] = [:]
        var ambiguous = false
        func edge(_ a: Cell, _ b: Cell) {
            if next.updateValue(b, forKey:a) != nil { ambiguous = true }
        }
        for c in component {
            let x=c.x, y=c.y
            if !component.contains(.init(x:x,y:y-1)) { edge(.init(x:x,y:y),.init(x:x+1,y:y)) }
            if !component.contains(.init(x:x+1,y:y)) { edge(.init(x:x+1,y:y),.init(x:x+1,y:y+1)) }
            if !component.contains(.init(x:x,y:y+1)) { edge(.init(x:x+1,y:y+1),.init(x:x,y:y+1)) }
            if !component.contains(.init(x:x-1,y:y)) { edge(.init(x:x,y:y+1),.init(x:x,y:y)) }
        }
        guard !ambiguous else { result.hint = "Sweep across gaps in the highlighted base."; return result }
        var rings: [[SIMD2<Float>]] = []
        while let start = next.keys.min(by: { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }) {
            var at = start, ring: [SIMD2<Float>] = []
            repeat {
                guard let end = next.removeValue(forKey:at) else { return result }
                ring.append(position(at,center:false)); at = end
            } while at != start
            rings.append(ring)
            guard rings.count <= 100 else { result.hint = "Sweep across gaps in the base."; return result }
        }
        func area(_ ring: [SIMD2<Float>]) -> Float {
            ring.indices.reduce(0) { let p=ring[$1], q=ring[($1+1)%ring.count]; return $0 + p.x*q.y-p.y*q.x } / 2
        }
        rings.sort { abs(area($0)) > abs(area($1)) }
        var outlines: [[SIMD3<Float>]] = []
        for (ringIndex, ring) in rings.enumerated() {
            // Tiny unobserved pinholes are not obstacles; any observed boundary is retained.
            if ringIndex > 0 && abs(area(ring)) < 0.0004 && !ring.contains(where: { p in lines.contains { $0.supports(p) } }) { continue }
            var runs: [(line:Int, at:SIMD2<Float>)] = []
            for i in ring.indices {
                let p = (ring[i]+ring[(i+1)%ring.count])/2
                let direction=simd_normalize(ring[(i+3)%ring.count]-ring[(i+ring.count-2)%ring.count])
                func score(_ index: Int) -> Float {
                    lines[index].distance(p) + (1-abs(simd_dot(direction,lines[index].tangent)))*0.025
                }
                guard let match = lines.indices.filter({ lines[$0].supports(p) }).min(by: { score($0)<score($1) }) else {
                    result.hint = ringIndex == 0 ? "Show the front edge and any unhighlighted sides." : "Show the gap or obstruction inside the base."
                    return result
                }
                if runs.last?.line != match { runs.append((match,p)) }
            }
            if runs.first?.line == runs.last?.line { runs.removeFirst() }
            guard (3...200).contains(runs.count) else { result.hint = "Keep sweeping until the edges separate clearly."; return result }
            var polygon: [SIMD3<Float>] = []
            for i in runs.indices {
                let a=lines[runs[(i+runs.count-1)%runs.count].line], b=lines[runs[i].line]
                let determinant = a.normal.x*b.normal.y-a.normal.y*b.normal.x
                guard abs(determinant) > 0.12 else { result.hint = "Show where the neighboring edges meet."; return result }
                let point = SIMD2((a.offset*b.normal.y-a.normal.y*b.offset)/determinant,
                                  (a.normal.x*b.offset-a.offset*b.normal.x)/determinant)
                guard simd_distance(point,runs[i].at) < 0.06, a.supports(point), b.supports(point) else {
                    result.hint = "Show more of the corner between the highlighted edges."; return result
                }
                let corner=SIMD3(point.x,seed.y,point.y)
                // Raster stair-steps can alternate between the same pair of fitted
                // lines at a rotated corner. Their identical intersection is one vertex.
                if polygon.last.map({ simd_distance($0,corner)>=0.001 }) ?? true { polygon.append(corner) }
            }
            if polygon.count>2, simd_distance(polygon[0],polygon.last!)<0.001 { polygon.removeLast() }
            outlines.append(polygon)
        }
        guard !outlines.isEmpty, (try? InteriorGeometry.project(outlines, enteredHeightMM:100)) != nil else {
            result.hint = "Move slowly to separate the inside edges."; return result
        }
        // Reject disconnected floors and unobserved extensions introduced by line intersections.
        let outer = outlines[0].map { InteriorPoint(x:Double($0.x),y:Double($0.z)) }
        let inner = outlines.dropFirst().map { $0.map { InteriorPoint(x:Double($0.x),y:Double($0.z)) } }
        let xs=outlines[0].map(\.x), zs=outlines[0].map(\.z)
        let minC=cell([xs.min()!,zs.min()!]), maxC=cell([xs.max()!,zs.max()!])
        var total=0, covered=0
        for x in minC.x...maxC.x { for y in minC.y...maxC.y {
            let c=Cell(x:x,y:y), p=position(c), q=InteriorPoint(x:Double(p.x),y:Double(p.y))
            if InteriorGeometry.contains(q,in:outer) && !inner.contains(where: { InteriorGeometry.contains(q,in:$0) }) {
                total += 1; if component.contains(c) { covered += 1 }
            }
        } }
        guard total > 40, Float(covered)/Float(total) > 0.97 else { result.hint = "Sweep the remaining base area before reviewing."; return result }
        result.loops = outlines
        result.height = overheadHeight(outer:outer, holes:inner)
        result.hint = result.ready ? (result.height == nil ? "Outline captured. Tilt up to see the underside above this compartment, or continue to height." : "Dimensions captured. Review the outline and clear height.") : "Move a little sideways to confirm these edges."
        return result
    }

    private func overheadHeight(outer: [InteriorPoint], holes: [[InteriorPoint]]) -> Float? {
        // Sample spatial coverage, not just point count. Repeated views of one patch
        // cannot establish clearance for the whole compartment.
        var bins: [Cell:[Int:[Float]]] = [:]
        let spacing: Float = 0.05
        for (view, frame) in observations.enumerated() { for p in frame.overhead {
            let q=InteriorPoint(x:Double(p.x),y:Double(p.z))
            guard InteriorGeometry.contains(q,in:outer), !holes.contains(where: { InteriorGeometry.contains(q,in:$0) }) else { continue }
            let c=Cell(x:Int(floor(p.x/spacing)),y:Int(floor(p.z/spacing)))
            if bins[c,default:[:]][view,default:[]].count < 24 { bins[c,default:[:]][view,default:[]].append(p.y-seed.y) }
        } }
        let supported=bins.values.compactMap { views -> Float? in
            guard views.count>=2 else { return nil }
            let medians=views.values.map { values in let sorted=values.sorted(); return sorted[sorted.count/2] }.sorted()
            guard medians.last!-medians.first! <= 0.012 else { return nil }
            return medians[medians.count/2]
        }
        let area=abs(InteriorGeometry.area(outer))-holes.reduce(0) { $0+abs(InteriorGeometry.area($1)) }
        guard area > 0, Float(supported.count)*spacing*spacing/Float(area) >= 0.8 else { return nil }
        let heights=supported.sorted()
        guard let lowest=heights.first, let highest=heights.last, highest-lowest <= 0.015 else { return nil }
        return lowest
    }

    static func fitLines(_ input: [Sample]) -> [Line] {
        var remaining = input, lines: [Line] = []
        while remaining.count >= 12 && lines.count < 32 {
            var best: [Int] = []
            // Deterministic RANSAC keeps replay and tests reproducible.
            var random: UInt64 = 0x47af123
            func pick() -> Int { random = random &* 6364136223846793005 &+ 1; return Int((random >> 32) % UInt64(remaining.count)) }
            for _ in 0..<100 {
                let a=remaining[pick()].p, b=remaining[pick()].p, d=b-a
                guard simd_length(d) > 0.035 else { continue }
                let n=simd_normalize(SIMD2(-d.y,d.x)), offset=simd_dot(n,a)
                let indices=remaining.indices.filter { abs(simd_dot(n,remaining[$0].p)-offset) < 0.006 }
                if indices.count > best.count { best=indices }
            }
            guard best.count >= 12 else { break }
            let points=best.map { remaining[$0] }
            let rejected=Set(best)
            remaining=remaining.enumerated().filter { !rejected.contains($0.offset) }.map(\.element)
            guard Set(points.map(\.view)).count >= 2 else { continue }
            let mean=points.reduce(SIMD2<Float>.zero) { $0+$1.p } / Float(points.count)
            var xx: Float=0, xy: Float=0, yy: Float=0
            for p in points { let d=p.p-mean; xx += d.x*d.x; xy += d.x*d.y; yy += d.y*d.y }
            let angle=0.5*atan2(2*xy,xx-yy), tangent=SIMD2(cos(angle),sin(angle)), normal=SIMD2(-sin(angle),cos(angle))
            let sorted=points.map { (t:simd_dot(tangent,$0.p),view:$0.view) }.sorted { $0.t < $1.t }
            var group: [(t:Float,view:Int)] = []
            func flush() {
                guard let a=group.first, let b=group.last, b.t-a.t >= 0.035, Set(group.map(\.view)).count >= 2 else { group=[]; return }
                lines.append(.init(normal:normal,offset:simd_dot(normal,mean),low:a.t,high:b.t)); group=[]
            }
            for p in sorted {
                if let last=group.last, p.t-last.t > 0.045 { flush() }
                group.append(p)
            }
            flush()
        }
        return lines
    }
}

private func finite(_ p: SIMD2<Float>) -> Bool { p.x.isFinite && p.y.isFinite }
private func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
