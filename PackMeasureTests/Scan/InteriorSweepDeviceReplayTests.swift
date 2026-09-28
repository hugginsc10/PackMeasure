import Foundation
import Testing
import simd
@testable import PackMeasure

private final class FixtureBundle {}

/// Replays real device sweeps (geometry and camera poses only) against tape measurements.
@Suite("Interior sweep device replay")
struct InteriorSweepDeviceReplayTests {
    struct Replay: Decodable { var seed: SIMD3<Float>; var observations: [InteriorSweepObservation] }
    static let inch: Float = 0.0254

    func replay(_ name: String) throws -> (observations: [InteriorSweepObservation], result: InteriorSweepResult) {
        let url = try #require(Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: "json"))
        let recorded = try JSONDecoder().decode(Replay.self, from: Data(contentsOf: url))
        var map = InteriorSweep(seed: recorded.seed), result = InteriorSweepResult()
        for observation in recorded.observations { result = map.add(observation) }
        return (recorded.observations, result)
    }

    /// Dimensions of a resolved four-corner outline: widths run across the view (the back
    /// wall faces the camera), depths along it.
    func spans(_ result: InteriorSweepResult, _ observations: [InteriorSweepObservation]) -> (widths: [Float], depths: [Float])? {
        let outline = result.outline.map { SIMD2($0.x, $0.z) }
        guard outline.count == 4 else { return nil }
        let look = simd_normalize(observations.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.forward.x, $1.forward.z) })
        var widths: [Float] = [], depths: [Float] = []
        for i in outline.indices {
            let edge = outline[(i+1)%4] - outline[i], length = simd_length(edge)/Self.inch
            if abs(simd_dot(simd_normalize(edge), look)) < 0.5 { widths.append(length) } else { depths.append(length) }
        }
        return (widths, depths)
    }

    /// Build 59.3, same compartment: front-edge samples came only from the first three views
    /// and cover about two thirds of the front, so the front stopped ~4 cm short of a corner
    /// and the sweep looped on "Show more of the corner". The observed shelf top ends along
    /// the same line to that corner.
    @Test func frontEvidenceCoveringPartOfTheEdgeStillReachesItsCorners() throws {
        let (observations, result) = try replay("cabinet-sweep-b59-partial-front")
        let dims = try #require(spans(result, observations), "\(result.hint)")
        #expect(dims.widths.count == 2 && dims.depths.count == 2)
        for width in dims.widths { #expect(abs(width - 10.5) < 0.3, "width \(width) in") }
        for depth in dims.depths { #expect(depth > 10.6 && depth < 11.3, "depth \(depth) in") }
    }

    /// Build 59 cabinet compartment: a loose shelf with a wall beside the cabinet and the
    /// door open. Tape: 10.5 in side to side, 11.2 in from the back wall to the shelf's
    /// front edge. Build 59 never produced an outline from this sweep.
    @Test func cabinetBesideAWallWithOpenDoorResolvesToTheTapedCompartment() throws {
        let (observations, result) = try replay("cabinet-sweep-b59")
        let outline = result.outline.map { SIMD2($0.x, $0.z) }
        #expect(outline.count == 4, "\(result.hint)")
        guard outline.count == 4 else { return }
        // Width runs across the view (the back wall faces the camera); depth runs along it.
        let look = simd_normalize(observations.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.forward.x, $1.forward.z) })
        var widths: [Float] = [], depths: [Float] = []
        for i in outline.indices {
            let edge = outline[(i+1)%4] - outline[i], length = simd_length(edge)/Self.inch
            if abs(simd_dot(simd_normalize(edge), look)) < 0.5 { widths.append(length) } else { depths.append(length) }
        }
        #expect(widths.count == 2 && depths.count == 2)
        for width in widths { #expect(abs(width - 10.5) < 0.3, "width \(width) in") }
        // The front snaps only as far as two views observed the shelf top, so depth may
        // stay short of the tape; it must never exceed it.
        for depth in depths { #expect(depth > 10.6 && depth < 11.3, "depth \(depth) in") }
        // One patch of this shelf was never observed; that, and only that, still blocks review.
        #expect(!result.ready)
        #expect(result.hint.contains("gap"), "\(result.hint)")
    }
}
