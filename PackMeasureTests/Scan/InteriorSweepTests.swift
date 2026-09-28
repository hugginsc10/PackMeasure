import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Interior sweep reconstruction")
struct InteriorSweepTests {
    let rectangle: [SIMD2<Float>] = [[0,0],[0.4,0],[0.4,0.3],[0,0.3]]
    func observation(_ index: Int, loops: [[SIMD2<Float>]], open: Bool = false, part: Int? = nil,
                     overhead: Float? = nil) -> InteriorSweepObservation {
        let outer=loops[0].map { InteriorPoint(x:Double($0.x),y:Double($0.y)) }
        let holes=loops.dropFirst().map { $0.map { InteriorPoint(x:Double($0.x),y:Double($0.y)) } }
        var floor=[SIMD2<Float>](), walls=[SIMD2<Float>](), front=[SIMD2<Float>](), top=[SIMD3<Float>]()
        for xi in 0..<80 { for yi in 0..<60 {
            let p=SIMD2<Float>(Float(xi)*0.006+0.003,Float(yi)*0.006+0.003)
            guard part == nil || (part==0 ? p.x<0.23 : p.x>0.17) else { continue }
            let q=InteriorPoint(x:Double(p.x),y:Double(p.y))
            if InteriorGeometry.contains(q,in:outer) && !holes.contains(where:{InteriorGeometry.contains(q,in:$0)}) {
                floor.append(p)
                if let overhead { top.append([p.x,overhead,p.y]) }
            }
        } }
        for (li,loop) in loops.enumerated() { for i in loop.indices {
            let a=loop[i], b=loop[(i+1)%loop.count], steps=Int(simd_distance(a,b)/0.005)
            for step in 0...steps {
                let p=a+(b-a)*Float(step)/Float(steps)
                guard part == nil || (part==0 ? p.x<0.23 : p.x>0.17) else { continue }
                if open && li==0 && i==0 { front.append(p) } else { walls.append(p) }
            }
        } }
        return .init(timestamp:Double(index)*0.4,camera:[Float(index)*0.025,0.8,0.6],forward:[0,-1,0],floor:floor,walls:walls,front:front,overhead:top)
    }
    func run(_ loops: [[SIMD2<Float>]], open: Bool=false, overhead: Float?=nil) -> InteriorSweepResult {
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 { result=map.add(observation(i,loops:loops,open:open,overhead:overhead)) }
        return result
    }
    @Test func openCabinetFrontAndWallsProduceAutomaticCorners() throws {
        let result=run([rectangle],open:true)
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        let loop=try #require(result.loops.first)
        #expect(loop.count==4)
        #expect(abs(loop.map(\.x).max()!-loop.map(\.x).min()!-0.4)<0.002)
        #expect(abs(loop.map(\.z).max()!-loop.map(\.z).min()!-0.3)<0.002)
    }
    @Test func partialViewsAccumulateWithoutOneCompleteFrame() {
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 {
            result=map.add(observation(i,loops:[rectangle],open:true,part:i%2))
            if i==0 { #expect(!result.ready) }
        }
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        #expect(result.loops.first?.count==4)
    }
    @Test func concaveNotchRemainsInOutline() throws {
        let notch: [SIMD2<Float>]=[[0,0],[0.4,0],[0.4,0.15],[0.25,0.15],[0.25,0.3],[0,0.3]]
        let result=run([notch])
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        let loop=try #require(result.loops.first)
        #expect(loop.count==6)
        #expect(!InteriorGeometry.contains(.init(x:0.35,y:0.25),in:loop.map{.init(x:Double($0.x),y:Double($0.z))}))
    }
    @Test func observedObstacleIsKeptAsCutout() {
        let hole: [SIMD2<Float>]=[[0.2,0.12],[0.28,0.12],[0.28,0.2],[0.2,0.2]]
        let result=run([rectangle,hole])
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        #expect(result.loops.count==2)
    }
    @Test func unobservedFrontCannotBeInvented() {
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 { var f=observation(i,loops:[rectangle],open:true); f.front=[]; result=map.add(f) }
        #expect(!result.ready && result.loops.isEmpty)
    }
    @Test func unsupportedHoleRequiresMoreCoverage() {
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 {
            var f=observation(i,loops:[rectangle]); f.floor.removeAll { (0.17...0.28).contains($0.x) && (0.1...0.22).contains($0.y) }
            result=map.add(f)
        }
        #expect(!result.ready)
    }
    @Test func neighboringDisconnectedFloorDoesNotExpandTarget() throws {
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 {
            var f=observation(i,loops:[rectangle])
            f.floor += f.floor.map { $0+SIMD2(0.6,0) }; f.walls += f.walls.map { $0+SIMD2(0.6,0) }
            result=map.add(f)
        }
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        #expect(try #require(result.loops.first).allSatisfy{$0.x<0.41})
    }
    @Test func repeatedStationaryFramesDoNotUnlockReview() {
        var map=InteriorSweep(seed:[0.1,0,0.1])
        for i in 0..<6 { var f=observation(i,loops:[rectangle]); f.camera=[0,0.8,0.6]; _=map.add(f) }
        #expect(map.observations.count==1)
        #expect(!map.reconstruct().ready)
    }
    @Test func outOfOrderAndNonfiniteObservationsAreRejected() {
        var map=InteriorSweep(seed:[0.1,0,0.1]); _=map.add(observation(3,loops:[rectangle]))
        _=map.add(observation(1,loops:[rectangle]))
        var f=observation(4,loops:[rectangle]); f.floor.append([.nan,0]); _=map.add(f)
        #expect(map.observations.count==1 && map.rejectedViews==2)
    }
    @Test func enoughUndersideCoverageCapturesHeight() {
        let result=run([rectangle],overhead:0.35)
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        #expect(result.height.map{abs($0-0.35)<0.001}==true)
    }
    @Test func oneCeilingPatchOrMultipleLevelsCannotClaimClearHeight() {
        for partial in [true,false] {
            var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
            for i in 0..<4 {
                var f=observation(i,loops:[rectangle],overhead:0.35)
                if partial { f.overhead.removeAll{$0.x>0.1} }
                else { f.overhead=f.overhead.map { p in [p.x,p.x>0.2 ? 0.4:p.y,p.z] } }
                result=map.add(f)
            }
            #expect(result.ready && result.height==nil)
        }
    }
    @Test func observationStorageIsBoundedAndReplayable() throws {
        var map=InteriorSweep(seed:[0.1,0,0.1])
        for i in 0..<44 { _=map.add(observation(i,loops:[rectangle],part:0)) }
        #expect(map.observations.count==40)
        let encoded=try JSONEncoder().encode(map.observations)
        let decoded=try JSONDecoder().decode([InteriorSweepObservation].self,from:encoded)
        #expect(decoded.count==40 && decoded[0].floor==map.observations[0].floor)
    }
    /// An open rectangle whose base has one unobserved 5 cm patch.
    func gapped(_ index: Int) -> InteriorSweepObservation {
        var o=observation(index,loops:[rectangle],open:true)
        o.floor=o.floor.filter { !((0.24...0.29).contains($0.x) && (0.12...0.17).contains($0.y)) }
        return o
    }
    @Test func fullSweepStillAcceptsViewsThatCoverALateGap() {
        // A gap left after the view budget fills must remain coverable, not a dead end.
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<40 { result=map.add(gapped(i)) }
        #expect(!result.ready)
        for i in 40..<44 { result=map.add(observation(i,loops:[rectangle],open:true)) }
        #expect(map.observations.count==40)
        #expect(result.ready, "\(result.hint)")
    }
    @Test @MainActor func reviewUnlocksWhenAGapIsCoveredAfterTheViewBudgetIsFull() {
        // Stored views stay at the budget once full; the scanner must still take each new
        // reconstruction, or a late covering view can never enable review.
        let state=InteriorScanState(); state.ready=true; state.sweepSeed=[0.1,0,0.1]
        var map=InteriorSweep(seed:[0.1,0,0.1])
        for i in 0..<40 { state.receiveSweep(map.add(gapped(i)),generation:state.generation) }
        #expect(!state.canReviewSweep)
        for i in 40..<44 {
            state.receiveSweep(map.add(observation(i,loops:[rectangle],open:true)),generation:state.generation)
        }
        #expect(state.canReviewSweep, "\(state.sweepResult.hint)")
    }
    @Test func offsetDuplicateSideCollapsesToTheSideNearerTheBase() {
        typealias L=InteriorSweep.Line
        let lines=[L(normal:[0,1],offset:0,low:0,high:0.4),        // front
                   L(normal:[1,0],offset:0,low:-0.3,high:0),       // side
                   L(normal:[1,0],offset:-0.021,low:-0.06,high:0)] // sliver 2.1 cm beyond it
        let runs=InteriorSweep.collapsingDuplicateSides([(0,[0.2,0]),(2,[-0.021,0.02]),(1,[0,0.1])],lines:lines,base:[0.1,0.1])
        #expect(runs.map(\.line)==[0,1])
    }
    @Test func genuineShallowBendIsNotStraightenedAway() {
        // Two edges 6° apart that meet where the outline turns are a real corner, even
        // though they are too close to parallel to intersect reliably. Leave them for the
        // corner checks rather than silently keeping one.
        typealias L=InteriorSweep.Line
        let bend=SIMD2<Float>(sin(6 * .pi/180),cos(6 * .pi/180))
        let lines=[L(normal:[0,1],offset:0,low:0,high:0.4),                                   // front
                   L(normal:[1,0],offset:0.4,low:-0.3,high:0),                                // right
                   L(normal:[0,1],offset:0.3,low:0.2,high:0.4),                               // back, first part
                   L(normal:bend,offset:simd_dot(bend,[0.2,0.3]),low:-0.2,high:0.0),           // back, bent 6°
                   L(normal:[1,0],offset:0,low:-0.32,high:0)]                                 // left
        let input: [InteriorSweep.Run]=[(0,[0.2,0]),(1,[0.4,0.15]),(2,[0.3,0.3]),(3,[0.199,0.3]),(4,[0,0.15])]
        #expect(InteriorSweep.collapsingDuplicateSides(input,lines:lines,base:[0.1,0.1]).map(\.line)==[0,1,2,3,4])
    }
    @Test func fullSweepDropsAViewThatRepeatsAStoredPose() {
        // Returning to an earlier pose adds nothing new; it must not push out a unique view.
        var map=InteriorSweep(seed:[0.1,0,0.1])
        for i in 0..<40 { _=map.add(observation(i,loops:[rectangle],open:true)) }
        let stored=map.observations.map(\.timestamp)
        var repeated=observation(5,loops:[rectangle],open:true); repeated.timestamp=40*0.4
        _=map.add(repeated)
        #expect(map.observations.map(\.timestamp)==stored)
    }
    @Test func shortFloorPatchIsNotExtrapolatedAlongALongFront() {
        // Base seen past a 40 cm front only along its first 8 cm, rising 1 cm per 10 cm:
        // extrapolating that slope would push the far end past edgeReach.
        var map=InteriorSweep(seed:[0.2,0,0.15])
        for view in 0..<2 {
            var floor=[SIMD2<Float>]()
            for x in stride(from:Float(0.001),through:0.079,by:0.006) {
                let beyond=0.01+0.1*(x-0.04)
                for y in stride(from:-beyond,through:0.03,by:0.006) { floor.append([x,y]) }
            }
            for x in stride(from:Float(0.085),through:0.4,by:0.006) { for y in stride(from:Float(0.05),through:0.3,by:0.006) { floor.append([x,y]) } }
            _=map.add(.init(timestamp:Double(view)*0.4,camera:[Float(view)*0.05,0.8,0.6],forward:[0,-1,0],floor:floor,walls:[],front:[],overhead:[]))
        }
        let front=InteriorSweep.Line(normal:[0,1],offset:0,low:0,high:0.4)
        let snapped=map.snappedToObservedBase(front)
        #expect(abs(abs(snapped.normal.y)-1)<0.0001 && abs(snapped.offset)<0.0001, "\(snapped)")
    }
    @Test func openFrontReachesObservedBaseDespiteBlurredDrop() throws {
        // Depth blur reports the drop inside the base; the base itself is seen to the edge.
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 {
            var o=observation(i,loops:[rectangle],open:true)
            o.front=o.front.map { [$0.x,$0.y+0.015] }
            result=map.add(o)
        }
        #expect(result.ready, "\(result.hint)")
        let loop=try #require(result.loops.first)
        #expect(abs(loop.map(\.z).max()!-loop.map(\.z).min()!-0.3)<0.006)
    }
    @Test func nearlyParallelSliverCollapsesToTheInnerSide() throws {
        // A short surface just beyond a side (trim, the wall past a cabinet) that the
        // outline also touches cannot stall review; the side nearer the base bounds it.
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 {
            var o=observation(i,loops:[rectangle],open:true)
            for y in stride(from:Float(0.003),through:0.045,by:0.006) {
                for x in stride(from:Float(-0.015),through:-0.003,by:0.006) { o.floor.append([x,y]) }
            }
            for y in stride(from:Float(0),through:0.06,by:0.005) { o.walls.append([-0.021,y]) }
            result=map.add(o)
        }
        #expect(result.ready, "\(result.hint)")
        let loop=try #require(result.loops.first)
        #expect(abs(loop.map(\.x).max()!-loop.map(\.x).min()!-0.4)<0.003)
    }

    func frame(drop: Bool, contrast: Bool=true, missing: Bool=false) -> InteriorSweepFrame {
        let width=80, height=80
        var ds=[Float](repeating:1,count:width*height), cs=[UInt8](repeating:2,count:ds.count), ls=[Float](repeating:0.5,count:ds.count)
        if drop { for y in 0..<height { for x in 0..<15 {
            ds[y*width+x]=1.15; if missing { cs[y*width+x]=0 }; if contrast { ls[y*width+x]=0.15 }
        } } }
        var pose=simd_float4x4(simd_quatf(angle:-.pi/2,axis:[1,0,0])); pose.columns.3=[0,1,0,1]
        return .init(width:width,height:height,depths:ds,confidence:cs,luminance:ls,
                     intrinsics:simd_float3x3(columns:([100,0,0],[0,100,0],[40,40,1])),transform:pose,timestamp:1)
    }
    @Test func baseSelectionUsesLocalLevelPatch() throws {
        let f=frame(drop:false), seed=try #require(f.selectedBase(at:[0.5,0.5]))
        #expect(abs(seed.y)<0.001)
        #expect(f.selectedBase(at:[.nan,0.5])==nil)
        #expect(f.selectedBase(at:[-0.1,0.5])==nil)
        #expect(f.selectedBase(at:[0.001,0.001])==nil)
    }
    @Test func openEdgeNeedsRealDepthBeyondItAndImageSupport() {
        #expect(!frame(drop:true).observation(seed:.zero).front.isEmpty)
        #expect(frame(drop:true,contrast:false).observation(seed:.zero).front.isEmpty)
        #expect(frame(drop:true,missing:true).observation(seed:.zero).front.isEmpty)
        #expect(frame(drop:false).observation(seed:.zero).front.isEmpty)
    }

    @Test func rotatedNoisyBoundariesDoNotNeedAxisAlignedCorners() throws {
        let angle: Float=0.43
        func rotate(_ p: SIMD2<Float>) -> SIMD2<Float> { [p.x*cos(angle)-p.y*sin(angle),p.x*sin(angle)+p.y*cos(angle)] }
        let selected=rotate([0.1,0.1])
        var map=InteriorSweep(seed:[selected.x,0,selected.y]), result=InteriorSweepResult()
        for i in 0..<5 {
            var f=observation(i,loops:[rectangle],open:true)
            f.floor=f.floor.map(rotate)
            f.walls=f.walls.enumerated().map { j,p in rotate(p)+SIMD2(Float((j*7+i)%5-2)*0.0005,Float((j*3+i)%5-2)*0.0005) }
            f.front=f.front.map(rotate); result=map.add(f)
        }
        #expect(result.ready, "\(result.hint)")
        let loop=try #require(result.loops.first)
        let area=abs(InteriorGeometry.area(loop.map{.init(x:Double($0.x),y:Double($0.z))}))
        #expect(abs(area-0.12)<0.003)
    }
    @Test func heightMustAgreeBetweenViewsAndDenseViewsCannotStarveOthers() {
        for disagree in [false,true] {
            var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
            for i in 0..<4 {
                var f=observation(i,loops:[rectangle],overhead:disagree && i%2==0 ? 0.42:0.35)
                f.overhead=Array(repeating:f.overhead,count:3).flatMap{$0}
                result=map.add(f)
            }
            #expect(result.ready)
            #expect(disagree ? result.height==nil : result.height != nil)
        }
    }
    @Test @MainActor func sweepReviewNeedsStableGeometryAndPreservesLiDARHeight() throws {
        let state=InteriorScanState(); state.ready=true; state.sweepSeed=[0.1,0,0.1]
        var r=run([rectangle],overhead:0.35); r.views=3; r.revision=3
        state.receiveSweep(r,generation:state.generation)
        #expect(!state.canReviewSweep)
        r.views=4; r.revision=4; state.receiveSweep(r,generation:state.generation)
        #expect(state.canReviewSweep)
        state.useSweepOutline()
        let value=try #require(state.result)
        #expect(value.heightSource == .lidar && abs(value.heightMM-350)<0.01)
    }
    @Test @MainActor func incompleteHeightGoesToHeightWithoutRetracingAndManualKeepsOutline() {
        for manual in [false,true] {
            let state=InteriorScanState(); state.ready=true; state.sweepSeed=[0.1,0,0.1]
            var r=run([rectangle]); r.views=3; r.revision=3; state.receiveSweep(r,generation:state.generation)
            r.views=4; r.revision=4; state.receiveSweep(r,generation:state.generation)
            if manual { state.useManual(); #expect(state.pinned && state.manualPlacement) }
            else { state.useSweepOutline(); #expect(state.takingHeight && state.result==nil) }
            #expect(state.loops==r.loops)
        }
    }
    @Test @MainActor func oldWorkerResultsCannotCrossReselectionOrInterruption() {
        let state=InteriorScanState(); state.ready=true; state.sweepSeed=[0.1,0,0.1]
        let old=state.generation, result=run([rectangle])
        state.chooseAnotherBase(); state.receiveSweep(result,generation:old)
        #expect(state.sweepResult.views==0 && state.sweepSeed==nil)
        state.sweepSeed=[0.1,0,0.1]; state.receiveSweep(result,generation:state.generation)
        state.trackingInterrupted=true; state.invalidate("Tracking reset")
        state.receiveSweep(result,generation:old)
        #expect(state.sweepResult.views==0 && !state.canReviewSweep)
    }
    @Test @MainActor func temporaryLackOfTrackingCannotApproveOldEvidence() {
        let state=InteriorScanState(); state.ready=true; state.sweepSeed=[0.1,0,0.1]
        var r=run([rectangle]); r.views=3; r.revision=3; state.receiveSweep(r,generation:state.generation)
        r.views=4; r.revision=4; state.receiveSweep(r,generation:state.generation); state.ready=false
        state.useSweepOutline()
        #expect(!state.pinned && state.result==nil && state.sweepResult.ready)
    }

    /// Render actual depth rays into a cabinet, exercising calibration, local normals
    /// and edge extraction together rather than supplying ideal boundary samples.
    func cabinetFrame(_ index: Int, fascia: Bool) -> InteriorSweepFrame {
        let width=160, height=120
        let camera=SIMD3<Float>(0.10+Float(index)*0.035,0.43,-0.30)
        let direction=simd_normalize(SIMD3<Float>(0.2,0.02,0.16)-camera)
        let right=simd_normalize(simd_cross(direction,SIMD3(0,1,0))), up=simd_cross(right,direction)
        let pose=simd_float4x4(columns:(SIMD4(right,0),SIMD4(up,0),SIMD4(-direction,0),SIMD4(camera,1)))
        let k=simd_float3x3(columns:([145,0,0],[0,145,0],[80,60,1]))
        var depths=[Float](), luma=[Float]()
        for y in 0..<height { for x in 0..<width {
            let r4=pose*SIMD4<Float>((Float(x)-80)/145,-(Float(y)-60)/145,-1,0)
            let r=SIMD3(r4.x,r4.y,r4.z)
            var hits: [(Float,Float)]=[]
            func plane(_ axis: Int, _ coordinate: Float, _ intensity: Float, _ contains: (SIMD3<Float>)->Bool) {
                guard abs(r[axis])>0.001 else { return }
                let t=(coordinate-camera[axis])/r[axis], p=camera+t*r
                if t>0.15 && t<2.5 && contains(p) { hits.append((t,intensity)) }
            }
            plane(1,0,0.6) { (0...0.4).contains($0.x) && (0...0.3).contains($0.z) }
            for wall: Float in [0,0.4] { plane(0,wall,0.4) { (0...0.35).contains($0.y) && (0...0.3).contains($0.z) } }
            plane(2,0.3,0.4) { (0...0.4).contains($0.x) && (0...0.35).contains($0.y) }
            if fascia { plane(2,0,0.3) { (0...0.4).contains($0.x) && (-0.04...0).contains($0.y) } }
            plane(1,-0.18,0.15) { _ in true }
            let hit=hits.min { $0.0<$1.0 }; depths.append(hit?.0 ?? .nan); luma.append(hit?.1 ?? 0)
        } }
        return .init(width:width,height:height,depths:depths,confidence:[UInt8](repeating:2,count:depths.count),luminance:luma,intrinsics:k,transform:pose,timestamp:Double(index)*0.4)
    }
    @Test func depthFramesReconstructCabinetIncludingFrontFascia() throws {
        for fascia in [false,true] {
            var map=InteriorSweep(seed:[0.2,0,0.15]), result=InteriorSweepResult()
            for i in 0..<7 { result=map.add(cabinetFrame(i,fascia:fascia).observation(seed:map.seed)) }
            #expect(result.ready, "\(result.hint), fascia=\(fascia), boundaries=\(result.boundaryCount)")
            let loop=try #require(result.loops.first)
            #expect(abs(loop.map(\.x).max()!-loop.map(\.x).min()!-0.4)<0.008)
            #expect(abs(loop.map(\.z).max()!-loop.map(\.z).min()!-0.3)<0.008)
        }
    }
}
