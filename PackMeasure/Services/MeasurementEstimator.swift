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

enum MeasurementEstimationFailure: Equatable, Sendable {
    case insufficientFrames(actual: Int, minimum: Int)
    case targetRejected(CenteredTargetRejection)
    case geometry(BoundingBoxEstimationError)
}

enum MeasurementEstimationOutcome: Equatable, Sendable {
    case success(MeasurementEstimate)
    case failure(MeasurementEstimationFailure)
}

struct MeasurementCaptureEvidence: Equatable, Sendable {
    let estimate: MeasurementEstimate
    let pointCloudConfidence: ScanConfidence
    let geometryCenter: SIMD3<Float>
}

enum MeasurementCaptureEvidenceOutcome: Equatable, Sendable {
    case success(MeasurementCaptureEvidence)
    case failure(MeasurementEstimationFailure)
}

enum MeasurementCompletenessEvidence: Equatable, Sendable {
    case singleView
    case independentViewpoints
}

/// Keeps point-cloud density separate from viewpoint completeness. One or more
/// frames from the same pose can produce a dense, internally consistent cloud
/// while still hiding a physical endpoint (for example, suitcase wheels).
struct MeasurementCompletenessPolicy: Equatable, Sendable {
    func reportedConfidence(
        pointCloudConfidence: ScanConfidence,
        evidence: MeasurementCompletenessEvidence
    ) -> ScanConfidence {
        guard evidence != .independentViewpoints,
              pointCloudConfidence == .high else {
            return pointCloudConfidence
        }
        return .medium
    }
}

struct MeasurementCameraViewpoint: Equatable, Sendable {
    static let minimumHorizontalForwardMagnitude: Float = 0.10

    let position: SIMD3<Float>
    /// Raw camera forward direction projected onto the gravity-horizontal XZ
    /// plane. It is normalized only when compared so invalid/vertical views
    /// remain observable and fail closed.
    let horizontalForward: SIMD2<Float>

    init(position: SIMD3<Float>, horizontalForward: SIMD2<Float>) {
        self.position = position
        self.horizontalForward = horizontalForward
    }

    init(cameraTransform: simd_float4x4) {
        let translation = cameraTransform.columns.3
        let cameraZAxis = cameraTransform.columns.2
        position = SIMD3<Float>(translation.x, translation.y, translation.z)
        // ARKit cameras look down local -Z.
        horizontalForward = SIMD2<Float>(-cameraZAxis.x, -cameraZAxis.z)
    }

    var hasValidEvidence: Bool {
        position.allFinite
            && horizontalForward.allFinite
            && simd_length(horizontalForward) > Self.minimumHorizontalForwardMagnitude
    }
}

struct MeasurementAngleCapture: Equatable, Sendable {
    let evidence: MeasurementCaptureEvidence
    let viewpoint: MeasurementCameraViewpoint
    let objectOverlay: MeasurementObjectOverlay?

    init(
        evidence: MeasurementCaptureEvidence,
        viewpoint: MeasurementCameraViewpoint,
        objectOverlay: MeasurementObjectOverlay? = nil
    ) {
        self.evidence = evidence
        self.viewpoint = viewpoint
        self.objectOverlay = objectOverlay
    }
}

enum MeasurementViewpointValidation: Equatable, Sendable {
    case distinct
    case tooSimilar
}

/// Proves that two captures came from meaningfully different camera positions
/// and viewing directions. Tilting in place, stepping straight toward the
/// item, translating the item and camera together without changing the view,
/// or moving only vertically does not count as a second viewpoint.
struct MeasurementViewpointPolicy: Equatable, Sendable {
    var minimumHorizontalBaselineMeters: Float = 0.15
    var minimumHorizontalViewDirectionChangeRadians: Float = .pi * 20 / 180

    func validate(
        _ candidate: MeasurementAngleCapture,
        against reference: MeasurementAngleCapture
    ) -> MeasurementViewpointValidation {
        let candidatePosition = candidate.viewpoint.position.horizontalXZ
        let referencePosition = reference.viewpoint.position.horizontalXZ
        guard simd_distance(candidatePosition, referencePosition)
            >= minimumHorizontalBaselineMeters else {
            return .tooSimilar
        }

        let candidateForward = candidate.viewpoint.horizontalForward
        let referenceForward = reference.viewpoint.horizontalForward
        let candidateForwardLength = simd_length(candidateForward)
        let referenceForwardLength = simd_length(referenceForward)
        guard candidateForwardLength > MeasurementCameraViewpoint.minimumHorizontalForwardMagnitude,
              referenceForwardLength > MeasurementCameraViewpoint.minimumHorizontalForwardMagnitude else {
            return .tooSimilar
        }

        let cosine = simd_dot(
            candidateForward / candidateForwardLength,
            referenceForward / referenceForwardLength
        )
        let viewingDirectionChange = acos(max(-1, min(1, cosine)))
        return viewingDirectionChange >= minimumHorizontalViewDirectionChangeRadians
            ? .distinct
            : .tooSimilar
    }
}

enum MeasurementAdditionalAngleReason: Equatable, Sendable {
    case firstAngleCaptured
    case viewpointTooSimilar
    case dimensionsDisagree
}

enum MeasurementConsensusFailure: Equatable, Sendable {
    case dimensionsInconsistent
    case invalidMeasurement
}

enum MultiAngleMeasurementProgress: Equatable, Sendable {
    case awaitingFirstAngle
    case needsAnotherAngle(reason: MeasurementAdditionalAngleReason, acceptedCount: Int)
    case accepted(MeasurementEstimate)
    case inconsistent(MeasurementConsensusFailure)

    var diagnosticDescription: String {
        switch self {
        case .awaitingFirstAngle:
            "awaiting_first_angle"
        case .needsAnotherAngle(.firstAngleCaptured, let count):
            "needs_second_angle,accepted_count=\(count)"
        case .needsAnotherAngle(.viewpointTooSimilar, let count):
            "viewpoint_too_similar,accepted_count=\(count)"
        case .needsAnotherAngle(.dimensionsDisagree, let count):
            "dimensions_disagree,accepted_count=\(count)"
        case .accepted(let estimate):
            "accepted,agreement_count=\(estimate.comparisonAgreementCount ?? 0),angle_count=\(estimate.comparisonAngleCount ?? 0)"
        case .inconsistent(.dimensionsInconsistent):
            "inconsistent,dimensions"
        case .inconsistent(.invalidMeasurement):
            "inconsistent,invalid_measurement"
        }
    }
}

struct MultiAngleMeasurementConsensusPolicy: Equatable, Sendable {
    var maximumAxisDifferenceMeters = 0.0381
    var maximumRelativeAxisDifference = 0.15
    var maximumVolumeRatio = 1.20

    func measurementsAgree(
        _ first: MeasurementCaptureEvidence,
        _ second: MeasurementCaptureEvidence
    ) -> Bool {
        let firstDimensions = first.estimate.normalizedDimensions
        let secondDimensions = second.estimate.normalizedDimensions
        let axesAgree = zip(firstDimensions, secondDimensions)
            .allSatisfy(axisValuesAgree)
        guard axesAgree else { return false }

        let firstVolume = firstDimensions.reduce(1, *)
        let secondVolume = secondDimensions.reduce(1, *)
        let smallerVolume = min(firstVolume, secondVolume)
        guard smallerVolume > 0 else { return false }
        return max(firstVolume, secondVolume) / smallerVolume <= maximumVolumeRatio
    }

    func consensusEstimate(
        from captures: [MeasurementAngleCapture],
        totalAngleCount: Int? = nil
    ) -> MeasurementEstimate? {
        guard captures.count == 2 || captures.count == 3,
              captures.allSatisfy({ $0.evidence.estimate.hasValidDimensions }) else {
            return nil
        }

        let dimensionRows = captures.map(\.evidence.estimate.normalizedDimensions)
        let consensusDimensions = (0..<3).map { axis in
            dimensionRows.map { $0[axis] }.max() ?? 0
        }
        let pointCloudConfidence = captures
            .map(\.evidence.pointCloudConfidence)
            .min(by: { $0.rank < $1.rank }) ?? .low
        let reportedConfidence = MeasurementCompletenessPolicy().reportedConfidence(
            pointCloudConfidence: pointCloudConfidence,
            evidence: .independentViewpoints
        )
        let sampleCount = captures.reduce(into: 0) { total, capture in
            let (sum, overflow) = total.addingReportingOverflow(
                capture.evidence.estimate.sampleCount
            )
            total = overflow ? .max : sum
        }

        return MeasurementEstimate(
            lengthMeters: consensusDimensions[0],
            widthMeters: consensusDimensions[1],
            heightMeters: consensusDimensions[2],
            confidence: reportedConfidence,
            sampleCount: sampleCount,
            frameCount: captures.count,
            comparisonAngleCount: totalAngleCount ?? captures.count,
            comparisonAgreementCount: captures.count
        )
    }

    func isMateriallyLarger(
        _ candidate: MeasurementCaptureEvidence,
        than consensus: MeasurementEstimate
    ) -> Bool {
        let candidateDimensions = candidate.estimate.normalizedDimensions
        let consensusDimensions = consensus.normalizedDimensions
        if zip(candidateDimensions, consensusDimensions).contains(where: {
            candidateAxis, consensusAxis in
            candidateAxis > consensusAxis
                && !axisValuesAgree(candidateAxis, consensusAxis)
        }) {
            return true
        }

        let candidateVolume = candidateDimensions.reduce(1, *)
        let consensusVolume = consensusDimensions.reduce(1, *)
        return candidateVolume > consensusVolume * maximumVolumeRatio
    }

    private func axisValuesAgree(_ first: Double, _ second: Double) -> Bool {
        let maximum = max(first, second)
        guard maximum > 0 else { return false }
        let difference = abs(first - second)
        return difference <= maximumAxisDifferenceMeters
            && difference / maximum <= maximumRelativeAxisDifference
    }
}

/// A small value-only state machine owned by the scanner sheet. It never keeps
/// ARFrame, pixel buffers, sessions, or point clouds alive between photos.
struct MultiAngleMeasurementWorkflow: Equatable, Sendable {
    private(set) var captures: [MeasurementAngleCapture] = []
    private(set) var progress = MultiAngleMeasurementProgress.awaitingFirstAngle
    var viewpointPolicy = MeasurementViewpointPolicy()
    var consensusPolicy = MultiAngleMeasurementConsensusPolicy()

    @discardableResult
    mutating func record(_ capture: MeasurementAngleCapture) -> MultiAngleMeasurementProgress {
        guard capture.evidence.estimate.hasValidDimensions,
              capture.evidence.geometryCenter.allFinite,
              capture.viewpoint.hasValidEvidence else {
            progress = .inconsistent(.invalidMeasurement)
            return progress
        }
        guard case .accepted = progress else {
            if case .inconsistent = progress { return progress }
            return recordUnresolved(capture)
        }
        return progress
    }

    mutating func reset() {
        captures = []
        progress = .awaitingFirstAngle
    }

    private mutating func recordUnresolved(
        _ capture: MeasurementAngleCapture
    ) -> MultiAngleMeasurementProgress {
        for reference in captures {
            switch viewpointPolicy.validate(capture, against: reference) {
            case .distinct:
                continue
            case .tooSimilar:
                progress = .needsAnotherAngle(
                    reason: .viewpointTooSimilar,
                    acceptedCount: captures.count
                )
                return progress
            }
        }

        captures.append(capture)
        switch captures.count {
        case 1:
            progress = .needsAnotherAngle(reason: .firstAngleCaptured, acceptedCount: 1)
        case 2:
            if consensusPolicy.measurementsAgree(captures[0].evidence, captures[1].evidence),
               let estimate = consensusPolicy.consensusEstimate(from: captures) {
                progress = .accepted(estimate)
            } else {
                progress = .needsAnotherAngle(reason: .dimensionsDisagree, acceptedCount: 2)
            }
        case 3:
            let agreeingPairs: [(indices: [Int], captures: [MeasurementAngleCapture])] = [
                (indices: [0, 1], captures: [captures[0], captures[1]]),
                (indices: [0, 2], captures: [captures[0], captures[2]]),
                (indices: [1, 2], captures: [captures[1], captures[2]]),
            ].filter { pair in
                consensusPolicy.measurementsAgree(
                    pair.captures[0].evidence,
                    pair.captures[1].evidence
                )
            }

            guard !agreeingPairs.isEmpty else {
                progress = .inconsistent(.dimensionsInconsistent)
                return progress
            }

            if agreeingPairs.count == 3,
               let estimate = consensusPolicy.consensusEstimate(
                   from: captures,
                   totalAngleCount: 3
               ) {
                progress = .accepted(estimate)
                return progress
            }

            let selectedPair = agreeingPairs.max { first, second in
                upperEnvelopeVolume(first.captures) < upperEnvelopeVolume(second.captures)
            }!
            guard let estimate = consensusPolicy.consensusEstimate(
                from: selectedPair.captures,
                totalAngleCount: 3
            ) else {
                progress = .inconsistent(.invalidMeasurement)
                return progress
            }
            let selectedIndices = Set(selectedPair.indices)
            let hasLargerDiscordantCapture = captures.indices.contains { index in
                !selectedIndices.contains(index)
                    && consensusPolicy.isMateriallyLarger(
                        captures[index].evidence,
                        than: estimate
                    )
            }
            if hasLargerDiscordantCapture {
                progress = .inconsistent(.dimensionsInconsistent)
            } else {
                progress = .accepted(estimate)
            }
        default:
            progress = .inconsistent(.dimensionsInconsistent)
        }
        return progress
    }

    private func upperEnvelopeVolume(_ captures: [MeasurementAngleCapture]) -> Double {
        guard let estimate = consensusPolicy.consensusEstimate(from: captures) else {
            return 0
        }
        return estimate.lengthMeters * estimate.widthMeters * estimate.heightMeters
    }
}

/// Adapts the shared geometry result into the scanner-facing measurement model.
/// All bounding-box math lives in `GravityAlignedBoundingBoxEstimator`.
enum MeasurementEstimator {
    static func estimate(
        from worldPoints: [SIMD3<Float>],
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid,
        completenessEvidence: MeasurementCompletenessEvidence = .singleView
    ) -> MeasurementEstimate? {
        guard case .success(let estimate) = outcome(
            from: worldPoints,
            frameCount: frameCount,
            targetValidation: targetValidation,
            completenessEvidence: completenessEvidence
        ) else {
            return nil
        }
        return estimate
    }

    static func outcome(
        from worldPoints: [SIMD3<Float>],
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid,
        completenessEvidence: MeasurementCompletenessEvidence = .singleView
    ) -> MeasurementEstimationOutcome {
        switch captureEvidenceOutcome(
            from: worldPoints,
            frameCount: frameCount,
            targetValidation: targetValidation,
            completenessEvidence: completenessEvidence
        ) {
        case .success(let evidence):
            return .success(evidence.estimate)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func captureEvidenceOutcome(
        from worldPoints: [SIMD3<Float>],
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid,
        completenessEvidence: MeasurementCompletenessEvidence = .singleView
    ) -> MeasurementCaptureEvidenceOutcome {
        if case .rejected(let reason) = targetValidation {
            return .failure(.targetRejected(reason))
        }
        guard frameCount >= 1 else {
            return .failure(.insufficientFrames(actual: frameCount, minimum: 1))
        }

        let geometry: GravityAlignedBoundingBoxEstimate
        do {
            geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: worldPoints)
        } catch let error as BoundingBoxEstimationError {
            return .failure(.geometry(error))
        } catch {
            return .failure(.geometry(.degeneratePointCloud))
        }

        let pointCloudConfidence = scanConfidence(from: geometry.confidence.level)
        let reportedConfidence = MeasurementCompletenessPolicy().reportedConfidence(
            pointCloudConfidence: pointCloudConfidence,
            evidence: completenessEvidence
        )

        return .success(
            MeasurementCaptureEvidence(
                estimate: MeasurementEstimate(
                    lengthMeters: geometry.dimensions.lengthMeters,
                    widthMeters: geometry.dimensions.widthMeters,
                    heightMeters: geometry.dimensions.heightMeters,
                    confidence: reportedConfidence,
                    sampleCount: geometry.diagnostics.inlierPointCount,
                    frameCount: frameCount
                ),
                pointCloudConfidence: pointCloudConfidence,
                geometryCenter: geometry.center
            )
        )
    }

    /// Compatibility for model-level callers that already hold Double points.
    /// ARKit's native Float representation remains the production path.
    static func estimate(
        from worldPoints: [SIMD3<Double>],
        frameCount: Int,
        targetValidation: CenteredTargetValidation = .valid,
        completenessEvidence: MeasurementCompletenessEvidence = .singleView
    ) -> MeasurementEstimate? {
        estimate(
            from: worldPoints.map {
                SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
            },
            frameCount: frameCount,
            targetValidation: targetValidation,
            completenessEvidence: completenessEvidence
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

private extension MeasurementEstimate {
    var normalizedDimensions: [Double] {
        [sortedBaseEdges[0], sortedBaseEdges[1], heightMeters]
    }

    var longestDimensionMeters: Double {
        max(lengthMeters, widthMeters, heightMeters)
    }

    var hasValidDimensions: Bool {
        normalizedDimensions.allSatisfy { $0.isFinite && $0 > 0 }
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }

    var horizontalXZ: SIMD2<Float> {
        SIMD2<Float>(x, z)
    }
}

private extension SIMD2 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite
    }
}

private extension ScanConfidence {
    var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}
