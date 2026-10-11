import Foundation
import simd

enum InteriorFootprintModel: String, Codable, CaseIterable, Sendable {
    case observed, rectangular
    var title: String { self == .rectangular ? "Rectangle" : "Follow edges" }
}

/// Geometry-only keyframes. No camera photographs are retained in diagnostics.
struct InteriorSweepObservation: Codable, Sendable {
    var timestamp: TimeInterval
    var camera: SIMD3<Float>
    var forward: SIMD3<Float>
    var floor: [SIMD2<Float>]
    var walls: [SIMD2<Float>]
    var front: [SIMD2<Float>]
    var overhead: [SIMD3<Float>]
    /// Diagnostic evidence before wall height is discarded for the planar fit.
    /// Absent from v1 captures; never synthesized from their flattened samples.
    var wallPoints3D: [SIMD3<Float>]? = nil
}

/// Repeatability of observed boundary positions, not an absolute accuracy estimate.
struct InteriorBoundaryAgreement: Codable, Equatable, Sendable {
    var loop: Int
    var edge: Int
    var views: Int
    /// 10th–90th percentile span of per-view median normal residuals, in mm.
    /// At least three views are needed; every view gets one vote regardless of density.
    var spreadMM: Double?
    var horizontalCameraSpanMM: Double
}

struct InteriorSweepResult: Codable, Equatable, Sendable {
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
    var boundaryAgreement: [InteriorBoundaryAgreement]? = nil
    var footprintModel: InteriorFootprintModel? = nil
    var wallPlaneViews: [Int]? = nil
    var ready: Bool { !loops.isEmpty && views >= 3 }
}

/// A retained map, rather than an acquisition stream. Admission/replacement already
/// happened: running these observations through `add` again changes the capture.
struct InteriorSweepSnapshot: Codable, Sendable {
    var format = "PackMeasure interior sweep v2"
    var seed: SIMD3<Float>
    var observations: [InteriorSweepObservation]
    var rejectedViews: Int
    var acceptedViews: Int? = nil
    var reconstruction: InteriorSweepResult? = nil
    var selectedResult: InteriorSweepResult? = nil
    var reviewMeasurement: InteriorMeasurement? = nil
    var footprintModel: InteriorFootprintModel? = nil
}

/// A bounded map of observed floor and boundary samples, shared across camera views.
/// The raster only orders edges; dimensions come from supported fitted lines.
/// Unobserved borders never become walls. A rectangular prior is used only when
/// explicitly selected and all four near-orthogonal sides already have support.
struct InteriorSweep: Sendable {
    let seed: SIMD3<Float>
    let footprintModel: InteriorFootprintModel
    private(set) var observations: [InteriorSweepObservation] = []
    private(set) var rejectedViews = 0
    /// Views accepted over the sweep, including repeats confirmed at the budget.
    private(set) var acceptedViews = 0
    /// Evidence cells each stored view contributes, kept in step with `observations`.
    private(set) var viewEvidence: [Set<Evidence>] = []
    /// One observed cell of one kind; underside cells also carry their height level.
    struct Evidence: Hashable, Sendable { var kind: UInt8; var cell: Cell; var level = 0 }
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
    /// Half-width of a slab of samples the density step treats as one surface, and the width
    /// of each shoulder beside it: the 6 mm band RANSAC itself calls one surface.
    static let slabHalf: Float = 0.003
    /// Slab centres tried on either side of a fitted line, in millimetres: nearer than 5 mm is
    /// below the sweep's resolution, and a surface centred at 15 mm or more keeps half its
    /// samples past `surfaceBand`, where RANSAC fits it on its own.
    static let slabCentres = 5...14
    /// How far from a fitted line the samples a slab may draw on are taken: the furthest
    /// centre plus `slabHalf`, so a slab centred at 14 mm is whole.
    static let slabReach: Float = 0.017
    /// A slab must hold this many times the samples of each 3 mm shoulder beside it over the
    /// same stretch; one surface's tail thins away and gives at most twice.
    static let peakFactor: Float = 3
    /// A slab's samples per metre must reach this fraction of the fitted line's own: Gaussian
    /// tails inside the best slab stay below 0.27, real plates above 0.45.
    static let densityFraction: Float = 0.3
    /// No two adjacent `cell`-wide steps along a slab may hold more than this share of its
    /// samples: a wall crossing the band at a corner clusters, a surface fills its span.
    static let clusterShareMax: Float = 0.5
    /// Splits of one inlier set into two levels are tried at multiples of this along its tangent:
    /// finer finds nothing more (each level is re-gathered), coarser loses short strips.
    static let stepBin: Float = 0.02
    /// Two levels of one inlier set must be at least this far apart, both at the split and once
    /// re-gathered: nearer is below the sweep's resolution (`slabCentres.lowerBound`).
    static let stepMin: Float = 0.005
    /// ... and at most this (`slabCentres.upperBound`): further apart RANSAC fits them itself.
    static let stepMax: Float = 0.014
    /// The two levels' intercepts must differ by this many of their own standard errors: a chance
    /// split of one surface reaches 3, a 3 mm bowed wall stays under 5, a real step above it.
    static let stepSigma: Float = 5
    /// A level re-gathers the pool samples within this of its line: the 6 mm band RANSAC itself
    /// calls one surface, wide enough to span a flat-topped scatter rather than tilt inside it.
    static let levelHalf: Float = 0.006
    /// Gather and refit passes per level; the third moves an offset by under 0.1 mm.
    static let gatherPasses = 3
    /// The two levels must be parallel within this |det| (3.4°), half `duplicate`'s tolerance:
    /// real steps stay under 0.05, the two legs of a shallow bend do not.
    static let levelDet: Float = 0.06
    /// Spacing along an open front at which the observed base's reach is sampled.
    static let frontBin: Float = 0.02

    init(seed: SIMD3<Float>, footprintModel: InteriorFootprintModel = .observed) {
        self.seed = seed; self.footprintModel = footprintModel
    }

    enum SnapshotError: Error { case invalid }

    /// Restore the final retained state without reapplying live admission gates.
    /// Validation still bounds storage and rejects invalid coordinates/counters.
    init(snapshot: InteriorSweepSnapshot) throws {
        guard ["PackMeasure interior sweep v1", "PackMeasure interior sweep v2"].contains(snapshot.format),
              finite(snapshot.seed), snapshot.observations.count <= Self.maxViews,
              snapshot.rejectedViews >= 0,
              snapshot.acceptedViews.map({ $0 >= snapshot.observations.count }) ?? true,
              snapshot.observations.allSatisfy(Self.valid) else { throw SnapshotError.invalid }
        self.init(seed: snapshot.seed, footprintModel:snapshot.footprintModel ?? .observed)
        observations = snapshot.observations
        rejectedViews = snapshot.rejectedViews
        acceptedViews = snapshot.acceptedViews ?? observations.count
        viewEvidence = observations.map(evidenceCells)
    }

    private static func valid(_ observation: InteriorSweepObservation) -> Bool {
        observation.timestamp.isFinite && finite(observation.camera) && finite(observation.forward)
        && observation.floor.allSatisfy(finite) && observation.walls.allSatisfy(finite)
        && observation.front.allSatisfy(finite) && observation.overhead.allSatisfy(finite)
        && (observation.wallPoints3D?.allSatisfy(finite) ?? true)
        && observation.floor.count <= 18000 && observation.walls.count <= 8000
        && observation.front.count <= 4000 && observation.overhead.count <= 12000
        && (observation.wallPoints3D?.count ?? 0) <= 8000
    }

    struct Cell: Hashable, Sendable {
        var x: Int; var y: Int
        var neighbors: [Cell] { [.init(x:x-1,y:y), .init(x:x+1,y:y), .init(x:x,y:y-1), .init(x:x,y:y+1)] }
    }
    struct Sample { var p: SIMD2<Float>; var view: Int }
    struct Line {
        var normal: SIMD2<Float>; var offset: Float
        var low: Float; var high: Float
        var isFront = false
        var tangent: SIMD2<Float> { [normal.y, -normal.x] }
        func distance(_ p: SIMD2<Float>) -> Float { abs(simd_dot(normal, p) - offset) }
        func supports(_ p: SIMD2<Float>, margin: Float = 0.028) -> Bool {
            let t = simd_dot(tangent, p)
            return distance(p) <= margin && t >= low - margin && t <= high + margin
        }
        /// This line with its extent widened to cover `o`'s end points, projected onto its tangent.
        func covering(_ o: Line) -> Line {
            let ts = [o.low, o.high].map { simd_dot(tangent, o.tangent*$0 + o.normal*o.offset) }
            return Line(normal: normal, offset: offset, low: min(low, ts.min()!), high: max(high, ts.max()!), isFront:isFront)
        }
    }

    mutating func add(_ observation: InteriorSweepObservation) -> InteriorSweepResult {
        guard observation.timestamp.isFinite, finite(observation.camera), finite(observation.forward),
              observation.floor.allSatisfy(finite), observation.walls.allSatisfy(finite),
              observation.front.allSatisfy(finite), observation.overhead.allSatisfy(finite),
              observation.wallPoints3D?.allSatisfy(finite) ?? true else {
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
        if let points = value.wallPoints3D {
            var seen = Set<Evidence>(), compacted = [SIMD3<Float>]()
            for p in points where local([p.x,p.z]) && (0.015...0.15).contains(p.y-seed.y) {
                let voxel = Evidence(kind:1, cell:cell([p.x,p.z]), level:Int(floor((p.y-seed.y)/Self.cell)))
                if seen.insert(voxel).inserted { compacted.append(p) }
                if compacted.count == 8000 { break }
            }
            value.wallPoints3D = compacted
        }
        guard !value.floor.isEmpty || !value.walls.isEmpty || !value.front.isEmpty || !value.overhead.isEmpty else {
            rejectedViews += 1; return reconstruct()
        }
        // A full map keeps the sweep useful: the stored view most redundant with another
        // gives way, so a late view that covers a remaining gap still counts.
        let incoming = evidenceCells(of: value)
        if observations.count >= Self.maxViews {
            // A view adding nothing is not stored, but still reported as a fresh
            // reconstruction so the scanner can confirm the outline is stable.
            guard let replaced = viewToReplace(adding: incoming) else { acceptedViews += 1; return reconstruct() }
            observations.remove(at: replaced); viewEvidence.remove(at: replaced)
        }
        observations.append(value); viewEvidence.append(incoming); acceptedViews += 1
        return reconstruct()
    }

    /// Cells of base, sides, front and (at the height estimate's 5 cm spacing) underside.
    /// Underside cells are split into 1 cm levels, finer than the 12 mm agreement the height
    /// needs, so a lower obstruction seen late is new evidence, not a repeat of a higher one.
    private func evidenceCells(of view: InteriorSweepObservation) -> Set<Evidence> {
        var cells = Set<Evidence>()
        for p in view.floor { cells.insert(.init(kind:0, cell:cell(p))) }
        for p in view.walls { cells.insert(.init(kind:1, cell:cell(p))) }
        for p in view.front { cells.insert(.init(kind:2, cell:cell(p))) }
        for p in view.overhead {
            cells.insert(.init(kind:3, cell:.init(x:Int(floor(p.x/0.05)), y:Int(floor(p.z/0.05))), level:Int(floor((p.y-seed.y)/0.01))))
        }
        return cells
    }

    /// Views a cell needs before reconstruction uses it: the base is kept from any one
    /// view, while edges and the underside need two that agree (`fitLines`, `overheadHeight`).
    static func support(_ kind: UInt8) -> Int { kind == 0 ? 1 : 2 }

    /// When full, the stored view whose loss costs least once the incoming view is kept gives
    /// way: fewest cells that would fall below the support they need, then the pose nearest
    /// another view, then the older.
    /// Close poses can still see different patches, so pose alone never decides. Nil when
    /// the incoming view brings no cell closer to its needed support.
    private func viewToReplace(adding incoming: Set<Evidence>) -> Int? {
        // Only evidence reconstruction can use counts, judged exactly as reconstruction
        // judges it: the connected base, edges near it, the underside above it. Seeing more
        // of a background surface never displaces a stored view.
        let base = Set(connectedBase(observedBase(adding: incoming))), near = base.isEmpty ? [] : neighborhood(of: base)
        let above = Set(base.map { c in let p = position(c); return Cell(x:Int(floor(p.x/0.05)), y:Int(floor(p.y/0.05))) })
        func usable(_ e: Evidence) -> Bool {
            guard !base.isEmpty else { return true }
            switch e.kind {
            case 0: return base.contains(e.cell)
            case 3: return above.contains(e.cell)
            default: return near.contains(e.cell)
            }
        }
        var seen: [Evidence: Int] = [:]
        for cells in viewEvidence { for e in cells where usable(e) { seen[e, default: 0] += 1 } }
        guard incoming.contains(where: { usable($0) && seen[$0, default: 0] < Self.support($0.kind) }) else { return nil }
        // Price each stored view as if the incoming view were already kept: evidence it
        // re-observes costs nothing to lose.
        for e in incoming where usable(e) { seen[e, default: 0] += 1 }
        let cost = viewEvidence.map { cells in
            cells.reduce(0) { $0 + (usable($1) && seen[$1, default: 0] <= Self.support($1.kind) ? 1 : 0) }
        }
        guard let least = cost.min() else { return nil }
        func separation(_ a: InteriorSweepObservation, _ b: InteriorSweepObservation) -> Float {
            let turn = acos(min(1, max(-1, simd_dot(simd_normalize(a.forward), simd_normalize(b.forward)))))
            return simd_distance(a.camera, b.camera) + turn*Self.turnWeight
        }
        var replaced: Int?, nearest = Float.infinity
        for i in observations.indices where cost[i] == least {
            let pose = observations.indices.filter { $0 != i }.map { separation(observations[i], observations[$0]) }.min() ?? .infinity
            if pose < nearest { nearest = pose; replaced = i }
        }
        return replaced
    }

    func cell(_ p: SIMD2<Float>) -> Cell {
        .init(x: Int(floor((p.x-seed.x)/Self.cell)), y: Int(floor((p.y-seed.z)/Self.cell)))
    }
    func position(_ c: Cell, center: Bool = true) -> SIMD2<Float> {
        [seed.x + (Float(c.x) + (center ? 0.5 : 0))*Self.cell,
         seed.z + (Float(c.y) + (center ? 0.5 : 0))*Self.cell]
    }

    /// Observed base cells, each widened by a one-cell footprint for the depth pixel's finite
    /// sampling area. Its displacement is removed when the boundary is intersected.
    private func observedBase(adding incoming: Set<Evidence> = []) -> Set<Cell> {
        var floorCells = Set<Cell>()
        func include(_ c: Cell) {
            for dx in -1...1 { for dy in -1...1 { floorCells.insert(.init(x:c.x+dx,y:c.y+dy)) } }
        }
        for frame in observations { for p in frame.floor { include(cell(p)) } }
        // Replacement prices the map after admission. Previously remote edge or
        // underside evidence can become usable when this floor extends the base.
        for e in incoming where e.kind == 0 { include(e.cell) }
        return floorCells
    }

    /// The observed base connected to the seed, in breadth-first order; empty when the
    /// seed itself is not covered.
    private func connectedBase(_ floorCells: Set<Cell>) -> [Cell] {
        let origin = cell([seed.x,seed.z])
        guard floorCells.contains(origin) else { return [] }
        var component: Set<Cell> = [origin], queue = [origin], cursor = 0
        while cursor < queue.count {
            let c = queue[cursor]; cursor += 1
            for n in c.neighbors where floorCells.contains(n) {
                if component.insert(n).inserted { queue.append(n) }
            }
        }
        return queue
    }

    func reconstruct() -> InteriorSweepResult {
        var result = InteriorSweepResult(views: observations.count, revision: acceptedViews, footprintModel:footprintModel)
        let floorCells = observedBase()
        guard floorCells.count > 40 else { result.hint = "Show more of this compartment’s base."; return result }
        let queue = connectedBase(floorCells)
        guard !queue.isEmpty else { result.hint = "Keep the selected base in view."; return result }
        let component = Set(queue)
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
                // Rings are traced with the observed base on the left of travel, for the outer
                // outline and obstacle cutouts alike.
                let edge = ring[(i+1)%ring.count]-ring[i], inward = simd_normalize(SIMD2(-edge.y, edge.x))
                func score(_ index: Int) -> Float {
                    lines[index].distance(p) + (1-abs(simd_dot(direction,lines[index].tangent)))*0.025
                }
                let candidates = lines.indices.filter { lines[$0].supports(p) }
                guard var match = candidates.min(by: { score($0)<score($1) }) else {
                    result.hint = ringIndex == 0 ? "Show the front edge and any unhighlighted sides." : "Show the gap or obstruction inside the base."
                    return result
                }
                // The ring is traced on 8 mm cells dilated by one cell, so along a surface a few
                // mm inside a side (a hinge plate) its edge still lies on the outer side. Matched by
                // distance the outer line would win and the plate could never reach the collapse,
                // so a parallel duplicate lying deeper into the base takes the match instead.
                for k in candidates where k != match && Self.duplicate(lines[match], lines[k], turn: p)
                    && Self.depth(lines[k], at: p, inward: inward) > Self.depth(lines[match], at: p, inward: inward) { match = k }
                if runs.last?.line != match { runs.append((match, p, inward)) }
            }
            if runs.first?.line == runs.last?.line { runs.removeFirst() }
            let (collapsed, sides) = Self.collapsingDuplicateSides(runs, lines: lines); runs = collapsed
            guard (3...200).contains(runs.count) else { result.hint = "Keep sweeping until the edges separate clearly."; return result }
            var polygon: [SIMD3<Float>] = []
            for i in runs.indices {
                let a=sides[runs[(i+runs.count-1)%runs.count].line], b=sides[runs[i].line]
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
            if ringIndex == 0 && footprintModel == .rectangular {
                guard let fitted = rectangularOutline(polygon, lines:sides) else {
                    result.hint = "Show four straight sides, or choose Follow edges for taper and notches."; return result
                }
                polygon = fitted.outline; result.wallPlaneViews = fitted.planeViews
            }
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
        result.boundaryAgreement = boundaryAgreement(for: outlines)
        result.height = overheadHeight(outer:outer, holes:inner)
        result.hint = result.ready ? (result.height == nil ? "Outline captured. Tilt up to see the underside above this compartment, or continue to height." : "Dimensions captured. Review the outline and clear height.") : "Move a little sideways to confirm these edges."
        return result
    }

    /// Measure disagreement outside the narrow RANSAC inlier set, using samples
    /// within the wider surface band around the selected
    /// edges. Corner samples are excluded so another wall cannot dominate a view's
    /// median. Sparse views of a short patch do not establish boundary repeatability.
    /// A small spread can still contain a shared sensor bias; it is not a fit guarantee.
    func boundaryAgreement(for loops: [[SIMD3<Float>]]) -> [InteriorBoundaryAgreement] {
        var output = [InteriorBoundaryAgreement]()
        for (li, loop) in loops.enumerated() { for ei in loop.indices {
            let a = SIMD2(loop[ei].x,loop[ei].z), b = SIMD2(loop[(ei+1)%loop.count].x,loop[(ei+1)%loop.count].z)
            let length = simd_distance(a,b)
            guard length > 0.075 else {
                output.append(.init(loop:li,edge:ei,views:0,spreadMM:nil,horizontalCameraSpanMM:0)); continue
            }
            let tangent = (b-a)/length, normal = SIMD2(-tangent.y,tangent.x)
            var medians = [Float](), cameras = [SIMD2<Float>]()
            for frame in observations {
                let samples = (frame.walls+frame.front).filter { p in
                    let t = simd_dot(tangent,p-a)
                    return t >= 0.02 && t <= length-0.02 && abs(simd_dot(normal,p-a)) <= Self.surfaceBand
                }
                guard samples.count >= 6 else { continue }
                let ts = samples.map { simd_dot(tangent,$0-a) }
                guard ts.max()!-ts.min()! >= 0.035 else { continue }
                let ds = samples.map { simd_dot(normal,$0-a) }.sorted()
                medians.append(ds[ds.count/2]); cameras.append([frame.camera.x,frame.camera.z])
            }
            medians.sort()
            func percentile(_ q: Float) -> Float {
                let at = q*Float(medians.count-1), low = Int(at), high = min(low+1,medians.count-1)
                return medians[low]+(medians[high]-medians[low])*(at-Float(low))
            }
            let spread = medians.count >= 3 ? Double(percentile(0.9)-percentile(0.1))*1000 : nil
            var cameraSpan: Float = 0
            for i in cameras.indices { for j in cameras.indices where j > i { cameraSpan = max(cameraSpan,simd_distance(cameras[i],cameras[j])) } }
            output.append(.init(loop:li,edge:ei,views:medians.count,spreadMM:spread,horizontalCameraSpanMM:Double(cameraSpan)*1000))
        } }
        return output
    }

    /// A stretch of ring matched to one line: where it starts, and the unit direction from
    /// there into the observed base.
    typealias Run = (line: Int, at: SIMD2<Float>, inward: SIMD2<Float>)

    /// Nearly parallel lines that do not meet within 6 cm of `turn`, where the outline turns
    /// between them: one side seen as two surfaces rather than a real shallow corner.
    static func duplicate(_ x: Line, _ y: Line, turn: SIMD2<Float>) -> Bool {
        let determinant=x.normal.x*y.normal.y-x.normal.y*y.normal.x
        guard abs(determinant) <= 0.12 else { return false }
        guard abs(determinant) > 0.000001 else { return true }
        let meet=SIMD2((x.offset*y.normal.y-x.normal.y*y.offset)/determinant,
                       (x.normal.x*y.offset-x.offset*y.normal.x)/determinant)
        return simd_distance(meet, turn) >= 0.06
    }
    /// How far `l` lies into the base along `inward`, measured at `at`.
    static func depth(_ l: Line, at: SIMD2<Float>, inward: SIMD2<Float>) -> Float {
        simd_dot(inward, at - (simd_dot(l.normal, at) - l.offset)*l.normal)
    }

    /// Nearly parallel neighbours that do not meet where the outline turns are one side seen
    /// as two surfaces (a trim, the wall beyond a cabinet, a hinge plate). The one lying further
    /// into the observed base bounds the usable space, so it replaces both: that shrinks an
    /// outline and grows an obstacle cutout. Neighbours that do meet there are a real shallow
    /// corner and are left for the corner checks, never straightened away.
    /// Returns the collapsed runs and this ring's copy of `lines`, in which each kept line's
    /// extent also covers the sides it replaced.
    static func collapsingDuplicateSides(_ input: [Run], lines: [Line]) -> (runs: [Run], lines: [Line]) {
        var runs = input, sides = lines
        var collapsed = true
        while collapsed && runs.count > 1 {
            collapsed = false
            for i in runs.indices {
                let j = (i+1) % runs.count, same = runs[i].line == runs[j].line
                guard same || Self.duplicate(lines[runs[i].line], lines[runs[j].line], turn: runs[j].at) else { continue }
                if !same {
                    // Depth is measured at the turn along whichever run's inward better aligns
                    // with the lines' normal: a single raster step across the notch carries an
                    // inward along the side, along which both lines are equally deep.
                    let at = runs[j].at, n = lines[runs[i].line].normal
                    let inward = abs(simd_dot(runs[i].inward, n)) > abs(simd_dot(runs[j].inward, n)) ? runs[i].inward : runs[j].inward
                    let deeper = Self.depth(lines[runs[j].line], at: at, inward: inward) > Self.depth(lines[runs[i].line], at: at, inward: inward)
                    let (kept, dropped) = deeper ? (runs[j].line, runs[i].line) : (runs[i].line, runs[j].line)
                    runs[i].line = kept
                    // A short deeper line (a hinge plate) replaces the whole side, so its extent
                    // must cover the dropped side's: otherwise the far corner is no longer
                    // supported and the corner check asks to show more of the corner.
                    sides[kept] = sides[kept].covering(sides[dropped])
                }
                // Collapsing can leave one line on both sides of a removed run, so the
                // same pass also joins identical neighbours (including across the seam).
                runs.remove(at: j); collapsed = true; break
            }
        }
        return (runs: runs, lines: sides)
    }

    /// The base plus everything within `edgeReach` of its border: where edge evidence counts.
    func neighborhood(of component: Set<Cell>) -> Set<Cell> {
        let reach = Int((Self.edgeReach / Self.cell).rounded(.up))
        var near = component
        for c in component where c.neighbors.contains(where: { !component.contains($0) }) {
            for dx in -reach...reach { for dy in -reach...reach { near.insert(.init(x:c.x+dx,y:c.y+dy)) } }
        }
        return near
    }

    /// Edge evidence must touch the selected base. Surfaces beyond it, such as a wall
    /// beside the cabinet or an open door, can be nearly collinear with a side; fitted
    /// together with it they widen that edge or split it into parallel duplicates.
    func boundaryLines(near component: Set<Cell>) -> [Line] {
        let near = neighborhood(of: component)
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
        // Only the walls are searched for a nearer surface inside them: an open front is a
        // drop, not a surface, and `snappedToObservedBase` only ever moves it outward.
        return Self.fitLines(samples(\.walls), nearerSurfaces: true) + Self.fitLines(samples(\.front)).map {
            var line = snappedToObservedBase($0, base: component); line.isFront = true; return line
        }
    }

    /// An open front cannot cut through base the sweep observed. Depth blur at the drop
    /// places front samples inside the true edge, while the base's own samples reach it,
    /// so refit the edge through the outermost base that two views agree on along its
    /// length. The edge only ever moves outward, never past `edgeReach`.
    func snappedToObservedBase(_ line: Line, base: Set<Cell>? = nil) -> Line {
        let component = base ?? Set(connectedBase(observedBase()))
        guard !component.isEmpty else { return line }
        // A concavity or obstacle can put the seed across the void from this edge.
        // Judge inward locally along its span, using the same observed footprint
        // and reach as reconstruction. Equal or conflicting sides cannot orient it.
        let steps = Int((Self.edgeReach / Self.cell).rounded(.up))
        var inward: Float?
        for t in stride(from: line.low + Self.frontBin/2, through: line.high, by: Self.frontBin) {
            let center = line.tangent*t + line.normal*line.offset
            var positive = 0, negative = 0
            for step in 1...steps {
                let delta = line.normal*(Float(step)*Self.cell)
                if component.contains(cell(center + delta)) { positive += 1 }
                if component.contains(cell(center - delta)) { negative += 1 }
            }
            guard positive != negative else { continue }
            let side: Float = positive > negative ? 1 : -1
            if let inward, inward != side { return line }
            inward = side
        }
        guard let inward else { return line }
        // Positive signed distances now lie away from the local base.
        let flip = -inward
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

    /// The line through `points` by principal component: its unit normal, offset and tangent.
    static func fit(_ points: [Sample]) -> (normal: SIMD2<Float>, offset: Float, tangent: SIMD2<Float>) {
        let mean=points.reduce(SIMD2<Float>.zero) { $0+$1.p } / Float(points.count)
        var xx: Float=0, xy: Float=0, yy: Float=0
        for p in points { let d=p.p-mean; xx += d.x*d.x; xy += d.x*d.y; yy += d.y*d.y }
        let angle=0.5*atan2(2*xy,xx-yy), tangent=SIMD2(cos(angle),sin(angle)), normal=SIMD2(-sin(angle),cos(angle))
        return (normal:normal,offset:simd_dot(normal,mean),tangent:tangent)
    }
    /// `samples` sorted along `tangent` and split at gaps over 4.5 cm; a run counts when it
    /// spans at least 3.5 cm and two views saw it, the support `fitLines` asks of a line.
    static func runs(of samples: [Sample], tangent: SIMD2<Float>) -> [(low: Float, high: Float, samples: [Sample])] {
        let sorted=samples.map { (t:simd_dot(tangent,$0.p),s:$0) }.sorted { $0.t < $1.t }
        var out: [(low: Float, high: Float, samples: [Sample])] = [], group: [(t:Float,s:Sample)] = []
        func flush() {
            if let a=group.first, let b=group.last, b.t-a.t >= 0.035, Set(group.map { $0.s.view }).count >= 2 {
                out.append((low:a.t,high:b.t,samples:group.map { $0.s }))
            }
            group=[]
        }
        for e in sorted { if let last=group.last, e.t-last.t > 0.045 { flush() }; group.append(e) }
        flush()
        return out
    }
    /// Up to one nearer parallel surface on each side of the line (`normal`, `offset`): a slab
    /// of `residue` 5–14 mm from it that is denser than the scatter on either side of it and has
    /// a line's own support is a surface in its own right (a hinge plate, a stop), not the
    /// line's tail. Each element is one surface's runs as lines sharing its fit. `pool` is
    /// everything the line was fitted from, for the shoulder counts, and `refDensity` the
    /// line's own inlier samples per metre.
    static func nearerParallelSurfaces(in residue: [Sample], pool: [Sample], normal: SIMD2<Float>, offset: Float,
                                       tangent: SIMD2<Float>, refDensity: Float) -> [[Line]] {
        var out: [[Line]] = []
        for sign in [Float(1), -1] {
            var best: (count: Int, runs: [[Sample]])? = nil
            for centre in Self.slabCentres {   // ascending, so a tie keeps the nearer centre
                let c=Float(centre)*0.001
                let slab=residue.filter { abs(sign*(simd_dot(normal,$0.p)-offset)-c) <= Self.slabHalf }
                guard slab.count >= 12 else { continue }
                var passing: [[Sample]] = []
                for run in Self.runs(of: slab, tangent: tangent) where run.samples.count >= 12 {
                    // A wall crossing the band at a corner puts its samples into one or two
                    // steps along the tangent, and a few tail samples stretch that into a run;
                    // a surface fills its span.
                    let first=Int(floor(run.low/Self.cell)), last=Int(floor(run.high/Self.cell))
                    var counts=[Int](repeating:0,count:last-first+2)
                    for s in run.samples { counts[min(max(Int(floor(simd_dot(tangent,s.p)/Self.cell))-first,0),last-first)] += 1 }
                    var pair=0
                    for k in 0..<(counts.count-1) { pair=max(pair,counts[k]+counts[k+1]) }
                    guard Float(pair) <= Self.clusterShareMax*Float(run.samples.count) else { continue }
                    // As dense as the line itself over the run's own span.
                    guard Float(run.samples.count)/(run.high-run.low) >= Self.densityFraction*refDensity else { continue }
                    // The slab must stand out from both 3 mm shoulders over that span, counted
                    // on everything the line was fitted from: a tail thins away, a surface peaks.
                    var slabN=0, nearN=0, farN=0
                    for s in pool {
                        let t=simd_dot(tangent,s.p)
                        guard t >= run.low, t <= run.high else { continue }
                        let d=sign*(simd_dot(normal,s.p)-offset)-c
                        if abs(d) <= Self.slabHalf { slabN += 1 }
                        else if d < -Self.slabHalf && d >= -2*Self.slabHalf { nearN += 1 }
                        else if d > Self.slabHalf && d <= 2*Self.slabHalf { farN += 1 }
                    }
                    guard Float(slabN) >= Self.peakFactor*Float(nearN), Float(slabN) >= Self.peakFactor*Float(farN) else { continue }
                    passing.append(run.samples)
                }
                let total=passing.reduce(0) { $0+$1.count }
                if !passing.isEmpty, total > (best?.count ?? 0) { best=(count:total,runs:passing) }
            }
            guard let best else { continue }
            let surface=Self.fit(best.runs.flatMap { $0 })
            // Parallel to the line by the collapse's own tolerance (`duplicate`): an oblique
            // sliver crossing the band is not a nearer surface.
            guard abs(normal.x*surface.normal.y-normal.y*surface.normal.x) <= 0.12 else { continue }
            out.append(best.runs.map { run -> Line in
                let ts=run.map { simd_dot(surface.tangent,$0.p) }
                return Line(normal:surface.normal,offset:surface.offset,low:ts.min()!,high:ts.max()!)
            })
        }
        return out
    }
    /// Two parallel levels 5–14 mm apart in one RANSAC inlier set, each on its own stretch of the
    /// line: a panel and a strip that replaces it over part of its length, which the 6 mm band
    /// fitted as one tilted blend. `points` are the inliers, (`normal`, `offset`, `tangent`) their
    /// PCA line and `residue` the band residue. Each element is one level's runs as lines sharing
    /// its fit; nil when the set is one surface.
    private static func steppedSurfaces(of points: [Sample], residue: [Sample], normal: SIMD2<Float>, offset: Float,
                                        tangent: SIMD2<Float>) -> [[Line]]? {
        let td=points.map { (t:simd_dot(tangent,$0.p),d:simd_dot(normal,$0.p)-offset,s:$0) }
        guard let tLow=td.map(\.t).min(), let tHigh=td.map(\.t).max() else { return nil }
        let kmin=Int((tLow/Self.stepBin).rounded(.down)), kmax=Int((tHigh/Self.stepBin).rounded(.down))
        guard kmax > kmin else { return nil }
        var best: (sse: Float, split: Float, slope: Float, gap: Float, sigma: Float, sides: [[Sample]])? = nil
        for k in (kmin+1)...kmax {   // ascending, so of equal residuals the first split wins
            let split=Float(k)*Self.stepBin
            let sides=[td.filter { $0.t < split }, td.filter { $0.t >= split }]
            // Each side needs a line's own support before the split is scored.
            guard sides.allSatisfy({ g in g.count >= 12 && Set(g.map { $0.s.view }).count >= 2
                                      && g.map(\.t).max()!-g.map(\.t).min()! >= 0.035 }) else { continue }
            // One slope shared by both sides, one intercept each: two parallel lines in the blend's frame.
            let means=sides.map { g in (t:g.map(\.t).reduce(0,+)/Float(g.count),d:g.map(\.d).reduce(0,+)/Float(g.count)) }
            var stt: Float=0, std: Float=0
            for (g,m) in zip(sides,means) { for e in g { stt += (e.t-m.t)*(e.t-m.t); std += (e.t-m.t)*(e.d-m.d) } }
            guard stt > 0 else { continue }
            let slope=std/stt
            var sse: Float=0
            for (g,m) in zip(sides,means) { for e in g { let r=e.d-m.d-slope*(e.t-m.t); sse += r*r } }
            let dc=abs((means[1].d-slope*means[1].t)-(means[0].d-slope*means[0].t))
            let gap=dc/(1+slope*slope).squareRoot()
            // Standard error of the intercept difference: the scatter about the two lines over the
            // counts, plus the slope's own uncertainty levered by the distance between the sides' means.
            let lever=means[1].t-means[0].t, variance=sse/Float(max(td.count-3,1))
            let se=(variance*(1/Float(sides[0].count)+1/Float(sides[1].count)+lever*lever/stt)).squareRoot()
            // With no scatter about either level, a separation is exact: as significant as it gets.
            let sigma: Float=se > 0 ? dc/se : (dc > 0 ? .infinity : 0)
            if best.map({ sse < $0.sse }) ?? true {
                best=(sse:sse,split:split,slope:slope,gap:gap,sigma:sigma,sides:sides.map { $0.map(\.s) })
            }
        }
        guard let best, best.gap >= Self.stepMin, best.gap <= Self.stepMax, best.sigma >= Self.stepSigma else { return nil }
        // Each level starts parallel to the shared slope, at the median offset of its own side of the
        // pool (inliers plus residue): the band clips each surface toward the other, the pool holds
        // its whole scatter, and the median is unbiased for a symmetric scatter and robust to a few
        // of the other surface's samples beside the split.
        let pool=points+residue
        let direction=simd_normalize(tangent+normal*best.slope)
        let across=SIMD2(-direction.y,direction.x), levelNormal=simd_dot(across,normal) < 0 ? -across : across
        let poolSides=[pool.filter { simd_dot(tangent,$0.p) < best.split }, pool.filter { simd_dot(tangent,$0.p) >= best.split }]
        var levels: [(normal: SIMD2<Float>, offset: Float, tangent: SIMD2<Float>)]=poolSides.map { side in
            let ds=side.map { simd_dot(levelNormal,$0.p) }.sorted()
            return (normal:levelNormal,offset:ds[ds.count/2],tangent:direction)   // upper median, as overheadHeight takes it
        }
        var groups=best.sides
        for _ in 0..<Self.gatherPasses {
            // A pool sample joins the nearer level when within levelHalf of it, on that level's side
            // of the split only: any reach past the split lets a level claim the other surface's
            // near tail and tilt toward it.
            groups=[[],[]]
            for s in pool {
                let d=levels.map { abs(simd_dot($0.normal,s.p)-$0.offset) }
                guard min(d[0],d[1]) <= Self.levelHalf else { continue }
                let g=d[0] <= d[1] ? 0 : 1, t=simd_dot(tangent,s.p)
                let ownSide=g == 0 ? t < best.split : t >= best.split
                if ownSide { groups[g].append(s) }
            }
            guard groups.allSatisfy({ $0.count >= 3 }) else { return nil }
            levels=groups.map(Self.fit)
        }
        let det=levels[0].normal.x*levels[1].normal.y-levels[0].normal.y*levels[1].normal.x
        let at=tangent*best.split+normal*offset   // the split point on the blend
        let flip: Float=simd_dot(levels[0].normal,levels[1].normal) >= 0 ? 1 : -1
        let sep=abs((simd_dot(levels[0].normal,at)-levels[0].offset)-flip*(simd_dot(levels[1].normal,at)-levels[1].offset))
        guard abs(det) <= Self.levelDet, sep >= Self.stepMin, sep <= Self.stepMax else { return nil }
        var out: [[Line]]=[]
        for (g,f) in zip(groups,levels) {
            // Each level keeps a line's own support, or the set stays one surface.
            guard g.count >= 12, Set(g.map(\.view)).count >= 2 else { return nil }
            let runs=Self.runs(of:g,tangent:f.tangent).filter { $0.samples.count >= 12 }
            guard !runs.isEmpty else { return nil }
            out.append(runs.map { Line(normal:f.normal,offset:f.offset,low:$0.low,high:$0.high) })
        }
        return out
    }

    /// With `nearerSurfaces`, a denser band of samples a few millimetres inside a fitted line
    /// also gets a line of its own (`nearerParallelSurfaces`); its band is cleared like any
    /// line's, and it is never itself searched again. One inlier set may also be a tilted blend
    /// of a panel and a strip that replaces it over part of its length (`steppedSurfaces`): then
    /// each level gets its own line and band instead, and the pair is not searched further.
    static func fitLines(_ input: [Sample], nearerSurfaces: Bool = false) -> [Line] {
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
            let pool=nearerSurfaces ? remaining : []   // everything this round saw, inliers included
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
            // What the band holds besides the inliers, out to one slab past it, before it is cleared.
            let residue=nearerSurfaces ? remaining.filter { abs(simd_dot(normal,$0.p)-offset) <= Self.slabReach } : []
            if nearerSurfaces, let levels=Self.steppedSurfaces(of:points,residue:residue,normal:normal,offset:offset,tangent:tangent),
               lines.count+levels.reduce(0, { $0+$1.count }) <= 32 {
                for level in levels {
                    lines += level
                    // Each level is an accepted surface: clear its own scatter band as any line's.
                    let s=level[0]
                    remaining=remaining.filter { abs(simd_dot(s.normal,$0.p)-s.offset) > surfaceBand }
                }
                continue   // the pair already explains the band: neither level is searched for nearer surfaces
            }
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
            guard !residue.isEmpty else { continue }
            let ts=points.map { simd_dot(tangent,$0.p) }, refDensity=Float(points.count)/max(ts.max()!-ts.min()!,1e-6)
            for sub in Self.nearerParallelSurfaces(in:residue,pool:pool,normal:normal,offset:offset,tangent:tangent,refDensity:refDensity) {
                guard lines.count+sub.count <= 32 else { break }
                lines += sub
                // An accepted surface: clear its own scatter band so the tail past this line's
                // band cannot refit as a duplicate of it.
                let s=sub[0]
                remaining=remaining.filter { abs(simd_dot(s.normal,$0.p)-s.offset) > surfaceBand }
            }
        }
        return lines
    }
}

private func finite(_ p: SIMD2<Float>) -> Bool { p.x.isFinite && p.y.isFinite }
private func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
