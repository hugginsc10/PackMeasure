import Foundation
import simd

extension InteriorSweep {
    struct WallPlane {
        var normal: SIMD2<Float>
        var offset: Float
        var heightSlope: Float
    }

    /// Fit d = intercept + alongSlope*t + heightSlope*h in one view, then
    /// intersect that wall plane with the selected base (h=0). A diagonal line of
    /// samples cannot identify both slopes; require vertical/tangential extent and
    /// a well-conditioned covariance. Huber weights limit isolated depth outliers.
    static func wallPlane(_ points: [SIMD3<Float>], at origin: SIMD3<Float>, tangent: SIMD2<Float>) -> WallPlane? {
        guard points.count >= 12 else { return nil }
        let n = SIMD2(-tangent.y,tangent.x)
        let data = points.map { p -> SIMD3<Float> in
            let q = SIMD2(p.x-origin.x,p.z-origin.z)
            return [simd_dot(tangent,q),p.y-origin.y,simd_dot(n,q)]
        }
        guard data.map(\.x).max()!-data.map(\.x).min()! >= 0.075,
              data.map(\.y).max()!-data.map(\.y).min()! >= 0.035 else { return nil }
        var weights = [Float](repeating:1,count:data.count), intercept: Float = 0, along: Float = 0, height: Float = 0
        for _ in 0..<3 {
            let sum = weights.reduce(0,+)
            let mean = zip(data,weights).reduce(SIMD3<Float>.zero) { $0+$1.0*$1.1 }/sum
            var tt: Float = 0, hh: Float = 0, th: Float = 0, td: Float = 0, hd: Float = 0
            for (p,w) in zip(data,weights) {
                let q = p-mean
                tt += w*q.x*q.x; hh += w*q.y*q.y; th += w*q.x*q.y
                td += w*q.x*q.z; hd += w*q.y*q.z
            }
            let determinant = tt*hh-th*th
            guard tt > 0, hh > 0, determinant > 0.1*tt*hh else { return nil }
            along = (td*hh-hd*th)/determinant; height = (hd*tt-td*th)/determinant
            intercept = mean.z-along*mean.x-height*mean.y
            weights = data.map { p in min(1,0.006/max(abs(p.z-intercept-along*p.x-height*p.y),1e-6)) }
        }
        guard abs(along) <= 0.12, abs(height) <= 0.2, abs(intercept) <= 0.025 else { return nil }
        let normal = simd_normalize(n-along*tangent), length = simd_length(n-along*tangent)
        let offset = (simd_dot(n-along*tangent,[origin.x,origin.z])+intercept)/length
        return .init(normal:normal,offset:offset,heightSlope:height/length)
    }

    private static func median(_ values: [Float]) -> Float {
        let values = values.sorted(), i = values.count/2
        return values.count%2 == 0 ? (values[i-1]+values[i])/2 : values[i]
    }

    /// Explicit rectangle prior: four supported sides must already exist. Joint
    /// orientation removes their noisy independent tilts. Each wall view contributes
    /// one offset; 3D evidence estimates the base intersection when available.
    /// The supported open-front fit is retained, including its observed-floor snap.
    /// Nearer trim constraints and obstacle loops are never averaged away.
    func rectangularOutline(_ polygon: [SIMD3<Float>], lines: [Line]) -> (outline:[SIMD3<Float>], planeViews:[Int])? {
        guard polygon.count == 4 else { return nil }
        let p = polygon.map { SIMD2($0.x,$0.z) }
        let initial = simd_normalize(p[1]-p[0])
        func rotated(_ v: SIMD2<Float>, _ i: Int) -> SIMD2<Float> {
            switch i%4 { case 0: v; case 1: [-v.y,v.x]; case 2: -v; default: [v.y,-v.x] }
        }
        var angles = [Float](), samples = [[(points:[SIMD2<Float>], plane:WallPlane?)]]()
        var supports = [Line](), protected = [Bool]()
        for i in 0..<4 {
            let a = p[i], b = p[(i+1)%4], mid = (a+b)/2, length = simd_distance(a,b)
            let t = (b-a)/length, n = SIMD2(-t.y,t.x), reference = rotated(initial,i)
            guard simd_dot(t,reference) > cos(0.12), length > 0.075,
                  let line = lines.filter({ abs(simd_dot($0.normal,a)-$0.offset)<0.001 && abs(simd_dot($0.normal,b)-$0.offset)<0.001 }).first else { return nil }
            supports.append(line)
            let isProtected = lines.contains { other in
                let aligned = simd_dot(other.normal,n) >= 0 ? other.normal : -other.normal
                let offset = simd_dot(other.normal,n) >= 0 ? other.offset : -other.offset
                let behind = simd_dot(aligned,mid)-offset
                return abs(n.x*aligned.y-n.y*aligned.x) <= 0.12 && behind >= 0.005 && behind <= Self.slabReach && other.supports(mid,margin:0.04)
            }
            protected.append(isProtected)
            var views = [(points:[SIMD2<Float>],plane:WallPlane?)]()
            func near(_ q: SIMD2<Float>) -> Bool {
                let along = simd_dot(t,q-a)
                return along >= 0.02 && along <= length-0.02 && abs(simd_dot(n,q-mid)) <= Self.surfaceBand
            }
            for frame in observations {
                let points = (line.isFront ? frame.front : frame.walls).filter(near)
                guard points.count >= 6, points.map({simd_dot(t,$0)}).max()!-points.map({simd_dot(t,$0)}).min()! >= 0.035 else { continue }
                let raw = (frame.wallPoints3D ?? []).filter { near([$0.x,$0.z]) }
                let plane = !line.isFront && !isProtected ? Self.wallPlane(raw,at:[mid.x,seed.y,mid.y],tangent:t) : nil
                views.append((points,plane))
                if !line.isFront && !isProtected && points.map({simd_dot(t,$0)}).max()!-points.map({simd_dot(t,$0)}).min()! >= 0.075 {
                    var direction = plane.map { SIMD2($0.normal.y,-$0.normal.x) } ?? Self.fit(points.map { Sample(p:$0,view:0) }).tangent
                    if simd_dot(direction,t)<0 { direction = -direction }
                    let delta = atan2(reference.x*direction.y-reference.y*direction.x,simd_dot(reference,direction))
                    if abs(delta) <= 0.12 { angles.append(delta) }
                }
            }
            samples.append(views)
            if !line.isFront && !isProtected && views.isEmpty {
                angles.append(atan2(reference.x*t.y-reference.y*t.x,simd_dot(reference,t)))
            }
        }
        guard !angles.isEmpty else { return nil }
        let delta = Self.median(angles), u = SIMD2(initial.x*cos(delta)-initial.y*sin(delta),initial.x*sin(delta)+initial.y*cos(delta))
        var offsets = [Float](), normals = [SIMD2<Float>](), counts = [Int]()
        for i in 0..<4 {
            let t = rotated(u,i), n = SIMD2(-t.y,t.x), mid = (p[i]+p[(i+1)%4])/2
            normals.append(n); counts.append(samples[i].filter { $0.plane != nil }.count)
            let votes = samples[i].map { view -> Float in
                if let plane = view.plane {
                    let basePoint = mid+plane.normal*(plane.offset-simd_dot(plane.normal,mid))
                    return simd_dot(n,basePoint)
                }
                return Self.median(view.points.map {simd_dot(n,$0)})
            }
            var offset = supports[i].isFront || protected[i] || votes.count < 2 ? simd_dot(n,mid) : Self.median(votes)
            if protected[i] { offset = max(offset,simd_dot(n,p[i]),simd_dot(n,p[(i+1)%4])) }
            offsets.append(offset)
        }
        var outline = [SIMD3<Float>]()
        for i in 0..<4 {
            let j = (i+3)%4, a = normals[j], b = normals[i], det = a.x*b.y-a.y*b.x
            let q = SIMD2((offsets[j]*b.y-a.y*offsets[i])/det,(a.x*offsets[i]-offsets[j]*b.x)/det)
            guard simd_distance(q,p[i])<0.04, supports[i].supports(q,margin:0.04), supports[j].supports(q,margin:0.04) else { return nil }
            outline.append([q.x,seed.y,q.y])
        }
        return (outline,counts)
    }
}
