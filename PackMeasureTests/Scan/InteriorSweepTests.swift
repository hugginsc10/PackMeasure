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
        let runs=InteriorSweep.collapsingDuplicateSides([(0,[0.2,0],[0,1]),(2,[-0.021,0.02],[1,0]),(1,[0,0.1],[1,0])],lines:lines).runs
        #expect(runs.map(\.line)==[0,1])
    }
    @Test func duplicateObstacleEdgeCollapsesOutwardToKeepTheObstacle() {
        // Around an obstacle the conservative edge grows the cutout: duplicates of its right
        // side at x=0.28 and x=0.30 must keep 0.30, even though 0.28 is nearer the seed.
        typealias L=InteriorSweep.Line
        let lines=[L(normal:[0,1],offset:0.10,low:0.2,high:0.29),     // obstacle bottom
                   L(normal:[1,0],offset:0.28,low:-0.2,high:-0.1),    // right side, fit A
                   L(normal:[1,0],offset:0.30,low:-0.2,high:-0.1),    // right side, fit B
                   L(normal:[0,1],offset:0.20,low:0.2,high:0.29),     // obstacle top
                   L(normal:[1,0],offset:0.20,low:-0.2,high:-0.1)]    // obstacle left
        let runs=InteriorSweep.collapsingDuplicateSides([(0,[0.245,0.10],[0,-1]),(1,[0.29,0.13],[1,0]),(2,[0.29,0.17],[1,0]),
                                                         (3,[0.245,0.20],[0,1]),(4,[0.20,0.15],[-1,0])],lines:lines).runs
        #expect(runs.map(\.line)==[0,2,3,4])
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
        let input: [InteriorSweep.Run]=[(0,[0.2,0],[0,1]),(1,[0.4,0.15],[-1,0]),(2,[0.3,0.3],[0,-1]),(3,[0.199,0.3],[0,-1]),(4,[0,0.15],[1,0])]
        #expect(InteriorSweep.collapsingDuplicateSides(input,lines:lines).runs.map(\.line)==[0,1,2,3,4])
    }
    @Test func hingePlateCollapsesWholeSideAndWidensTheKeptExtent() {
        // A hinge plate 1 cm inside the left side is matched along 8 cm of the ring. It bounds
        // the usable width, so it replaces the whole side; the kept line must then span the
        // side's full extent, or the corners at either end lose their support.
        typealias L=InteriorSweep.Line
        let lines=[L(normal:[0,1],offset:0,low:0,high:0.4),          // front
                   L(normal:[1,0],offset:0.4,low:-0.3,high:0),       // right
                   L(normal:[0,1],offset:0.3,low:0,high:0.4),        // back
                   L(normal:[1,0],offset:0,low:-0.3,high:0),         // left panel
                   L(normal:[1,0],offset:0.01,low:-0.10,high:-0.02)] // hinge plate 1 cm inside it
        let input: [InteriorSweep.Run]=[(0,[0.2,0],[0,1]),(1,[0.4,0.15],[-1,0]),(2,[0.2,0.3],[0,-1]),
                                        (3,[0,0.2],[1,0]),(4,[0,0.10],[1,0]),(3,[0,0.02],[1,0])]
        let result=InteriorSweep.collapsingDuplicateSides(input,lines:lines)
        #expect(result.runs.map(\.line)==[0,1,2,4])
        #expect(abs(result.lines[4].low+0.3)<0.0001 && abs(result.lines[4].high)<0.0001, "\(result.lines[4])")
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
    @Test func fullSweepKeepsTheOnlyViewOfARegion() {
        // Views can stand close together yet see different parts of the base (occlusion);
        // the only view of a region must not be replaced because its pose is redundant.
        var map=InteriorSweep(seed:[0.1,0,0.1])
        for i in 0..<38 { _=map.add(gapped(i)) }
        _=map.add(observation(38,loops:[rectangle],open:true))            // the only view of the patch
        var near=gapped(39); near.camera.x=38*0.025+0.019; _=map.add(near) // nearly repeats that pose
        var novel=observation(40,loops:[rectangle],open:true,overhead:0.35); novel.floor=gapped(40).floor
        let result=map.add(novel)                                          // new evidence: the underside
        #expect(map.observations.contains { $0.timestamp==38*0.4 })
        #expect(result.ready, "\(result.hint)")
    }
    @Test func fullSweepKeepsCorroboratingViewsOfALateEdge() {
        // Edges need two views. At the budget, a second view of an edge only one stored
        // view has seen is new evidence, not a repeat.
        func withoutRightSide(_ i: Int) -> InteriorSweepObservation {
            var o=observation(i,loops:[rectangle],open:true); o.walls=o.walls.filter { $0.x<0.39 }; return o
        }
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<39 { result=map.add(withoutRightSide(i)) }
        result=map.add(observation(39,loops:[rectangle],open:true))   // first sight of the right side
        #expect(!result.ready)
        result=map.add(observation(40,loops:[rectangle],open:true))   // a second view corroborates it
        #expect(result.ready, "\(result.hint)")
    }
    @Test func lowerUndersideSeenLateIsNotTreatedAsARepeat() {
        // Two views agreeing on a higher underside must not make a later, lower one look
        // redundant: its height differs, so it is new evidence, and clearance must not be
        // reported from the higher level alone.
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<38 { result=map.add(observation(i,loops:[rectangle],open:true)) }
        for i in 38..<40 { result=map.add(observation(i,loops:[rectangle],open:true,overhead:0.40)) }
        for i in 40..<42 { result=map.add(observation(i,loops:[rectangle],open:true,overhead:0.35)) }
        #expect(map.observations.contains { $0.timestamp==41*0.4 })
        #expect(result.height == nil || result.height! < 0.36, "\(String(describing: result.height))")
    }
    @Test func fullSweepCountsTheIncomingViewWhenChoosingAReplacement() {
        // A candidate that re-observes one stored view's only patch makes that view free to
        // replace; replacing another view instead would reopen that other view's patch.
        func uncover(_ o: inout InteriorSweepObservation, _ x: ClosedRange<Float>, _ y: ClosedRange<Float>) {
            o.floor=o.floor.filter { !(x.contains($0.x) && y.contains($0.y)) }
        }
        let ax: ClosedRange<Float>=0.04...0.10, ay: ClosedRange<Float>=0.04...0.10
        let bx: ClosedRange<Float>=0.28...0.33, by: ClosedRange<Float>=0.18...0.23
        var map=InteriorSweep(seed:[0.2,0,0.15])
        for i in 0..<38 {   // neither patch, plus an underside level no other view shares
            var o=observation(i,loops:[rectangle],open:true,overhead:0.30+Float(i)*0.02)
            uncover(&o,ax,ay); uncover(&o,bx,by); _=map.add(o)
        }
        var onlyA=observation(38,loops:[rectangle],open:true); uncover(&onlyA,bx,by); _=map.add(onlyA)
        var onlyB=observation(39,loops:[rectangle],open:true); uncover(&onlyB,ax,ay); _=map.add(onlyB)
        var again=observation(40,loops:[rectangle],open:true,overhead:0.2); uncover(&again,bx,by)
        let result=map.add(again)   // re-observes patch A and adds a new underside level
        #expect(map.observations.contains { $0.timestamp==39*0.4 })
        #expect(result.ready, "\(result.hint)")
    }
    @Test func backgroundSurfacesDoNotDisplaceBaseEvidenceAtTheBudget() {
        // Walls far from the selected base never bound it, so seeing more of them at the
        // budget is not new evidence and must not push out a view of the base.
        var map=InteriorSweep(seed:[0.1,0,0.1])
        for i in 0..<40 { _=map.add(observation(i,loops:[rectangle],open:true)) }
        let stored=map.observations.map(\.timestamp)
        var background=observation(40,loops:[rectangle],open:true)
        for y in stride(from:Float(0),through:0.3,by:0.005) { background.walls.append([0.9,y]) }
        _=map.add(background)
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
    /// Exercises issue #33: a hinge plate standing 1 cm inside a side.
    @Test func hingePlateInsideASideNarrowsTheOutlineConservatively() throws {
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 {
            var f=observation(i,loops:[rectangle],open:true)
            // Real panels scatter a few mm across views; the sides move along their normals.
            f.walls=f.walls.enumerated().map { j,p -> SIMD2<Float> in
                let jitter=Float((j*7+i)%11-5)*0.001
                return p.x<0.001 || p.x>0.399 ? [p.x+jitter,p.y] : [p.x,p.y+jitter]
            }
            let n=f.walls.count   // the plate: 8 cm along the left side, 1 cm inside it
            for k in 0...16 { f.walls.append([0.010+Float(((n+k)*7+i)%11-5)*0.001,0.02+0.005*Float(k)]) }
            f.floor.removeAll { $0.x<0.010 && (0.02...0.10).contains($0.y) }   // it stands on the base
            result=map.add(f)
        }
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        let loop=try #require(result.loops.first)
        #expect(loop.count==4 && result.boundaryCount==5, "\(loop.count) vertices · \(result.boundaryCount) boundaries")
        // The whole left side collapses to the plate: never wider than the plate allows.
        #expect(loop.map(\.x).min()!>=0.008, "\(loop)")
        #expect(abs(loop.map(\.x).max()!-0.4)<0.002 && abs(loop.map(\.z).max()!-0.3)<0.002 && abs(loop.map(\.z).min()!)<0.002, "\(loop)")
    }
    /// Exercises issue #33: a side scattered uniformly by ±8 mm must fit as one edge at its
    /// mean, not as parallel fits that collapse inward.
    @Test func noisySideStillFitsAsOneEdgeWithoutInwardShrink() throws {
        var map=InteriorSweep(seed:[0.1,0,0.1]), result=InteriorSweepResult()
        for i in 0..<4 {
            var f=observation(i,loops:[rectangle],open:true)
            f.walls=f.walls.enumerated().map { j,p -> SIMD2<Float> in p.x<0.001 ? [Float((j*7+i)%17-8)*0.001,p.y] : p }
            result=map.add(f)
        }
        #expect(result.ready, "\(result.hint) · \(result.boundaryCount) boundaries")
        let loop=try #require(result.loops.first)
        #expect(loop.count==4 && result.boundaryCount==4, "\(loop.count) vertices · \(result.boundaryCount) boundaries")
        #expect(abs(loop.map(\.x).max()!-loop.map(\.x).min()!-0.4)<0.004, "\(loop)")
    }
    /// Exercises issue #33 at the line level: a 30 cm panel scattered ±2 mm across three views
    /// with a dense band 12 mm inside it over 8 cm. Only the density step gives the band its
    /// own line; without it the band is cleared as the panel's scatter.
    @Test func aDenseBandInsideASideGetsItsOwnLine() throws {
        var samples=[InteriorSweep.Sample]()
        for view in 0..<3 {
            for k in 0...60 { samples.append(.init(p:[Float((k*7+view)%5-2)*0.001,0.005*Float(k)],view:view)) }
            for k in 0...16 { samples.append(.init(p:[0.012+Float((k*7+view+1)%5-2)*0.001,0.02+0.005*Float(k)],view:view)) }
        }
        let lines=InteriorSweep.fitLines(samples,nearerSurfaces:true)
        #expect(lines.count==2, "\(lines)")
        let panel=try #require(lines.first { abs($0.offset)<0.003 }, "\(lines)")
        let plate=try #require(lines.first { abs(abs($0.offset)-0.012)<0.003 }, "\(lines)")
        #expect(abs(panel.high-panel.low-0.3)<0.01, "\(panel)")
        let ends=[abs(plate.low),abs(plate.high)].sorted()
        #expect(abs(ends[0]-0.02)<0.008 && abs(ends[1]-0.10)<0.008, "\(plate)")
        #expect(InteriorSweep.fitLines(samples,nearerSurfaces:false).count==1)
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
    @Test @MainActor func diagnosticsNeedNoCameraViewAndKeepACopy() async throws {
        // Review replaces the camera view; the report must still come from the sweep's own
        // evidence, name the running build, and stay on the device for USB retrieval.
        let state=InteriorScanState()
        for i in 0..<3 { _=await state.sweepWorker.process(cabinetFrame(i,fascia:false),seed:[0.2,0,0.15],generation:state.generation) }
        let directory=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        await state.prepareDiagnostics(saveTo:directory)
        let report=try #require(state.sweepDiagnostics)
        let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown"
        #expect(report.hasPrefix("Build \(build) interior sweep"))
        #expect(report.contains("PackMeasure interior sweep v1"))
        #expect(try String(contentsOf:directory.appending(path:"last-interior-sweep.txt"),encoding:.utf8)==report)
        #expect(state.diagnosticsStorage?.contains("retrieval over USB")==true)
    }
    @Test @MainActor func aPlaceholderReportNeverReplacesTheKeptSweep() async throws {
        // Choosing another base leaves no sweep to report; the kept copy of the finished
        // sweep must survive, and the sheet must not claim a new copy was kept.
        let state=InteriorScanState()
        for i in 0..<3 { _=await state.sweepWorker.process(cabinetFrame(i,fascia:false),seed:[0.2,0,0.15],generation:state.generation) }
        let directory=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        await state.prepareDiagnostics(saveTo:directory)
        let kept=try String(contentsOf:directory.appending(path:"last-interior-sweep.txt"),encoding:.utf8)
        state.chooseAnotherBase()
        await state.prepareDiagnostics(saveTo:directory)
        #expect(state.sweepDiagnostics?.contains("PackMeasure interior sweep v1")==false)
        #expect(try String(contentsOf:directory.appending(path:"last-interior-sweep.txt"),encoding:.utf8)==kept)
        #expect(state.diagnosticsStorage?.contains("retrieval over USB") != true)
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
