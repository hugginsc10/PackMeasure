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
    case invalidHeight, invalidShelf, invalidShelfBin, invalidDifference, invalidInput, wallReference, unevenShelf, upperPoint, outsideSelection
    var errorDescription: String? {
        switch self {
        case .invalidHeight: "Enter a ceiling height greater than zero and no more than 20 meters."
        case .invalidShelf: "Check the shelf dimensions: depth must be positive, height cannot be negative, and clear space must be positive if entered."
        case .invalidShelfBin: "Enter positive bin width, depth, and height, and a nonnegative clearance allowance."
        case .invalidDifference: "The distance to the back edge must be greater than the distance to the front edge. Measure both from the same reference along the same direction."
        case .invalidInput: "Enter a valid, nonnegative length. When using feet and inches, feet must be whole and inches must be less than 12."
        case .wallReference: "Capture two points at least 20 cm apart along the same straight back edge."
        case .unevenShelf: "The shelf points aren’t level. Aim at the top of the same shelf, including its front edge, then try again."
        case .outsideSelection: "Those points don’t enclose the locked shelf surface. Capture the left and right ends of its back edge and its front edge."
        case .upperPoint: "Aim at the underside directly above the front point. It must be above the shelf and within 15 cm horizontally of that point."
        }
    }
}

struct ShelfBinSpec: Codable, Equatable, Sendable {
    static let defaultClearanceAllowanceMeters: Float = 0.0127 // 0.5 in (12.7 mm)

    var name: String
    let width: Float
    let depth: Float
    let height: Float
    let clearanceAllowance: Float
    let allowQuarterTurnOnShelf: Bool

    init(
        name: String = "Bin",
        width: Float,
        depth: Float,
        height: Float,
        clearanceAllowance: Float = ShelfBinSpec.defaultClearanceAllowanceMeters,
        allowQuarterTurnOnShelf: Bool = false
    ) throws {
        guard width.isFinite, width > 0, width <= 10,
              depth.isFinite, depth > 0, depth <= 10,
              height.isFinite, height > 0, height <= 10,
              clearanceAllowance.isFinite, clearanceAllowance >= 0, clearanceAllowance <= 1 else {
            throw RoomDimensionError.invalidShelfBin
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "Bin" : trimmed
        self.width = width
        self.depth = depth
        self.height = height
        self.clearanceAllowance = clearanceAllowance
        self.allowQuarterTurnOnShelf = allowQuarterTurnOnShelf
    }
}

struct ShelfBinFitEvaluation: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case passesListedChecks
        case insufficientInformation
        case exceedsShelfEnvelope
    }

    enum Orientation: String, Equatable, Sendable {
        case asEntered
        case quarterTurnOnShelf

        var description: String {
            switch self {
            case .asEntered:
                "As entered (width along shelf, depth front-to-back)"
            case .quarterTurnOnShelf:
                "Rotated 90° on shelf (depth along shelf, width front-to-back)"
            }
        }
    }

    static let defaultLimitationsNote =
        "Checks the measured shelf surface and vertical headroom only. Face-frame openings, brackets, slide-in tilt clearance, and shelf weight capacity are not certified."

    let bin: ShelfBinSpec
    let status: Status
    let headline: String
    let matchedOrientation: Orientation?
    let maxSideBySideCount: Int?
    let constraintDetails: [String]
    let limitationsNote: String
}

struct RoomShelfMeasurement: Codable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case lidar, twoView, manual, difference }
    let id: UUID
    var name: String
    var wallID: UUID?
    let usableWidth: Float?
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
    let intendedBin: ShelfBinSpec?

    init(id: UUID = UUID(), name: String, wallID: UUID? = nil, usableWidth: Float? = nil, depth: Float,
         heightAboveFloor: Float, clearanceAbove: Float?, source: Source,
         measuredAt: Date = .now, capturedPoints: [SIMD3<Float>]? = nil, selectedTop: SIMD3<Float>? = nil,
         referenceToBack: Float? = nil, referenceToFront: Float? = nil, pointMatches: [ShelfPointMatch]? = nil,
         intendedBin: ShelfBinSpec? = nil) throws {
        guard depth.isFinite, depth > 0, depth <= 10,
              usableWidth.map({ $0.isFinite && $0 > 0 && $0 <= 20 }) ?? true,
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
                  usableWidth.map({ abs($0 - geometry.width) < 0.001 }) ?? true,
                  (clearanceAbove == nil && geometry.clearance == nil)
                    || (clearanceAbove != nil && geometry.clearance != nil && abs(clearanceAbove! - geometry.clearance!) < 0.001) else { throw RoomDimensionError.invalidShelf }
        }
        self.id = id; self.name = name; self.wallID = wallID; self.usableWidth = usableWidth
        self.depth = depth; self.heightAboveFloor = heightAboveFloor; self.clearanceAbove = clearanceAbove
        self.source = source; self.measuredAt = measuredAt; self.capturedPoints = capturedPoints
        self.selectedTop = selectedTop
        self.pointMatches = pointMatches
        self.referenceToBack = referenceToBack; self.referenceToFront = referenceToFront
        self.intendedBin = intendedBin
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

    static func dimension(_ meters: Float, units: MeasurementUnits) -> String {
        units.preciseLength(millimeters: Double(meters) * 1_000)
    }

    static func dimension(_ meters: Float) -> String {
        String(format: "%.1f in · %.1f cm", meters / 0.0254, meters * 100)
    }

    func binFitEvaluation(units: MeasurementUnits = .inches) -> ShelfBinFitEvaluation? {
        evaluateBinFit { Self.dimension($0, units: units) }
    }

    private func evaluateBinFit(format: (Float) -> String) -> ShelfBinFitEvaluation? {
        guard let bin = intendedBin else { return nil }
        let epsilon: Float = 0.0001
        let requiredWidth = bin.width + bin.clearanceAllowance
        let requiredDepth = bin.depth + bin.clearanceAllowance
        let requiredHeight = bin.height + bin.clearanceAllowance

        var details: [String] = []
        var missingInformation = false

        if usableWidth == nil {
            missingInformation = true
            details.append("Usable shelf width not measured.")
        }
        // Floor elevation (heightAboveFloor) never substitutes for headroom.
        if clearanceAbove == nil {
            missingInformation = true
            details.append("Clear space above (headroom) not measured; shelf top height above floor cannot substitute for headroom.")
        }

        var matchedOrientation: ShelfBinFitEvaluation.Orientation?
        var maxSideBySideCount: Int?
        var exceedsMeasuredAxis = false

        if let usableWidth {
            let fitsAsEntered = requiredWidth <= usableWidth + epsilon && requiredDepth <= depth + epsilon
            let fitsQuarterTurn = bin.allowQuarterTurnOnShelf
                && requiredDepth <= usableWidth + epsilon
                && requiredWidth <= depth + epsilon

            let asEnteredCount = fitsAsEntered
                ? max(1, Int(floor(Double((usableWidth + epsilon) / max(0.001, requiredWidth)))))
                : nil
            let quarterTurnCount = fitsQuarterTurn
                ? max(1, Int(floor(Double((usableWidth + epsilon) / max(0.001, requiredDepth)))))
                : nil

            if let asEnteredCount, let quarterTurnCount {
                if quarterTurnCount > asEnteredCount {
                    matchedOrientation = .quarterTurnOnShelf
                    maxSideBySideCount = quarterTurnCount
                } else {
                    matchedOrientation = .asEntered
                    maxSideBySideCount = asEnteredCount
                }
            } else if let asEnteredCount {
                matchedOrientation = .asEntered
                maxSideBySideCount = asEnteredCount
            } else if let quarterTurnCount {
                matchedOrientation = .quarterTurnOnShelf
                maxSideBySideCount = quarterTurnCount
            } else {
                exceedsMeasuredAxis = true
                if requiredWidth > usableWidth + epsilon {
                    details.append("\(bin.name) width with clearance (\(format(requiredWidth))) exceeds usable shelf width (\(format(usableWidth))).")
                }
                if requiredDepth > depth + epsilon {
                    details.append("\(bin.name) depth with clearance (\(format(requiredDepth))) exceeds shelf depth (\(format(depth))).")
                }
                if bin.allowQuarterTurnOnShelf {
                    details.append("Rotating 90° on the shelf (\(format(requiredDepth)) along shelf × \(format(requiredWidth)) deep) also exceeds the measured footprint.")
                }
            }
        } else {
            let fitsDepthDirect = requiredDepth <= depth + epsilon
            let fitsDepthRotated = bin.allowQuarterTurnOnShelf && requiredWidth <= depth + epsilon
            if !fitsDepthDirect && !fitsDepthRotated {
                exceedsMeasuredAxis = true
                details.append("\(bin.name) depth with clearance (\(format(requiredDepth))) exceeds shelf depth (\(format(depth))).")
            }
        }

        if let clearanceAbove {
            if requiredHeight > clearanceAbove + epsilon {
                exceedsMeasuredAxis = true
                details.append("\(bin.name) height with clearance (\(format(requiredHeight))) exceeds clear space above (\(format(clearanceAbove))).")
            }
        }

        let status: ShelfBinFitEvaluation.Status
        let headline: String
        if missingInformation {
            status = .insufficientInformation
            headline = "Insufficient information to verify \(bin.name)"
        } else if exceedsMeasuredAxis {
            status = .exceedsShelfEnvelope
            headline = "\(bin.name) does not fit measured shelf envelope"
        } else {
            status = .passesListedChecks
            headline = "\(bin.name) passes listed shelf envelope checks"
        }

        return ShelfBinFitEvaluation(
            bin: bin,
            status: status,
            headline: headline,
            matchedOrientation: status == .passesListedChecks ? matchedOrientation : nil,
            maxSideBySideCount: status == .passesListedChecks ? maxSideBySideCount : nil,
            constraintDetails: details,
            limitationsNote: ShelfBinFitEvaluation.defaultLimitationsNote
        )
    }

    var shareText: String { shareText(format: Self.dimension) }

    func shareText(units: MeasurementUnits) -> String {
        shareText { Self.dimension($0, units: units) }
    }

    private func shareText(format: (Float) -> String) -> String {
        let widthPrefix = usableWidth.map { "width \(format($0)); " } ?? ""
        var result = "\(name): \(widthPrefix)depth \(format(depth)); top above floor \(format(heightAboveFloor))"
        result += clearanceAbove.map { "; clear space above \(format($0))" } ?? "; clear space above not measured"
        result += " (\(sourceLabel))"
        if let referenceToBack, let referenceToFront, source == .difference {
            result += "\nDepth calculation: \(format(referenceToBack)) − \(format(referenceToFront)) from the same reference/direction."
        }
        if let evaluation = evaluateBinFit(format: format) {
            let bin = evaluation.bin
            result += "\nBin check (\(bin.name) \(format(bin.width)) × \(format(bin.depth)) × \(format(bin.height)), clearance \(format(bin.clearanceAllowance))): \(evaluation.headline)."
            if let orientation = evaluation.matchedOrientation, let count = evaluation.maxSideBySideCount {
                result += " Orientation: \(orientation.description); up to \(count) side-by-side along measured width."
            }
            if !evaluation.constraintDetails.isEmpty {
                result += " " + evaluation.constraintDetails.joined(separator: " ")
            }
            result += " \(evaluation.limitationsNote)"
        }
        return result
    }
}

/// Five points in one gravity-aligned session: floor, two points along the
/// shelf's back edge, front/top edge, underside above. No saved-room AR origin
/// or changing camera-to-object range is reused in this calculation.
struct ShelfGeometry {
    let width: Float
    let depth: Float
    let height: Float
    let clearance: Float?

    init(points: [SIMD3<Float>], selectedTop: SIMD3<Float>? = nil) throws {
        guard (4...5).contains(points.count), points.allSatisfy({ [$0.x, $0.y, $0.z].allSatisfy(\.isFinite) }) else {
            throw RoomDimensionError.invalidShelf
        }
        let floor = points[0], a = points[1], b = points[2], front = points[3]
        let edge = SIMD2<Float>(b.x - a.x, b.z - a.z)
        let edgeLength = simd_length(edge)
        guard edgeLength >= 0.2, edgeLength <= 20 else { throw RoomDimensionError.wallReference }
        width = edgeLength
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
            guard along >= -0.03, along <= edgeLength + 0.03,
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

enum RoomEntryUnits: String, CaseIterable {
    case inches = "Inches", centimeters = "Centimeters", imperial = "Feet & inches", metric = "Meters"

    init(preferred units: MeasurementUnits) {
        self = units == .centimeters ? .centimeters : .inches
    }
}

struct RoomLengthEntry {
    var feet = "" { didSet { unchangedValue = nil } }
    var inches = "" { didSet { unchangedValue = nil } }
    var meters = "" { didSet { unchangedValue = nil } }
    var totalInches = "" { didSet { unchangedValue = nil } }
    var centimeters = "" { didSet { unchangedValue = nil } }
    // Formatting an unchanged value must not round the stored measurement when
    // the user switches entry units or applies an unedited captured dimension.
    private var unchangedValue: Float?
    init(_ value: Float? = nil) {
        guard let value, value.isFinite, (0...1000).contains(value) else { return }
        // Round the total before splitting so 11.999 in never renders as 12 in.
        let total = (Double(value) / 0.0254 * 100).rounded() / 100
        feet = String(Int(total / 12))
        inches = String(format: "%.2f", total.truncatingRemainder(dividingBy: 12))
        meters = String(format: "%.7f", value)
        totalInches = String(format: "%.6f", Double(value) / 0.0254)
        centimeters = String(format: "%.6f", Double(value) * 100)
        unchangedValue = value
    }
    func value(in units: RoomEntryUnits) throws -> Float? {
        if let unchangedValue { return unchangedValue }
        func number(_ text: String) -> Float? {
            Float(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        if units != .imperial {
            let text = units == .metric ? meters : units == .centimeters ? centimeters : totalInches
            let scale: Float = units == .metric ? 1 : units == .centimeters ? 0.01 : 0.0254
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let entered = number(text), entered.isFinite, entered >= 0 else { throw RoomDimensionError.invalidInput }
            let value = entered * scale
            guard value.isFinite, value <= 1000 else { throw RoomDimensionError.invalidInput }
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
