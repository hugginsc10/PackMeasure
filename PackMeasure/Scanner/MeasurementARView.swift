@preconcurrency import ARKit
import Foundation
import OSLog
import RealityKit
import SwiftUI
import Vision
import simd

enum ScannerPreviewCommand: Equatable, Sendable {
    case none
    case pause
    case resume
}

struct ScannerPreviewLifecycle: Equatable, Sendable {
    private(set) var isFrozen = false

    mutating func measurementFinalized() -> ScannerPreviewCommand {
        guard !isFrozen else { return .none }
        isFrozen = true
        return .pause
    }

    mutating func scanRequested() -> ScannerPreviewCommand {
        guard isFrozen else { return .none }
        isFrozen = false
        return .resume
    }
}

enum ScannerViewRequestCommand: Equatable, Sendable {
    case resumePreview
    case startCapture
}

struct ScannerViewRequestTracker: Equatable, Sendable {
    private(set) var lastPreviewRequestID = 0
    private(set) var lastCaptureRequestID = 0

    mutating func commands(
        previewRequestID: Int,
        captureRequestID: Int
    ) -> [ScannerViewRequestCommand] {
        var commands: [ScannerViewRequestCommand] = []
        if previewRequestID != lastPreviewRequestID {
            lastPreviewRequestID = previewRequestID
            commands.append(.resumePreview)
        }
        if captureRequestID != lastCaptureRequestID {
            lastCaptureRequestID = captureRequestID
            commands.append(.startCapture)
        }
        return commands
    }
}

struct SettledFrameCapturePolicy: Equatable, Sendable {
    var settleInterval: TimeInterval = 0.25

    func shouldCapture(
        requestedAt: TimeInterval,
        frameArrivedAt: TimeInterval
    ) -> Bool {
        frameArrivedAt - requestedAt >= settleInterval
    }

    func progress(
        requestedAt: TimeInterval,
        frameArrivedAt: TimeInterval
    ) -> Double {
        guard settleInterval > 0 else { return 0.45 }
        let elapsed = max(0, frameArrivedAt - requestedAt)
        return min(0.45, 0.45 * elapsed / settleInterval)
    }
}

enum SettledFrameCaptureDecision: Equatable, Sendable {
    case wait(progress: Double)
    case capture
    case completed
}

struct SettledFrameCaptureGate: Equatable, Sendable {
    let requestedAt: TimeInterval
    var policy = SettledFrameCapturePolicy()
    private(set) var normalSince: TimeInterval?
    private(set) var didCapture = false

    mutating func trackingWasNotNormal() {
        normalSince = nil
    }

    mutating func frameArrived(at time: TimeInterval) -> SettledFrameCaptureDecision {
        guard !didCapture else { return .completed }
        let settledSince: TimeInterval
        if let normalSince {
            settledSince = normalSince
        } else {
            normalSince = time
            settledSince = time
        }
        guard policy.shouldCapture(requestedAt: settledSince, frameArrivedAt: time) else {
            return .wait(
                progress: policy.progress(
                    requestedAt: settledSince,
                    frameArrivedAt: time
                )
            )
        }
        didCapture = true
        return .capture
    }
}

struct ScannerSessionEventGate: Equatable, Sendable {
    private(set) var lastAppliedSequence = 0

    mutating func shouldApply(sequence: Int) -> Bool {
        guard sequence > lastAppliedSequence else { return false }
        lastAppliedSequence = sequence
        return true
    }
}

struct MeasurementARView: UIViewRepresentable {
    @Bindable var scannerState: ScannerSheetView.ScannerStateModel

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.scannerState = scannerState
        return coordinator
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.cameraMode = .ar
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.scannerState = scannerState
        context.coordinator.handleRequests(
            previewRequestID: scannerState.previewRequestID,
            captureRequestID: scannerState.captureRequestID
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// `ARSessionDelegate` invokes this object on `processingQueue`. The unchecked
    /// conformance is constrained by keeping AR/capture mutations on that serial
    /// queue and isolating all view-model/ARView access to `MainActor`.
    final class Coordinator: NSObject, ARSessionDelegate, @unchecked Sendable {
        private struct CaptureAccumulator {
            let requestID: Int
            let measurementSeriesID: Int
            var settledFrameGate: SettledFrameCaptureGate
            var cameraViewpoint: MeasurementCameraViewpoint?
            var geometryCenter: SIMD3<Float>?
            var pointCloudConfidence: ScanConfidence?
            var worldPoints: [SIMD3<Float>] = []
            var frameCount = 0
            var sampleAttemptCount = 0
            var unavailableFrameCount = 0
            var rejectedFrameCount = 0
            var floorRejectedFrameCount = 0
            var lastRejection: CenteredTargetRejection?
            var lastCalibration: FrameCalibrationDiagnostics?
            var lastPhotoFailure: SingleShotCaptureFailure?
            var capturePath = SingleShotCapturePath.visionMask
            var fallbackTrigger: SingleShotCaptureFailure?
            var fallbackResult = SingleShotFallbackResult.notAttempted
        }

        private struct FrameCalibrationDiagnostics: Sendable {
            let rawRegionPixelCount: Int
            let retainedRegionPixelCount: Int
            let regionCoverage: Float
            let absoluteUpNormal: Float?
            let elevationAboveFloorMeters: Float?
            let floorEstimate: SceneFloorEstimate?
        }

        private enum DepthFrameSample {
            case accepted([SIMD3<Float>], FrameCalibrationDiagnostics)
            case rejected(CenteredTargetRejection, FrameCalibrationDiagnostics?)
            case unavailable(FrameCalibrationDiagnostics?)
        }

        private enum SingleShotFrameSample {
            case accepted(
                [SIMD3<Float>],
                FrameCalibrationDiagnostics,
                SingleShotCaptureRoute
            )
            case failed(
                SingleShotCaptureFailure,
                FrameCalibrationDiagnostics?,
                SingleShotCaptureRoute
            )
        }

        private struct SingleShotCaptureRoute: Sendable {
            let path: SingleShotCapturePath
            let fallbackTrigger: SingleShotCaptureFailure?
            let fallbackResult: SingleShotFallbackResult

            static let visionMask = SingleShotCaptureRoute(
                path: .visionMask,
                fallbackTrigger: nil,
                fallbackResult: .notAttempted
            )
        }

        private static let calibrationLogger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "org.example.PackMeasure",
            category: "calibration"
        )

        private static func failureMessage(for failure: MeasurementEstimationFailure) -> String {
            switch failure {
            case .targetRejected(.floorSurface):
                "The photo appears to target the floor. Keep one whole object centered and retake it."
            case .targetRejected(.insufficientSurfaceEvidence), .insufficientFrames:
                "The photo did not contain enough object depth. Keep one whole object in frame and retake it."
            case .geometry(.groundPlaneContamination):
                "Too much floor or background entered the photo. Keep the whole object centered with space around its edges."
            case .geometry:
                "The object could not be measured reliably from this photo. Try a clearer three-quarter angle."
            }
        }

        private static let settledFramePolicy = SettledFrameCapturePolicy()
        private static let maximumTrackingWait: TimeInterval = 2
        private static let maximumPointsPerFrame = 3_500
        private static let maximumAccumulatedPoints = 42_000
        private static let minimumRegionPixelCount = 36
        private static let maximumRegionCoverage = 0.94
        private static let peripheralSampleTarget = 1_200
        private static let edgeMarginPixels = 2
        private static let minimumTargetElevationForFloorFiltering: Float = 0.08

        private let processingQueue = DispatchQueue(
            label: "PackMeasure.scan.queue",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        )
        private let segmenter = DepthRegionSegmenter(
            minimumConfidence: UInt8(ARConfidenceLevel.medium.rawValue)
        )
        private let targetValidator = CenteredTargetValidator()
        private let targetCapturePolicy = CenteredTargetCapturePolicy()
        private let peripheralFloorEstimator = PeripheralFloorEstimator()
        private let objectRegionFilter = ReticleSeededObjectRegionFilter()

        // Accessed only on processingQueue.
        private var capture: CaptureAccumulator?
        private var sessionEventSequence = 0

        @MainActor private weak var arView: ARView?
        @MainActor private var depthSupported = false
        @MainActor private var previewLifecycle = ScannerPreviewLifecycle()
        @MainActor private var sessionConfiguration: ARWorldTrackingConfiguration?
        @MainActor private var sessionEventGate = ScannerSessionEventGate()
        @MainActor private var requestTracker = ScannerViewRequestTracker()
        @MainActor weak var scannerState: ScannerSheetView.ScannerStateModel?

        @MainActor
        func attach(to view: ARView) {
            arView = view
            view.automaticallyConfigureSession = false
            view.session.delegate = self
            view.session.delegateQueue = processingQueue
            configureSession()
        }

        @MainActor
        func stop() {
            arView?.session.pause()
            processingQueue.async { [weak self] in
                self?.capture = nil
            }
        }

        @MainActor
        func handleRequests(previewRequestID: Int, captureRequestID: Int) {
            let commands = requestTracker.commands(
                previewRequestID: previewRequestID,
                captureRequestID: captureRequestID
            )
            for command in commands {
                switch command {
                case .resumePreview:
                    resumePreviewForAiming()
                case .startCapture:
                    startCapture()
                }
            }
        }

        @MainActor
        private func resumePreviewForAiming() {
            guard depthSupported, let sessionConfiguration else {
                scannerState?.phase = .unsupported(
                    "LiDAR scene depth is not available on this device."
                )
                return
            }

            if previewLifecycle.scanRequested() == .resume {
                arView?.session.run(sessionConfiguration)
            }
            scannerState?.phase = .ready
        }

        @MainActor
        func startCapture() {
            guard depthSupported else {
                scannerState?.phase = .unsupported(
                    "LiDAR scene depth is not available on this device."
                )
                return
            }

            if previewLifecycle.scanRequested() == .resume,
               let sessionConfiguration {
                arView?.session.run(sessionConfiguration)
            }

            let requestID = requestTracker.lastCaptureRequestID
            let measurementSeriesID = scannerState?.measurementSeriesID ?? 0
            let now = CACurrentMediaTime()
            scannerState?.estimate = nil
            scannerState?.phase = .scanning(progress: 0)

            processingQueue.async { [weak self] in
                self?.capture = CaptureAccumulator(
                    requestID: requestID,
                    measurementSeriesID: measurementSeriesID,
                    settledFrameGate: SettledFrameCaptureGate(
                        requestedAt: now,
                        policy: Self.settledFramePolicy
                    )
                )
            }
        }

        @MainActor
        private func configureSession() {
            guard ARWorldTrackingConfiguration.isSupported else {
                scannerState?.phase = .unsupported("World tracking is unavailable.")
                return
            }

            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection.insert(.horizontal)

            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
                depthSupported = true
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
                depthSupported = true
            }

            sessionConfiguration = configuration
            scannerState?.resetMeasurementSeries()
            arView?.session.run(configuration)
            scannerState?.phase = depthSupported
                ? .ready
                : .unsupported("This app needs a LiDAR-capable iPhone or iPad.")
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // ARKit calls this method on processingQueue; never move ARFrame or
            // its pixel buffers across another concurrency boundary.
            guard var activeCapture = capture else { return }
            guard case .normal = frame.camera.trackingState else {
                activeCapture.settledFrameGate.trackingWasNotNormal()
                if CACurrentMediaTime() - activeCapture.settledFrameGate.requestedAt
                    >= Self.maximumTrackingWait {
                    capture = nil
                    publishFailure(
                        "Camera tracking wasn't ready. Hold steady and try the photo again.",
                        requestID: activeCapture.requestID,
                        measurementSeriesID: activeCapture.measurementSeriesID
                    )
                    return
                }
                capture = activeCapture
                publishProgress(0.1, requestID: activeCapture.requestID)
                return
            }
            let frameArrivedAt = CACurrentMediaTime()
            switch activeCapture.settledFrameGate.frameArrived(at: frameArrivedAt) {
            case .wait(let progress):
                capture = activeCapture
                publishProgress(progress, requestID: activeCapture.requestID)
                return
            case .capture:
                capture = nil
            case .completed:
                capture = nil
                return
            }
            activeCapture.sampleAttemptCount += 1
            activeCapture.cameraViewpoint = MeasurementCameraViewpoint(
                cameraTransform: frame.camera.transform
            )
            publishProgress(0.5, requestID: activeCapture.requestID)
            // Freeze the exact RGB/depth pair being measured before Vision runs.
            session.pause()

            switch sampleSingleShotFrame(from: frame) {
            case .accepted(let points, let diagnostics, let route):
                activeCapture.worldPoints = points
                activeCapture.frameCount = 1
                activeCapture.lastCalibration = diagnostics
                apply(route, to: &activeCapture)
                finalizeCapture(activeCapture)
            case .failed(let photoFailure, let diagnostics, let route):
                activeCapture.lastPhotoFailure = photoFailure
                activeCapture.lastCalibration = diagnostics
                apply(route, to: &activeCapture)
                let disposition: SingleShotFailureDisposition = switch route.fallbackResult {
                case .targetRejected:
                    .targetRejected
                case .unavailable:
                    .unavailable
                case .notAttempted, .accepted:
                    photoFailure.disposition
                }
                switch disposition {
                case .targetRejected:
                    let rejection: CenteredTargetRejection = if case .targetRejected(
                        let reason
                    ) = route.fallbackResult {
                        reason
                    } else {
                        .insufficientSurfaceEvidence
                    }
                    activeCapture.rejectedFrameCount = 1
                    activeCapture.lastRejection = rejection
                    if rejection == .floorSurface {
                        activeCapture.floorRejectedFrameCount = 1
                    }
                    let failure = MeasurementEstimationFailure.targetRejected(rejection)
                    logCalibrationSummary(activeCapture, result: .failure(failure))
                case .unavailable:
                    activeCapture.unavailableFrameCount = 1
                    logCalibrationSummary(activeCapture, result: nil)
                }
                publishFailure(
                    ScannerPhotoFailureCopy.message(
                        for: photoFailure,
                        fallbackResult: route.fallbackResult
                    ),
                    requestID: activeCapture.requestID,
                    measurementSeriesID: activeCapture.measurementSeriesID
                )
            }
        }

        private func apply(
            _ route: SingleShotCaptureRoute,
            to capture: inout CaptureAccumulator
        ) {
            capture.capturePath = route.path
            capture.fallbackTrigger = route.fallbackTrigger
            capture.fallbackResult = route.fallbackResult
        }

        func session(_ session: ARSession, didFailWithError error: any Error) {
            let requestID = capture?.requestID
            capture = nil
            sessionEventSequence += 1

            let message: String
            if let arError = error as? ARError,
               arError.code == .cameraUnauthorized {
                message = "Camera access is off. Allow PackMeasure in Settings, then reopen the scanner."
            } else {
                message = "The camera session stopped: \(error.localizedDescription) Close and reopen the scanner."
            }
            publishFailure(
                message,
                requestID: requestID,
                sessionEventSequence: sessionEventSequence,
                resetMeasurementSeries: true
            )
        }

        func sessionWasInterrupted(_ session: ARSession) {
            let requestID = capture?.requestID
            capture = nil
            sessionEventSequence += 1
            publishFailure(
                "The camera was interrupted. Wait for it to return, then scan the item again.",
                requestID: requestID,
                sessionEventSequence: sessionEventSequence,
                resetMeasurementSeries: true
            )
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            capture = nil
            sessionEventSequence += 1
            publishReadyAfterInterruption(sessionEventSequence: sessionEventSequence)
        }

        private func finalizeCapture(_ initialCapture: CaptureAccumulator) {
            var capture = initialCapture
            let targetValidation = targetCapturePolicy.finalValidation(
                acceptedObjectFrameCount: capture.frameCount,
                floorRejectedFrameCount: capture.floorRejectedFrameCount
            )
            let outcome = MeasurementEstimator.captureEvidenceOutcome(
                from: capture.worldPoints,
                frameCount: capture.frameCount,
                targetValidation: targetValidation
            )

            guard case .success(let evidence) = outcome else {
                let failure: MeasurementEstimationFailure
                if case .failure(let capturedFailure) = outcome {
                    failure = capturedFailure
                } else {
                    failure = .geometry(.degeneratePointCloud)
                }
                logCalibrationSummary(capture, result: .failure(failure))
                publishFailure(
                    Self.failureMessage(for: failure),
                    requestID: capture.requestID,
                    measurementSeriesID: capture.measurementSeriesID
                )
                return
            }
            capture.geometryCenter = evidence.geometryCenter
            capture.pointCloudConfidence = evidence.pointCloudConfidence

            guard let cameraViewpoint = capture.cameraViewpoint else {
                logCalibrationSummary(
                    capture,
                    result: .success(evidence.estimate)
                )
                publishFailure(
                    "PackMeasure couldn't verify the camera angle. Try a lower three-quarter view.",
                    requestID: capture.requestID,
                    measurementSeriesID: capture.measurementSeriesID
                )
                return
            }

            let angleCapture = MeasurementAngleCapture(
                evidence: evidence,
                viewpoint: cameraViewpoint
            )

            logCalibrationSummary(capture, result: .success(evidence.estimate))
            publishMeasurementCapture(
                angleCapture,
                requestID: capture.requestID,
                measurementSeriesID: capture.measurementSeriesID
            )
        }

        private func sampleDepthFrame(
            from frame: ARFrame,
            grid: DepthGrid,
            maximumCount: Int
        ) -> DepthFrameSample {
            guard maximumCount > 0,
                  let rawRegion = segmenter.segment(grid) else {
                return .unavailable(nil)
            }

            let rawCoverage = Float(rawRegion.pixelCount) / Float(grid.depths.count)
            let touchesEdge = rawRegion.bounds.minX <= Self.edgeMarginPixels
                || rawRegion.bounds.minY <= Self.edgeMarginPixels
                || rawRegion.bounds.maxX >= grid.width - 1 - Self.edgeMarginPixels
                || rawRegion.bounds.maxY >= grid.height - 1 - Self.edgeMarginPixels

            let imageResolution = frame.camera.imageResolution
            let scaleX = imageResolution.width / CGFloat(grid.width)
            let scaleY = imageResolution.height / CGFloat(grid.height)
            guard scaleX > 0, scaleY > 0 else {
                return .unavailable(
                    FrameCalibrationDiagnostics(
                        rawRegionPixelCount: rawRegion.pixelCount,
                        retainedRegionPixelCount: rawRegion.pixelCount,
                        regionCoverage: rawCoverage,
                        absoluteUpNormal: nil,
                        elevationAboveFloorMeters: nil,
                        floorEstimate: nil
                    )
                )
            }

            var intrinsics = frame.camera.intrinsics
            intrinsics[0][0] /= Float(scaleX)
            intrinsics[1][1] /= Float(scaleY)
            intrinsics[2][0] /= Float(scaleX)
            intrinsics[2][1] /= Float(scaleY)
            guard intrinsics[0][0] > 0, intrinsics[1][1] > 0 else {
                return .unavailable(
                    FrameCalibrationDiagnostics(
                        rawRegionPixelCount: rawRegion.pixelCount,
                        retainedRegionPixelCount: rawRegion.pixelCount,
                        regionCoverage: rawCoverage,
                        absoluteUpNormal: nil,
                        elevationAboveFloorMeters: nil,
                        floorEstimate: nil
                    )
                )
            }

            let cameraTransform = frame.camera.transform
            let floorEstimate = sceneFloorEstimate(
                from: frame,
                region: rawRegion,
                grid: grid,
                intrinsics: intrinsics,
                cameraTransform: cameraTransform
            )
            let context = CenteredTargetContext(
                floorEstimate: floorEstimate,
                regionCoverage: rawCoverage,
                regionTouchesImageEdge: touchesEdge
            )
            guard let targetSample = centeredTargetSurfaceSample(
                region: rawRegion,
                grid: grid,
                intrinsics: intrinsics,
                cameraTransform: cameraTransform
            ) else {
                return .rejected(
                    .insufficientSurfaceEvidence,
                    FrameCalibrationDiagnostics(
                        rawRegionPixelCount: rawRegion.pixelCount,
                        retainedRegionPixelCount: rawRegion.pixelCount,
                        regionCoverage: rawCoverage,
                        absoluteUpNormal: nil,
                        elevationAboveFloorMeters: nil,
                        floorEstimate: floorEstimate
                    )
                )
            }
            let assessment = targetValidator.assess(targetSample, context: context)
            guard assessment.validation == .valid else {
                let diagnostics = FrameCalibrationDiagnostics(
                    rawRegionPixelCount: rawRegion.pixelCount,
                    retainedRegionPixelCount: rawRegion.pixelCount,
                    regionCoverage: rawCoverage,
                    absoluteUpNormal: assessment.absoluteUpNormal,
                    elevationAboveFloorMeters: assessment.elevationAboveFloorMeters,
                    floorEstimate: floorEstimate
                )
                if case .rejected(let reason) = assessment.validation {
                    return .rejected(reason, diagnostics)
                }
                return .unavailable(diagnostics)
            }

            let usableFloorEstimate: SceneFloorEstimate? = if let elevation = assessment
                .elevationAboveFloorMeters,
                elevation > Self.minimumTargetElevationForFloorFiltering {
                floorEstimate
            } else {
                nil
            }
            guard let region = objectRegionFilter.filter(
                region: rawRegion,
                gridWidth: grid.width,
                gridHeight: grid.height,
                floorEstimate: usableFloorEstimate,
                worldPointAt: { index in
                    worldPoint(
                        at: index,
                        grid: grid,
                        intrinsics: intrinsics,
                        cameraTransform: cameraTransform
                    )
                }
            ) else {
                return .rejected(
                    .insufficientSurfaceEvidence,
                    FrameCalibrationDiagnostics(
                        rawRegionPixelCount: rawRegion.pixelCount,
                        retainedRegionPixelCount: 0,
                        regionCoverage: 0,
                        absoluteUpNormal: assessment.absoluteUpNormal,
                        elevationAboveFloorMeters: assessment.elevationAboveFloorMeters,
                        floorEstimate: floorEstimate
                    )
                )
            }

            let coverage = Float(region.pixelCount) / Float(grid.depths.count)
            let diagnostics = FrameCalibrationDiagnostics(
                rawRegionPixelCount: rawRegion.pixelCount,
                retainedRegionPixelCount: region.pixelCount,
                regionCoverage: coverage,
                absoluteUpNormal: assessment.absoluteUpNormal,
                elevationAboveFloorMeters: assessment.elevationAboveFloorMeters,
                floorEstimate: floorEstimate
            )
            guard region.pixelCount >= Self.minimumRegionPixelCount else {
                return .rejected(.insufficientSurfaceEvidence, diagnostics)
            }

            guard Double(coverage) <= Self.maximumRegionCoverage else {
                // A nearly full-frame vertical region is usually a wall rather
                // than a centered object with visible separation around it.
                return .rejected(.insufficientSurfaceEvidence, diagnostics)
            }

            let samplingStride = max(
                1,
                Int(ceil(sqrt(Double(region.pixelCount) / Double(maximumCount))))
            )
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(min(maximumCount, region.pixelCount))

            // Only the center-connected object component that remains after
            // removing the observed floor band reaches geometry accumulation.
            for index in region.indices {
                let x = index % grid.width
                let y = index / grid.width
                guard x.isMultiple(of: samplingStride),
                      y.isMultiple(of: samplingStride) else {
                    continue
                }

                guard let point = worldPoint(
                    at: index,
                    grid: grid,
                    intrinsics: intrinsics,
                    cameraTransform: cameraTransform
                ) else {
                    continue
                }

                points.append(point)
                if points.count == maximumCount { break }
            }

            return points.isEmpty
                ? .unavailable(diagnostics)
                : .accepted(points, diagnostics)
        }

        private func sampleSingleShotFrame(from frame: ARFrame) -> SingleShotFrameSample {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
                return .failed(.sceneDepthUnavailable, nil, .visionMask)
            }
            guard let grid = depthGrid(from: depthData) else {
                return .failed(.depthGridUnreadable, nil, .visionMask)
            }

            let labelMask: PhotoInstanceLabelMask
            do {
                labelMask = try foregroundInstanceLabelMask(from: frame.capturedImage)
            } catch let error as ForegroundMaskAdapterError {
                return frameSample(
                    after: .foreground(error),
                    from: frame,
                    grid: grid
                )
            } catch {
                let error = error as NSError
                return .failed(
                    .unexpectedProcessingFailure(domain: error.domain, code: error.code),
                    nil,
                    .visionMask
                )
            }

            let imageResolution = frame.camera.imageResolution
            let calibration = PhotoCameraCalibration(
                imageWidth: Int(imageResolution.width),
                imageHeight: Int(imageResolution.height),
                intrinsics: frame.camera.intrinsics,
                cameraTransform: frame.camera.transform
            )
            do {
                var policy = PhotoObjectMeasurementPolicy()
                policy.protectedEdgeMarginPixels = max(
                    1,
                    min(labelMask.width, labelMask.height) / 50
                )
                let pointCloud = try PhotoObjectMeasurement(policy: policy).makePointCloud(
                    labelMask: labelMask,
                    depthGrid: grid,
                    calibration: calibration
                )
                let diagnostics = FrameCalibrationDiagnostics(
                    rawRegionPixelCount: pointCloud.maskQuality.selectedPixelCount,
                    retainedRegionPixelCount: pointCloud.depthSupport.supportedSampleCount,
                    regionCoverage: pointCloud.depthSupport.coverage,
                    absoluteUpNormal: nil,
                    elevationAboveFloorMeters: nil,
                    floorEstimate: nil
                )
                return .accepted(pointCloud.worldPoints, diagnostics, .visionMask)
            } catch let error as PhotoObjectMeasurementError {
                return frameSample(
                    after: .photo(error),
                    from: frame,
                    grid: grid
                )
            } catch {
                let error = error as NSError
                return .failed(
                    .unexpectedProcessingFailure(domain: error.domain, code: error.code),
                    nil,
                    .visionMask
                )
            }
        }

        private func frameSample(
            after failure: SingleShotCaptureFailure,
            from frame: ARFrame,
            grid: DepthGrid
        ) -> SingleShotFrameSample {
            guard failure.shouldAttemptReticleDepthFallback else {
                return .failed(failure, nil, .visionMask)
            }

            switch sampleDepthFrame(
                from: frame,
                grid: grid,
                maximumCount: Self.maximumAccumulatedPoints
            ) {
            case .accepted(let points, let diagnostics):
                return .accepted(
                    points,
                    diagnostics,
                    SingleShotCaptureRoute(
                        path: .reticleDepthFallback,
                        fallbackTrigger: failure,
                        fallbackResult: .accepted
                    )
                )
            case .rejected(let reason, let diagnostics):
                return .failed(
                    failure,
                    diagnostics,
                    SingleShotCaptureRoute(
                        path: .reticleDepthFallback,
                        fallbackTrigger: failure,
                        fallbackResult: .targetRejected(reason)
                    )
                )
            case .unavailable(let diagnostics):
                return .failed(
                    failure,
                    diagnostics,
                    SingleShotCaptureRoute(
                        path: .reticleDepthFallback,
                        fallbackTrigger: failure,
                        fallbackResult: .unavailable
                    )
                )
            }
        }

        private func scaledIntrinsics(
            for camera: ARCamera,
            depthGrid: DepthGrid
        ) -> simd_float3x3? {
            let imageResolution = camera.imageResolution
            let scaleX = imageResolution.width / CGFloat(depthGrid.width)
            let scaleY = imageResolution.height / CGFloat(depthGrid.height)
            guard scaleX > 0, scaleY > 0 else { return nil }

            var intrinsics = camera.intrinsics
            intrinsics[0][0] /= Float(scaleX)
            intrinsics[1][1] /= Float(scaleY)
            intrinsics[2][0] /= Float(scaleX)
            intrinsics[2][1] /= Float(scaleY)
            guard intrinsics[0][0] > 0, intrinsics[1][1] > 0 else { return nil }
            return intrinsics
        }

        private func foregroundInstanceLabelMask(
            from pixelBuffer: CVPixelBuffer
        ) throws -> PhotoInstanceLabelMask {
            try autoreleasepool {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let requestHandler = VNImageRequestHandler(
                    cvPixelBuffer: pixelBuffer,
                    options: [:]
                )

                do {
                    try requestHandler.perform([request])
                } catch {
                    let error = error as NSError
                    throw ForegroundMaskAdapterError.requestFailed(
                        domain: error.domain,
                        code: error.code
                    )
                }

                guard let observation = request.results?.first else {
                    throw ForegroundMaskAdapterError.noObservation
                }

                let lowResolutionMask: PhotoInstanceLabelMask
                do {
                    lowResolutionMask = try PhotoInstanceLabelMask(
                        pixelBuffer: observation.instanceMask
                    )
                } catch let error as PhotoObjectMeasurementError {
                    throw ForegroundMaskAdapterError.photo(
                        stage: .lowResolutionDecode,
                        error: error
                    )
                } catch {
                    let error = error as NSError
                    throw ForegroundMaskAdapterError.maskProcessingFailed(
                        stage: "low_resolution_decode",
                        domain: error.domain,
                        code: error.code
                    )
                }

                let selected: PhotoSelectedInstanceMask
                do {
                    selected = try PhotoForegroundInstanceSelector().select(
                        in: lowResolutionMask
                    )
                } catch let error as PhotoObjectMeasurementError {
                    throw ForegroundMaskAdapterError.photo(
                        stage: .instanceSelection,
                        error: error
                    )
                } catch {
                    let error = error as NSError
                    throw ForegroundMaskAdapterError.maskProcessingFailed(
                        stage: "instance_selection",
                        domain: error.domain,
                        code: error.code
                    )
                }

                let scaledMask: CVPixelBuffer
                do {
                    // Keep the request and scaled-mask generation in the same
                    // Vision API family. Bridging this legacy observation into
                    // the new `InstanceMaskObservation` API can yield an empty
                    // full-resolution mask even when the low-resolution mask
                    // contains the selected foreground label.
                    scaledMask = try observation.generateScaledMaskForImage(
                        forInstances: IndexSet(integer: Int(selected.label)),
                        from: requestHandler
                    )
                } catch {
                    let error = error as NSError
                    throw ForegroundMaskAdapterError.scaledMaskFailed(
                        domain: error.domain,
                        code: error.code
                    )
                }

                do {
                    return try PhotoInstanceLabelMask(pixelBuffer: scaledMask)
                } catch let error as PhotoObjectMeasurementError {
                    throw ForegroundMaskAdapterError.photo(
                        stage: .scaledMaskDecode,
                        error: error
                    )
                } catch {
                    let error = error as NSError
                    throw ForegroundMaskAdapterError.maskProcessingFailed(
                        stage: "scaled_mask_decode",
                        domain: error.domain,
                        code: error.code
                    )
                }
            }
        }

        private func sceneFloorEstimate(
            from frame: ARFrame,
            region: DepthRegion,
            grid: DepthGrid,
            intrinsics: simd_float3x3,
            cameraTransform: simd_float4x4
        ) -> SceneFloorEstimate? {
            let classifiedFloorHeights = frame.anchors.compactMap { anchor -> Float? in
                guard let plane = anchor as? ARPlaneAnchor,
                      plane.alignment == .horizontal,
                      plane.classification == .floor else {
                    return nil
                }
                let y = plane.transform.columns.3.y
                return y.isFinite ? y : nil
            }
            if let y = median(classifiedFloorHeights) {
                return SceneFloorEstimate(y: y, source: .classifiedPlane)
            }

            let regionTouchesEdge = region.bounds.minX <= Self.edgeMarginPixels
                || region.bounds.minY <= Self.edgeMarginPixels
                || region.bounds.maxX >= grid.width - 1 - Self.edgeMarginPixels
                || region.bounds.maxY >= grid.height - 1 - Self.edgeMarginPixels
            let regionCoverage = Float(region.pixelCount) / Float(grid.depths.count)
            // A leaked region often owns the peripheral floor pixels itself.
            // Include those pixels in fallback floor estimation only when the
            // raw region is already broad or reaches the frame boundary.
            let centerRegion: Set<Int> = if regionTouchesEdge || regionCoverage >= 0.55 {
                []
            } else {
                Set(region.indices)
            }
            let peripheralPoints = peripheralWorldPoints(
                grid: grid,
                excluding: centerRegion,
                intrinsics: intrinsics,
                cameraTransform: cameraTransform
            )
            return peripheralFloorEstimator.estimate(from: peripheralPoints)
        }

        private func peripheralWorldPoints(
            grid: DepthGrid,
            excluding centerRegion: Set<Int>,
            intrinsics: simd_float3x3,
            cameraTransform: simd_float4x4
        ) -> [SIMD3<Float>] {
            let borderWidth = max(2, grid.width / 5)
            let borderHeight = max(2, grid.height / 5)
            let peripheralPixelEstimate = max(
                1,
                grid.width * grid.height
                    - max(0, grid.width - 2 * borderWidth)
                        * max(0, grid.height - 2 * borderHeight)
            )
            let sampleStride = max(
                1,
                Int(
                    ceil(
                        sqrt(
                            Double(peripheralPixelEstimate)
                                / Double(Self.peripheralSampleTarget)
                        )
                    )
                )
            )
            let minimumConfidence = UInt8(ARConfidenceLevel.medium.rawValue)
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(Self.peripheralSampleTarget)

            for y in stride(from: 0, to: grid.height, by: sampleStride) {
                for x in stride(from: 0, to: grid.width, by: sampleStride) {
                    let isPeripheral = x < borderWidth
                        || x >= grid.width - borderWidth
                        || y < borderHeight
                        || y >= grid.height - borderHeight
                    guard isPeripheral else { continue }

                    let index = y * grid.width + x
                    let depth = grid.depths[index]
                    guard !centerRegion.contains(index),
                          depth.isFinite,
                          depth >= 0.15,
                          depth <= 6,
                          grid.confidences[index] >= minimumConfidence,
                          let point = worldPoint(
                              at: index,
                              grid: grid,
                              intrinsics: intrinsics,
                              cameraTransform: cameraTransform
                          ) else {
                        continue
                    }
                    points.append(point)
                    if points.count == Self.peripheralSampleTarget { return points }
                }
            }

            return points
        }

        private func median(_ values: [Float]) -> Float? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let middle = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[middle - 1] + sorted[middle]) / 2
            }
            return sorted[middle]
        }

        private func centeredTargetSurfaceSample(
            region: DepthRegion,
            grid: DepthGrid,
            intrinsics: simd_float3x3,
            cameraTransform: simd_float4x4
        ) -> CenteredTargetSurfaceSample? {
            let centerX = grid.width / 2
            let centerY = grid.height / 2
            guard let seedIndex = region.indices.min(by: { lhs, rhs in
                let lhsX = lhs % grid.width
                let lhsY = lhs / grid.width
                let rhsX = rhs % grid.width
                let rhsY = rhs / grid.width
                let lhsDistance = (lhsX - centerX) * (lhsX - centerX)
                    + (lhsY - centerY) * (lhsY - centerY)
                let rhsDistance = (rhsX - centerX) * (rhsX - centerX)
                    + (rhsY - centerY) * (rhsY - centerY)
                return lhsDistance < rhsDistance
            }) else {
                return nil
            }

            let seedX = seedIndex % grid.width
            let seedY = seedIndex / grid.width
            let accepted = Set(region.indices)

            // Prefer a wider local baseline for a stable normal, then fall
            // back toward the seed if the object face is small.
            for radius in [3, 2, 4, 1, 5] {
                let leftX = seedX - radius
                let rightX = seedX + radius
                let upY = seedY - radius
                let downY = seedY + radius
                guard leftX >= 0, rightX < grid.width,
                      upY >= 0, downY < grid.height else {
                    continue
                }

                let leftIndex = seedY * grid.width + leftX
                let rightIndex = seedY * grid.width + rightX
                let upIndex = upY * grid.width + seedX
                let downIndex = downY * grid.width + seedX
                guard accepted.contains(leftIndex),
                      accepted.contains(rightIndex),
                      accepted.contains(upIndex),
                      accepted.contains(downIndex),
                      let center = worldPoint(
                          at: seedIndex,
                          grid: grid,
                          intrinsics: intrinsics,
                          cameraTransform: cameraTransform
                      ),
                      let left = worldPoint(
                          at: leftIndex,
                          grid: grid,
                          intrinsics: intrinsics,
                          cameraTransform: cameraTransform
                      ),
                      let right = worldPoint(
                          at: rightIndex,
                          grid: grid,
                          intrinsics: intrinsics,
                          cameraTransform: cameraTransform
                      ),
                      let up = worldPoint(
                          at: upIndex,
                          grid: grid,
                          intrinsics: intrinsics,
                          cameraTransform: cameraTransform
                      ),
                      let down = worldPoint(
                          at: downIndex,
                          grid: grid,
                          intrinsics: intrinsics,
                          cameraTransform: cameraTransform
                      ) else {
                    continue
                }

                return CenteredTargetSurfaceSample(
                    center: center,
                    left: left,
                    right: right,
                    up: up,
                    down: down
                )
            }

            return nil
        }

        private func worldPoint(
            at index: Int,
            grid: DepthGrid,
            intrinsics: simd_float3x3,
            cameraTransform: simd_float4x4
        ) -> SIMD3<Float>? {
            let x = index % grid.width
            let y = index / grid.width
            let localPoint = unproject(
                pixel: SIMD2<Float>(Float(x), Float(y)),
                depth: grid.depths[index],
                intrinsics: intrinsics
            )
            let world = cameraTransform * SIMD4<Float>(
                localPoint.x,
                localPoint.y,
                localPoint.z,
                1
            )
            let point = SIMD3<Float>(world.x, world.y, world.z)
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                return nil
            }
            return point
        }

        /// Copies row-strided Core Video storage while the buffers are locked,
        /// leaving a Sendable value grid for connected-depth segmentation.
        private func depthGrid(from depthData: ARDepthData) -> DepthGrid? {
            let depthMap = depthData.depthMap
            let width = CVPixelBufferGetWidth(depthMap)
            let height = CVPixelBufferGetHeight(depthMap)
            guard width > 0, height > 0,
                  CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else {
                return nil
            }
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

            guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
                return nil
            }

            let confidenceMap = depthData.confidenceMap
            let confidenceDimensionsMatch = confidenceMap.map {
                CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height
            } ?? false
            let confidenceLocked: Bool
            if let confidenceMap, confidenceDimensionsMatch {
                confidenceLocked = CVPixelBufferLockBaseAddress(
                    confidenceMap,
                    .readOnly
                ) == kCVReturnSuccess
            } else {
                confidenceLocked = false
            }
            defer {
                if let confidenceMap, confidenceLocked {
                    CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
                }
            }

            let depthPointer = depthBaseAddress.assumingMemoryBound(to: Float32.self)
            let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap)
                / MemoryLayout<Float32>.stride
            let pixelCount = width * height
            var depths = Array(repeating: Float.nan, count: pixelCount)

            for y in 0..<height {
                let sourceRow = depthPointer.advanced(by: y * depthRowStride)
                let destinationOffset = y * width
                for x in 0..<width {
                    depths[destinationOffset + x] = sourceRow[x]
                }
            }

            let fallbackConfidence = UInt8(ARConfidenceLevel.medium.rawValue)
            var confidences = Array(repeating: fallbackConfidence, count: pixelCount)
            if let confidenceMap, confidenceLocked,
               let confidenceBaseAddress = CVPixelBufferGetBaseAddress(confidenceMap) {
                let confidencePointer = confidenceBaseAddress.assumingMemoryBound(to: UInt8.self)
                let confidenceRowStride = CVPixelBufferGetBytesPerRow(confidenceMap)
                    / MemoryLayout<UInt8>.stride

                for y in 0..<height {
                    let sourceRow = confidencePointer.advanced(by: y * confidenceRowStride)
                    let destinationOffset = y * width
                    for x in 0..<width {
                        confidences[destinationOffset + x] = sourceRow[x]
                    }
                }
            }

            return DepthGrid(
                width: width,
                height: height,
                depths: depths,
                confidences: confidences
            )
        }

        private func unproject(
            pixel: SIMD2<Float>,
            depth: Float,
            intrinsics: simd_float3x3
        ) -> SIMD3<Float> {
            let x = (pixel.x - intrinsics[2][0]) * depth / intrinsics[0][0]
            let y = (pixel.y - intrinsics[2][1]) * depth / intrinsics[1][1]
            return SIMD3<Float>(x, -y, -depth)
        }

        private func logCalibrationSummary(
            _ capture: CaptureAccumulator,
            result: MeasurementEstimationOutcome?
        ) {
            let resultDescription: String
            let failureDescription: String
            let geometryErrorDescription: String
            let successfulEstimate: MeasurementEstimate?
            switch result {
            case .some(.success(let estimate)):
                resultDescription = "success"
                failureDescription = "none"
                geometryErrorDescription = "none"
                successfulEstimate = estimate
            case .some(.failure(let failure)):
                resultDescription = "failure"
                failureDescription = String(describing: failure)
                successfulEstimate = nil
                if case .geometry(let error) = failure {
                    geometryErrorDescription = String(describing: error)
                } else {
                    geometryErrorDescription = "none"
                }
            case .none:
                resultDescription = "unavailable"
                failureDescription = "none"
                geometryErrorDescription = "none"
                successfulEstimate = nil
            }

            let diagnostics = capture.lastCalibration
            let rawRegionPixels = diagnostics
                .map { String($0.rawRegionPixelCount) } ?? "none"
            let retainedRegionPixels = diagnostics
                .map { String($0.retainedRegionPixelCount) } ?? "none"
            let coverage = diagnosticString(diagnostics?.regionCoverage)
            let seedUpNormal = diagnosticString(diagnostics?.absoluteUpNormal)
            let elevation = diagnosticString(diagnostics?.elevationAboveFloorMeters)
            let floorY = diagnosticString(diagnostics?.floorEstimate?.y)
            let floorSource = diagnostics?.floorEstimate?.source.rawValue ?? "none"
            let finalTargetReason: CenteredTargetRejection? = if let result,
                case .failure(.targetRejected(let reason)) = result {
                reason
            } else {
                nil
            }
            let finalTargetReasonDescription = finalTargetReason
                .map(String.init(describing:)) ?? "none"
            let lastRejectionDescription = capture.lastRejection
                .map(String.init(describing:)) ?? "none"
            let photoFailureCode = capture.lastPhotoFailure?.diagnosticCode ?? "none"
            let photoFailureDetail = capture.lastPhotoFailure?.diagnosticDescription ?? "none"
            let fallbackTriggerCode = capture.fallbackTrigger?.diagnosticCode ?? "none"
            let fallbackTriggerDetail = capture.fallbackTrigger?.diagnosticDescription ?? "none"
            let capturePath = capture.capturePath.rawValue
            let fallbackResult = capture.fallbackResult.diagnosticDescription
            let lengthMeters = diagnosticString(successfulEstimate?.lengthMeters)
            let widthMeters = diagnosticString(successfulEstimate?.widthMeters)
            let heightMeters = diagnosticString(successfulEstimate?.heightMeters)
            let pointCloudConfidence = capture.pointCloudConfidence?.rawValue ?? "none"
            let cameraX = diagnosticString(capture.cameraViewpoint?.position.x)
            let cameraY = diagnosticString(capture.cameraViewpoint?.position.y)
            let cameraZ = diagnosticString(capture.cameraViewpoint?.position.z)
            let cameraForwardX = diagnosticString(
                capture.cameraViewpoint?.horizontalForward.x
            )
            let cameraForwardZ = diagnosticString(
                capture.cameraViewpoint?.horizontalForward.y
            )
            let centerX = diagnosticString(capture.geometryCenter?.x)
            let centerY = diagnosticString(capture.geometryCenter?.y)
            let centerZ = diagnosticString(capture.geometryCenter?.z)

            Self.calibrationLogger.notice(
                "scan_calibration request_id=\(capture.requestID, privacy: .public) measurement_series_id=\(capture.measurementSeriesID, privacy: .public) result=\(resultDescription, privacy: .public) attempts=\(capture.sampleAttemptCount, privacy: .public) accepted_frames=\(capture.frameCount, privacy: .public) rejected_frames=\(capture.rejectedFrameCount, privacy: .public) floor_rejected_frames=\(capture.floorRejectedFrameCount, privacy: .public) unavailable_frames=\(capture.unavailableFrameCount, privacy: .public) points=\(capture.worldPoints.count, privacy: .public) length_m=\(lengthMeters, privacy: .public) width_m=\(widthMeters, privacy: .public) height_m=\(heightMeters, privacy: .public) point_cloud_confidence=\(pointCloudConfidence, privacy: .public) camera_x=\(cameraX, privacy: .public) camera_y=\(cameraY, privacy: .public) camera_z=\(cameraZ, privacy: .public) camera_forward_x=\(cameraForwardX, privacy: .public) camera_forward_z=\(cameraForwardZ, privacy: .public) target_center_x=\(centerX, privacy: .public) target_center_y=\(centerY, privacy: .public) target_center_z=\(centerZ, privacy: .public) raw_region_pixels=\(rawRegionPixels, privacy: .public) retained_region_pixels=\(retainedRegionPixels, privacy: .public) coverage=\(coverage, privacy: .public) seed_abs_up_normal=\(seedUpNormal, privacy: .public) elevation_m=\(elevation, privacy: .public) background_floor_y_m=\(floorY, privacy: .public) floor_source=\(floorSource, privacy: .public) target_reason=\(finalTargetReasonDescription, privacy: .public) last_frame_rejection=\(lastRejectionDescription, privacy: .public) capture_path=\(capturePath, privacy: .public) fallback_trigger_code=\(fallbackTriggerCode, privacy: .public) fallback_trigger_detail=\(fallbackTriggerDetail, privacy: .public) fallback_result=\(fallbackResult, privacy: .public) photo_failure_code=\(photoFailureCode, privacy: .public) photo_failure_detail=\(photoFailureDetail, privacy: .public) estimation_failure=\(failureDescription, privacy: .public) geometry_error=\(geometryErrorDescription, privacy: .public)"
            )
        }

        private func diagnosticString(_ value: Float?) -> String {
            guard let value, value.isFinite else { return "none" }
            return String(format: "%.6f", value)
        }

        private func diagnosticString(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "none" }
            return String(format: "%.6f", value)
        }

        private func publishProgress(_ progress: Double, requestID: Int) {
            Task { @MainActor [weak self] in
                guard let state = self?.scannerState,
                      state.captureRequestID == requestID,
                      case .scanning = state.phase else {
                    return
                }
                state.phase = .scanning(progress: progress)
            }
        }

        private func publishFailure(
            _ message: String,
            requestID: Int?,
            measurementSeriesID: Int? = nil,
            sessionEventSequence: Int? = nil,
            resetMeasurementSeries: Bool = false
        ) {
            Task { @MainActor [weak self] in
                guard let self, let state = scannerState else {
                    return
                }
                if let sessionEventSequence,
                   !sessionEventGate.shouldApply(sequence: sessionEventSequence) {
                    return
                }
                if let requestID, state.captureRequestID != requestID { return }
                if let measurementSeriesID,
                   state.measurementSeriesID != measurementSeriesID {
                    return
                }
                if previewLifecycle.measurementFinalized() == .pause {
                    arView?.session.pause()
                }
                if resetMeasurementSeries {
                    state.resetMeasurementSeries()
                }
                state.estimate = nil
                state.phase = .failed(message)
            }
        }

        private func publishReadyAfterInterruption(sessionEventSequence: Int) {
            Task { @MainActor [weak self] in
                guard let self,
                      sessionEventGate.shouldApply(sequence: sessionEventSequence),
                      depthSupported,
                      let state = scannerState,
                      let sessionConfiguration else {
                    return
                }
                _ = previewLifecycle.scanRequested()
                arView?.session.run(sessionConfiguration)
                state.resetMeasurementSeries()
                state.estimate = nil
                state.phase = .ready
            }
        }

        private func publishMeasurementCapture(
            _ capture: MeasurementAngleCapture,
            requestID: Int,
            measurementSeriesID: Int
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      let state = scannerState,
                      state.captureRequestID == requestID,
                      state.measurementSeriesID == measurementSeriesID else {
                    return
                }
                if previewLifecycle.measurementFinalized() == .pause {
                    // The delegate already pauses on the settled frame. Repeating
                    // here is an idempotent fallback if ARKit races a final frame.
                    arView?.session.pause()
                }
                let progress = state.receiveMeasurement(capture)
                Self.calibrationLogger.notice(
                    "multi_angle measurement_series_id=\(measurementSeriesID, privacy: .public) request_id=\(requestID, privacy: .public) decision=\(progress.diagnosticDescription, privacy: .public)"
                )
            }
        }

    }
}
