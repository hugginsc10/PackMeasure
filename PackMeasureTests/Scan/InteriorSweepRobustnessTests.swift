import Foundation
import Testing
import simd
@testable import PackMeasure

// HARNESS-CORE-BEGIN
// Pure Foundation and simd, no Testing: a macOS command-line runner compiles this section
// verbatim beside InteriorSweep.swift, so the simulator and the fast runner score one case
// matrix with one flip rule and print identical METRIC lines.

/// Shared yardstick for sweep reconstructions: device recordings replayed view by view
/// through the scanner's review gate, unchanged and under rigid motions, LiDAR-scale noise
/// and dropped views. Depends only on `InteriorSweep.add` and `InteriorSweepResult`.
///
/// Flips. A view "resolves the outline" when `result.outline` has exactly four corners (the
/// compartment is a rectangle), is "ready" when `result.ready`, and "unlocks review" when the
/// result is ready and the scanner has seen at least two consecutive matching results
/// (`InteriorScanState.canReviewSweep` with the camera ready, i.e. `stableSweepPreviews >= 2`).
/// For each of the three conditions separately, once it first holds, every later view on
/// which it does not hold is one flip. `flips` is the sum of the three counts. A recording
/// that never resolves, never readies or never unlocks has no flips of that kind; the outline
/// must still resolve on the final view for a case to pass. A recording holds the views the
/// sweep kept (at most `InteriorSweep.maxViews`, in capture order), so a replay is the sweep
/// those views alone would have produced.
enum SweepRobustness {
    static let inch: Float = 0.0254
    static let fixtures = ["cabinet-sweep-b59", "cabinet-sweep-b59-partial-front"]
    /// Tape: 10.5 in side to side (each width within 0.3 in of it), 11.2 in from the back wall
    /// to the shelf front edge (each depth strictly inside this range; it may stay short).
    static let tapeWidth: Float = 10.5, widthTolerance: Float = 0.3, depth: ClosedRange<Float> = 10.6...11.3
    /// LiDAR-scale noise for jitter and per-view registration offsets, metres.
    static let noise: Double = 0.003

    struct Recording: Decodable, Sendable { var seed: SIMD3<Float>; var observations: [InteriorSweepObservation] }

    /// SplitMix64: deterministic, platform independent, so every run perturbs identically.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * Double(next() >> 11) / Double(UInt64(1) << 53)
        }
    }

    /// Rotation about the vertical (y) axis, then translation. Horizontal samples are (x, z).
    /// Angle 0 with no translation is exact: 1*x - 0*z + 0 == x bit for bit.
    struct Motion: Sendable {
        var angle: Double, translation: SIMD3<Float>
        let c: Float, s: Float
        init(angle: Double = 0, translation: SIMD3<Float> = .zero) {
            self.angle = angle; self.translation = translation; c = Float(cos(angle)); s = Float(sin(angle))
        }
        func point(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(c*p.x - s*p.z + translation.x, p.y + translation.y, s*p.x + c*p.z + translation.z)
        }
        func point(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(c*p.x - s*p.y + translation.x, s*p.x + c*p.y + translation.z)
        }
        func direction(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(c*v.x - s*v.z, v.y, s*v.x + c*v.z) }
        /// Every geometric field of a view: camera pose and all four sample arrays.
        func moved(_ o: InteriorSweepObservation) -> InteriorSweepObservation {
            var o = o
            o.camera = point(o.camera); o.forward = direction(o.forward)
            o.floor = o.floor.map(point); o.walls = o.walls.map(point); o.front = o.front.map(point)
            o.overhead = o.overhead.map(point)
            return o
        }
    }

    /// One perturbation of a whole recording. Components apply in order: drop views, offset
    /// each view rigidly, jitter each sample, then move the whole recording (seed included).
    struct Case: Sendable, CustomStringConvertible {
        var id: String
        var motion: Motion? = nil
        var jitter: UInt64? = nil
        var viewOffset: UInt64? = nil
        var drop: UInt64? = nil
        var description: String { id }
    }

    /// Identity, a quarter turn and six seeded arbitrary turns (each with a 0.3 to 3 m
    /// horizontal and up to 1 m vertical translation), three seeds each of per-sample jitter,
    /// per-view offsets and dropped views, and two combinations of everything.
    static func cases() -> [Case] {
        var random = Random(state: 0x5EED_2026_0928)
        func motion(_ angle: Double) -> Motion {
            let heading = random.uniform(0...(2 * .pi)), reach = random.uniform(0.3...3), lift = random.uniform(-1...1)
            return Motion(angle: angle, translation: SIMD3(Float(reach*cos(heading)), Float(lift), Float(reach*sin(heading))))
        }
        var list = [Case(id: "identity", motion: Motion()), Case(id: "rot90", motion: motion(.pi/2))]
        for _ in 0..<6 {
            let angle = random.uniform(0...(2 * .pi))
            list.append(Case(id: "rot\(Int((angle*180 / .pi).rounded()))", motion: motion(angle)))
        }
        for s in UInt64(1)...3 { list.append(Case(id: "jitter\(s)", jitter: 0x1177_0000 + s)) }
        for s in UInt64(1)...3 { list.append(Case(id: "shift\(s)", viewOffset: 0x5417_0000 + s)) }
        for s in UInt64(1)...3 { list.append(Case(id: "drop\(s)", drop: 0xD409_0000 + s)) }
        for s in UInt64(1)...2 {
            let angle = random.uniform(0...(2 * .pi))
            list.append(Case(id: "combo\(s)", motion: motion(angle), jitter: 0xC0B0_1000 + s,
                             viewOffset: 0xC0B0_2000 + s, drop: 0xC0B0_3000 + s))
        }
        return list
    }

    static func perturbed(_ recording: Recording, by perturbation: Case) -> Recording {
        var observations = recording.observations, seed = recording.seed
        if let state = perturbation.drop, observations.count >= 5 {
            // Drop 1 to 20% of the views, keeping order.
            var random = Random(state: state), dropped = Set<Int>()
            let count = 1 + Int(random.next() % UInt64(observations.count / 5))
            while dropped.count < count { dropped.insert(Int(random.next() % UInt64(observations.count))) }
            observations = observations.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
        }
        if let state = perturbation.viewOffset {
            var random = Random(state: state)
            observations = observations.map { o in
                let d = SIMD3(Float(random.uniform(-noise...noise)), Float(random.uniform(-noise...noise)), Float(random.uniform(-noise...noise)))
                return Motion(translation: d).moved(o)
            }
        }
        if let state = perturbation.jitter {
            var random = Random(state: state)
            func j() -> Float { Float(random.uniform(-noise...noise)) }
            observations = observations.map { o in
                var o = o
                o.floor = o.floor.map { $0 + SIMD2(j(), j()) }
                o.walls = o.walls.map { $0 + SIMD2(j(), j()) }
                o.front = o.front.map { $0 + SIMD2(j(), j()) }
                o.overhead = o.overhead.map { $0 + SIMD3(j(), j(), j()) }
                return o
            }
        }
        if let motion = perturbation.motion { seed = motion.point(seed); observations = observations.map(motion.moved) }
        return Recording(seed: seed, observations: observations)
    }

    struct View: Equatable, Sendable { var corners: Int; var ready: Bool; var stable: Int; var reviewable: Bool; var hint: String }
    struct Outcome: Sendable {
        var views: [View]; var result: InteriorSweepResult; var observations: [InteriorSweepObservation]
        var outlineFlips: Int { SweepRobustness.flips(views.map { $0.corners == 4 }) }
        var readyFlips: Int { SweepRobustness.flips(views.map(\.ready)) }
        var reviewFlips: Int { SweepRobustness.flips(views.map(\.reviewable)) }
        var flips: Int { outlineFlips + readyFlips + reviewFlips }
    }
    /// Views after the condition first holds on which it no longer holds.
    static func flips(_ holds: [Bool]) -> Int {
        guard let first = holds.firstIndex(of: true) else { return 0 }
        return holds[first...].filter { !$0 }.count
    }

    /// The reconstruction after each view, adding the views one at a time. Pure and
    /// nonisolated, so cases can replay in parallel.
    static func results(_ recording: Recording) -> [InteriorSweepResult] {
        var map = InteriorSweep(seed: recording.seed)
        return recording.observations.map { map.add($0) }
    }

    /// Hands every per-view result, in order, to the scanner's review gate, which answers its
    /// stable-preview count and whether review is unlocked.
    @MainActor static func outcome(_ recording: Recording, _ results: [InteriorSweepResult],
                                   gate: @MainActor (InteriorSweepResult) -> (stable: Int, reviewable: Bool)) -> Outcome {
        let views = results.map { result in
            let state = gate(result)
            return View(corners: result.outline.count, ready: result.ready, stable: state.stable,
                        reviewable: state.reviewable, hint: result.hint)
        }
        return Outcome(views: views, result: results.last ?? InteriorSweepResult(), observations: recording.observations)
    }

    /// Dimensions of a resolved four-corner outline: widths run across the view (the back
    /// wall faces the camera), depths along it.
    static func spans(_ outcome: Outcome) -> (widths: [Float], depths: [Float])? {
        let outline = outcome.result.outline.map { SIMD2($0.x, $0.z) }
        guard outline.count == 4 else { return nil }
        let look = simd_normalize(outcome.observations.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.forward.x, $1.forward.z) })
        var widths: [Float] = [], depths: [Float] = []
        for i in outline.indices {
            let edge = outline[(i+1)%4] - outline[i], length = simd_length(edge)/inch
            if abs(simd_dot(simd_normalize(edge), look)) < 0.5 { widths.append(length) } else { depths.append(length) }
        }
        return (widths, depths)
    }

    /// Everything that fails the tape and flip criteria; empty when the case passes.
    static func problems(_ outcome: Outcome) -> [String] {
        var problems: [String] = []
        if let dims = spans(outcome) {
            if dims.widths.count != 2 || dims.depths.count != 2 { problems.append("\(dims.widths.count) widths, \(dims.depths.count) depths") }
            for w in dims.widths where !(abs(w - tapeWidth) < widthTolerance) { problems.append(String(format: "width %.2f in", w)) }
            for d in dims.depths where !(d > depth.lowerBound && d < depth.upperBound) { problems.append(String(format: "depth %.2f in", d)) }
        } else {
            problems.append("outline has \(outcome.result.outline.count) corners: \(outcome.result.hint)")
        }
        if outcome.flips > 0 { problems.append("flips outline \(outcome.outlineFlips), ready \(outcome.readyFlips), review \(outcome.reviewFlips)") }
        return problems
    }

    static func metric(fixture: String, case id: String, _ outcome: Outcome) -> String {
        func list(_ values: [Float]?) -> String {
            values.map { $0.sorted().map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? "-"
        }
        let dims = spans(outcome)
        return "METRIC fixture=\(fixture) case=\(id) corners=\(outcome.result.outline.count) widths=\(list(dims?.widths)) depths=\(list(dims?.depths)) flips=\(outcome.flips) ready=\(outcome.result.ready)"
    }

    static func flipCounts(fixture: String, case id: String, _ outcome: Outcome) -> String {
        "FLIPS fixture=\(fixture) case=\(id) outline=\(outcome.outlineFlips) ready=\(outcome.readyFlips) review=\(outcome.reviewFlips)"
    }

    static func trace(fixture: String, case id: String, _ outcome: Outcome) -> [String] {
        outcome.views.enumerated().map { i, v in
            "TRACE fixture=\(fixture) case=\(id) view=\(i) corners=\(v.corners) ready=\(v.ready) stable=\(v.stable) review=\(v.reviewable) hint=\(v.hint)"
        }
    }
}
// HARNESS-CORE-END

private final class RobustnessFixtureBundle {}

extension SweepRobustness.Case: CustomTestStringConvertible { var testDescription: String { id } }

/// Device replays must not flap between ready and not ready as views arrive, and must keep
/// their dimensions under rigid motions, LiDAR-scale noise and dropped views. The review gate
/// is the real `InteriorScanState.receiveSweep`.
@Suite("Interior sweep robustness")
struct InteriorSweepRobustnessTests {
    /// Decoded once per test run: the partial-front recording is 2.9 MB of JSON.
    static let recordings: [String: SweepRobustness.Recording] = Dictionary(uniqueKeysWithValues: SweepRobustness.fixtures.compactMap { name in
        guard let url = Bundle(for: RobustnessFixtureBundle.self).url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let recording = try? JSONDecoder().decode(SweepRobustness.Recording.self, from: data) else { return nil }
        return (name, recording)
    })
    func recording(_ name: String) throws -> SweepRobustness.Recording {
        try #require(Self.recordings[name], "fixture \(name).json")
    }

    /// Reconstructs off the main actor (cases run in parallel), then feeds each result, in
    /// order, to a fresh scanner in its sweeping state with the camera ready, as the camera
    /// view would feed it.
    func replay(_ recording: SweepRobustness.Recording) async -> SweepRobustness.Outcome {
        let results = SweepRobustness.results(recording)
        return await MainActor.run {
            let state = InteriorScanState()
            state.ready = true
            return SweepRobustness.outcome(recording, results) { value in
                state.receiveSweep(value, generation: state.generation)
                return (state.stableSweepPreviews, state.canReviewSweep)
            }
        }
    }

    /// Replaying the recording view by view, the outline, readiness and the review unlock
    /// each hold from the first view they appear on. b59 stays not ready by design (one
    /// patch of its shelf was never observed), so only its outline can flip.
    @Test(arguments: SweepRobustness.fixtures)
    func readinessDoesNotFlapOnceTheOutlineResolves(fixture: String) async throws {
        let outcome = await replay(try recording(fixture))
        SweepRobustness.trace(fixture: fixture, case: "recorded", outcome).forEach { print($0) }
        print(SweepRobustness.metric(fixture: fixture, case: "recorded", outcome))
        print(SweepRobustness.flipCounts(fixture: fixture, case: "recorded", outcome))
        #expect(outcome.views.last?.corners == 4, "\(outcome.result.hint)")
        #expect(outcome.outlineFlips == 0, "outline flips")
        #expect(outcome.readyFlips == 0, "ready flips")
        #expect(outcome.reviewFlips == 0, "review flips")
    }

    /// Harness self-check: the identity perturbation runs the transform code and must
    /// reproduce the recording's replay exactly, view by view and corner by corner.
    @Test(arguments: SweepRobustness.fixtures)
    func identityPerturbationReproducesTheRecording(fixture: String) async throws {
        let recorded = try recording(fixture), identity = try #require(SweepRobustness.cases().first { $0.id == "identity" })
        let plain = await replay(recorded), moved = await replay(SweepRobustness.perturbed(recorded, by: identity))
        #expect(plain.views == moved.views)
        #expect(plain.result.outline == moved.result.outline)
        #expect(plain.result.loops == moved.result.loops)
    }

    /// Harness self-check: a rigid motion reaches every geometric field. Distances to the
    /// moved seed are preserved, so a field left behind would be off by the translation.
    @Test func rigidMotionMovesEveryGeometricField() throws {
        let recorded = try recording(SweepRobustness.fixtures[1])
        let fields = Mirror(reflecting: recorded.observations[0]).children.compactMap(\.label)
        #expect(fields == ["timestamp", "camera", "forward", "floor", "walls", "front", "overhead"], "new field to perturb")
        let motion = SweepRobustness.Motion(angle: 2.1, translation: [1.7, -0.4, -2.3])
        let moved = SweepRobustness.perturbed(recorded, by: .init(id: "check", motion: motion))
        let a = recorded.seed, b = moved.seed
        func same(_ p: SIMD3<Float>, _ q: SIMD3<Float>) -> Bool { abs(simd_distance(p, a) - simd_distance(q, b)) < 0.0001 && simd_distance(p, q) > 0.1 }
        func same(_ p: SIMD2<Float>, _ q: SIMD2<Float>) -> Bool { same(SIMD3(p.x, a.y, p.y), SIMD3(q.x, b.y, q.y)) }
        for (o, m) in zip(recorded.observations, moved.observations) {
            #expect(o.timestamp == m.timestamp && same(o.camera, m.camera))
            #expect(abs(simd_dot(o.forward, [0, 1, 0]) - simd_dot(m.forward, [0, 1, 0])) < 0.0001)
            #expect(abs(simd_dot(o.forward, o.camera - a) - simd_dot(m.forward, m.camera - b)) < 0.0001)
            #expect(zip(o.floor, m.floor).allSatisfy(same) && zip(o.walls, m.walls).allSatisfy(same))
            #expect(zip(o.front, m.front).allSatisfy(same) && zip(o.overhead, m.overhead).allSatisfy(same))
        }
    }

    /// Both device sweeps under the whole perturbation matrix keep a four-corner outline
    /// within tape tolerance and never flip.
    @Test(arguments: SweepRobustness.fixtures, SweepRobustness.cases())
    func perturbedSweepStaysWithinTape(fixture: String, perturbation: SweepRobustness.Case) async throws {
        let outcome = await replay(SweepRobustness.perturbed(try recording(fixture), by: perturbation))
        print(SweepRobustness.metric(fixture: fixture, case: perturbation.id, outcome))
        print(SweepRobustness.flipCounts(fixture: fixture, case: perturbation.id, outcome))
        let problems = SweepRobustness.problems(outcome)
        #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
    }
}
