import Foundation
import simd

struct RoomCeilingHeight: Codable, Sendable {
    let meters: Float
    let enteredAt: Date
    init(meters: Float, enteredAt: Date = .now) throws {
        guard meters.isFinite, meters > 0, meters <= 20 else { throw RoomDimensionError.invalidHeight }
        self.meters = meters
        self.enteredAt = enteredAt
    }
}

enum RoomDimensionError: LocalizedError {
    case invalidHeight, invalidShelf, invalidDifference, invalidInput, wallReference, unevenShelf, upperPoint, outsideSelection
    var errorDescription: String? {
        switch self {
        case .invalidHeight: "Enter a ceiling height greater than zero and no more than 20 meters."
        case .invalidShelf: "Check the shelf dimensions: depth must be positive, height cannot be negative, and clear space must be positive if entered."
        case .invalidDifference: "The distance to the back edge must be greater than the distance to the front edge. Measure both from the same reference along the same direction."
        case .invalidInput: "Enter a valid length. Feet must be a whole number and inches must be less than 12."
        case .wallReference: "Capture two points at least 20 cm apart along the same straight back edge."
        case .unevenShelf: "The shelf points aren’t level. Aim at the top of the same shelf, including its front edge, then try again."
        case .outsideSelection: "Those points don’t enclose the locked shelf surface. Capture the left and right ends of its back edge and its front edge."
        case .upperPoint: "Aim at the underside directly above the front point. It must be above the shelf and within 15 cm horizontally of that point."
        }
    }
}

struct RoomShelfMeasurement: Codable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case lidar, twoView, manual, difference }
    let id: UUID
    var name: String
    var wallID: UUID?
    let depth: Float
    let heightAboveFloor: Float
    let clearanceAbove: Float?
    let source: Source
    let measuredAt: Date
    let capturedPoints: [SIMD3<Float>]?
    let selectedTop: SIMD3<Float>?
    let pointMatches: [ShelfPointMatch]?
    let referenceToBack: Float?
    let referenceToFront: Float?

    init(id: UUID = UUID(), name: String, wallID: UUID? = nil, depth: Float,
         heightAboveFloor: Float, clearanceAbove: Float?, source: Source,
         measuredAt: Date = .now, capturedPoints: [SIMD3<Float>]? = nil, selectedTop: SIMD3<Float>? = nil,
         referenceToBack: Float? = nil, referenceToFront: Float? = nil, pointMatches: [ShelfPointMatch]? = nil) throws {
        guard depth.isFinite, depth > 0, depth <= 10,
              heightAboveFloor.isFinite, (0...20).contains(heightAboveFloor),
              clearanceAbove.map({ $0.isFinite && $0 > 0 && $0 <= 20 }) ?? true else {
            throw RoomDimensionError.invalidShelf
        }
        if source == .difference {
            guard let referenceToBack, let referenceToFront,
                  abs(try Self.depthFromDistances(back: referenceToBack, front: referenceToFront) - depth) < 0.0001 else {
                throw RoomDimensionError.invalidDifference
            }
        }
        if source == .twoView {
            guard let capturedPoints, let pointMatches, let selectedTop,
                  pointMatches.count == capturedPoints.count, (4...5).contains(pointMatches.count) else { throw RoomDimensionError.invalidShelf }
            for (point, match) in zip(capturedPoints, pointMatches) {
                let checked = try ShelfPointMatch(first: match.first, second: match.second)
                guard simd_distance(point, checked.point) < 0.001 else { throw RoomDimensionError.invalidShelf }
            }
            let geometry = try ShelfGeometry(points: capturedPoints, selectedTop: selectedTop)
            guard abs(depth - geometry.depth) < 0.001, abs(heightAboveFloor - geometry.height) < 0.001,
                  (clearanceAbove == nil && geometry.clearance == nil)
                    || (clearanceAbove != nil && geometry.clearance != nil && abs(clearanceAbove! - geometry.clearance!) < 0.001) else { throw RoomDimensionError.invalidShelf }
        }
        self.id = id; self.name = name; self.wallID = wallID
        self.depth = depth; self.heightAboveFloor = heightAboveFloor; self.clearanceAbove = clearanceAbove
        self.source = source; self.measuredAt = measuredAt; self.capturedPoints = capturedPoints
        self.selectedTop = selectedTop
        self.pointMatches = pointMatches
        self.referenceToBack = referenceToBack; self.referenceToFront = referenceToFront
    }

    static func depthFromDistances(back: Float, front: Float) throws -> Float {
        guard back.isFinite, front.isFinite, back > front, front >= 0 else { throw RoomDimensionError.invalidDifference }
        return back - front
    }

    var sourceLabel: String {
        switch source {
        case .lidar: "LiDAR estimate · verify dimensions"
        case .twoView: "Matched-point estimate · verify dimensions"
        case .manual: "Entered measurements"
        case .difference: "Depth from entered distances · heights entered"
        }
    }

    static func dimension(_ meters: Float) -> String {
        String(format: "%.1f in · %.1f cm", meters / 0.0254, meters * 100)
    }

    var shareText: String {
        var result = "\(name): depth \(Self.dimension(depth)); top above floor \(Self.dimension(heightAboveFloor))"
        result += clearanceAbove.map { "; clear space above \(Self.dimension($0))" } ?? "; clear space above not measured"
        result += " (\(sourceLabel))"
        if let referenceToBack, let referenceToFront, source == .difference {
            result += "\nDepth calculation: \(Self.dimension(referenceToBack)) − \(Self.dimension(referenceToFront)) from the same reference/direction."
        }
        return result
    }
}

/// Five points in one gravity-aligned session: floor, two points along the
/// shelf's back edge, front/top edge, underside above. No saved-room AR origin
/// or changing camera-to-object range is reused in this calculation.
struct ShelfGeometry {
    let depth: Float
    let height: Float
    let clearance: Float?

    init(points: [SIMD3<Float>], selectedTop: SIMD3<Float>? = nil) throws {
        guard (4...5).contains(points.count), points.allSatisfy({ [$0.x, $0.y, $0.z].allSatisfy(\.isFinite) }) else {
            throw RoomDimensionError.invalidShelf
        }
        let floor = points[0], a = points[1], b = points[2], front = points[3]
        let edge = SIMD2<Float>(b.x - a.x, b.z - a.z)
        guard simd_length(edge) >= 0.2 else { throw RoomDimensionError.wallReference }
        guard abs(a.y - b.y) <= 0.03, abs(front.y - (a.y + b.y) / 2) <= 0.03 else {
            throw RoomDimensionError.unevenShelf
        }
        let axis = simd_normalize(edge)
        let normal = SIMD2<Float>(-axis.y, axis.x)
        depth = abs(simd_dot(SIMD2(front.x - a.x, front.z - a.z), normal))
        if let selectedTop {
            guard [selectedTop.x, selectedTop.y, selectedTop.z].allSatisfy(\.isFinite), abs(selectedTop.y - front.y) <= 0.03 else { throw RoomDimensionError.unevenShelf }
            let delta = SIMD2<Float>(selectedTop.x - a.x, selectedTop.z - a.z)
            let along = simd_dot(delta, axis)
            let frontDepth = simd_dot(SIMD2<Float>(front.x - a.x, front.z - a.z), normal)
            let seedDepth = simd_dot(delta, normal) * (frontDepth >= 0 ? 1 : -1)
            guard along >= -0.03, along <= simd_length(edge) + 0.03,
                  seedDepth >= -0.03, seedDepth <= depth + 0.03 else { throw RoomDimensionError.outsideSelection }
        }
        height = front.y - floor.y
        guard depth >= 0.03, depth <= 3, height >= 0, height <= 5 else { throw RoomDimensionError.invalidShelf }
        if points.count == 5 {
            let upper = points[4]
            let horizontalOffset = simd_length(SIMD2<Float>(upper.x - front.x, upper.z - front.z))
            guard upper.y - front.y >= 0.02, horizontalOffset <= 0.15 else { throw RoomDimensionError.upperPoint }
            clearance = upper.y - front.y
        } else { clearance = nil }
    }
}

enum RoomEntryUnits: String, CaseIterable { case imperial = "Feet & inches", metric = "Meters" }

struct RoomLengthEntry {
    var feet = ""
    var inches = ""
    var meters = ""
    init(_ value: Float? = nil) {
        guard let value, value.isFinite, (0...1000).contains(value) else { return }
        // Round the total before splitting so 11.999 in never renders as 12 in.
        let total = (Double(value) / 0.0254 * 100).rounded() / 100
        feet = String(Int(total / 12))
        inches = String(format: "%.2f", total.truncatingRemainder(dividingBy: 12))
        meters = String(format: "%.4f", value)
    }
    func value(in units: RoomEntryUnits) throws -> Float? {
        func number(_ text: String) -> Float? {
            Float(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        if units == .metric {
            guard !meters.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let value = number(meters), value.isFinite, (0...1000).contains(value) else { throw RoomDimensionError.invalidInput }
            return value
        }
        guard !feet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !inches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let f = feet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : number(feet)
        let i = inches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : number(inches)
        guard let f, let i, f.isFinite, i.isFinite, f >= 0, f.rounded(.towardZero) == f, i >= 0, i < 12 else { throw RoomDimensionError.invalidInput }
        let result = f * 0.3048 + i * 0.0254
        guard result.isFinite, result <= 1000 else { throw RoomDimensionError.invalidInput }
        return result
    }
    mutating func convert(from units: RoomEntryUnits) throws {
        self = RoomLengthEntry(try value(in: units))
    }
}
