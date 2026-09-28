import XCTest
import UIKit
import simd
@testable import PackMeasure

final class WireShelfGeometryTests: XCTestCase {
    private func match(_ p: SIMD3<Float>) throws -> ShelfPointMatch {
        let a = p + [-0.2,0.1,0.7], b = p + [0.2,0.1,0.7]
        return try ShelfPointMatch(first: .init(origin: a, direction: p-a), second: .init(origin: b, direction: p-b))
    }
    func testMatchingViewsRecoverWirePointWithoutAnyDepthInput() throws {
        let p = SIMD3<Float>(0.3,1.2,-1.4), m = try match(p)
        XCTAssertLessThan(simd_distance(m.point,p),0.00001)
        XCTAssertEqual(m.baseline,0.4,accuracy:0.00001)
        XCTAssertLessThan(m.rayGap,0.00001)
    }
    func testTriangulationIsInvariantUnderWorldTranslationAndRotation() throws {
        let p = SIMD3<Float>(0.3,1.2,-1.4), m = try match(p)
        let rotation = simd_quatf(angle:0.72,axis:simd_normalize(SIMD3<Float>(0.4,1,0.2)))
        let translation = SIMD3<Float>(7,-2,4)
        let rotated = try ShelfPointMatch(first: .init(origin:rotation.act(m.first.origin)+translation,direction:rotation.act(m.first.direction)),
                                         second:.init(origin:rotation.act(m.second.origin)+translation,direction:rotation.act(m.second.direction)))
        XCTAssertLessThan(simd_distance(rotated.point,rotation.act(p)+translation),0.00001)
    }
    func testTurningInPlaceAndInsufficientParallaxCannotProduceMeasurement() throws {
        let a = try ShelfCameraRay(origin:[0,0,0],direction:[0,0,-1])
        XCTAssertThrowsError(try ShelfPointMatch(first:a,second:.init(origin:[0,0,0],direction:[0.1,0,-1])))
        XCTAssertThrowsError(try ShelfPointMatch(first:a,second:.init(origin:[0.2,0,0],direction:[0,0,-1])))
        XCTAssertThrowsError(try ShelfPointMatch(first:a,second:.init(origin:[0.05,0,0],direction:[-0.2,0,-1])))
    }
    func testRaysMustAgreeAndPointMustBeInFrontAndWithinRange() throws {
        let a = try ShelfCameraRay(origin:[-0.2,0,0],direction:[0.2,0,-1])
        XCTAssertThrowsError(try ShelfPointMatch(first:a,second:.init(origin:[0.2,0.1,0],direction:[-0.2,0,-1])))
        XCTAssertThrowsError(try ShelfPointMatch(first:a,second:.init(origin:[0.2,0,0],direction:[0.2,0,-1])))
        let p = SIMD3<Float>(0,0,-4)
        XCTAssertThrowsError(try ShelfPointMatch(first:.init(origin:[-0.5,0,0],direction:p-[-0.5,0,0]),second:.init(origin:[0.5,0,0],direction:p-[0.5,0,0])))
        XCTAssertThrowsError(try ShelfCameraRay(origin:[.nan,0,0],direction:[0,0,-1]))
        XCTAssertThrowsError(try ShelfCameraRay(origin:.zero,direction:.zero))
    }
    func testPortraitPhotoSelectionUnrotatesOnceAndUsesCameraIntrinsics() throws {
        let k = simd_float3x3(columns:([1000,0,0],[0,1000,0],[960,720,1]))
        let center = try ShelfCameraRay(portraitPoint:[0.5,0.5],imageSize:[1920,1440],intrinsics:k,cameraTransform:matrix_identity_float4x4)
        XCTAssertEqual(center.direction,SIMD3<Float>(0,0,-1))
        let corner = try ShelfCameraRay(portraitPoint:[0,0],imageSize:[1920,1440],intrinsics:k,cameraTransform:matrix_identity_float4x4)
        XCTAssertLessThan(simd_distance(corner.direction,simd_normalize(SIMD3<Float>(-0.96,-0.72,-1))),0.000001)
        var pose = matrix_identity_float4x4;pose.columns.3=[3,2,1,1]
        XCTAssertEqual(try ShelfCameraRay(portraitPoint:[0.5,0.5],imageSize:[1920,1440],intrinsics:k,cameraTransform:pose).origin,[3,2,1])
        XCTAssertThrowsError(try ShelfCameraRay(portraitPoint:[-0.1,0.5],imageSize:[1920,1440],intrinsics:k,cameraTransform:pose))
    }
    func testFiveMatchedPointsGiveAllThreeDimensionsAndOrderedEvidence() throws {
        var sequence = WireShelfSequence()
        for p: SIMD3<Float> in [[0.5,1.2,0.4],[0.5,0,0.4],[0,1.2,0],[1,1.2,0],[0.5,1.7,0.4]] { try sequence.append(match(p)) }
        XCTAssertEqual(try XCTUnwrap(sequence.result).depth,0.4,accuracy:0.00001)
        XCTAssertEqual(sequence.result!.height,1.2,accuracy:0.00001)
        XCTAssertEqual(sequence.result!.clearance!,0.5,accuracy:0.00001)
        XCTAssertEqual(sequence.orderedMatches.map(\.point),sequence.measurementPoints)
        XCTAssertEqual(sequence.selectedTop,sequence.measurementPoints[3])
    }
    func testWrongFloorAndShelfLevelDoNotAdvanceAndUndoRemovesEvidence() throws {
        var sequence = WireShelfSequence();try sequence.append(match([0.5,1.2,0.4]))
        XCTAssertThrowsError(try sequence.append(match([0.5,1.4,0.4])))
        XCTAssertEqual(sequence.stage,1)
        try sequence.append(match([0.5,0,0.4]))
        XCTAssertThrowsError(try sequence.append(match([0,1.5,0])))
        XCTAssertEqual(sequence.stage,2)
        sequence.undo(); XCTAssertEqual(sequence.stage,1)
        sequence.undo(); XCTAssertNil(sequence.selectedTop)
    }
    func testInvalidBackEdgeOrUpperPointDoesNotLeavePartialGeometry() throws {
        var s = WireShelfSequence()
        for p: SIMD3<Float> in [[0.5,1.2,0.4],[0.5,0,0.4],[0,1.2,0]] { try s.append(match(p)) }
        XCTAssertThrowsError(try s.append(match([0.1,1.2,0])))
        XCTAssertEqual(s.stage,3)
        try s.append(match([1,1.2,0]))
        XCTAssertThrowsError(try s.append(match([1,1.7,0.4])))
        XCTAssertEqual(s.stage,4);XCTAssertNil(s.result)
        try s.skipClearance();XCTAssertNil(s.result?.clearance);XCTAssertNotNil(s.result)
    }
    func testMatchedPointProvenanceSurvivesRoomSaveReloadAndShare() throws {
        var s = WireShelfSequence()
        for p: SIMD3<Float> in [[0.5,1.2,0.4],[0.5,0,0.4],[0,1.2,0],[1,1.2,0]] { try s.append(match(p)) }
        try s.skipClearance()
        let shelf = try RoomShelfMeasurement(name:"Wire",depth:s.result!.depth,heightAboveFloor:s.result!.height,clearanceAbove:nil,source:.twoView,capturedPoints:s.measurementPoints,selectedTop:s.selectedTop,pointMatches:s.orderedMatches)
        var room = try MeasuredRoom(walls:[.init(id:UUID(),start:[0,0],end:[1,0],height:2.7,confidence:"high")])
        room.shelves=[shelf]
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=RoomScanStore(directory:directory);try store.save(room)
        let loaded=try XCTUnwrap(store.load().first?.shelves?.first)
        XCTAssertEqual(loaded.source,.twoView);XCTAssertEqual(loaded.pointMatches?.count,4)
        XCTAssertEqual(loaded.capturedPoints,s.measurementPoints)
        XCTAssertTrue(loaded.shareText.contains("Matched-point estimate"))
        XCTAssertFalse(loaded.shareText.contains("LiDAR"))
    }
    func testMatchedSourceRequiresEvidenceAndCannotLabelChangedDimensionsAsCaptured() throws {
        XCTAssertThrowsError(try RoomShelfMeasurement(name:"Missing",depth:0.4,heightAboveFloor:1.2,clearanceAbove:nil,source:.twoView))
        var s = WireShelfSequence()
        for p: SIMD3<Float> in [[0.5,1.2,0.4],[0.5,0,0.4],[0,1.2,0],[1,1.2,0]] { try s.append(match(p)) }
        XCTAssertThrowsError(try RoomShelfMeasurement(name:"Changed",depth:0.5,heightAboveFloor:1.2,clearanceAbove:nil,source:.twoView,capturedPoints:s.measurementPoints,selectedTop:s.selectedTop,pointMatches:s.orderedMatches))
        let edited = try RoomShelfMeasurement(name:"Edited",depth:0.5,heightAboveFloor:1.2,clearanceAbove:nil,source:.manual,capturedPoints:s.measurementPoints,selectedTop:s.selectedTop,pointMatches:s.orderedMatches)
        XCTAssertEqual(edited.sourceLabel,"Entered measurements")
    }
    func testLegacyShelfWithoutMatchedViewsStillDecodes() throws {
        let shelf = try RoomShelfMeasurement(name:"Previous",depth:0.4,heightAboveFloor:1.2,clearanceAbove:nil,source:.manual)
        let data = try JSONEncoder().encode(shelf)
        XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("pointMatches"))
        let loaded = try JSONDecoder().decode(RoomShelfMeasurement.self,from:data)
        XCTAssertNil(loaded.pointMatches);XCTAssertEqual(loaded.depth,0.4)
    }
}

@MainActor final class WireShelfStateTests: XCTestCase {
    private let k = simd_float3x3(columns:([700,0,0],[0,700,0],[640,480,1]))
    private func photo(_ state: WireShelfScanState, point: SIMD3<Float>, side: Float) throws -> (WireShelfPhoto,CGPoint) {
        let origin = point + [side,0.1,0.7]
        var pose = matrix_identity_float4x4;pose.columns.3=[origin.x,origin.y,origin.z,1]
        let d = point-origin
        let x = 700*d.x / -d.z+640, y = 480-700*d.y / -d.z
        return (WireShelfPhoto(generation:state.generation,image:UIImage(),imageSize:[1280,960],intrinsics:k,transform:pose),CGPoint(x:CGFloat(1-y/960),y:CGFloat(x/1280)))
    }
    private func capture(_ state: WireShelfScanState, _ point: SIMD3<Float>) throws {
        for side: Float in [-0.2,0.2] {
            state.ready=true;state.requestPhoto()
            let (photo,cursor)=try photo(state,point:point,side:side)
            state.receive(photo,request:try XCTUnwrap(state.photoRequest));state.cursor=cursor;state.confirmPoint()
        }
    }
    func testPhotoRequiresExplicitTapBeforeConfirmAndBothViewsBeforeLock() throws {
        let s=WireShelfScanState();s.ready=true;s.requestPhoto()
        let (photo,cursor)=try photo(s,point:[0.5,1.2,0.4],side:-0.2)
        s.receive(photo,request:try XCTUnwrap(s.photoRequest));s.confirmPoint()
        XCTAssertNil(s.firstPhoto);XCTAssertEqual(s.sequence.stage,0)
        s.cursor=cursor;s.confirmPoint();XCTAssertNotNil(s.firstPhoto);XCTAssertNil(s.sequence.selectedTop)
        s.requestPhoto();let (second,cursor2)=try self.photo(s,point:[0.5,1.2,0.4],side:0.2)
        s.receive(second,request:try XCTUnwrap(s.photoRequest));s.cursor=cursor2;s.confirmPoint()
        XCTAssertEqual(s.sequence.stage,1);XCTAssertNotNil(s.sequence.selectedTop)
    }
    func testBackgroundInvalidatesFirstViewFrozenPhotoAndStaleSnapshot() throws {
        let s=WireShelfScanState();s.ready=true;s.requestPhoto()
        let request=try XCTUnwrap(s.photoRequest), (old,cursor)=try photo(s,point:[0.5,1.2,0.4],side:-0.2)
        s.receive(old,request:request);s.cursor=cursor;s.confirmPoint()
        s.requestPhoto();let pending=try XCTUnwrap(s.photoRequest)
        s.invalidate("Background");s.receive(old,request:pending)
        XCTAssertNil(s.photo);XCTAssertNil(s.firstPhoto);XCTAssertNil(s.photoRequest)
        XCTAssertEqual(s.sequence.stage,0);XCTAssertFalse(s.ready)
    }
    func testRestartPointKeepsEarlierMeasurementsButUndoRemovesLastOne() throws {
        let s=WireShelfScanState();try capture(s,[0.5,1.2,0.4]);try capture(s,[0.5,0,0.4])
        s.requestPhoto();s.restartPoint();XCTAssertEqual(s.sequence.stage,2)
        s.undo();XCTAssertEqual(s.sequence.stage,1);XCTAssertNil(s.firstPhoto)
    }
    func testCompletedSkippedClearanceSurvivesBackgroundAndSharesMatchingEvidence() throws {
        let s=WireShelfScanState()
        for p: SIMD3<Float> in [[0.5,1.2,0.4],[0.5,0,0.4],[0,1.2,0],[1,1.2,0]] {try capture(s,p)}
        s.skipClearance();XCTAssertNotNil(s.sequence.result)
        s.invalidate("Background");XCTAssertNotNil(s.sequence.result)
        XCTAssertTrue(s.diagnostics.contains("baseline_m="));XCTAssertFalse(s.diagnostics.contains("LiDAR estimate"))
    }
    func testAutoFallsBackOnlyForUnusableInitialSurfaceNotTrackingOrLaterPoints() {
        let s=ShelfScanState();s.ready=true;s.request()
        s.reject("Tracking limited",request:s.requestID)
        XCTAssertFalse(s.needsMatchedViews)
        s.request();s.receive([0,1,0],horizontalSurface:false,request:s.requestID)
        XCTAssertTrue(s.needsMatchedViews);XCTAssertNil(s.selectedTop)
        s.request();XCTAssertFalse(s.needsMatchedViews)
        for _ in 0..<5 {s.receive([0,1,0],horizontalSurface:true,request:s.requestID)}
        s.request();s.reject("Depth unavailable",request:s.requestID,useMatchedViews:true)
        XCTAssertFalse(s.needsMatchedViews);XCTAssertNotNil(s.selectedTop)
    }
}
