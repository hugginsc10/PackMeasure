import Foundation

enum GeometryLengthUnit: String, CaseIterable, Sendable {
    case meters
    case centimeters
    case inches
    case feet

    fileprivate var unitsPerMeter: Double {
        switch self {
        case .meters: 1
        case .centimeters: 100
        case .inches: 39.370_078_740_157_48
        case .feet: 3.280_839_895_013_123
        }
    }
}

struct ConvertedGeometryDimensions: Equatable, Sendable {
    let length: Double
    let width: Double
    let height: Double
    let unit: GeometryLengthUnit
}

/// A conservative packing box. Geometry remains in SI units until the UI or
/// packing domain explicitly converts it.
struct GeometryDimensions: Equatable, Sendable {
    let lengthMeters: Double
    let widthMeters: Double
    let heightMeters: Double

    var footprintSquareMeters: Double {
        lengthMeters * widthMeters
    }

    var volumeCubicMeters: Double {
        footprintSquareMeters * heightMeters
    }

    func converted(to unit: GeometryLengthUnit) -> ConvertedGeometryDimensions {
        ConvertedGeometryDimensions(
            length: lengthMeters * unit.unitsPerMeter,
            width: widthMeters * unit.unitsPerMeter,
            height: heightMeters * unit.unitsPerMeter,
            unit: unit
        )
    }
}

enum GeometryConfidenceLevel: String, Equatable, Sendable {
    case low
    case medium
    case high
}

struct GeometryMeasurementConfidence: Equatable, Sendable {
    let score: Double
    let level: GeometryConfidenceLevel
    let pointCount: Int
    let inlierRatio: Double

    /// 0 means the XZ covariance is rotationally ambiguous (for example, a
    /// square footprint); 1 means the principal horizontal axis is strong.
    let horizontalStability: Double
}

struct GeometryDiagnostics: Equatable, Sendable {
    let inputPointCount: Int
    let finitePointCount: Int
    let uniquePointCount: Int
    let inlierPointCount: Int
    let filteredNonFinitePointCount: Int
    let deduplicatedPointCount: Int
    let rejectedOutlierCount: Int
}

struct GravityAlignedBoundingBoxEstimate: Equatable, Sendable {
    let dimensions: GeometryDimensions
    let center: SIMD3<Float>
    let yawRadians: Float
    let confidence: GeometryMeasurementConfidence
    let diagnostics: GeometryDiagnostics
}

enum BoundingBoxEstimationError: Error, Equatable, Sendable {
    case invalidConfiguration
    case insufficientFinitePoints(actual: Int, minimum: Int)
    case insufficientUniquePoints(actual: Int, minimum: Int)
    case degeneratePointCloud
    case groundPlaneContamination
}
