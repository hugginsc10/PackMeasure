import Foundation
import simd

struct CenteredTargetSurfaceSample: Equatable, Sendable {
    let center: SIMD3<Float>
    let left: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let down: SIMD3<Float>
}

enum CenteredTargetRejection: Equatable, Sendable {
    case horizontalSurface
    case insufficientSurfaceEvidence
}

enum CenteredTargetValidation: Equatable, Sendable {
    case valid
    case rejected(CenteredTargetRejection)
}

/// Verifies that the reticle is on an object's vertical face rather than on a
/// horizontal support surface. World Y is gravity-aligned by the AR session.
struct CenteredTargetValidator: Sendable {
    var maximumAbsoluteUpNormal: Float = 0.72
    var minimumTangentLengthMeters: Float = 0.003

    func validate(_ sample: CenteredTargetSurfaceSample) -> CenteredTargetValidation {
        let horizontalTangent = sample.right - sample.left
        let verticalImageTangent = sample.down - sample.up
        guard simd_length(horizontalTangent) >= minimumTangentLengthMeters,
              simd_length(verticalImageTangent) >= minimumTangentLengthMeters else {
            return .rejected(.insufficientSurfaceEvidence)
        }

        let normal = simd_cross(horizontalTangent, verticalImageTangent)
        let normalLength = simd_length(normal)
        guard normalLength > 0.000_001 else {
            return .rejected(.insufficientSurfaceEvidence)
        }

        let absoluteUpNormal = abs(normal.y / normalLength)
        guard absoluteUpNormal < maximumAbsoluteUpNormal else {
            return .rejected(.horizontalSurface)
        }
        return .valid
    }
}

/// Adapts the shared geometry result into the scanner-facing measurement model.
/// All bounding-box math lives in `GravityAlignedBoundingBoxEstimator`.
enum MeasurementEstimator {
    static func estimate(
        from worldPoints: [SIMD3<Float>],
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid
    ) -> MeasurementEstimate? {
        guard frameCount >= 3, targetValidation == .valid else { return nil }

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
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid
    ) -> MeasurementEstimate? {
        estimate(
            from: worldPoints.map {
                SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
            },
            frameCount: frameCount,
            targetValidation: targetValidation
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
