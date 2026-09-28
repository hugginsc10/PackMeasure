import SwiftUI
import simd

struct SweepFixture: View {
    @State private var state: InteriorScanState
    @State private var saved: InteriorMeasurement?
    private let store=InteriorStore(url:URL.documentsDirectory.appending(path:"sweep-fixture.json"))
    init() {
        let s=InteriorScanState(); s.ready=true; s.sweepSeed=[0.1,0,0.1]
        _state=State(initialValue:s)
    }
    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("reopen"), let record=try? store.load().first {
                NavigationStack { InteriorReviewView(record:record,onSave:{_ in}) }
            } else if let saved {
                Text("Saved \(saved.contours[0].count) corners · \(saved.heightMM.formatted()) mm").accessibilityIdentifier("saved-sweep")
            } else {
                InteriorScannerView(state:state,onSave:{record in try store.save([record]);saved=record})
                    .task {
                        var map=InteriorSweep(seed:[0.1,0,0.1])
                        for i in 0..<5 {
                            let result=map.add(Self.observation(i))
                            state.receiveSweep(result,generation:state.generation)
                            try? await Task.sleep(for:.milliseconds(180))
                        }
                    }
            }
        }.safeAreaInset(edge:.top) { Text("Synthetic reconstruction fixture · no camera").font(.caption2).foregroundStyle(.secondary) }
    }
    static func observation(_ i: Int) -> InteriorSweepObservation {
        var floor=[SIMD2<Float>](), walls=[SIMD2<Float>](), front=[SIMD2<Float>](), top=[SIMD3<Float>]()
        let args=ProcessInfo.processInfo.arguments
        for x in 0..<65 { for y in 0..<49 {
            let p=SIMD2<Float>(Float(x)*0.006+0.003,Float(y)*0.006+0.003)
            floor.append(p)
            if !args.contains("no-height") { top.append([p.x,0.35,p.y]) }
        } }
        let loop: [SIMD2<Float>]=[[0,0],[0.4,0],[0.4,0.3],[0,0.3]]
        for j in loop.indices {
            let a=loop[j], b=loop[(j+1)%4], count=Int(simd_distance(a,b)/0.005)
            for step in 0...count {
                let p=a+(b-a)*Float(step)/Float(count)
                if j==0 { if !args.contains("missing-front") { front.append(p) } } else { walls.append(p) }
            }
        }
        return .init(timestamp:Double(i)*0.4,camera:[Float(i)*0.025,0.8,0.6],forward:[0,-1,0],floor:floor,walls:walls,front:front,overhead:top)
    }
}
