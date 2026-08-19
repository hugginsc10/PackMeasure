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

/// Removes the observed floor band, then repeats connected-component selection
/// from the reticle seed. Background geometry that was reachable only through
/// the floor is therefore excluded without cropping the object's upper faces.
struct ReticleSeededObjectRegionFilter: Sendable {
    var floorClearanceMeters: Float = 0.025

    func filter(
        region: DepthRegion,
        gridWidth: Int,
        gridHeight: Int,
        floorEstimate: SceneFloorEstimate?,
        worldPointAt: (Int) -> SIMD3<Float>?
    ) -> DepthRegion? {
        guard gridWidth > 0, gridHeight > 0,
              floorClearanceMeters >= 0,
              let floorEstimate,
              floorEstimate.y.isFinite else {
            return region
        }

        let pixelCount = gridWidth * gridHeight
        let validIndices = region.indices.filter { 0..<pixelCount ~= $0 }
        guard !validIndices.isEmpty else { return nil }

        let centerX = gridWidth / 2
        let centerY = gridHeight / 2
        guard let seedIndex = validIndices.min(by: { lhs, rhs in
            let lhsX = lhs % gridWidth
            let lhsY = lhs / gridWidth
            let rhsX = rhs % gridWidth
            let rhsY = rhs / gridWidth
            let lhsDistance = (lhsX - centerX) * (lhsX - centerX)
                + (lhsY - centerY) * (lhsY - centerY)
            let rhsDistance = (rhsX - centerX) * (rhsX - centerX)
                + (rhsY - centerY) * (rhsY - centerY)
            return lhsDistance < rhsDistance
        }) else {
            return nil
        }

        let minimumObjectY = floorEstimate.y + floorClearanceMeters
        let eligible = Set(validIndices.filter { index in
            guard let point = worldPointAt(index) else { return false }
            return point.x.isFinite
                && point.y.isFinite
                && point.z.isFinite
                && point.y > minimumObjectY
        })
        guard eligible.contains(seedIndex) else { return nil }

        var connected = Set([seedIndex])
        var queue = [seedIndex]
        var readIndex = 0
        while readIndex < queue.count {
            let index = queue[readIndex]
            readIndex += 1
            let x = index % gridWidth
            let y = index / gridWidth

            if x > 0 {
                enqueue(index - 1, eligible: eligible, connected: &connected, queue: &queue)
            }
            if x + 1 < gridWidth {
                enqueue(index + 1, eligible: eligible, connected: &connected, queue: &queue)
            }
            if y > 0 {
                enqueue(
                    index - gridWidth,
                    eligible: eligible,
                    connected: &connected,
                    queue: &queue
                )
            }
            if y + 1 < gridHeight {
                enqueue(
                    index + gridWidth,
                    eligible: eligible,
                    connected: &connected,
                    queue: &queue
                )
            }
        }

        guard !queue.isEmpty else { return nil }
        let xs = queue.map { $0 % gridWidth }
        let ys = queue.map { $0 / gridWidth }
        return DepthRegion(
            indices: queue,
            seedDepthMeters: region.seedDepthMeters,
            bounds: PixelBounds(
                minX: xs.min() ?? centerX,
                minY: ys.min() ?? centerY,
                maxX: xs.max() ?? centerX,
                maxY: ys.max() ?? centerY
            )
        )
    }

    private func enqueue(
        _ index: Int,
        eligible: Set<Int>,
        connected: inout Set<Int>,
        queue: inout [Int]
    ) {
        guard eligible.contains(index), connected.insert(index).inserted else { return }
        queue.append(index)
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

/// Converts noisy per-frame target assessments into one capture-level decision.
/// A lone floor vote cannot veto otherwise usable object frames, while a
/// repeated floor majority still blocks floor-derived measurements.
struct CenteredTargetCapturePolicy: Sendable {
    var minimumFloorRejectedFrameCount = 2

    func finalValidation(
        acceptedObjectFrameCount: Int,
        floorRejectedFrameCount: Int
    ) -> CenteredTargetValidation {
        guard floorRejectedFrameCount >= minimumFloorRejectedFrameCount,
              floorRejectedFrameCount > acceptedObjectFrameCount else {
            return .valid
        }
        return .rejected(.floorSurface)
    }
}

struct TemporalWorldPointSupportResult: Equatable, Sendable {
    let points: [SIMD3<Float>]
    let inputPointCount: Int
    let contributingFrameCount: Int
    let requiredSupportingFrameCount: Int
}

/// Keeps world-space surfaces seen across multiple depth frames while dropping
/// transient silhouette mixtures. Neighboring voxels count as the same support
/// so normal LiDAR jitter does not erase a legitimate face or protrusion.
struct TemporalWorldPointSupportFilter: Sendable {
    private struct VoxelKey: Hashable, Sendable {
        let x: Int
        let y: Int
        let z: Int
    }

    private let voxelSizeMeters: Float
    private let requiredFrameFraction: Double
    private let neighborRadius: Int
    private let minimumSupportingFrames: Int

    init(
        voxelSizeMeters: Float = 0.02,
        requiredFrameFraction: Double = 0.25,
        neighborRadius: Int = 1,
        minimumSupportingFrames: Int = 3
    ) {
        precondition(voxelSizeMeters.isFinite && voxelSizeMeters > 0)
        precondition(requiredFrameFraction > 0 && requiredFrameFraction <= 1)
        precondition(neighborRadius >= 0)
        precondition(minimumSupportingFrames > 0)
        self.voxelSizeMeters = voxelSizeMeters
        self.requiredFrameFraction = requiredFrameFraction
        self.neighborRadius = neighborRadius
        self.minimumSupportingFrames = minimumSupportingFrames
    }

    func filter(frames: [[SIMD3<Float>]]) -> TemporalWorldPointSupportResult {
        let inputPointCount = frames.reduce(0) { $0 + $1.count }
        let finiteFrames = frames.compactMap { frame -> [SIMD3<Float>]? in
            let finitePoints = frame.filter(isFinite)
            return finitePoints.isEmpty ? nil : finitePoints
        }
        guard !finiteFrames.isEmpty else {
            return TemporalWorldPointSupportResult(
                points: [],
                inputPointCount: inputPointCount,
                contributingFrameCount: 0,
                requiredSupportingFrameCount: 0
            )
        }

        let proportionalRequirement = Int(
            ceil(Double(finiteFrames.count) * requiredFrameFraction)
        )
        let requiredSupportingFrameCount = min(
            finiteFrames.count,
            max(minimumSupportingFrames, proportionalRequirement)
        )
        let occupiedVoxels = finiteFrames.map { frame in
            Set(frame.map(voxelKey))
        }
        let allVoxels = Set(occupiedVoxels.flatMap { $0 })
        var supportByVoxel: [VoxelKey: Int] = [:]
        supportByVoxel.reserveCapacity(allVoxels.count)

        for voxel in allVoxels {
            supportByVoxel[voxel] = occupiedVoxels.reduce(into: 0) { support, frame in
                if frameHasSupport(near: voxel, occupiedVoxels: frame) {
                    support += 1
                }
            }
        }

        let retainedPoints = finiteFrames.flatMap { frame in
            frame.filter { point in
                supportByVoxel[voxelKey(point), default: 0]
                    >= requiredSupportingFrameCount
            }
        }
        return TemporalWorldPointSupportResult(
            points: retainedPoints,
            inputPointCount: inputPointCount,
            contributingFrameCount: finiteFrames.count,
            requiredSupportingFrameCount: requiredSupportingFrameCount
        )
    }

    private func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    private func voxelKey(_ point: SIMD3<Float>) -> VoxelKey {
        VoxelKey(
            x: Int((point.x / voxelSizeMeters).rounded(.down)),
            y: Int((point.y / voxelSizeMeters).rounded(.down)),
            z: Int((point.z / voxelSizeMeters).rounded(.down))
        )
    }

    private func frameHasSupport(
        near voxel: VoxelKey,
        occupiedVoxels: Set<VoxelKey>
    ) -> Bool {
        for xOffset in -neighborRadius...neighborRadius {
            for yOffset in -neighborRadius...neighborRadius {
                for zOffset in -neighborRadius...neighborRadius {
                    if occupiedVoxels.contains(
                        VoxelKey(
                            x: voxel.x + xOffset,
                            y: voxel.y + yOffset,
                            z: voxel.z + zOffset
                        )
                    ) {
                        return true
                    }
                }
            }
        }
        return false
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
        if case .rejected(let reason) = targetValidation {
            return .failure(.targetRejected(reason))
        }
        guard frameCount >= 3 else {
            return .failure(.insufficientFrames(actual: frameCount, minimum: 3))
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
