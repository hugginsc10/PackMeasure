import Testing
import UIKit
import simd
@testable import PackMeasure

@Suite("Interior photo placement and guided flow") @MainActor
struct InteriorExperienceTests {
    let world: [[SIMD3<Float>]] = [[.init(0,0,0),.init(0.4,0,0),.init(0.4,0,0.3),.init(0,0,0.3)]]
    func photo(generation: UUID, badPixel: Bool = false) -> InteriorPhoto {
        var confidence = [UInt8](repeating: 2, count: 10000)
        if badPixel { confidence[50*100+50] = 0 }
        var pose = simd_float4x4(simd_quatf(angle: -.pi/2, axis: [1,0,0]))
        pose.columns.3 = [0,1,0,1]
        return InteriorPhoto(generation: generation, image: UIImage(),
            grid: DepthGrid(width: 100, height: 100, depths: [Float](repeating: 1, count: 10000), confidences: confidence),
            imageSize: [100,100], intrinsics: simd_float3x3(columns: ([100,0,0],[0,100,0],[50,50,1])), transform: pose)
    }
    @Test func portraitTapAndOverlayUseSameCameraFrame() throws {
        let photo = photo(generation: UUID())
        for p in [CGPoint(x:0.2,y:0.3),CGPoint(x:0.8,y:0.7),CGPoint(x:0.5,y:0.5)] {
            let world = try #require(photo.worldPoint(at: p))
            #expect(abs(world.y) < 0.0001)
            let roundTrip = try #require(photo.portraitPoint(world))
            #expect(abs(roundTrip.x-p.x) <= 0.011 && abs(roundTrip.y-p.y) <= 0.011)
        }
        #expect(photo.portraitPoint([0,2,0]) == nil)
    }
    @Test func badTappedPixelDoesNotChooseReliableNeighbors() {
        let photo = photo(generation: UUID(), badPixel: true)
        #expect(photo.worldPoint(at: CGPoint(x:0.5,y:0.5)) == nil)
        #expect(photo.worldPoint(at: CGPoint(x:0.7,y:0.7)) != nil)
        #expect(photo.worldPoint(at: CGPoint(x:-0.1,y:0.5)) == nil)
        #expect(photo.worldPoint(at: CGPoint(x:Double.nan,y:0.5)) == nil)
    }
    @Test func frozenCornersRemainWhenChangingView() {
        let state = InteriorScanState(); state.ready = true; state.useManual(); state.freezeView()
        state.receivePhoto(photo(generation: state.generation))
        [CGPoint(x:0.2,y:0.2),CGPoint(x:0.8,y:0.2),CGPoint(x:0.8,y:0.8),CGPoint(x:0.2,y:0.8)].forEach(state.placePhotoPoint)
        #expect(state.loops[0].count == 4)
        let original = state.loops
        state.resumeCamera(); state.freezeView(); state.receivePhoto(photo(generation: state.generation))
        #expect(state.loops == original)
        #expect(state.photo != nil)
        state.finishLoop(addObstacle: false)
        #expect(state.takingHeight && state.photo == nil)
    }
    @Test func badPhotoTapAndOldGenerationCannotAdvanceScan() {
        let state = InteriorScanState(); state.ready = true; state.useManual(); state.freezeView()
        let old = photo(generation: state.generation, badPixel: true)
        state.receivePhoto(old); state.placePhotoPoint(CGPoint(x:0.5,y:0.5))
        #expect(state.loops == [[]] && state.error != nil)
        state.invalidate("Interrupted"); state.ready = true; state.freezeView(); state.receivePhoto(old)
        #expect(state.photo == nil && state.loops == [[]])
    }
    @Test func pinnedOutlineSupportsAddingAnObstacleWithoutStartingOver() {
        let state = InteriorScanState(); state.loops = world; state.pinned = true
        state.useManual()
        #expect(state.loops == world && state.pinned)
        state.finishLoop(addObstacle: true)
        #expect(state.loops[0] == world[0] && !state.pinned)
        [[Float(0.1),0,0.1],[0.2,0,0.1],[0.2,0,0.2],[0.1,0,0.2]].forEach { state.receive(SIMD3($0)) }
        state.finishLoop(addObstacle: false); state.enterHeight(100)
        #expect(state.result?.contours.count == 2)
        #expect(state.result?.heightSource == .entered)
    }
    @Test func frozenCorrectionMovesOnlyChosenCorner() {
        let state = InteriorScanState(); state.ready = true; state.useManual(); state.freezeView()
        state.receivePhoto(photo(generation: state.generation))
        [CGPoint(x:0.2,y:0.2),CGPoint(x:0.8,y:0.2),CGPoint(x:0.8,y:0.8),CGPoint(x:0.2,y:0.8)].forEach(state.placePhotoPoint)
        let original = state.loops
        state.selectCorner(loop: 0, point: 1); state.placePhotoPoint(CGPoint(x:0.82,y:0.2))
        #expect(state.loops[0].count == 4 && state.loops[0][1] != original[0][1])
        #expect(state.loops[0][0] == original[0][0] && state.loops[0][2] == original[0][2])
        #expect(state.selectedCorner == nil)
    }
    @Test func acceptingAutomaticOutlineGoesStraightToHeightAndBackKeepsOutline() {
        let state = InteriorScanState(); state.automatic = true
        state.updatePreview(world, now: 1); state.updatePreview(world, now: 1.2); state.updatePreview(world, now: 1.4)
        state.useOutline(now: 1.5)
        #expect(state.pinned && state.takingHeight && state.loops == world)
        state.editOutline()
        #expect(!state.takingHeight && state.loops == world)
    }
    @Test func staleAutomaticOutlineCannotAdvanceToHeight() {
        let state = InteriorScanState(); state.automatic = true
        state.updatePreview(world, now: 1); state.updatePreview(world, now: 1.2); state.updatePreview(world, now: 1.4)
        state.useOutline(now: 2.1)
        #expect(!state.takingHeight && !state.pinned)
    }
    @Test func heightMayUseAnotherVisibleTopEdgeButNotUnrelatedGeometry() throws {
        let record = try InteriorGeometry.project(world, heightPoint: [0.4,0.15,0.3])
        #expect(abs(record.heightMM - 150) < 0.01 && record.heightSource == .lidar)
        #expect(throws: (any Error).self) { try InteriorGeometry.project(world, heightPoint: [0.8,0.15,0.3]) }
        let withObstacle = world + [[SIMD3(0.1,0,0.1),SIMD3(0.2,0,0.1),SIMD3(0.2,0,0.2),SIMD3(0.1,0,0.2)]]
        #expect(throws: (any Error).self) { try InteriorGeometry.project(withObstacle, heightPoint: [0.15,0.1,0.15]) }
    }
    @Test func enteredHeightSupportsCabinetsAndRejectsInvalidValues() throws {
        let record = try InteriorGeometry.project(world, enteredHeightMM: 1800)
        #expect(record.heightMM == 1800 && record.heightSource == .entered)
        for endpoint in [10.0, 3000.0] {
            #expect(try InteriorGeometry.project(world, enteredHeightMM: endpoint).heightMM == endpoint)
        }
        for invalid in [Double.nan, .infinity, -1, 0, 3001] {
            #expect(throws: (any Error).self) { try InteriorGeometry.project(world, enteredHeightMM: invalid) }
        }
    }
    @Test func oldRecordsDecodeAndHeightSourcePersists() throws {
        let record = try InteriorGeometry.project(world, enteredHeightMM: 123)
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(InteriorMeasurement.self, from: data) == record)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]); old.removeValue(forKey: "heightSource")
        let restored = try JSONDecoder().decode(InteriorMeasurement.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.heightSource == nil && restored.contours == record.contours)
    }
    @Test func completedDraftSurvivesInterruptionButUnfinishedPhotoDoesNot() {
        let state = InteriorScanState(); state.loops = world; state.finishLoop(addObstacle: false); state.enterHeight(100)
        let completed = state.result; state.invalidate("Background")
        #expect(state.result == completed)
        let other = InteriorScanState(); other.ready = true; other.freezeView(); other.receivePhoto(photo(generation: other.generation))
        other.placePhotoPoint(CGPoint(x:0.5,y:0.5)); other.invalidate("Background")
        #expect(other.photo == nil && !other.photoRequested && other.loops == [[]])
    }
}
