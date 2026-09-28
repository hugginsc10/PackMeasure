import SwiftUI
import simd

struct InteriorFixture: View {
    @State private var state: InteriorScanState
    @State private var saved: InteriorMeasurement?
    private let store = InteriorStore(url: URL.documentsDirectory.appending(path: "fixture-interiors.json"))
    init() {
        let s = InteriorScanState(); s.ready = true; s.manualPlacement = true
        var pose = simd_float4x4(simd_quatf(angle: -.pi/2, axis: [1,0,0]));pose.columns.3=[0,1,0,1]
        var confidence=[UInt8](repeating:2,count:10000)
        if ProcessInfo.processInfo.arguments.contains("bad-depth") {
            for y in 47...53 {for x in 47...53 {confidence[y*100+x]=0}}
        }
        let image = UIGraphicsImageRenderer(size:CGSize(width:800,height:800)).image { ctx in
            UIColor(white:0.08,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:800,height:800))
            UIColor(white:0.24,alpha:1).setFill();ctx.fill(CGRect(x:160,y:160,width:480,height:480))
            UIColor(white:0.6,alpha:1).setStroke();ctx.cgContext.setLineWidth(16);ctx.cgContext.stroke(CGRect(x:160,y:160,width:480,height:480))
            for x in stride(from:200,through:600,by:40) {ctx.cgContext.setStrokeColor(UIColor(white:0.3,alpha:1).cgColor);ctx.cgContext.setLineWidth(2);ctx.cgContext.move(to:CGPoint(x:x,y:180));ctx.cgContext.addLine(to:CGPoint(x:x,y:620));ctx.cgContext.strokePath()}
            ("Synthetic drawer fixture" as NSString).draw(at:CGPoint(x:220,y:50),withAttributes:[.font:UIFont.systemFont(ofSize:28),.foregroundColor:UIColor.white])
        }
        let photo = InteriorPhoto(generation:s.generation,image:image,
            grid:DepthGrid(width:100,height:100,depths:[Float](repeating:1,count:10000),confidences:confidence),
            imageSize:[100,100],intrinsics:simd_float3x3(columns:([100,0,0],[0,100,0],[50,50,1])),transform:pose)
        s.freezeView();s.receivePhoto(photo)
        if ProcessInfo.processInfo.arguments.contains("pinned") || ProcessInfo.processInfo.arguments.contains("automatic-outline") {
            [CGPoint(x:0.2,y:0.2),CGPoint(x:0.8,y:0.2),CGPoint(x:0.8,y:0.8),CGPoint(x:0.2,y:0.8)].forEach(s.placePhotoPoint)
            s.pinned = true
            if ProcessInfo.processInfo.arguments.contains("automatic-outline") {s.pinned=false;s.automatic=true;s.preview=s.loops;s.stablePreviewFrames=3;s.previewTimestamp=CACurrentMediaTime()}
        }
        _state=State(initialValue:s)
    }
    var body: some View {
        Group {
            if ProcessInfo.processInfo.arguments.contains("reopen"), let record = try? store.load().first {
                NavigationStack {InteriorReviewView(record:record,onSave:{_ in})}
            } else if let saved {
                Text("Saved \(saved.contours.count) outlines · \(saved.contours[0].count) corners · \(saved.heightMM.formatted()) mm").accessibilityIdentifier("saved-interior")
            } else {
                InteriorScannerView(state:state,onSave:{record in try store.save([record]);saved=record})
                    .task {
                        while state.automatic {state.previewTimestamp=CACurrentMediaTime();try? await Task.sleep(for:.milliseconds(150))}
                    }
            }
        }
    }
}
