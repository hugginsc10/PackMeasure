import Foundation
import simd

struct ShelfCameraRay: Codable, Sendable {
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>

    init(origin: SIMD3<Float>, direction: SIMD3<Float>) throws {
        guard [origin.x, origin.y, origin.z, direction.x, direction.y, direction.z].allSatisfy(\.isFinite),
              simd_length(direction).isFinite, simd_length(direction) > 0.0001 else { throw WireShelfError.invalidPoint }
        self.origin = origin
        self.direction = simd_normalize(direction)
    }

    /// The picker shows the full sensor image rotated clockwise into portrait.
    /// Its normalized point is mapped back to sensor pixels exactly once.
    init(portraitPoint: SIMD2<Float>, imageSize: SIMD2<Float>, intrinsics: simd_float3x3,
         cameraTransform: simd_float4x4) throws {
        guard [portraitPoint.x, portraitPoint.y].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              imageSize.x.isFinite, imageSize.y.isFinite, imageSize.x > 0, imageSize.y > 0,
              intrinsics[0][0].isFinite, intrinsics[1][1].isFinite,
              intrinsics[0][0] > 0, intrinsics[1][1] > 0 else { throw WireShelfError.invalidPoint }
        let pixel = SIMD2<Float>(portraitPoint.y * imageSize.x, (1 - portraitPoint.x) * imageSize.y)
        let local = SIMD4<Float>((pixel.x - intrinsics[2][0]) / intrinsics[0][0],
                                 -(pixel.y - intrinsics[2][1]) / intrinsics[1][1], -1, 0)
        let world = cameraTransform * local
        let position = cameraTransform.columns.3
        try self.init(origin: [position.x, position.y, position.z], direction: [world.x, world.y, world.z])
    }
}

enum WireShelfError: LocalizedError {
    case invalidPoint, moveSideways, mismatch, outOfRange, floorAboveShelf, differentLevel
    var errorDescription: String? {
        switch self {
        case .invalidPoint: "Choose a visible point on the photo."
        case .moveSideways: "Move the phone sideways about 20–40 cm, then take another view of the same point. Turning in place is not enough."
        case .mismatch: "Those views don’t agree on the point. Zoom in and select the exact same wire crossing or corner in both photos."
        case .outOfRange: "Move closer so the point is 15 cm–3 m away in both views, then restart this point."
        case .floorAboveShelf: "The floor point must be below the locked shelf front. Choose a visible mark on the actual floor."
        case .differentLevel: "That back-edge point is on another level. Choose the top of the same shelf as the locked front point."
        }
    }
}

/// Manual correspondences in two tracked views, independent of LiDAR depth.
/// A small ray gap is a consistency check, not proof of correct correspondence.
struct ShelfPointMatch: Codable, Sendable {
    let first: ShelfCameraRay
    let second: ShelfCameraRay
    let point: SIMD3<Float>
    let baseline: Float
    let angleDegrees: Float
    let rayGap: Float

    init(first: ShelfCameraRay, second: ShelfCameraRay) throws {
        self.first = first; self.second = second
        // Revalidate decoded or externally assembled rays before using them.
        let a = try ShelfCameraRay(origin: first.origin, direction: first.direction)
        let b = try ShelfCameraRay(origin: second.origin, direction: second.direction)
        baseline = simd_distance(a.origin, b.origin)
        let dot = min(Float(1), max(Float(-1), simd_dot(a.direction, b.direction)))
        angleDegrees = acos(dot) * 180 / .pi
        guard baseline >= 0.15, angleDegrees >= 10, angleDegrees <= 80 else { throw WireShelfError.moveSideways }
        let delta = a.origin - b.origin
        let d = simd_dot(a.direction, delta), e = simd_dot(b.direction, delta)
        let denominator = 1 - dot * dot
        let t = (dot * e - d) / denominator, u = (e - dot * d) / denominator
        guard t.isFinite, u.isFinite, (0.15...3).contains(t), (0.15...3).contains(u) else { throw WireShelfError.outOfRange }
        let p = a.origin + t * a.direction, q = b.origin + u * b.direction
        rayGap = simd_distance(p, q)
        guard rayGap <= 0.015 else { throw WireShelfError.mismatch }
        point = (p + q) / 2
    }
}

/// Front/top, floor, back/left top, back/right top, optional underside above.
/// The front point is also the lock, so it does not need to be captured twice.
struct WireShelfSequence {
    private(set) var matches: [ShelfPointMatch] = []
    private(set) var result: ShelfGeometry?
    var selectedTop: SIMD3<Float>? { matches.first?.point }
    var stage: Int { matches.count }
    var measurementPoints: [SIMD3<Float>] {
        guard matches.count >= 4 else { return [] }
        return [matches[1].point, matches[2].point, matches[3].point, matches[0].point]
            + (matches.count == 5 ? [matches[4].point] : [])
    }
    var orderedMatches: [ShelfPointMatch] {
        guard matches.count >= 4 else { return [] }
        return [matches[1], matches[2], matches[3], matches[0]] + (matches.count == 5 ? [matches[4]] : [])
    }
    mutating func append(_ match: ShelfPointMatch) throws {
        guard result == nil, matches.count < 5 else { return }
        let point = match.point
        if let selectedTop {
            if matches.count == 1 && point.y >= selectedTop.y { throw WireShelfError.floorAboveShelf }
            if (2...3).contains(matches.count), abs(point.y - selectedTop.y) > 0.03 { throw WireShelfError.differentLevel }
        }
        var candidate = self
        candidate.matches.append(match)
        if candidate.matches.count >= 4 {
            let geometry = try ShelfGeometry(points: candidate.measurementPoints, selectedTop: candidate.selectedTop)
            if candidate.matches.count == 5 { candidate.result = geometry }
        }
        self = candidate
    }
    mutating func skipClearance() throws {
        guard matches.count == 4 else { return }
        result = try ShelfGeometry(points: measurementPoints, selectedTop: selectedTop)
    }
    mutating func undo() {
        result = nil
        if !matches.isEmpty { matches.removeLast() }
    }
}
