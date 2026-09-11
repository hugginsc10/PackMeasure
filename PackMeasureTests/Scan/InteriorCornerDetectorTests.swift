import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Automatic interior corners")
struct InteriorCornerDetectorTests {
    let size = 40
    func sample(_ floor: (Int,Int) -> Bool) -> [SIMD3<Float>?] {
        (0..<size*size).map { i in
            let x = i % size, y = i / size
            return SIMD3<Float>(Float(x)*0.01, floor(x,y) ? 0 : 0.05, Float(y)*0.01)
        }
    }
    func detect(_ data: [SIMD3<Float>?], seed: Int = 410) throws -> [[SIMD3<Float>]] {
        try InteriorCornerDetector.detect(width: size, height: size, surface: data, seed: seed) { x,y in
            SIMD3<Float>(x*0.01,0,y*0.01)
        }
    }
    func rectangle(_ x: Int, _ y: Int) -> Bool { (5..<35).contains(x) && (5..<30).contains(y) }
    @Test func rectangleFindsFourCornersWithoutTaps() throws {
        let loops = try detect(sample(rectangle))
        #expect(loops.count == 1)
        #expect(loops[0].count == 4)
        #expect(abs(loops[0].map(\.x).max()! - loops[0].map(\.x).min()! - 0.3) < 0.0001)
    }
    @Test func notchRemainsConcave() throws {
        let loops = try detect(sample { x,y in rectangle(x,y) && !(x >= 20 && y >= 20) })
        #expect(loops[0].count == 6)
        let polygon = loops[0].map { InteriorPoint(x: Double($0.x)*1000,y:Double($0.z)*1000) }
        #expect(!InteriorGeometry.contains(.init(x:250,y:250), in:polygon))
    }
    @Test func raisedObstacleCreatesHole() throws {
        let loops = try detect(sample { x,y in rectangle(x,y) && !((18..<23).contains(x) && (15..<20).contains(y)) })
        #expect(loops.count == 2)
        #expect(loops.allSatisfy { $0.count == 4 })
    }
    @Test func unknownDepthCannotBecomeAnObstacle() {
        var data = sample(rectangle); data[17*size+20] = nil
        #expect(throws: (any Error).self) { try detect(data) }
    }
    @Test func clippedFloorRejected() {
        #expect(throws: (any Error).self) { try detect(sample { x,y in x < 35 && y < 30 }) }
    }
    @Test func missingEdgeRejected() {
        var data = sample(rectangle); data[4*size+10] = nil
        #expect(throws: (any Error).self) { try detect(data) }
    }
    @Test func dropOffIsNotAWall() {
        var data = sample(rectangle); data[4*size+10]?.y = -0.1
        #expect(throws: (any Error).self) { try detect(data) }
    }
    @Test @MainActor func pinRequiresFreshPreview() {
        let state = InteriorScanState()
        state.automatic = true
        state.preview = [[SIMD3(0,0,0),SIMD3(0.4,0,0),SIMD3(0.4,0,0.3),SIMD3(0,0,0.3)]]
        state.previewTimestamp = 10
        state.stablePreviewFrames = 3
        state.pinOutline(now: 11)
        #expect(!state.pinned)
        state.pinOutline(now: 10.2)
        #expect(state.pinned)
        #expect(state.loops[0].count == 4)
        #expect(!state.automatic)
    }
    @Test @MainActor func movingOrChangingOutlineCannotPin() {
        let state = InteriorScanState()
        state.automatic = true
        let loop: [[SIMD3<Float>]] = [[SIMD3(0,0,0),SIMD3(0.4,0,0),SIMD3(0.4,0,0.3),SIMD3(0,0,0.3)]]
        state.updatePreview(loop, now: 1)
        state.pinOutline(now: 1.1)
        #expect(!state.pinned)
        state.updatePreview(loop, now: 1.3)
        state.updatePreview(loop, now: 1.6)
        #expect(state.stablePreviewFrames == 3)
        state.updatePreview(loop.map { $0.map { $0 + SIMD3<Float>(0.02,0,0) } }, now: 1.9)
        #expect(state.stablePreviewFrames == 1)
    }
    @Test @MainActor func interruptionClearsAutomaticGeometry() {
        let state = InteriorScanState()
        state.automatic = true
        state.automaticSeed = .zero
        state.preview = [[.zero]]
        state.invalidate("Interrupted")
        #expect(!state.automatic)
        #expect(state.preview.isEmpty)
        #expect(state.automaticSeed == nil)
        #expect(state.loops == [[]])
    }
    @Test @MainActor func cornerAdjustmentValidatesWholeOutline() {
        let state = InteriorScanState()
        state.loops = [[SIMD3(0,0,0),SIMD3(0.4,0,0),SIMD3(0.4,0,0.3),SIMD3(0,0,0.3)]]
        state.pinned = true
        state.selectedCorner = (0,1)
        let original = state.loops
        state.receive(SIMD3(0,0,0.3))
        #expect(state.loops == original)
        #expect(state.error != nil)
        state.receive(SIMD3(0.41,0,0))
        #expect(state.loops[0][1].x == 0.41)
        #expect(state.selectedCorner == nil)
    }
}
