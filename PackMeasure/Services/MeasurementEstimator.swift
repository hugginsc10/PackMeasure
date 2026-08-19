import Foundation
import simd

/// Adapts the shared geometry result into the scanner-facing measurement model.
/// All bounding-box math lives in `GravityAlignedBoundingBoxEstimator`.
enum MeasurementEstimator {
    static func estimate(
        from worldPoints: [SIMD3<Float>],
        frameCount: Int
    ) -> MeasurementEstimate? {
        guard frameCount >= 3 else { return nil }

        let geometry: GravityAlignedBoundingBoxEstimate
        do {
            geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: worldPoints)
        } catch {
            return nil
        }

        return MeasurementEstimate(
            lengthMeters: geometry.dimensions.lengthMeters,
            widthMeters: geometry.dimensions.widthMeters,
            heightMeters: geometry.dimensions.heightMeters,
            confidence: scanConfidence(from: geometry.confidence.level),
            sampleCount: geometry.diagnostics.inlierPointCount,
            frameCount: frameCount
        )
    }

    /// Compatibility for model-level callers that already hold Double points.
    /// ARKit's native Float representation remains the production path.
    static func estimate(
        from worldPoints: [SIMD3<Double>],
        frameCount: Int
    ) -> MeasurementEstimate? {
        estimate(
            from: worldPoints.map {
                SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
            },
            frameCount: frameCount
        )
    }

    private static func scanConfidence(
        from geometryConfidence: GeometryConfidenceLevel
    ) -> ScanConfidence {
        switch geometryConfidence {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}
