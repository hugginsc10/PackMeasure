import ARKit
import Foundation
import simd

/// Immutable data copied before crossing to the reconstruction actor. Pixel buffers
/// and ARFrames never cross that boundary or remain retained between views.
struct InteriorSweepFrame: Sendable {
    let width: Int
    let height: Int
    let depths: [Float]
    let confidence: [UInt8]
    let luminance: [Float]
    let intrinsics: simd_float3x3 // scaled to depth dimensions
    let transform: simd_float4x4
    let timestamp: TimeInterval

    @MainActor init?(frame: ARFrame) {
        guard case .normal = frame.camera.trackingState,
              CACurrentMediaTime()-frame.timestamp < 0.3,
              let depth=frame.sceneDepth, let conf=depth.confidenceMap else { return nil }
        let map=depth.depthMap, rgb=frame.capturedImage
        width=CVPixelBufferGetWidth(map); height=CVPixelBufferGetHeight(map)
        guard width > 4, height > 4, width <= 1024, height <= 1024,
              CVPixelBufferGetPixelFormatType(map)==kCVPixelFormatType_DepthFloat32,
              CVPixelBufferGetPixelFormatType(conf)==kCVPixelFormatType_OneComponent8,
              CVPixelBufferGetWidth(conf)==width, CVPixelBufferGetHeight(conf)==height,
              CVPixelBufferGetPlaneCount(rgb)>=2 else { return nil }
        CVPixelBufferLockBaseAddress(map,.readOnly); CVPixelBufferLockBaseAddress(conf,.readOnly); CVPixelBufferLockBaseAddress(rgb,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map,.readOnly); CVPixelBufferUnlockBaseAddress(conf,.readOnly); CVPixelBufferUnlockBaseAddress(rgb,.readOnly) }
        guard let d=CVPixelBufferGetBaseAddress(map), let c=CVPixelBufferGetBaseAddress(conf),
              let l=CVPixelBufferGetBaseAddressOfPlane(rgb,0) else { return nil }
        var ds=[Float](), cs=[UInt8](), ls=[Float]()
        ds.reserveCapacity(width*height); cs.reserveCapacity(width*height); ls.reserveCapacity(width*height)
        let lw=CVPixelBufferGetWidthOfPlane(rgb,0), lh=CVPixelBufferGetHeightOfPlane(rgb,0)
        for y in 0..<height {
            let dr=d.advanced(by:y*CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to:Float.self)
            let cr=c.advanced(by:y*CVPixelBufferGetBytesPerRow(conf)).assumingMemoryBound(to:UInt8.self)
            let lr=l.advanced(by:min(lh-1,y*lh/height)*CVPixelBufferGetBytesPerRowOfPlane(rgb,0)).assumingMemoryBound(to:UInt8.self)
            for x in 0..<width { ds.append(dr[x]); cs.append(cr[x]); ls.append(Float(lr[min(lw-1,x*lw/width)])/255) }
        }
        depths=ds; confidence=cs; luminance=ls
        let sx=Float(width)/Float(frame.camera.imageResolution.width), sy=Float(height)/Float(frame.camera.imageResolution.height)
        var k=frame.camera.intrinsics; k[0][0] *= sx; k[1][1] *= sy; k[2][0] *= sx; k[2][1] *= sy
        intrinsics=k; transform=frame.camera.transform; timestamp=frame.timestamp
    }

    init(width: Int, height: Int, depths: [Float], confidence: [UInt8], luminance: [Float], intrinsics: simd_float3x3,
         transform: simd_float4x4, timestamp: TimeInterval) {
        self.width=width; self.height=height; self.depths=depths; self.confidence=confidence; self.luminance=luminance
        self.intrinsics=intrinsics; self.transform=transform; self.timestamp=timestamp
    }
    var camera: SIMD3<Float> { .init(transform.columns.3.x,transform.columns.3.y,transform.columns.3.z) }
    var forward: SIMD3<Float> { -.init(transform.columns.2.x,transform.columns.2.y,transform.columns.2.z) }
    var valid: Bool {
        width > 4 && height > 4 && width <= 1024 && height <= 1024 && depths.count == width*height
        && confidence.count == depths.count && luminance.count == depths.count
        && intrinsics[0][0].isFinite && intrinsics[0][0] > 0 && intrinsics[1][1].isFinite && intrinsics[1][1] > 0
    }
    func ray(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let r=transform * SIMD4((x-intrinsics[2][0])/intrinsics[0][0],-(y-intrinsics[2][1])/intrinsics[1][1],-1,0)
        return [r.x,r.y,r.z]
    }
    func points() -> [SIMD3<Float>?] {
        guard valid else { return [] }
        return depths.indices.map { i in
            let d=depths[i]
            guard confidence[i]==2, d.isFinite, (0.15...2.5).contains(d) else { return nil }
            let p=camera+ray(Float(i%width),Float(i/width))*d
            return p.x.isFinite && p.y.isFinite && p.z.isFinite ? p : nil
        }
    }
    func normal(_ x: Int, _ y: Int, _ points: [SIMD3<Float>?]) -> SIMD3<Float>? {
        guard x>1, y>1, x<width-2, y<height-2,
              let a=points[y*width+x-1], let b=points[y*width+x+1],
              let c=points[(y-1)*width+x], let d=points[(y+1)*width+x],
              simd_distance(a,b)<0.08, simd_distance(c,d)<0.08 else { return nil }
        let n=simd_cross(b-a,d-c)
        guard simd_length(n)>0.000001 else { return nil }
        return simd_normalize(n)
    }
    /// A target patch, not an exact measurement tap: all samples remain within two
    /// depth pixels of the user's selection. No image-center or remote-plane fallback.
    func selectedBase(at point: SIMD2<Float>) -> SIMD3<Float>? {
        guard valid, point.x.isFinite, point.y.isFinite, (0..<1).contains(point.x), (0..<1).contains(point.y) else { return nil }
        let points=points(), x=Int(point.x*Float(width)), y=Int(point.y*Float(height))
        guard x>=2, y>=2, x<width-2, y<height-2 else { return nil }
        var patch=[SIMD3<Float>]()
        for yy in max(2,y-2)...min(height-3,y+2) { for xx in max(2,x-2)...min(width-3,x+2) {
            if let p=points[yy*width+xx], let n=normal(xx,yy,points), abs(n.y)>0.94 { patch.append(p) }
        } }
        guard patch.count>=6 else { return nil }
        let ys=patch.map(\.y).sorted(), middle=ys[ys.count/2]
        guard ys.last!-ys.first! < 0.012, camera.y>middle+0.04 else { return nil }
        let direction=ray(point.x*Float(width),point.y*Float(height))
        guard abs(direction.y)>0.2 else { return nil }
        let t=(middle-camera.y)/direction.y
        guard (0.15...2.5).contains(t) else { return nil }
        let target=camera+t*direction
        guard patch.contains(where: { simd_distance($0,target)<0.035 }) else { return nil }
        return target
    }
    func observation(seed: SIMD3<Float>) -> InteriorSweepObservation {
        let points=points()
        var result=InteriorSweepObservation(timestamp:timestamp,camera:camera,forward:forward,floor:[],walls:[],front:[],overhead:[])
        guard points.count==width*height else { return result }
        for y in 2..<height-2 { for x in 2..<width-2 {
            let i=y*width+x
            guard let p=points[i], simd_distance(SIMD2(p.x,p.z),SIMD2(seed.x,seed.z))<InteriorSweep.radius else { continue }
            let dy=p.y-seed.y
            let n=normal(x,y,points)
            if abs(dy)<0.01, n.map({ abs($0.y)>0.9 }) ?? false {
                result.floor.append([p.x,p.z])
            }
            if (0.015...0.15).contains(dy), let n, abs(n.y)<0.15 {
                result.walls.append([p.x,p.z])
            }
            if (0.04...3).contains(dy), camera.y<p.y-0.025, let n, abs(n.y)>0.94 {
                result.overhead.append(p)
            }
            // A cabinet commonly has a visible fascia immediately below its base.
            // Its vertical face supplies the termination plane even when the next
            // pixel is trim rather than a large drop. Require nearby observed floor
            // and image contrast; an isolated lower wall is not a cabinet front.
            if (-0.12 ... -0.012).contains(dy), let n, abs(n.y)<0.15 {
                var touchesFloor=false
                for (dx,dyp) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    for step in 1...5 {
                        let xx=x+dx*step, yy=y+dyp*step
                        guard (0..<width).contains(xx), (0..<height).contains(yy) else { continue }
                        let j=yy*width+xx
                        if let base=points[j], abs(base.y-seed.y)<0.01,
                           simd_distance(SIMD2(p.x,p.z),SIMD2(base.x,base.z))<0.035,
                           abs(luminance[i]-luminance[j])>0.035,
                           let baseNormal=normal(xx,yy,points), abs(baseNormal.y)>0.9 { touchesFloor=true; break }
                    }
                    if touchesFloor { break }
                }
                if touchesFloor { result.front.append([p.x,p.z]) }
            }
            // An observed drop beyond an image-supported edge can terminate an open
            // front. Missing depth never qualifies; two distinct views must agree.
            guard abs(dy)<0.01 else { continue }
            for (dx,dyPixel) in [(1,0),(-1,0),(0,1),(0,-1)] {
                let j=(y+dyPixel)*width+x+dx
                guard let beyond=points[j], beyond.y<seed.y-0.025,
                      abs(luminance[i]-luminance[j])>0.035 else { continue }
                let r=ray(Float(x)+Float(dx)*0.5,Float(y)+Float(dyPixel)*0.5)
                guard abs(r.y)>0.2 else { continue }
                let t=(seed.y-camera.y)/r.y
                guard (0.15...2.5).contains(t) else { continue }
                let edge=camera+t*r
                guard simd_distance(edge,p)<0.035 else { continue }
                result.front.append([edge.x,edge.z])
            }
        } }
        return result
    }
}

actor InteriorSweepWorker {
    private var generation: UUID?
    private var sweep: InteriorSweep?
    private var result=InteriorSweepResult()
    func process(_ frame: InteriorSweepFrame, seed: SIMD3<Float>, generation: UUID) -> InteriorSweepResult {
        if self.generation != generation { self.generation=generation; sweep=InteriorSweep(seed:seed); result=InteriorSweepResult() }
        if let last=sweep?.observations.last,
           simd_distance(last.camera,frame.camera)<0.018 && simd_dot(last.forward,frame.forward)>0.9986 { return result }
        result=sweep!.add(frame.observation(seed:seed))
        return result
    }
    func diagnostics(generation: UUID) -> String {
        struct Replay: Encodable {
            var format="PackMeasure interior sweep v1"
            var seed: SIMD3<Float>
            var observations: [InteriorSweepObservation]
            var rejectedViews: Int
        }
        guard self.generation==generation, let sweep else { return "No sweep observations in this camera session." }
        let value=Replay(seed:sweep.seed,observations:sweep.observations,rejectedViews:sweep.rejectedViews)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        guard let data=try? encoder.encode(value), let text=String(data:data,encoding:.utf8) else { return "Could not export scan diagnostics." }
        return text
    }
}
