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
    /// Views accepted over the whole sweep. Unlike `views` it keeps rising once the
    /// budget is full, so consumers can tell a new reconstruction from a repeated one.
    var revision = 0
    var boundaryCount = 0
    /// The outer outline once its edges resolve, even while an inner gap still needs
    /// coverage. Diagnostic only: `loops` stays empty until every ring resolves.
    var outline: [SIMD3<Float>] = []
    var ready: Bool { !loops.isEmpty && views >= 3 }
}

/// A bounded map of observed floor and boundary samples, shared across camera views.
/// The raster only orders edges; dimensions come from supported fitted lines.
/// Unobserved borders never become walls, and no rectangular/convex hull is imposed.
struct InteriorSweep: Sendable {
    let seed: SIMD3<Float>
    private(set) var observations: [InteriorSweepObservation] = []
    private(set) var rejectedViews = 0
    private(set) var acceptedViews = 0
    static let cell: Float = 0.008
    static let radius: Float = 1.2
    /// Stored views; beyond this the most redundant view is replaced, not the new one refused.
    static let maxViews = 40
    /// Metres of camera travel equivalent to one radian of turn (3° ≈ 1.8 cm, as for new views).
    static let turnWeight: Float = 0.35
    /// How far outside the observed base a wall or front sample may lie and still
    /// bound it: the floor stops short of a wall by the depth sampling footprint.
    static let edgeReach: Float = 0.04
    /// Scatter of one flat surface across LiDAR views; parallel surfaces closer than
    /// this are below the sweep's resolution and fit as a single edge.
    static let surfaceBand: Float = 0.015
    /// Spacing along an open front at which the observed base's reach is sampled.
    static let frontBin: Float = 0.02

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
        // A full map keeps the sweep useful: the stored view most redundant with another
        // gives way, so a late view that covers a remaining gap still counts.
        if observations.count >= Self.maxViews {
            guard let replaced = viewToReplace(with: value) else { rejectedViews += 1; return reconstruct() }
            observations.remove(at: replaced)
        }
        observations.append(value); acceptedViews += 1
        return reconstruct()
    }

    /// The stored view whose pose is nearest another stored view (ties give up the older),
    /// or nil when the candidate itself repeats a stored pose more closely than any stored
    /// pair: then the candidate adds nothing and is the one dropped.
    private func viewToReplace(with candidate: InteriorSweepObservation) -> Int? {
        func separation(_ a: InteriorSweepObservation, _ b: InteriorSweepObservation) -> Float {
            let turn = acos(min(1, max(-1, simd_dot(simd_normalize(a.forward), simd_normalize(b.forward)))))
            return simd_distance(a.camera, b.camera) + turn*Self.turnWeight
        }
        var redundant = 0, nearest = Float.infinity
        for i in observations.indices { for j in observations.indices where j != i {
            let s = separation(observations[i], observations[j])
            if s < nearest { nearest = s; redundant = i }
        } }
        let repeats = observations.map { separation($0, candidate) }.min() ?? .infinity
        return repeats + 0.001 < nearest ? nil : redundant
    }

    func cell(_ p: SIMD2<Float>) -> Cell {
        .init(x: Int(floor((p.x-seed.x)/Self.cell)), y: Int(floor((p.y-seed.z)/Self.cell)))
    }
    func position(_ c: Cell, center: Bool = true) -> SIMD2<Float> {
        [seed.x + (Float(c.x) + (center ? 0.5 : 0))*Self.cell,
         seed.z + (Float(c.y) + (center ? 0.5 : 0))*Self.cell]
    }

    func reconstruct() -> InteriorSweepResult {
        var result = InteriorSweepResult(views: observations.count, revision: acceptedViews)
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
        let lines = boundaryLines(near: component)
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
            var runs: [Run] = []
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
            runs = Self.collapsingDuplicateSides(runs, lines: lines, base: SIMD2(seed.x, seed.z))
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
            if ringIndex == 0 { result.outline = polygon }
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

    typealias Run = (line: Int, at: SIMD2<Float>)

    /// Nearly parallel neighbours that do not meet where the outline turns are one side seen
    /// as two surfaces (a trim, the wall beyond a cabinet): the one nearer the selected base
    /// bounds the usable space, so it replaces both. Neighbours that do meet there are a real
    /// shallow corner and are left for the corner checks, never straightened away.
    static func collapsingDuplicateSides(_ input: [Run], lines: [Line], base: SIMD2<Float>) -> [Run] {
        var runs = input
        func duplicate(_ a: Int, _ b: Int, turn: SIMD2<Float>) -> Bool {
            let x=lines[a], y=lines[b], determinant=x.normal.x*y.normal.y-x.normal.y*y.normal.x
            guard abs(determinant) <= 0.12 else { return false }
            guard abs(determinant) > 0.000001 else { return true }
            let meet=SIMD2((x.offset*y.normal.y-x.normal.y*y.offset)/determinant,
                           (x.normal.x*y.offset-x.offset*y.normal.x)/determinant)
            return simd_distance(meet, turn) >= 0.06
        }
        var collapsed = true
        while collapsed && runs.count > 1 {
            collapsed = false
            for i in runs.indices {
                let j = (i+1) % runs.count, same = runs[i].line == runs[j].line
                guard same || duplicate(runs[i].line, runs[j].line, turn: runs[j].at) else { continue }
                if !same, lines[runs[j].line].distance(base) < lines[runs[i].line].distance(base) {
                    runs[i].line = runs[j].line
                }
                // Collapsing can leave one line on both sides of a removed run, so the
                // same pass also joins identical neighbours (including across the seam).
                runs.remove(at: j)
                collapsed = true
                break
            }
        }
        return runs
    }

    /// Edge evidence must touch the selected base. Surfaces beyond it, such as a wall
    /// beside the cabinet or an open door, can be nearly collinear with a side; fitted
    /// together with it they widen that edge or split it into parallel duplicates.
    func boundaryLines(near component: Set<Cell>) -> [Line] {
        let reach = Int((Self.edgeReach / Self.cell).rounded(.up))
        var near = component
        for c in component where c.neighbors.contains(where: { !component.contains($0) }) {
            for dx in -reach...reach { for dy in -reach...reach { near.insert(.init(x:c.x+dx,y:c.y+dy)) } }
        }
        func samples(_ key: KeyPath<InteriorSweepObservation, [SIMD2<Float>]>) -> [Sample] {
            var values: [Sample] = []
            for (view, frame) in observations.enumerated() {
                var cells = Set<Cell>()
                for p in frame[keyPath: key] {
                    let c = cell(p)
                    if near.contains(c) && cells.insert(c).inserted { values.append(.init(p:p,view:view)) }
                }
            }
            return values
        }
        return Self.fitLines(samples(\.walls)) + Self.fitLines(samples(\.front)).map(snappedToObservedBase)
    }

    /// An open front cannot cut through base the sweep observed. Depth blur at the drop
    /// places front samples inside the true edge, while the base's own samples reach it,
    /// so refit the edge through the outermost base that two views agree on along its
    /// length. The edge only ever moves outward, never past `edgeReach`.
    func snappedToObservedBase(_ line: Line) -> Line {
        let seed2 = SIMD2(seed.x, seed.z)
        // Orient the normal outward (away from the base) so positive distances lie beyond.
        let flip: Float = simd_dot(line.normal, seed2) - line.offset > 0 ? -1 : 1
        let normal = line.normal*flip, offset = line.offset*flip, tangent = SIMD2(normal.y, -normal.x)
        let low = min(line.low*flip, line.high*flip), high = max(line.low*flip, line.high*flip)
        var reach: [Int: [Int: Float]] = [:]   // bin -> view -> outermost base sample
        for (view, frame) in observations.enumerated() { for p in frame.floor {
            let d = simd_dot(normal, p) - offset, t = simd_dot(tangent, p)
            guard d > -Self.edgeReach, d <= Self.edgeReach, t >= low, t <= high else { continue }
            let bin = Int(floor(t / Self.frontBin))
            reach[bin, default: [:]][view] = max(reach[bin]?[view] ?? -.infinity, d)
        } }
        let bins: [(t: Float, d: Float)] = reach.compactMap { bin, views in
            let extents = views.values.sorted(by: >)
            guard extents.count >= 2 else { return nil }
            return ((Float(bin)+0.5)*Self.frontBin, extents[1])
        }
        guard bins.count >= 3 else { return line }
        let mt = bins.map(\.t).reduce(0,+)/Float(bins.count), md = bins.map(\.d).reduce(0,+)/Float(bins.count)
        let stt = bins.reduce(Float(0)) { $0 + ($1.t-mt)*($1.t-mt) }
        guard stt > 0 else { return line }
        let slope = bins.reduce(Float(0)) { $0 + ($1.t-mt)*($1.d-md) } / stt
        // The observed base must span most of the edge; a short patch is not extrapolated.
        guard md > 0, abs(slope) <= 0.12, Float(bins.count)*Self.frontBin >= 0.5*(high-low) else { return line }
        // Each end moves outward by at most edgeReach, never inward.
        func shift(_ t: Float) -> Float { min(Self.edgeReach, max(0, md + slope*(t-mt))) }
        let a = tangent*low + normal*(offset+shift(low)), b = tangent*high + normal*(offset+shift(high))
        let direction = simd_normalize(b-a)
        var newNormal = SIMD2(-direction.y, direction.x)
        if simd_dot(newNormal, normal) < 0 { newNormal = -newNormal }
        let newTangent = SIMD2(newNormal.y, -newNormal.x), ts = [a, b].map { simd_dot(newTangent, $0) }
        return Line(normal: newNormal, offset: simd_dot(newNormal, a), low: ts.min()!, high: ts.max()!)
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
            // One surface scatters wider than the narrow band that found it. Clear the rest
            // of its band so those tails cannot fit parallel duplicates or corner slivers.
            let offset=simd_dot(normal,mean)
            remaining=remaining.filter { abs(simd_dot(normal,$0.p)-offset) > surfaceBand }
            let sorted=points.map { (t:simd_dot(tangent,$0.p),view:$0.view) }.sorted { $0.t < $1.t }
            var group: [(t:Float,view:Int)] = []
            func flush() {
                guard let a=group.first, let b=group.last, b.t-a.t >= 0.035, Set(group.map(\.view)).count >= 2 else { group=[]; return }
                lines.append(.init(normal:normal,offset:offset,low:a.t,high:b.t)); group=[]
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
