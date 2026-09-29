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
///
/// Review-time tape. Review can be tapped at any view where it is unlocked, and the scanner
/// then commits the result it holds (`InteriorScanState.sweepResult`, which a same-revision
/// result does not replace), so a correct final view does not excuse an earlier wide one.
/// At every view where review is unlocked, the held outline must have four corners, two
/// widths each within `widthTolerance` of `tapeWidth` and two depths each inside `depth`,
/// the same test the final view gets. Widths and depths are told apart by the whole
/// replay's mean view direction, as for the final view. A view failing any of this is one
/// `over` view; any `over` view fails the case.
///
/// Coverage classes. Each fixture is either a successful capture or outline-only evidence
/// (`coverage`), and its perturbation cases inherit that class. Both classes need a final
/// four-corner outline within tape, zero flips of each kind and in-tape held outlines at every
/// review-unlocked view. A capture must also unlock review at least once, so a replay that
/// never reaches review can not pass as a capture. An outline-only replay that does unlock
/// review fails with a request to reclassify it, so it can not be counted silently either.
/// Every output line carries `class=capture` or `class=outline` after `case=`.
enum SweepRobustness {
    static let inch: Float = 0.0254

    /// What a fixture's replay is evidence of. The class is fixed per recording, never derived
    /// from a result, so a capture that stops reaching review fails instead of being demoted.
    enum Coverage: String, Sendable {
        /// Successful capture: review unlocks, every review-unlocked view is within tape, and
        /// the outline, readiness and the unlock each hold to the last view once they appear.
        case capture
        /// Outline-only: the scan is incomplete, so review never unlocks by design. Its final
        /// dimensions are outline evidence, not a successful capture.
        case outline
    }
    /// Every fixture and its class, in replay order. Reclassifying one is a one-line change.
    static let coverage: [(fixture: String, coverage: Coverage)] = [
        // One patch of its shelf was never observed, so it waits on the gap hint and never
        // unlocks review. Outline-only until that incomplete scan is addressed.
        ("cabinet-sweep-b59", .outline),
        // Same compartment with front evidence along part of the edge; review unlocks.
        ("cabinet-sweep-b59-partial-front", .capture),
    ]
    static let fixtures = coverage.map(\.fixture)
    static func fixtures(_ kind: Coverage) -> [String] { coverage.filter { $0.coverage == kind }.map(\.fixture) }
    static func coverage(of fixture: String) -> Coverage? { coverage.first { $0.fixture == fixture }?.coverage }
    /// The `class=` value of every output line.
    static func label(_ fixture: String) -> String { coverage(of: fixture)?.rawValue ?? "unclassified" }
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

    struct Dims: Equatable, Sendable { var widths: [Float]; var depths: [Float] }
    /// `held` measures the outline the scanner holds after this view (what review commits).
    struct View: Equatable, Sendable { var corners: Int; var ready: Bool; var stable: Int; var reviewable: Bool; var hint: String; var held: Dims? = nil }
    struct Outcome: Sendable {
        var views: [View]; var result: InteriorSweepResult; var observations: [InteriorSweepObservation]
        var outlineFlips: Int { SweepRobustness.flips(views.map { $0.corners == 4 }) }
        var readyFlips: Int { SweepRobustness.flips(views.map(\.ready)) }
        var reviewFlips: Int { SweepRobustness.flips(views.map(\.reviewable)) }
        var flips: Int { outlineFlips + readyFlips + reviewFlips }
        /// Indices of the views on which review is unlocked.
        var reviewViews: [Int] { views.indices.filter { views[$0].reviewable } }
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
    /// stable-preview count, whether review is unlocked and the result it now holds.
    @MainActor static func outcome(_ recording: Recording, _ results: [InteriorSweepResult],
                                   gate: @MainActor (InteriorSweepResult) -> (stable: Int, reviewable: Bool, held: InteriorSweepResult)) -> Outcome {
        let look = look(recording.observations)
        let views = results.map { result in
            let state = gate(result)
            return View(corners: result.outline.count, ready: result.ready, stable: state.stable,
                        reviewable: state.reviewable, hint: result.hint, held: spans(state.held.outline, look: look))
        }
        return Outcome(views: views, result: results.last ?? InteriorSweepResult(), observations: recording.observations)
    }

    /// Dimensions of a resolved four-corner outline: widths run across the view (the back
    /// wall faces the camera), depths along it.
    static func spans(_ outcome: Outcome) -> (widths: [Float], depths: [Float])? {
        spans(outcome.result.outline, look: look(outcome.observations)).map { ($0.widths, $0.depths) }
    }
    /// The sweep's mean horizontal view direction.
    static func look(_ observations: [InteriorSweepObservation]) -> SIMD2<Float> {
        simd_normalize(observations.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.forward.x, $1.forward.z) })
    }
    static func spans(_ outline3: [SIMD3<Float>], look: SIMD2<Float>) -> Dims? {
        let outline = outline3.map { SIMD2($0.x, $0.z) }
        guard outline.count == 4 else { return nil }
        var widths: [Float] = [], depths: [Float] = []
        for i in outline.indices {
            let edge = outline[(i+1)%4] - outline[i], length = simd_length(edge)/inch
            if abs(simd_dot(simd_normalize(edge), look)) < 0.5 { widths.append(length) } else { depths.append(length) }
        }
        return Dims(widths: widths, depths: depths)
    }

    /// Tape failures of one measured outline.
    static func tapeProblems(_ dims: Dims) -> [String] {
        var problems: [String] = []
        if dims.widths.count != 2 || dims.depths.count != 2 { problems.append("\(dims.widths.count) widths, \(dims.depths.count) depths") }
        for w in dims.widths where !(abs(w - tapeWidth) < widthTolerance) { problems.append(String(format: "width %.2f in", w)) }
        for d in dims.depths where !(d > depth.lowerBound && d < depth.upperBound) { problems.append(String(format: "depth %.2f in", d)) }
        return problems
    }

    /// Tape failures at the views where review is unlocked, one entry per `over` view.
    static func reviewProblems(_ outcome: Outcome) -> [String] {
        outcome.reviewViews.compactMap { i in
            let found = outcome.views[i].held.map(tapeProblems) ?? ["outline is not four corners"]
            return found.isEmpty ? nil : "review view \(i): \(found.joined(separator: ", "))"
        }
    }

    /// One failed requirement: a stable code for the ACCEPT line, and what failed.
    struct Failure: Sendable { var code: String; var detail: String }

    /// The requirements both classes share: a final four-corner outline within tape, no flips
    /// of the outline, readiness or the review unlock, and in-tape held outlines wherever
    /// review is unlocked (vacuous for a replay that never unlocks it, hence the classes).
    static func sharedFailures(_ outcome: Outcome) -> [Failure] {
        var failures: [Failure] = []
        if let dims = spans(outcome) {
            failures += tapeProblems(Dims(widths: dims.widths, depths: dims.depths)).map { Failure(code: "final-tape", detail: $0) }
        } else {
            failures.append(Failure(code: "final-outline", detail: "outline has \(outcome.result.outline.count) corners: \(outcome.result.hint)"))
        }
        if outcome.flips > 0 {
            failures.append(Failure(code: "flips", detail: "flips outline \(outcome.outlineFlips), ready \(outcome.readyFlips), review \(outcome.reviewFlips)"))
        }
        return failures + reviewProblems(outcome).map { Failure(code: "review-tape", detail: $0) }
    }
    /// The shared requirements' failures alone, class-blind; empty when they all hold.
    static func problems(_ outcome: Outcome) -> [String] { sharedFailures(outcome).map(\.detail) }

    static func neverReachesReview(_ fixture: String) -> String {
        "never reaches Review: capture fixture \(fixture) must unlock review at least once"
    }
    static func reclassify(_ fixture: String, _ outcome: Outcome) -> String {
        "outline-only fixture \(fixture) unlocks Review at views \(outcome.reviewViews.map(String.init).joined(separator: ",")):"
            + " reclassify it as capture in SweepRobustness.coverage, it is no longer outline-only"
    }

    /// Acceptance for the fixture's class; empty when the case passes. A capture fails when
    /// review never unlocks; an outline-only replay fails when it does.
    static func acceptance(fixture: String, _ outcome: Outcome) -> [Failure] {
        var failures = sharedFailures(outcome)
        switch coverage(of: fixture) {
        case .capture?: if outcome.reviewViews.isEmpty { failures.append(Failure(code: "no-review", detail: neverReachesReview(fixture))) }
        case .outline?: if !outcome.reviewViews.isEmpty { failures.append(Failure(code: "reclassify", detail: reclassify(fixture, outcome))) }
        case nil: failures.append(Failure(code: "unclassified", detail: "\(fixture) has no entry in SweepRobustness.coverage"))
        }
        return failures
    }

    /// The verdict line: class, pass or fail, review-unlocked view count and failed codes.
    static func accept(fixture: String, case id: String, _ outcome: Outcome) -> String {
        var codes: [String] = []
        for failure in acceptance(fixture: fixture, outcome) where !codes.contains(failure.code) { codes.append(failure.code) }
        return "ACCEPT fixture=\(fixture) case=\(id) class=\(label(fixture)) result=\(codes.isEmpty ? "PASS" : "FAIL") reviewViews=\(outcome.reviewViews.count) fails=\(codes.isEmpty ? "-" : codes.joined(separator: ","))"
    }

    /// Every line one case prints, in order; `traced` adds the per-view TRACE and RVIEW lines.
    static func report(fixture: String, case id: String, _ outcome: Outcome, traced: Bool) -> [String] {
        (traced ? trace(fixture: fixture, case: id, outcome) : [])
            + [metric(fixture: fixture, case: id, outcome), flipCounts(fixture: fixture, case: id, outcome)]
            + (traced ? reviewTrace(fixture: fixture, case: id, outcome) : [])
            + [review(fixture: fixture, case: id, outcome), accept(fixture: fixture, case: id, outcome)]
    }

    static func metric(fixture: String, case id: String, _ outcome: Outcome) -> String {
        func list(_ values: [Float]?) -> String {
            values.map { $0.sorted().map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? "-"
        }
        let dims = spans(outcome)
        return "METRIC fixture=\(fixture) case=\(id) class=\(label(fixture)) corners=\(outcome.result.outline.count) widths=\(list(dims?.widths)) depths=\(list(dims?.depths)) flips=\(outcome.flips) ready=\(outcome.result.ready)"
    }

    static func flipCounts(fixture: String, case id: String, _ outcome: Outcome) -> String {
        "FLIPS fixture=\(fixture) case=\(id) class=\(label(fixture)) outline=\(outcome.outlineFlips) ready=\(outcome.readyFlips) review=\(outcome.reviewFlips)"
    }

    /// Review-time tape summary over the views where review is unlocked: how many, how many
    /// fail the tape (`over`), the first one, and the extreme widths and depths held there.
    static func review(fixture: String, case id: String, _ outcome: Outcome) -> String {
        let held = outcome.reviewViews.compactMap { outcome.views[$0].held }
        let widths = held.flatMap(\.widths), depths = held.flatMap(\.depths)
        func value(_ v: Float?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
        return "REVIEW fixture=\(fixture) case=\(id) class=\(label(fixture)) views=\(outcome.reviewViews.count) over=\(reviewProblems(outcome).count) first=\(outcome.reviewViews.first.map(String.init) ?? "-") peakWidth=\(value(widths.max())) minWidth=\(value(widths.min())) peakDepth=\(value(depths.max())) minDepth=\(value(depths.min()))"
    }

    /// The held widths and depths at each view where review is unlocked.
    static func reviewTrace(fixture: String, case id: String, _ outcome: Outcome) -> [String] {
        func list(_ values: [Float]?) -> String {
            values.map { $0.sorted().map { String(format: "%.2f", $0) }.joined(separator: ",") } ?? "-"
        }
        return outcome.reviewViews.map { i in
            let held = outcome.views[i].held
            return "RVIEW fixture=\(fixture) case=\(id) class=\(label(fixture)) view=\(i) widths=\(list(held?.widths)) depths=\(list(held?.depths))"
        }
    }

    static func trace(fixture: String, case id: String, _ outcome: Outcome) -> [String] {
        outcome.views.enumerated().map { i, v in
            "TRACE fixture=\(fixture) case=\(id) class=\(label(fixture)) view=\(i) corners=\(v.corners) ready=\(v.ready) stable=\(v.stable) review=\(v.reviewable) hint=\(v.hint)"
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
                return (state.stableSweepPreviews, state.canReviewSweep, state.sweepResult)
            }
        }
    }

    /// Replays and prints every line of one case (TRACE and RVIEW for recorded replays).
    func scored(_ fixture: String, case id: String, _ recording: SweepRobustness.Recording, traced: Bool) async -> SweepRobustness.Outcome {
        let outcome = await replay(recording)
        SweepRobustness.report(fixture: fixture, case: id, outcome, traced: traced).forEach { print($0) }
        return outcome
    }

    /// Successful capture, replayed view by view: review unlocks, the held outline is within
    /// tape at every view where it is unlocked, the final outline has four corners within tape,
    /// and the outline, readiness and the unlock each hold from the first view they appear on,
    /// so once review unlocks it stays unlocked through the last view.
    @Test(arguments: SweepRobustness.fixtures(.capture))
    func captureReachesReviewWithinTapeAndHoldsIt(fixture: String) async throws {
        let outcome = await scored(fixture, case: "recorded", try recording(fixture), traced: true)
        let review = SweepRobustness.reviewProblems(outcome)
        let final = SweepRobustness.spans(outcome).map { SweepRobustness.tapeProblems(.init(widths: $0.widths, depths: $0.depths)) } ?? []
        #expect(!outcome.reviewViews.isEmpty, "capture: \(SweepRobustness.neverReachesReview(fixture))")
        #expect(review.isEmpty, "capture: \(review.joined(separator: "; "))")
        #expect(outcome.views.last?.corners == 4, "capture: \(outcome.result.hint)")
        #expect(final.isEmpty, "capture: final \(final.joined(separator: ", "))")
        #expect(outcome.outlineFlips == 0, "capture: outline flips")
        #expect(outcome.readyFlips == 0, "capture: ready flips")
        #expect(outcome.reviewFlips == 0, "capture: review flips")
    }

    /// Outline-only, replayed view by view: the final outline has four corners within tape and
    /// nothing flips. b59 stays not ready by design (one patch of its shelf was never observed),
    /// so review never unlocks. If it ever does, the held outline must still be within tape at
    /// each such view, and the replay fails asking for the fixture to be reclassified as capture.
    @Test(arguments: SweepRobustness.fixtures(.outline))
    func outlineOnlyReplayResolvesWithinTapeWithoutFlapping(fixture: String) async throws {
        let outcome = await scored(fixture, case: "recorded", try recording(fixture), traced: true)
        let review = SweepRobustness.reviewProblems(outcome)
        let final = SweepRobustness.spans(outcome).map { SweepRobustness.tapeProblems(.init(widths: $0.widths, depths: $0.depths)) } ?? []
        #expect(outcome.reviewViews.isEmpty, "outline-only: \(SweepRobustness.reclassify(fixture, outcome))")
        #expect(review.isEmpty, "outline-only: \(review.joined(separator: "; "))")
        #expect(outcome.views.last?.corners == 4, "outline-only: \(outcome.result.hint)")
        #expect(final.isEmpty, "outline-only: final \(final.joined(separator: ", "))")
        #expect(outcome.outlineFlips == 0, "outline-only: outline flips")
        #expect(outcome.readyFlips == 0, "outline-only: ready flips")
        #expect(outcome.reviewFlips == 0, "outline-only: review flips")
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

    /// Every capture perturbation case must pass capture acceptance: reach review, hold only
    /// in-tape outlines wherever review is unlocked, end on a four-corner outline within tape,
    /// and never flip.
    @Test(arguments: SweepRobustness.fixtures(.capture), SweepRobustness.cases())
    func perturbedCaptureReachesReviewWithinTape(fixture: String, perturbation: SweepRobustness.Case) async throws {
        let outcome = await scored(fixture, case: perturbation.id, SweepRobustness.perturbed(try recording(fixture), by: perturbation), traced: false)
        let failures = SweepRobustness.acceptance(fixture: fixture, outcome)
        #expect(failures.isEmpty, "capture: \(failures.map(\.detail).joined(separator: "; "))")
    }

    /// Every outline-only perturbation case must end on a four-corner outline within tape and
    /// never flip; one that unlocks review must be within tape there and asks for reclassifying.
    @Test(arguments: SweepRobustness.fixtures(.outline), SweepRobustness.cases())
    func perturbedOutlineOnlyStaysWithinTape(fixture: String, perturbation: SweepRobustness.Case) async throws {
        let outcome = await scored(fixture, case: perturbation.id, SweepRobustness.perturbed(try recording(fixture), by: perturbation), traced: false)
        let failures = SweepRobustness.acceptance(fixture: fixture, outcome)
        #expect(failures.isEmpty, "outline-only: \(failures.map(\.detail).joined(separator: "; "))")
    }
}
