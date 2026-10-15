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
        guard x>1, y>1, x<width-2, y<height-2, let p=points[y*width+x] else { return nil }
        func tangent(_ a2: SIMD3<Float>?, _ a: SIMD3<Float>?, _ b: SIMD3<Float>?, _ b2: SIMD3<Float>?) -> SIMD3<Float>? {
            let u1 = a.flatMap { let v = p-$0; return simd_length(v)<0.045 ? v : nil }
            let u2 = b.flatMap { let v = $0-p; return simd_length(v)<0.045 ? v : nil }
            if let u1, let u2 {
                let l1 = simd_length(u1), l2 = simd_length(u2)
                guard l1 > 0.0001, l2 > 0.0001 else { return nil }
                let d1 = u1 / l1, d2 = u2 / l2
                if simd_dot(d1, d2) < 0.96 || max(l1, l2) > 1.6 * min(l1, l2) {
                    func stepError(_ v: SIMD3<Float>?, _ u: SIMD3<Float>, _ lu: Float) -> Float {
                        guard let v, simd_length(v) > 0.0001, simd_length(v) < 0.045 else { return .infinity }
                        return simd_length(u - v) / max(lu, simd_length(v))
                    }
                    let err1 = stepError(a != nil && a2 != nil ? a! - a2! : nil, u1, l1)
                    let err2 = stepError(b != nil && b2 != nil ? b2! - b! : nil, u2, l2)
                    if err1 < 0.25 && err1 + 0.08 < err2 { return u1 }
                    if err2 < 0.25 && err2 + 0.08 < err1 { return u2 }
                    if err1 < 0.25 && err2 < 0.25 {
                        if abs(d1.y) + 0.2 < abs(d2.y) { return u1 }
                        if abs(d2.y) + 0.2 < abs(d1.y) { return u2 }
                    }
                }
                return simd_length(u1+u2) < 0.08 ? u1+u2 : nil
            }
            if let u1, simd_length(u1) < 0.04 { return u1 }
            if let u2, simd_length(u2) < 0.04 { return u2 }
            return nil
        }
        guard let dx=tangent(points[y*width+x-2],points[y*width+x-1],points[y*width+x+1],points[y*width+x+2]),
              let dy=tangent(points[(y-2)*width+x],points[(y-1)*width+x],points[(y+1)*width+x],points[(y+2)*width+x]) else { return nil }
        let n=simd_cross(dx,dy)
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
        var result=InteriorSweepObservation(timestamp:timestamp,camera:camera,forward:forward,floor:[],walls:[],front:[],overhead:[],wallPoints3D:[])
        guard points.count==width*height else { return result }
        for y in 2..<height-2 { for x in 2..<width-2 {
            let i=y*width+x
            guard let p=points[i], simd_distance(SIMD2(p.x,p.z),SIMD2(seed.x,seed.z))<InteriorSweep.radius else { continue }
            let dy=p.y-seed.y
            let n=normal(x,y,points)
            if abs(dy)<0.01, n.map({ abs($0.y)>0.9 }) ?? false {
                result.floor.append([p.x,p.z])
            }
            if (0.015...0.15).contains(dy), let n, abs(n.y)<0.20 {
                result.walls.append([p.x,p.z])
                result.wallPoints3D?.append(p)
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
                guard let step1=points[j] else { continue }
                let dropped: Bool
                if step1.y < seed.y-0.025 {
                    dropped = abs(luminance[i]-luminance[j])>0.035
                } else if step1.y < seed.y-0.01,
                          (0..<width).contains(x+2*dx), (0..<height).contains(y+2*dyPixel) {
                    let j2=(y+2*dyPixel)*width+x+2*dx
                    dropped = points[j2].map {
                        $0.y < seed.y-0.025 && max(abs(luminance[i]-luminance[j]),abs(luminance[i]-luminance[j2]))>0.035
                    } ?? false
                } else {
                    dropped = false
                }
                guard dropped else { continue }
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
    private var resultConfirmed = false
    func process(_ frame: InteriorSweepFrame, seed: SIMD3<Float>, generation: UUID, footprintModel: InteriorFootprintModel = .observed) -> InteriorSweepResult {
        if self.generation != generation || sweep?.seed != seed || sweep?.footprintModel != footprintModel {
            self.generation=generation; sweep=InteriorSweep(seed:seed,footprintModel:footprintModel); result=InteriorSweepResult(); resultConfirmed=false
        }
        if !result.ready || resultConfirmed,
           let last=sweep?.observations.last,
           simd_distance(last.camera,frame.camera)<0.018 && simd_dot(last.forward,frame.forward)>0.9986 { return result }
        if let last=sweep?.observations.last,
           simd_distance(last.camera,frame.camera)<0.018 && simd_dot(last.forward,frame.forward)>0.9986 {
            if frame.timestamp - last.timestamp >= 0.18, !frame.observation(seed: seed).floor.isEmpty {
                result.revision += 1
                resultConfirmed = true
            }
            return result
        }
        let previous = result
        result=sweep!.add(frame.observation(seed:seed))
        resultConfirmed = previous.ready && result.ready && InteriorScanState.loopsMatch(previous.loops, result.loops)
        return result
    }
    /// The sweep's replayable evidence, or why there is none to report.
    enum Replay: Sendable { case available(String), unavailable(String) }

    func replay(generation: UUID, selectedResult: InteriorSweepResult? = nil, reviewMeasurement: InteriorMeasurement? = nil) -> Replay {
        guard self.generation==generation, let sweep else { return .unavailable("No sweep observations in this camera session.") }
        let value=InteriorSweepSnapshot(seed:sweep.seed,observations:sweep.observations,rejectedViews:sweep.rejectedViews,
                                       acceptedViews:sweep.acceptedViews,reconstruction:sweep.reconstruct(),
                                       selectedResult:selectedResult,reviewMeasurement:reviewMeasurement,footprintModel:sweep.footprintModel)
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        guard let data=try? encoder.encode(value), let text=String(data:data,encoding:.utf8) else { return .unavailable("Could not export scan diagnostics.") }
        return .available(text)
    }
}
