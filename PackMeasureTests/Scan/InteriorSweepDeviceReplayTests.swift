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

    func snapshot(_ name: String) throws -> InteriorSweepSnapshot {
        let url = try #require(Bundle(for: FixtureBundle.self).url(forResource:name,withExtension:"json"))
        return try JSONDecoder().decode(InteriorSweepSnapshot.self,from:Data(contentsOf:url))
    }

    func replay(_ name: String) throws -> (observations: [InteriorSweepObservation], result: InteriorSweepResult) {
        let url = try #require(Bundle(for: FixtureBundle.self).url(forResource: name, withExtension: "json"))
        let recorded = try JSONDecoder().decode(Replay.self, from: Data(contentsOf: url))
        var map = InteriorSweep(seed: recorded.seed), result = InteriorSweepResult()
        for observation in recorded.observations { result = map.add(observation) }
        return (recorded.observations, result)
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

    /// Lock down the actual error before optimizing. These assertions reproduce the
    /// screenshots; they are not acceptance tolerances against the tape baseline.
    @Test(arguments: ["cabinet-sweep-b61-short", "cabinet-sweep-b61-wide"])
    func retainedBuild61SnapshotsReproduceTheReviewedDimensions(_ name: String) throws {
        let capture = try snapshot(name), map = try InteriorSweep(snapshot:capture)
        let result = map.reconstruct()
        #expect(result.ready && result.outline.count == 4)
        let record = try InteriorGeometry.project(result.loops,enteredHeightMM:100), p = record.contours[0]
        let along = (p.map(\.x).max()!-p.map(\.x).min()!)/25.4
        let across = (p.map(\.y).max()!-p.map(\.y).min()!)/25.4
        let expected = name.hasSuffix("short") ? (10.5719749383,10.6063907541) : (11.05147318577,10.71045952519)
        #expect(abs(along-expected.0)<0.0001 && abs(across-expected.1)<0.0001)
        #expect(map.observations.count == capture.observations.count)
        #expect(map.viewEvidence.count == capture.observations.count)
        #expect(capture.observations.allSatisfy { $0.wallPoints3D == nil })
    }

    @Test func retainedBudgetSnapshotMustNotBeReadmittedAsAnAcquisitionStream() throws {
        let capture = try snapshot("cabinet-sweep-b61-wide")
        var readmitted = InteriorSweep(seed:capture.seed)
        for view in capture.observations { _ = readmitted.add(view) }
        // Discarded acquisition history is absent: a retained view now fails the pose
        // gate despite having passed it during the original capture.
        #expect(readmitted.observations.count == 39)
        #expect(try InteriorSweep(snapshot:capture).observations.count == 40)
    }

    @Test func wideCaptureReportsDisagreementAndShortCaptureHasLittleLateralEvidence() throws {
        let wide = try InteriorSweep(snapshot:snapshot("cabinet-sweep-b61-wide")).reconstruct()
        let wideAgreement = try #require(wide.boundaryAgreement)
        #expect(wideAgreement.compactMap(\.spreadMM).max()! > 8)
        #expect(wideAgreement.map(\.horizontalCameraSpanMM).max()! > 250)
        let short = try InteriorSweep(snapshot:snapshot("cabinet-sweep-b61-short")).reconstruct()
        let shortAgreement = try #require(short.boundaryAgreement)
        #expect(shortAgreement.map(\.horizontalCameraSpanMM).max()! < 12)
        // Neither high-confidence depth nor similar successive polygons proves
        // dimensional accuracy; the two captures fail for different reasons.
    }

    @Test(arguments:["cabinet-sweep-b61-short","cabinet-sweep-b61-wide"])
    func explicitRectangleReducesWidthAndWorstEdgeErrorWithoutInventingDepth(_ name: String) throws {
        var capture = try snapshot(name)
        let old = try InteriorSweep(snapshot:capture).reconstruct()
        capture.footprintModel = .rectangular
        let fitted = try InteriorSweep(snapshot:capture).reconstruct()
        #expect(fitted.ready,"\(fitted.hint)")
        let loop = try #require(fitted.loops.first)
        let edges = loop.indices.map { simd_distance(loop[$0],loop[($0+1)%4])/Self.inch }
        #expect(abs(edges[0]-edges[2])<0.0001 && abs(edges[1]-edges[3])<0.0001)
        #expect(abs(edges[1]-10.5)<0.02)
        #expect(edges[0]<11.2,"An unobserved front must not extend to the tape reference")
        let oldErrors = old.outline.indices.map { abs(simd_distance(old.outline[$0],old.outline[($0+1)%4])/Self.inch - ($0%2==0 ? 11.2:10.5)) }
        let newErrors = edges.indices.map { abs(edges[$0]-($0%2==0 ? 11.2:10.5)) }
        #expect(newErrors.max()!<oldErrors.max()!)
        #expect(newErrors.reduce(0,+)<oldErrors.reduce(0,+))
        #expect(fitted.wallPlaneViews == [0,0,0,0],"v1 captures must not fabricate wall heights")
    }
}
