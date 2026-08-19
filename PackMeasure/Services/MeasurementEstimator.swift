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
    case floorSurface
    case insufficientSurfaceEvidence
}

enum CenteredTargetValidation: Equatable, Sendable {
    case valid
    case rejected(CenteredTargetRejection)
}

enum SceneFloorEstimateSource: String, Equatable, Sendable {
    case classifiedPlane
    case peripheralDepth
}

struct SceneFloorEstimate: Equatable, Sendable {
    let y: Float
    let source: SceneFloorEstimateSource
}

struct CenteredTargetContext: Equatable, Sendable {
    let floorEstimate: SceneFloorEstimate?
    let regionCoverage: Float
    let regionTouchesImageEdge: Bool

    static let unknown = CenteredTargetContext(
        floorEstimate: nil,
        regionCoverage: 0,
        regionTouchesImageEdge: false
    )
}

struct CenteredTargetAssessment: Equatable, Sendable {
    let validation: CenteredTargetValidation
    let absoluteUpNormal: Float
    let elevationAboveFloorMeters: Float?
}

/// Finds a dominant, low world-Y band in sparse peripheral depth points.
/// World Y is gravity-aligned, so a dense band is useful floor context while
/// diffuse wall/clutter samples do not become authoritative on their own.
struct PeripheralFloorEstimator: Sendable {
    var binWidthMeters: Float = 0.04
    var minimumPointCount = 24
    var minimumSupportCount = 12
    var minimumSupportFraction: Float = 0.08
    var relativePeakThreshold: Float = 0.45

    func estimate(from points: [SIMD3<Float>]) -> SceneFloorEstimate? {
        let ys = points.map(\.y).filter(\.isFinite)
        guard binWidthMeters > 0, ys.count >= minimumPointCount else { return nil }

        var bins: [Int: [Float]] = [:]
        for y in ys {
            let key = Int((y / binWidthMeters).rounded())
            bins[key, default: []].append(y)
        }
        guard let peakCount = bins.values.map(\.count).max() else { return nil }

        let requiredSupport = max(
            minimumSupportCount,
            max(
                Int(ceil(Float(ys.count) * minimumSupportFraction)),
                Int(ceil(Float(peakCount) * relativePeakThreshold))
            )
        )
        guard let lowestDenseKey = bins
            .filter({ $0.value.count >= requiredSupport })
            .keys
            .min(),
              var values = bins[lowestDenseKey] else {
            return nil
        }

        values.sort()
        return SceneFloorEstimate(
            y: values[values.count / 2],
            source: .peripheralDepth
        )
    }
}

/// Distinguishes a legitimate elevated top from the floor by combining its
/// gravity-aligned normal with scene-floor and connected-region context.
struct CenteredTargetValidator: Sendable {
    var maximumAbsoluteUpNormal: Float = 0.72
    var minimumTangentLengthMeters: Float = 0.003
    var minimumElevatedTopMeters: Float = 0.12
    var maximumFloorDeltaMeters: Float = 0.08
    var broadHorizontalCoverage: Float = 0.55

    func validate(_ sample: CenteredTargetSurfaceSample) -> CenteredTargetValidation {
        validate(sample, context: .unknown)
    }

    func validate(
        _ sample: CenteredTargetSurfaceSample,
        context: CenteredTargetContext
    ) -> CenteredTargetValidation {
        assess(sample, context: context).validation
    }

    func assess(
        _ sample: CenteredTargetSurfaceSample,
        context: CenteredTargetContext
    ) -> CenteredTargetAssessment {
        let horizontalTangent = sample.right - sample.left
        let verticalImageTangent = sample.down - sample.up
        let elevation = context.floorEstimate.map { sample.center.y - $0.y }
        guard simd_length(horizontalTangent) >= minimumTangentLengthMeters,
              simd_length(verticalImageTangent) >= minimumTangentLengthMeters else {
            return CenteredTargetAssessment(
                validation: .rejected(.insufficientSurfaceEvidence),
                absoluteUpNormal: 0,
                elevationAboveFloorMeters: elevation
            )
        }

        let normal = simd_cross(horizontalTangent, verticalImageTangent)
        let normalLength = simd_length(normal)
        guard normalLength > 0.000_001 else {
            return CenteredTargetAssessment(
                validation: .rejected(.insufficientSurfaceEvidence),
                absoluteUpNormal: 0,
                elevationAboveFloorMeters: elevation
            )
        }

        let absoluteUpNormal = abs(normal.y / normalLength)
        guard absoluteUpNormal >= maximumAbsoluteUpNormal else {
            return CenteredTargetAssessment(
                validation: .valid,
                absoluteUpNormal: absoluteUpNormal,
                elevationAboveFloorMeters: elevation
            )
        }

        if let elevation, elevation >= minimumElevatedTopMeters {
            return CenteredTargetAssessment(
                validation: .valid,
                absoluteUpNormal: absoluteUpNormal,
                elevationAboveFloorMeters: elevation
            )
        }

        let isBroadFloorCandidate = context.regionCoverage >= broadHorizontalCoverage
            || context.regionTouchesImageEdge
        let isAuthoritativeFloor = context.floorEstimate?.source == .classifiedPlane
        let isAtObservedFloor = elevation.map { abs($0) <= maximumFloorDeltaMeters } ?? false
        let validation: CenteredTargetValidation
        if isAtObservedFloor && (isAuthoritativeFloor || isBroadFloorCandidate) {
            validation = .rejected(.floorSurface)
        } else if context.floorEstimate == nil, isBroadFloorCandidate {
            validation = .rejected(.floorSurface)
        } else {
            // A compact horizontal region without reliable floor context may be
            // a box top; the downstream geometry contamination gate remains.
            validation = .valid
        }

        return CenteredTargetAssessment(
            validation: validation,
            absoluteUpNormal: absoluteUpNormal,
            elevationAboveFloorMeters: elevation
        )
    }
}

enum MeasurementEstimationFailure: Equatable, Sendable {
    case insufficientFrames(actual: Int, minimum: Int)
    case targetRejected(CenteredTargetRejection)
    case geometry(BoundingBoxEstimationError)
}

enum MeasurementEstimationOutcome: Equatable, Sendable {
    case success(MeasurementEstimate)
    case failure(MeasurementEstimationFailure)
}

/// Adapts the shared geometry result into the scanner-facing measurement model.
/// All bounding-box math lives in `GravityAlignedBoundingBoxEstimator`.
enum MeasurementEstimator {
    static func estimate(
        from worldPoints: [SIMD3<Float>],
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid
    ) -> MeasurementEstimate? {
        guard case .success(let estimate) = outcome(
            from: worldPoints,
            frameCount: frameCount,
            targetValidation: targetValidation
        ) else {
            return nil
        }
        return estimate
    }

    static func outcome(
        from worldPoints: [SIMD3<Float>],
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid
    ) -> MeasurementEstimationOutcome {
        guard frameCount >= 3 else {
            return .failure(.insufficientFrames(actual: frameCount, minimum: 3))
        }
        if case .rejected(let reason) = targetValidation {
            return .failure(.targetRejected(reason))
        }

        let geometry: GravityAlignedBoundingBoxEstimate
        do {
            geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: worldPoints)
        } catch let error as BoundingBoxEstimationError {
            return .failure(.geometry(error))
        } catch {
            return .failure(.geometry(.degeneratePointCloud))
        }

        return .success(
            MeasurementEstimate(
                lengthMeters: geometry.dimensions.lengthMeters,
                widthMeters: geometry.dimensions.widthMeters,
                heightMeters: geometry.dimensions.heightMeters,
                confidence: scanConfidence(from: geometry.confidence.level),
                sampleCount: geometry.diagnostics.inlierPointCount,
                frameCount: frameCount
            )
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
