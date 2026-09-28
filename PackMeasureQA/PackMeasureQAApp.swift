import SwiftUI
import simd

@main struct PackMeasureQAApp: App {
    @State private var accepted = false
    @State private var pickerPoint: CGPoint?
    @State private var capturedSource: RoomShelfMeasurement.Source?
    private var args: [String] { ProcessInfo.processInfo.arguments }
    @MainActor private var rejected: ShelfScanState {
        let s=ShelfScanState();s.ready=true;s.request();s.receive([0,1,0],horizontalSurface:false,request:s.requestID);return s
    }
    @MainActor private var result: WireShelfScanState {
        let s=WireShelfScanState()
        for p: SIMD3<Float> in [[0.5,1.2192,0.3048],[0.5,0,0.3048],[0,1.2192,0],[1,1.2192,0],[0.5,1.6002,0.3048]] {
            for side: Float in [-0.2,0.2] {
                let origin=p+[side,0.1,0.7]
                var pose=matrix_identity_float4x4;pose.columns.3=[origin.x,origin.y,origin.z,1]
                let d=p-origin
                let x=700*d.x / -d.z+640,y=480-700*d.y / -d.z
                s.ready=true;s.requestPhoto()
                s.receive(.init(generation:s.generation,image:Self.grid,imageSize:[1280,960],intrinsics:.init(columns:([700,0,0],[0,700,0],[640,480,1])),transform:pose),request:s.photoRequest!)
                s.cursor=CGPoint(x:CGFloat(1-y/960),y:CGFloat(x/1280));s.confirmPoint()
            }
        }
        return s
    }
    static var grid: UIImage {
        UIGraphicsImageRenderer(size:CGSize(width:720,height:960)).image { ctx in
            UIColor(white:0.12,alpha:1).setFill();ctx.fill(CGRect(x:0,y:0,width:720,height:960))
            UIColor.white.setStroke();ctx.cgContext.setLineWidth(3)
            for x in stride(from:0,through:720,by:60) {ctx.cgContext.move(to:CGPoint(x:x,y:0));ctx.cgContext.addLine(to:CGPoint(x:x,y:960))}
            for y in stride(from:0,through:960,by:60) {ctx.cgContext.move(to:CGPoint(x:0,y:y));ctx.cgContext.addLine(to:CGPoint(x:720,y:y))}
            ctx.cgContext.strokePath()
            UIColor.systemTeal.setFill();ctx.fill(CGRect(x:354,y:474,width:12,height:12))
        }
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if args.contains("room-sheet") {
                    RoomScanSheet(store:RoomScanStore(directory:URL.temporaryDirectory.appending(path:"room-sheet-fixture")),guidance:.room)
                } else if args.contains("sweep") { SweepFixture() } else if args.contains("interior") { InteriorFixture() } else if args.contains("picker") {
                    VStack {
                        Text("Synthetic wire photo").font(.headline)
                        ShelfPhotoPointPicker(image:Self.grid,point:$pickerPoint).frame(width:300,height:400).accessibilityIdentifier("photo-picker")
                        Text(pickerPoint.map {String(format:"x=%.3f y=%.3f",$0.x,$0.y)} ?? "No point chosen").accessibilityIdentifier("point-coordinate")
                        Button("Use this point") {accepted=true}.disabled(pickerPoint==nil).accessibilityIdentifier("confirm-picker")
                        if accepted {Text("Point accepted").accessibilityIdentifier("accepted")}
                    }
                } else if args.contains("result") {
                    if accepted {Text("Matched-point result accepted").accessibilityIdentifier("accepted")}
                    else {WireShelfScannerView(onMeasured:{_,_,_,_ in accepted=true},state:result)}
                } else if args.contains("auto-failure") {
                    ShelfCaptureFlow(onMeasured:{_,_,_,_,_ in},solidState:rejected)
                } else {
                    ShelfCaptureFlow(onMeasured:{_,_,_,source,_ in capturedSource=source})
                }
            }.preferredColorScheme(.dark).tint(MeasureStyle.accent)
        }
    }
}
