import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Interior sweep evidence")
struct InteriorSweepEvidenceTests {
    let helper = InteriorSweepTests()
    var loops: [[SIMD3<Float>]] { [helper.rectangle.map { [$0.x,0,$0.y] }] }

    @Test func agreementGivesDenseAndSparseViewsEqualWeight() throws {
        func capture(dense: Bool) -> InteriorSweepSnapshot {
            let views = (0..<4).map { i -> InteriorSweepObservation in
                var o = helper.observation(i,loops:[helper.rectangle],open:true)
                o.front = o.front.map { [$0.x,Float(i*4-6)*0.001] }
                if dense && i == 3 { o.front = Array(repeating:o.front,count:20).flatMap { $0 } }
                return o
            }
            return .init(seed:[0.1,0,0.1],observations:views,rejectedViews:0)
        }
        let normal = try InteriorSweep(snapshot:capture(dense:false)).boundaryAgreement(for:loops)
        let dense = try InteriorSweep(snapshot:capture(dense:true)).boundaryAgreement(for:loops)
        #expect(normal == dense)
        #expect(normal[0].views == 4)
        #expect(abs(try #require(normal[0].spreadMM)-9.6)<0.001)
    }

    @Test func twoViewsCannotReportARepeatabilitySpread() throws {
        let capture = InteriorSweepSnapshot(seed:[0.1,0,0.1],observations:(0..<2).map { helper.observation($0,loops:[helper.rectangle],open:true) },rejectedViews:0)
        let agreement = try InteriorSweep(snapshot:capture).boundaryAgreement(for:loops)
        #expect(agreement.allSatisfy { $0.views == 2 && $0.spreadMM == nil })
    }

    @Test func wallEvidenceRetainsVerticalExtentAtTheSamePlanarPosition() throws {
        var o = helper.observation(0,loops:[helper.rectangle])
        o.wallPoints3D = [[0,0.02,0.1],[0,0.10,0.1],[0,0.02,0.1]]
        var map = InteriorSweep(seed:[0.1,0,0.1]); _ = map.add(o)
        let walls = try #require(map.observations.first?.wallPoints3D)
        #expect(walls.count == 2)
        #expect(walls.map(\.y).max()!-walls.map(\.y).min()! > 0.07)
        let capture = InteriorSweepSnapshot(seed:map.seed,observations:map.observations,rejectedViews:map.rejectedViews,acceptedViews:map.acceptedViews,reconstruction:map.reconstruct())
        let encoded = try JSONEncoder().encode(capture)
        let decoded = try JSONDecoder().decode(InteriorSweepSnapshot.self,from:encoded)
        let restored = try InteriorSweep(snapshot:decoded)
        #expect(restored.observations.first?.wallPoints3D == walls)
        #expect(restored.reconstruct() == capture.reconstruction)
    }

    @Test func invalidOrUnboundedSnapshotsAreRejectedWithoutAdmission() throws {
        let o = helper.observation(0,loops:[helper.rectangle])
        var capture = InteriorSweepSnapshot(seed:[0.1,0,0.1],observations:[o],rejectedViews:0)
        capture.observations[0].wallPoints3D = [[0,.nan,0]]
        #expect(throws:InteriorSweep.SnapshotError.self) { try InteriorSweep(snapshot:capture) }
        capture.observations = Array(repeating:o,count:InteriorSweep.maxViews+1)
        #expect(throws:InteriorSweep.SnapshotError.self) { try InteriorSweep(snapshot:capture) }
        capture.observations = [o]; capture.acceptedViews = 0
        #expect(throws:InteriorSweep.SnapshotError.self) { try InteriorSweep(snapshot:capture) }
    }

    @Test func diagnosticSnapshotKeepsSelectedGeometryAndReviewHeightSeparate() async throws {
        let worker = InteriorSweepWorker(), generation = UUID()
        let frame = helper.cabinetFrame(0,fascia:false)
        let live = await worker.process(frame,seed:[0.2,0,0.15],generation:generation)
        let selected = InteriorSweepResult(loops:loops,views:3)
        let review = try InteriorGeometry.project(loops,enteredHeightMM:123)
        let report = await worker.replay(generation:generation,selectedResult:selected,reviewMeasurement:review)
        guard case .available(let json) = report else { Issue.record("No snapshot"); return }
        let capture = try JSONDecoder().decode(InteriorSweepSnapshot.self,from:Data(json.utf8))
        #expect(capture.reconstruction == live)
        #expect(capture.selectedResult == selected)
        #expect(capture.reviewMeasurement == review)
        #expect(capture.reviewMeasurement?.heightSource == .entered)
    }

    @Test @MainActor func reviewPreservesSweepAgreementAndDoesNotAttachItToCorrectedCorners() throws {
        let state = InteriorScanState(); state.loops = loops; state.takingHeight = true
        let agreement = [InteriorBoundaryAgreement(loop:0,edge:0,views:4,spreadMM:9.6,horizontalCameraSpanMM:75)]
        state.sweepResult = .init(loops:loops,views:4,boundaryAgreement:agreement)
        state.enterHeight(123)
        let record = try #require(state.result)
        #expect(record.capturedBoundaryAgreement == agreement)
        let restored = try JSONDecoder().decode(InteriorMeasurement.self,from:JSONEncoder().encode(record))
        #expect(restored == record)
        state.result = nil; state.loops[0][1].x -= 0.01
        state.enterHeight(123)
        #expect(state.result?.capturedBoundaryAgreement == nil)
    }
}
