import Foundation

enum ScannerMeasurementMode: Equatable, Sendable {
    case automaticPhotos
    case guidedCorners
}

enum MeasurementEvidenceSource: String, Equatable, Sendable {
    case automaticPhoto
    case guidedLidarCorners
}

/// Keeps delayed automatic-photo callbacks from entering a guided result (and
/// vice versa). The adapters may share an AR session, but they never share
/// measurement evidence.
struct MeasurementEvidenceSeparationPolicy: Equatable, Sendable {
    func accepts(
        _ source: MeasurementEvidenceSource,
        for mode: ScannerMeasurementMode
    ) -> Bool {
        switch (mode, source) {
        case (.automaticPhotos, .automaticPhoto),
             (.guidedCorners, .guidedLidarCorners):
            true
        case (.automaticPhotos, .guidedLidarCorners),
             (.guidedCorners, .automaticPhoto):
            false
        }
    }
}

struct GuidedBoxCaptureContext: Equatable, Sendable {
    let measurementSeriesID: Int
    let targetID: UUID
}

/// Quaternion components use ARKit/simd's `(x, y, z, w)` order.
struct GuidedBoxCapturePose: Equatable, Sendable {
    let position: SIMD3<Float>
    let orientation: SIMD4<Float>
}

struct GuidedBoxCaptureRequest: Equatable, Sendable {
    let requestID: Int
    let context: GuidedBoxCaptureContext
    let point: GuidedBoxPoint
    let requestedPose: GuidedBoxCapturePose
}

struct GuidedBoxPointProvenance: Equatable, Sendable {
    var requestID: Int
    var context: GuidedBoxCaptureContext
    var point: GuidedBoxPoint
    var source: MeasurementEvidenceSource
}

struct GuidedBoxPointSample: Equatable, Sendable {
    let provenance: GuidedBoxPointProvenance
    let worldPosition: SIMD3<Float>
    let gravity: SIMD3<Float>
    let capturedPose: GuidedBoxCapturePose
}

struct GuidedBoxOverlayMarker: Equatable, Sendable {
    let number: Int
    let point: GuidedBoxPoint
    let worldPosition: SIMD3<Float>
}

struct GuidedBoxOverlayLine: Equatable, Sendable {
    let reference: GuidedBoxPoint
    let endpoint: GuidedBoxPoint
    let referenceWorldPosition: SIMD3<Float>
    let endpointWorldPosition: SIMD3<Float>
}

struct GuidedBoxOverlay: Equatable, Sendable {
    let markers: [GuidedBoxOverlayMarker]
    let lines: [GuidedBoxOverlayLine]

    static let empty = GuidedBoxOverlay(markers: [], lines: [])

    var isEmpty: Bool {
        markers.isEmpty && lines.isEmpty
    }
}

struct GuidedBoxMeasurementResult: Equatable, Sendable {
    let source: MeasurementEvidenceSource
    let context: GuidedBoxCaptureContext
    let measurement: GuidedBoxMeasurement
    let estimate: MeasurementEstimate
    let provenance: [GuidedBoxPointProvenance]
}

enum GuidedBoxLifecycleBoundary: CaseIterable, Equatable, Sendable {
    case restart
    case exit
    case interruption
    case teardown
    case sessionReset
}

enum GuidedBoxCaptureRejection: Equatable, Sendable {
    case inactive
    case noPendingRequest
    case requestMismatch(expected: Int, actual: Int)
    case contextMismatch(
        expected: GuidedBoxCaptureContext,
        actual: GuidedBoxCaptureContext
    )
    case pointMismatch(expected: GuidedBoxPoint, actual: GuidedBoxPoint)
    case wrongEvidenceSource(
        expected: MeasurementEvidenceSource,
        actual: MeasurementEvidenceSource
    )
    case invalidCapturePose
    case cameraMoved(
        translationMeters: Float,
        maximumTranslationMeters: Float,
        rotationDegrees: Float,
        maximumRotationDegrees: Float
    )
}

enum GuidedBoxCaptureSessionUpdate: Equatable, Sendable {
    /// The callback did not belong to the pending guided request. It must not
    /// mutate or terminate a newer request.
    case ignored(GuidedBoxCaptureRejection)
    /// The callback matched and consumed the pending request, but failed a
    /// safety gate. The coordinator can stop its spinner and offer a retry.
    case rejected(GuidedBoxCaptureRejection)
    case workflow(GuidedBoxWorkflowUpdate)
}

struct GuidedBoxFrameStabilityPolicy: Equatable, Sendable {
    var maximumTranslationMeters: Float = 0.03
    var maximumRotationDegrees: Float = 4

    func rejection(
        from requestedPose: GuidedBoxCapturePose,
        to capturedPose: GuidedBoxCapturePose
    ) -> GuidedBoxCaptureRejection? {
        guard maximumTranslationMeters.isFinite,
              maximumTranslationMeters >= 0,
              maximumRotationDegrees.isFinite,
              maximumRotationDegrees >= 0,
              requestedPose.hasFiniteComponents,
              capturedPose.hasFiniteComponents,
              let requestedOrientation = normalized(requestedPose.orientation),
              let capturedOrientation = normalized(capturedPose.orientation) else {
            return .invalidCapturePose
        }

        let delta = capturedPose.position - requestedPose.position
        let translation = magnitude(delta)
        let quaternionDot = min(
            1,
            abs(dot(requestedOrientation, capturedOrientation))
        )
        let rotationDegrees = 2 * acos(quaternionDot) * 180 / .pi

        guard translation > maximumTranslationMeters
                || rotationDegrees > maximumRotationDegrees else {
            return nil
        }
        return .cameraMoved(
            translationMeters: translation,
            maximumTranslationMeters: maximumTranslationMeters,
            rotationDegrees: rotationDegrees,
            maximumRotationDegrees: maximumRotationDegrees
        )
    }

    private func normalized(_ quaternion: SIMD4<Float>) -> SIMD4<Float>? {
        let length = magnitude(quaternion)
        guard length.isFinite, length > 0.000_001 else { return nil }
        return quaternion / length
    }

    private func magnitude(_ value: SIMD3<Float>) -> Float {
        sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
    }

    private func magnitude(_ value: SIMD4<Float>) -> Float {
        sqrt(
            value.x * value.x
                + value.y * value.y
                + value.z * value.z
                + value.w * value.w
        )
    }

    private func dot(_ first: SIMD4<Float>, _ second: SIMD4<Float>) -> Float {
        first.x * second.x
            + first.y * second.y
            + first.z * second.z
            + first.w * second.w
    }
}

/// Pure ownership boundary for the LiDAR four-point flow. UI and AR adapters
/// issue requests and return exact-frame world samples; this type validates
/// provenance and motion, owns marker/line state, and produces a guided-only
/// result for the existing save flow.
struct GuidedBoxCaptureSession: Sendable {
    private let evidencePolicy: MeasurementEvidenceSeparationPolicy
    private let stabilityPolicy: GuidedBoxFrameStabilityPolicy

    private var workflow = GuidedBoxWorkflow()
    private var issuedRequestIDs: Set<Int> = []

    private(set) var context: GuidedBoxCaptureContext?
    private(set) var pendingRequest: GuidedBoxCaptureRequest?
    private(set) var samples: [GuidedBoxPointSample] = []
    private(set) var measurementResult: GuidedBoxMeasurementResult?

    init(
        context: GuidedBoxCaptureContext,
        evidencePolicy: MeasurementEvidenceSeparationPolicy = .init(),
        stabilityPolicy: GuidedBoxFrameStabilityPolicy = .init()
    ) {
        self.context = context
        self.evidencePolicy = evidencePolicy
        self.stabilityPolicy = stabilityPolicy
    }

    var isActive: Bool {
        context != nil
    }

    var step: GuidedBoxWorkflowStep {
        workflow.step
    }

    var overlay: GuidedBoxOverlay {
        let orderedSamples = GuidedBoxPoint.captureOrder.compactMap(sample(for:))
        let markers = orderedSamples.map { sample in
            GuidedBoxOverlayMarker(
                number: sample.provenance.point.markerNumber,
                point: sample.provenance.point,
                worldPosition: sample.worldPosition
            )
        }

        guard let reference = sample(for: .referenceCorner) else {
            return GuidedBoxOverlay(markers: markers, lines: [])
        }
        let lines = GuidedBoxPoint.captureOrder.dropFirst().compactMap { endpoint in
            sample(for: endpoint).map { sample in
                GuidedBoxOverlayLine(
                    reference: .referenceCorner,
                    endpoint: endpoint,
                    referenceWorldPosition: reference.worldPosition,
                    endpointWorldPosition: sample.worldPosition
                )
            }
        }
        return GuidedBoxOverlay(markers: markers, lines: lines)
    }

    mutating func start(context: GuidedBoxCaptureContext) {
        resetState()
        self.context = context
    }

    mutating func beginRequest(
        requestID: Int,
        requestedPose: GuidedBoxCapturePose
    ) -> GuidedBoxCaptureRequest? {
        guard let context,
              pendingRequest == nil,
              !issuedRequestIDs.contains(requestID),
              let point = workflow.step.point else {
            return nil
        }
        let request = GuidedBoxCaptureRequest(
            requestID: requestID,
            context: context,
            point: point,
            requestedPose: requestedPose
        )
        issuedRequestIDs.insert(requestID)
        pendingRequest = request
        return request
    }

    @discardableResult
    mutating func consume(
        _ sample: GuidedBoxPointSample
    ) -> GuidedBoxCaptureSessionUpdate {
        guard let context else {
            return .ignored(.inactive)
        }
        guard let request = pendingRequest else {
            return .ignored(.noPendingRequest)
        }
        guard sample.provenance.requestID == request.requestID else {
            return .ignored(
                .requestMismatch(
                    expected: request.requestID,
                    actual: sample.provenance.requestID
                )
            )
        }

        // From this point onward the exact pending request has been consumed,
        // even if its returned evidence is rejected.
        pendingRequest = nil

        guard sample.provenance.context == context else {
            return .rejected(
                .contextMismatch(expected: context, actual: sample.provenance.context)
            )
        }
        guard sample.provenance.point == request.point else {
            return .rejected(
                .pointMismatch(expected: request.point, actual: sample.provenance.point)
            )
        }
        guard evidencePolicy.accepts(sample.provenance.source, for: .guidedCorners) else {
            return .rejected(
                .wrongEvidenceSource(
                    expected: .guidedLidarCorners,
                    actual: sample.provenance.source
                )
            )
        }
        if let rejection = stabilityPolicy.rejection(
            from: request.requestedPose,
            to: sample.capturedPose
        ) {
            return .rejected(rejection)
        }

        let update = workflow.record(
            point: sample.worldPosition,
            gravity: sample.gravity
        )
        apply(sample, for: update)
        measurementResult = nil
        return .workflow(update)
    }

    mutating func back() {
        pendingRequest = nil
        measurementResult = nil
        workflow.back()
        guard let point = workflow.step.point else { return }
        removeSamples(startingAt: point)
    }

    @discardableResult
    mutating func confirm() -> GuidedBoxMeasurementResult? {
        if let measurementResult {
            return measurementResult
        }
        guard let context,
              let measurement = workflow.measurement,
              let estimate = workflow.confirm() else {
            return nil
        }
        let orderedSamples = GuidedBoxPoint.captureOrder.compactMap(sample(for:))
        guard orderedSamples.count == GuidedBoxPoint.captureOrder.count,
              orderedSamples.allSatisfy({
                  evidencePolicy.accepts($0.provenance.source, for: .guidedCorners)
              }) else {
            return nil
        }
        let result = GuidedBoxMeasurementResult(
            source: .guidedLidarCorners,
            context: context,
            measurement: measurement,
            estimate: estimate,
            provenance: orderedSamples.map(\.provenance)
        )
        measurementResult = result
        return result
    }

    mutating func clear(for boundary: GuidedBoxLifecycleBoundary) {
        _ = boundary
        resetState()
        context = nil
    }

    private mutating func resetState() {
        pendingRequest = nil
        samples.removeAll(keepingCapacity: false)
        measurementResult = nil
        issuedRequestIDs.removeAll(keepingCapacity: false)
        workflow.reset()
    }

    private mutating func apply(
        _ sample: GuidedBoxPointSample,
        for update: GuidedBoxWorkflowUpdate
    ) {
        switch update {
        case .advanced, .ready:
            upsert(sample)
        case let .needsReplacement(point, _):
            upsert(sample)
            removeSample(for: point)
        case .failed, .ignored:
            break
        }
    }

    private mutating func upsert(_ sample: GuidedBoxPointSample) {
        removeSample(for: sample.provenance.point)
        samples.append(sample)
    }

    private mutating func removeSample(for point: GuidedBoxPoint) {
        samples.removeAll { $0.provenance.point == point }
    }

    private mutating func removeSamples(startingAt point: GuidedBoxPoint) {
        guard let index = GuidedBoxPoint.captureOrder.firstIndex(of: point) else {
            return
        }
        let removedPoints = GuidedBoxPoint.captureOrder[index...]
        samples.removeAll { removedPoints.contains($0.provenance.point) }
    }

    private func sample(for point: GuidedBoxPoint) -> GuidedBoxPointSample? {
        samples.first { $0.provenance.point == point }
    }
}

extension GuidedBoxPoint {
    static let captureOrder: [GuidedBoxPoint] = [
        .referenceCorner,
        .lengthEndpoint,
        .widthEndpoint,
        .heightEndpoint,
    ]

    var markerNumber: Int {
        switch self {
        case .referenceCorner: 1
        case .lengthEndpoint: 2
        case .widthEndpoint: 3
        case .heightEndpoint: 4
        }
    }
}

private extension GuidedBoxCapturePose {
    var hasFiniteComponents: Bool {
        position.x.isFinite
            && position.y.isFinite
            && position.z.isFinite
            && orientation.x.isFinite
            && orientation.y.isFinite
            && orientation.z.isFinite
            && orientation.w.isFinite
    }
}
