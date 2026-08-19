import Foundation

/// The four reticle placements needed to define a rectangular box. Every edge
/// starts at the same visible corner; gravity comes from the active AR frame.
struct GuidedBoxCapture: Equatable, Sendable {
    var referenceCorner: SIMD3<Float>
    var lengthEndpoint: SIMD3<Float>
    var widthEndpoint: SIMD3<Float>
    var heightEndpoint: SIMD3<Float>
    var gravity: SIMD3<Float>
}

enum GuidedBoxEdge: String, CaseIterable, Equatable, Sendable {
    case length
    case width
    case height
}

enum GuidedBoxPoint: String, Equatable, Sendable {
    case referenceCorner = "reference corner"
    case lengthEndpoint = "length point"
    case widthEndpoint = "width point"
    case heightEndpoint = "height point"
}

struct GuidedBoxRawEdgeLengths: Equatable, Sendable {
    let length: Double
    let width: Double
    let height: Double
}

struct GuidedBoxMeasurement: Equatable, Sendable {
    /// Dimensions are sorted so length is the longer horizontal edge. Each
    /// value is rounded upward to avoid under-booking cargo space.
    let dimensions: GeometryDimensions
    let rawEdgeLengthsMeters: GuidedBoxRawEdgeLengths
}

enum GuidedBoxMeasurementError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidGravity
    case nonFinitePoint(GuidedBoxPoint)
    case edgeTooShort(
        edge: GuidedBoxEdge,
        actualMeters: Double,
        minimumMeters: Double
    )
    case edgeNotHorizontal(
        edge: GuidedBoxEdge,
        deviationDegrees: Double,
        maximumDegrees: Double
    )
    case heightNotGravityAligned(
        deviationDegrees: Double,
        maximumDegrees: Double
    )
    case edgesNotPerpendicular(
        first: GuidedBoxEdge,
        second: GuidedBoxEdge,
        deviationDegrees: Double,
        maximumDegrees: Double
    )
}

extension GuidedBoxMeasurementError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Guided box measurement is not configured correctly."
        case .invalidGravity:
            "Motion tracking is not ready. Hold the phone steady, then try again."
        case let .nonFinitePoint(point):
            "The \(point.rawValue) was not captured. Keep the reticle on the box and tap again."
        case let .edgeTooShort(edge, _, minimum):
            "Move the \(edge.rawValue) point farther from the shared corner (at least \(Self.inches(minimum)) in)."
        case let .edgeNotHorizontal(edge, deviation, maximum):
            "Retap the \(edge.rawValue) point along a level edge (tilt \(Self.degrees(deviation)) degrees; maximum \(Self.degrees(maximum)))."
        case let .heightNotGravityAligned(deviation, maximum):
            "Retap the height point along a vertical edge (tilt \(Self.degrees(deviation)) degrees; maximum \(Self.degrees(maximum)))."
        case let .edgesNotPerpendicular(first, second, deviation, maximum):
            "Retap the \(first.rawValue) and \(second.rawValue) points on edges that meet at a square corner (error \(Self.degrees(deviation)) degrees; maximum \(Self.degrees(maximum)))."
        }
    }

    private static func inches(_ meters: Double) -> String {
        String(format: "%.1f", meters * 39.370_078_740_157_48)
    }

    private static func degrees(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

/// Validates four user-selected box edges and converts them into conservative
/// packing dimensions without attempting to segment a cluttered scene.
struct GuidedBoxMeasurementEstimator: Sendable {
    struct Configuration: Equatable, Sendable {
        var minimumEdgeMeters: Double
        var maximumHorizontalDeviationDegrees: Double
        var maximumHeightDeviationDegrees: Double
        var maximumPerpendicularDeviationDegrees: Double
        var roundingIncrementMeters: Double
        var minimumGravityMagnitude: Double

        init(
            minimumEdgeMeters: Double = 0.05,
            maximumHorizontalDeviationDegrees: Double = 12,
            maximumHeightDeviationDegrees: Double = 12,
            maximumPerpendicularDeviationDegrees: Double = 15,
            roundingIncrementMeters: Double = 0.0127,
            minimumGravityMagnitude: Double = 0.01
        ) {
            self.minimumEdgeMeters = minimumEdgeMeters
            self.maximumHorizontalDeviationDegrees = maximumHorizontalDeviationDegrees
            self.maximumHeightDeviationDegrees = maximumHeightDeviationDegrees
            self.maximumPerpendicularDeviationDegrees = maximumPerpendicularDeviationDegrees
            self.roundingIncrementMeters = roundingIncrementMeters
            self.minimumGravityMagnitude = minimumGravityMagnitude
        }

        static let `default` = Configuration()
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    func estimate(_ capture: GuidedBoxCapture) throws -> GuidedBoxMeasurement {
        try validateConfiguration()
        try validatePoints(capture)

        let gravityMagnitude = magnitude(capture.gravity)
        guard gravityMagnitude.isFinite,
              gravityMagnitude >= configuration.minimumGravityMagnitude else {
            throw GuidedBoxMeasurementError.invalidGravity
        }
        let up = capture.gravity / -Float(gravityMagnitude)

        let vectors: [GuidedBoxEdge: SIMD3<Float>] = [
            .length: capture.lengthEndpoint - capture.referenceCorner,
            .width: capture.widthEndpoint - capture.referenceCorner,
            .height: capture.heightEndpoint - capture.referenceCorner,
        ]
        let lengths = Dictionary(uniqueKeysWithValues: vectors.map { edge, vector in
            (edge, magnitude(vector))
        })

        for edge in GuidedBoxEdge.allCases {
            let actual = lengths[edge] ?? 0
            guard actual >= configuration.minimumEdgeMeters else {
                throw GuidedBoxMeasurementError.edgeTooShort(
                    edge: edge,
                    actualMeters: actual,
                    minimumMeters: configuration.minimumEdgeMeters
                )
            }
        }

        let directions = Dictionary(uniqueKeysWithValues: vectors.map { edge, vector in
            (edge, vector / Float(lengths[edge] ?? 1))
        })

        for edge in [GuidedBoxEdge.length, .width] {
            let deviation = horizontalDeviationDegrees(
                direction: directions[edge] ?? .zero,
                up: up
            )
            guard deviation <= configuration.maximumHorizontalDeviationDegrees else {
                throw GuidedBoxMeasurementError.edgeNotHorizontal(
                    edge: edge,
                    deviationDegrees: deviation,
                    maximumDegrees: configuration.maximumHorizontalDeviationDegrees
                )
            }
        }

        let heightDeviation = verticalDeviationDegrees(
            direction: directions[.height] ?? .zero,
            up: up
        )
        guard heightDeviation <= configuration.maximumHeightDeviationDegrees else {
            throw GuidedBoxMeasurementError.heightNotGravityAligned(
                deviationDegrees: heightDeviation,
                maximumDegrees: configuration.maximumHeightDeviationDegrees
            )
        }

        for (first, second) in [
            (GuidedBoxEdge.length, GuidedBoxEdge.width),
            (.length, .height),
            (.width, .height),
        ] {
            let deviation = perpendicularDeviationDegrees(
                first: directions[first] ?? .zero,
                second: directions[second] ?? .zero
            )
            guard deviation <= configuration.maximumPerpendicularDeviationDegrees else {
                throw GuidedBoxMeasurementError.edgesNotPerpendicular(
                    first: first,
                    second: second,
                    deviationDegrees: deviation,
                    maximumDegrees: configuration.maximumPerpendicularDeviationDegrees
                )
            }
        }

        let firstHorizontal = conservative(lengths[.length] ?? 0)
        let secondHorizontal = conservative(lengths[.width] ?? 0)
        let height = conservative(lengths[.height] ?? 0)

        return GuidedBoxMeasurement(
            dimensions: GeometryDimensions(
                lengthMeters: max(firstHorizontal, secondHorizontal),
                widthMeters: min(firstHorizontal, secondHorizontal),
                heightMeters: height
            ),
            rawEdgeLengthsMeters: GuidedBoxRawEdgeLengths(
                length: lengths[.length] ?? 0,
                width: lengths[.width] ?? 0,
                height: lengths[.height] ?? 0
            )
        )
    }

    private func validateConfiguration() throws {
        guard configuration.minimumEdgeMeters.isFinite,
              configuration.minimumEdgeMeters > 0,
              configuration.maximumHorizontalDeviationDegrees.isFinite,
              configuration.maximumHorizontalDeviationDegrees > 0,
              configuration.maximumHorizontalDeviationDegrees < 90,
              configuration.maximumHeightDeviationDegrees.isFinite,
              configuration.maximumHeightDeviationDegrees > 0,
              configuration.maximumHeightDeviationDegrees < 90,
              configuration.maximumPerpendicularDeviationDegrees.isFinite,
              configuration.maximumPerpendicularDeviationDegrees > 0,
              configuration.maximumPerpendicularDeviationDegrees < 90,
              configuration.roundingIncrementMeters.isFinite,
              configuration.roundingIncrementMeters > 0,
              configuration.minimumGravityMagnitude.isFinite,
              configuration.minimumGravityMagnitude > 0 else {
            throw GuidedBoxMeasurementError.invalidConfiguration
        }
    }

    private func validatePoints(_ capture: GuidedBoxCapture) throws {
        for (label, point) in [
            (GuidedBoxPoint.referenceCorner, capture.referenceCorner),
            (.lengthEndpoint, capture.lengthEndpoint),
            (.widthEndpoint, capture.widthEndpoint),
            (.heightEndpoint, capture.heightEndpoint),
        ] where !point.hasFiniteComponents {
            throw GuidedBoxMeasurementError.nonFinitePoint(label)
        }
    }

    private func conservative(_ meters: Double) -> Double {
        let increments = meters / configuration.roundingIncrementMeters
        // Taps exactly on an increment should not jump another half inch due
        // only to Float-to-Double noise from ARKit world coordinates.
        return ceil(increments - 1e-4) * configuration.roundingIncrementMeters
    }

    private func magnitude(_ vector: SIMD3<Float>) -> Double {
        sqrt(
            Double(vector.x) * Double(vector.x)
                + Double(vector.y) * Double(vector.y)
                + Double(vector.z) * Double(vector.z)
        )
    }

    private func dot(_ first: SIMD3<Float>, _ second: SIMD3<Float>) -> Double {
        Double(first.x) * Double(second.x)
            + Double(first.y) * Double(second.y)
            + Double(first.z) * Double(second.z)
    }

    private func horizontalDeviationDegrees(
        direction: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> Double {
        radiansToDegrees(asin(clamp(abs(dot(direction, up)))))
    }

    private func verticalDeviationDegrees(
        direction: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> Double {
        radiansToDegrees(acos(clamp(abs(dot(direction, up)))))
    }

    private func perpendicularDeviationDegrees(
        first: SIMD3<Float>,
        second: SIMD3<Float>
    ) -> Double {
        radiansToDegrees(asin(clamp(abs(dot(first, second)))))
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func radiansToDegrees(_ value: Double) -> Double {
        value * 180 / .pi
    }
}

private extension SIMD3 where Scalar == Float {
    var hasFiniteComponents: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
