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
            let startedAt: TimeInterval
            let deadline: TimeInterval
            var nextSampleAt: TimeInterval
            var worldPoints: [SIMD3<Float>] = []
            var frameCount = 0
            var sampleAttemptCount = 0
            var unavailableFrameCount = 0
            var rejectedFrameCount = 0
            var floorRejectedFrameCount = 0
            var lastRejection: CenteredTargetRejection?
            var lastCalibration: FrameCalibrationDiagnostics?
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

        private static let calibrationLogger = Logger(
            subsystem: "org.example.PackMeasure",
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

        private static let captureDuration: TimeInterval = 1.0
        private static let sampleInterval: TimeInterval = 1.0 / 12.0
        private static let maximumPointsPerFrame = 3_500
        private static let maximumAccumulatedPoints = 42_000
        private static let minimumRegionPixelCount = 36
        private static let maximumRegionCoverage = 0.94
        private static let peripheralSampleTarget = 1_200
        private static let edgeMarginPixels = 2
        private static let minimumTargetElevationForFloorFiltering: Float = 0.08

        private let processingQueue = DispatchQueue(
            label: "PackMeasure.scan.queue",
            qos: .userInitiated
        )
        private let segmenter = DepthRegionSegmenter(
            minimumConfidence: UInt8(ARConfidenceLevel.medium.rawValue)
        )
        private let maskedProjector = MaskedDepthPointProjector(
            minimumConfidence: UInt8(ARConfidenceLevel.medium.rawValue),
            minimumMaskValue: 0.5
        )
        private let targetValidator = CenteredTargetValidator()
        private let targetCapturePolicy = CenteredTargetCapturePolicy()
        private let peripheralFloorEstimator = PeripheralFloorEstimator()
        private let objectRegionFilter = ReticleSeededObjectRegionFilter()

        // Accessed only on processingQueue.
        private var capture: CaptureAccumulator?

        @MainActor private weak var arView: ARView?
        @MainActor private var depthSupported = false
        @MainActor private var previewLifecycle = ScannerPreviewLifecycle()
        @MainActor private var sessionConfiguration: ARWorldTrackingConfiguration?
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
            let now = CACurrentMediaTime()
            scannerState?.estimate = nil
            scannerState?.phase = .scanning(progress: 0)

            processingQueue.async { [weak self] in
                self?.capture = CaptureAccumulator(
                    requestID: requestID,
                    startedAt: now,
                    deadline: now + Self.captureDuration,
                    nextSampleAt: now
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
            arView?.session.run(configuration)
            scannerState?.phase = depthSupported
                ? .ready
                : .unsupported("This app needs a LiDAR-capable iPhone or iPad.")
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // ARKit calls this method on processingQueue; never move ARFrame or
            // its pixel buffers across another concurrency boundary.
            guard var activeCapture = capture else { return }
            capture = nil
            activeCapture.sampleAttemptCount += 1
            publishProgress(0.5, requestID: activeCapture.requestID)

            switch sampleSingleShotFrame(from: frame) {
            case .accepted(let points, let diagnostics):
                activeCapture.worldPoints = points
                activeCapture.frameCount = 1
                activeCapture.lastCalibration = diagnostics
                session.pause()
                finalizeCapture(activeCapture)
            case .rejected(let reason, let diagnostics):
                activeCapture.rejectedFrameCount = 1
                activeCapture.lastRejection = reason
                activeCapture.lastCalibration = diagnostics
                if reason == .floorSurface {
                    activeCapture.floorRejectedFrameCount = 1
                }
                session.pause()
                let failure = MeasurementEstimationFailure.targetRejected(reason)
                logCalibrationSummary(activeCapture, result: .failure(failure))
                resumePreviewAfterFailedCapture(requestID: activeCapture.requestID)
                publishFailure(
                    Self.failureMessage(for: failure),
                    requestID: activeCapture.requestID
                )
            case .unavailable(let diagnostics):
                activeCapture.unavailableFrameCount = 1
                activeCapture.lastCalibration = diagnostics
                session.pause()
                let failure = MeasurementEstimationFailure.targetRejected(
                    .insufficientSurfaceEvidence
                )
                logCalibrationSummary(activeCapture, result: .failure(failure))
                resumePreviewAfterFailedCapture(requestID: activeCapture.requestID)
                publishFailure(
                    Self.failureMessage(for: failure),
                    requestID: activeCapture.requestID
                )
            }
        }

        func session(_ session: ARSession, didFailWithError error: any Error) {
            let requestID = capture?.requestID
            capture = nil

            let message: String
            if let arError = error as? ARError,
               arError.code == .cameraUnauthorized {
                message = "Camera access is off. Allow PackMeasure in Settings, then reopen the scanner."
            } else {
                message = "The camera session stopped: \(error.localizedDescription) Close and reopen the scanner."
            }
            publishFailure(message, requestID: requestID)
        }

        func sessionWasInterrupted(_ session: ARSession) {
            let requestID = capture?.requestID
            capture = nil
            publishFailure(
                "The camera was interrupted. Wait for it to return, then scan the item again.",
                requestID: requestID
            )
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            capture = nil
            publishReadyAfterInterruption()
        }

        private func finalizeCapture(_ capture: CaptureAccumulator) {
            let targetValidation = targetCapturePolicy.finalValidation(
                acceptedObjectFrameCount: capture.frameCount,
                floorRejectedFrameCount: capture.floorRejectedFrameCount
            )
            let outcome = MeasurementEstimator.outcome(
                from: capture.worldPoints,
                frameCount: capture.frameCount,
                targetValidation: targetValidation
            )

            guard case .success(let estimate) = outcome else {
                let failure: MeasurementEstimationFailure
                if case .failure(let capturedFailure) = outcome {
                    failure = capturedFailure
                } else {
                    failure = .geometry(.degeneratePointCloud)
                }
                logCalibrationSummary(capture, result: .failure(failure))
                resumePreviewAfterFailedCapture(requestID: capture.requestID)
                publishFailure(
                    Self.failureMessage(for: failure),
                    requestID: capture.requestID
                )
                return
            }

            logCalibrationSummary(capture, result: .success(estimate))
            publishEstimate(estimate, requestID: capture.requestID)
        }

        private func sampleDepthFrame(
            from frame: ARFrame,
            maximumCount: Int
        ) -> DepthFrameSample {
            guard maximumCount > 0,
                  let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
                  let grid = depthGrid(from: depthData),
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

        private func sampleSingleShotFrame(from frame: ARFrame) -> DepthFrameSample {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
                  let grid = depthGrid(from: depthData),
                  let intrinsics = scaledIntrinsics(for: frame.camera, depthGrid: grid),
                  let mask = centerObjectMask(
                      from: frame.capturedImage,
                      cameraIntrinsics: frame.camera.intrinsics
                  ),
                  let projection = maskedProjector.project(
                      mask: mask,
                      depthGrid: grid,
                      imageResolution: frame.camera.imageResolution,
                      intrinsics: intrinsics,
                      cameraTransform: frame.camera.transform,
                      maximumCount: Self.maximumAccumulatedPoints
                  ) else {
                return .unavailable(nil)
            }

            let diagnostics = FrameCalibrationDiagnostics(
                rawRegionPixelCount: projection.selectedDepthSampleCount,
                retainedRegionPixelCount: projection.selectedDepthSampleCount,
                regionCoverage: projection.coverage,
                absoluteUpNormal: nil,
                elevationAboveFloorMeters: nil,
                floorEstimate: nil
            )

            if case .rejected(let reason) = SingleShotObjectMeasurement.validation(for: projection) {
                return .rejected(reason, diagnostics)
            }

            return .accepted(projection.points, diagnostics)
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

        private func centerObjectMask(
            from pixelBuffer: CVPixelBuffer,
            cameraIntrinsics: simd_float3x3
        ) -> ImageMask? {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let requestHandler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                options: [:]
            )

            do {
                try requestHandler.perform([request])
                guard let observation = request.results?.first,
                      let instanceObservation = InstanceMaskObservation(observation) else {
                    return nil
                }
                let centerInstances = instanceObservation.instanceAtPoint(
                    NormalizedPoint(x: 0.5, y: 0.5)
                )
                guard !centerInstances.isEmpty else { return nil }
                let imageRequestHandler = ImageRequestHandler(pixelBuffer)
                let scaledMask = try instanceObservation.generateScaledMask(
                    for: centerInstances,
                    scaledToImageFrom: imageRequestHandler
                )
                return try ImageMask(pixelBuffer: scaledMask)
            } catch {
                return nil
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
            result: MeasurementEstimationOutcome
        ) {
            let resultDescription: String
            let failureDescription: String
            let geometryErrorDescription: String
            switch result {
            case .success:
                resultDescription = "success"
                failureDescription = "none"
                geometryErrorDescription = "none"
            case .failure(let failure):
                resultDescription = "failure"
                failureDescription = String(describing: failure)
                if case .geometry(let error) = failure {
                    geometryErrorDescription = String(describing: error)
                } else {
                    geometryErrorDescription = "none"
                }
            }

            let diagnostics = capture.lastCalibration
            let rawRegionPixels = diagnostics?.rawRegionPixelCount ?? 0
            let retainedRegionPixels = diagnostics?.retainedRegionPixelCount ?? 0
            let coverage = diagnosticString(diagnostics?.regionCoverage)
            let seedUpNormal = diagnosticString(diagnostics?.absoluteUpNormal)
            let elevation = diagnosticString(diagnostics?.elevationAboveFloorMeters)
            let floorY = diagnosticString(diagnostics?.floorEstimate?.y)
            let floorSource = diagnostics?.floorEstimate?.source.rawValue ?? "none"
            let finalTargetReason: CenteredTargetRejection? = if case .failure(
                .targetRejected(let reason)
            ) = result {
                reason
            } else {
                nil
            }
            let finalTargetReasonDescription = finalTargetReason
                .map(String.init(describing:)) ?? "none"
            let lastRejectionDescription = capture.lastRejection
                .map(String.init(describing:)) ?? "none"

            Self.calibrationLogger.notice(
                "scan_calibration request_id=\(capture.requestID, privacy: .public) result=\(resultDescription, privacy: .public) attempts=\(capture.sampleAttemptCount, privacy: .public) accepted_frames=\(capture.frameCount, privacy: .public) rejected_frames=\(capture.rejectedFrameCount, privacy: .public) floor_rejected_frames=\(capture.floorRejectedFrameCount, privacy: .public) unavailable_frames=\(capture.unavailableFrameCount, privacy: .public) points=\(capture.worldPoints.count, privacy: .public) raw_region_pixels=\(rawRegionPixels, privacy: .public) retained_region_pixels=\(retainedRegionPixels, privacy: .public) coverage=\(coverage, privacy: .public) seed_abs_up_normal=\(seedUpNormal, privacy: .public) elevation_m=\(elevation, privacy: .public) background_floor_y_m=\(floorY, privacy: .public) floor_source=\(floorSource, privacy: .public) target_reason=\(finalTargetReasonDescription, privacy: .public) last_frame_rejection=\(lastRejectionDescription, privacy: .public) estimation_failure=\(failureDescription, privacy: .public) geometry_error=\(geometryErrorDescription, privacy: .public)"
            )
        }

        private func diagnosticString(_ value: Float?) -> String {
            guard let value, value.isFinite else { return "none" }
            return String(format: "%.3f", value)
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

        private func publishFailure(_ message: String, requestID: Int?) {
            Task { @MainActor [weak self] in
                guard let state = self?.scannerState else {
                    return
                }
                if let requestID, state.captureRequestID != requestID { return }
                state.estimate = nil
                state.phase = .failed(message)
            }
        }

        private func publishReadyAfterInterruption() {
            Task { @MainActor [weak self] in
                guard let self, depthSupported, let state = scannerState else {
                    return
                }
                state.estimate = nil
                state.phase = .ready
            }
        }

        private func publishEstimate(_ estimate: MeasurementEstimate, requestID: Int) {
            Task { @MainActor [weak self] in
                guard let self,
                      let state = scannerState,
                      state.captureRequestID == requestID else {
                    return
                }
                if previewLifecycle.measurementFinalized() == .pause {
                    // The delegate already pauses at the deadline. Repeating
                    // here is an idempotent fallback if ARKit races a final frame.
                    arView?.session.pause()
                }
                state.estimate = estimate
                state.phase = .measured
            }
        }

        private func resumePreviewAfterFailedCapture(requestID: Int) {
            Task { @MainActor [weak self] in
                guard let self,
                      scannerState?.captureRequestID == requestID,
                      let sessionConfiguration else {
                    return
                }
                arView?.session.run(sessionConfiguration)
            }
        }
    }
}
