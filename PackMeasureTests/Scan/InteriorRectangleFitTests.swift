import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Rectangular compartment fitting")
struct InteriorRectangleFitTests {
    let helper = InteriorSweepTests()

    @Test func tiltedWallPlaneIntersectsTheBaseInsteadOfFlatteningHeight() throws {
        var points = [SIMD3<Float>]()
        for ti in 0..<30 { for hi in 0..<12 {
            let t = 0.02+Float(ti)*0.009, h = 0.025+Float(hi)*0.01
            let noise = Float((ti*7+hi)%5-2)*0.0002
            points.append([0.01+0.04*t+0.08*h+noise,h,t])
        } }
        let plane = try #require(InteriorSweep.wallPlane(points,at:.zero,tangent:[0,1]))
        for t: Float in [0.04,0.15,0.27] {
            #expect(abs(simd_dot(plane.normal,[0.01+0.04*t,t])-plane.offset)<0.0003)
        }
        #expect(abs(plane.heightSlope+0.08)<0.001)
        let flat = InteriorSweep.fit(points.map { .init(p:[$0.x,$0.z],view:0) })
        #expect(abs(simd_dot(flat.normal,[0.016,0.15])-flat.offset)>0.006)
    }

    @Test func aThinOrDiagonalWallPatchCannotIdentifyAPlane() {
        let thin = (0..<40).map { i -> SIMD3<Float> in [0,0.05,Float(i)*0.006] }
        let diagonal = (0..<40).map { i -> SIMD3<Float> in let t=Float(i)*0.006; return [0,t/2,t] }
        #expect(InteriorSweep.wallPlane(thin,at:.zero,tangent:[0,1]) == nil)
        #expect(InteriorSweep.wallPlane(diagonal,at:.zero,tangent:[0,1]) == nil)
    }

    func tiltedObservation(_ i: Int) -> InteriorSweepObservation {
        var frame = helper.observation(i,loops:[helper.rectangle],open:true)
        var raw = [SIMD3<Float>]()
        for p in frame.walls { for hi in 0..<20 {
            let h = 0.02+Float(hi)*0.006
            let x = p.x<0.001 ? p.x+0.08*h : p.x>0.399 ? p.x-0.08*h : p.x
            let z = p.y>0.299 ? p.y-0.06*h : p.y
            raw.append([x,h,z])
        } }
        frame.wallPoints3D = raw; frame.walls = raw.map { [$0.x,$0.z] }
        return frame
    }

    @Test func rectangularSweepUsesWallHeightToRecoverTheBaseFootprint() throws {
        var observed = InteriorSweep(seed:[0.1,0,0.1])
        var rectangle = InteriorSweep(seed:[0.1,0,0.1],footprintModel:.rectangular)
        for i in 0..<5 { _ = observed.add(tiltedObservation(i)); _ = rectangle.add(tiltedObservation(i)) }
        let result = rectangle.reconstruct(), baseline = observed.reconstruct()
        #expect(result.ready,"\(result.hint)")
        let loop = try #require(result.loops.first)
        let width = loop.map(\.x).max()!-loop.map(\.x).min()!
        let depth = loop.map(\.z).max()!-loop.map(\.z).min()!
        #expect(abs(width-0.4)<0.001 && abs(depth-0.3)<0.001,"\(width), \(depth), planes \(result.wallPlaneViews ?? [])")
        #expect((result.wallPlaneViews ?? []).reduce(0,+)>=10)
        let old = try #require(baseline.loops.first)
        #expect(abs(old.map(\.x).max()!-old.map(\.x).min()!-0.4)>0.003)
    }

    @Test(arguments:[Float(0.37),1.17,-0.62])
    func jointAxesFollowTheCompartmentRatherThanWorldAxes(_ angle: Float) throws {
        func rotate(_ p: SIMD2<Float>) -> SIMD2<Float> {
            [p.x*cos(angle)-p.y*sin(angle)-0.12,p.x*sin(angle)+p.y*cos(angle)+0.35]
        }
        let seed = rotate([0.1,0.1])
        var map = InteriorSweep(seed:[seed.x,0,seed.y],footprintModel:.rectangular)
        for i in 0..<5 {
            var frame = helper.observation(i,loops:[helper.rectangle],open:true)
            frame.floor = frame.floor.map(rotate); frame.front = frame.front.map(rotate)
            frame.walls = frame.walls.enumerated().map { index,p in
                rotate(p+[Float((index+i)%5-2)*0.0002,Float((index*3+i)%5-2)*0.0002])
            }
            let camera = rotate([frame.camera.x,frame.camera.z]); frame.camera = [camera.x,frame.camera.y,camera.y]
            _ = map.add(frame)
        }
        let result = map.reconstruct()
        #expect(result.ready,"\(result.hint)")
        let loop = try #require(result.loops.first)
        let lengths = loop.indices.map { simd_distance(loop[$0],loop[($0+1)%4]) }.sorted()
        #expect(abs(lengths[0]-0.3)<0.001 && abs(lengths[3]-0.4)<0.001)
        let a = simd_normalize(loop[1]-loop[0]), b = simd_normalize(loop[2]-loop[1])
        #expect(abs(simd_dot(a,b))<0.00001)
    }

    @Test func aDenseBiasedViewCannotOutvoteThreeAgreeingViews() throws {
        var frames = (0..<4).map { helper.observation($0,loops:[helper.rectangle],open:true) }
        let biased = frames[3].walls.map { $0.x<0.001 ? $0+SIMD2<Float>(0.006,0) : $0 }
        frames[3].walls = Array(repeating:biased,count:20).flatMap { $0 }
        let map = try InteriorSweep(snapshot:.init(seed:[0.1,0,0.1],observations:frames,rejectedViews:0,footprintModel:.rectangular))
        let polygon = helper.rectangle.map { SIMD3<Float>($0.x,0,$0.y) }
        let lines = helper.rectangle.indices.map { i -> InteriorSweep.Line in
            let a = helper.rectangle[i], b = helper.rectangle[(i+1)%4], t = simd_normalize(b-a), n = SIMD2(-t.y,t.x)
            return .init(normal:n,offset:simd_dot(n,a),low:min(simd_dot(t,a),simd_dot(t,b)),high:max(simd_dot(t,a),simd_dot(t,b)),isFront:i==0)
        }
        let fitted = try #require(map.rectangularOutline(polygon,lines:lines))
        #expect(abs(fitted.outline.map(\.x).min()!)<0.0001)
        #expect(abs(fitted.outline.map(\.x).max()!-0.4)<0.0001)
    }

    @Test func missingFrontAndNotchesCannotBecomeRectangles() {
        for notch in [false,true] {
            let shape: [SIMD2<Float>] = notch ? [[0,0],[0.4,0],[0.4,0.15],[0.25,0.15],[0.25,0.3],[0,0.3]] : helper.rectangle
            var map = InteriorSweep(seed:[0.1,0,0.1],footprintModel:.rectangular)
            for i in 0..<4 {
                var o = helper.observation(i,loops:[shape],open:true)
                if !notch { o.front=[] }
                _ = map.add(o)
            }
            #expect(!map.reconstruct().ready)
        }
    }

    @Test func rectanglePreservesObstacleLoopsAndNearerHingeConstraint() throws {
        let hole: [SIMD2<Float>] = [[0.2,0.12],[0.28,0.12],[0.28,0.2],[0.2,0.2]]
        var map = InteriorSweep(seed:[0.1,0,0.1],footprintModel:.rectangular)
        for i in 0..<4 {
            var o = helper.observation(i,loops:[helper.rectangle,hole],open:true)
            for step in 0...16 { o.walls.append([0.01,0.02+Float(step)*0.005]) }
            o.floor.removeAll { $0.x<0.01 && (0.02...0.10).contains($0.y) }
            _ = map.add(o)
        }
        let result = map.reconstruct()
        #expect(result.ready,"\(result.hint)")
        try #require(result.loops.count == 2)
        #expect(try #require(result.loops.first).map(\.x).min()!>=0.009)
        #expect(InteriorGeometry.contains(.init(x:0.24,y:0.16),in:result.loops[1].map{.init(x:Double($0.x),y:Double($0.z))}))
        #expect(abs(abs(InteriorGeometry.area(result.loops[1].map{.init(x:Double($0.x),y:Double($0.z))}))-0.0064)<0.0001)
    }

    @Test func rectangularSnapshotRestoresItsModel() throws {
        var map = InteriorSweep(seed:[0.1,0,0.1],footprintModel:.rectangular)
        for i in 0..<4 { _ = map.add(helper.observation(i,loops:[helper.rectangle],open:true)) }
        let capture = InteriorSweepSnapshot(seed:map.seed,observations:map.observations,rejectedViews:0,acceptedViews:map.acceptedViews,reconstruction:map.reconstruct(),footprintModel:.rectangular)
        let decoded = try JSONDecoder().decode(InteriorSweepSnapshot.self,from:JSONEncoder().encode(capture))
        #expect(try InteriorSweep(snapshot:decoded).reconstruct()==capture.reconstruction)
    }
}
