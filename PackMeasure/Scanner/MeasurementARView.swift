@preconcurrency import ARKit
import RealityKit
import SwiftUI
import simd

struct MeasurementARView: UIViewRepresentable {
    @Bindable var scannerState: ScannerSheetView.ScannerStateModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        view.cameraMode = .ar
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.scannerState = scannerState

        if context.coordinator.lastCaptureRequestID != scannerState.captureRequestID {
            context.coordinator.lastCaptureRequestID = scannerState.captureRequestID
            context.coordinator.startCapture()
        }
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
        }

        private static let captureDuration: TimeInterval = 1.0
        private static let sampleInterval: TimeInterval = 1.0 / 12.0
        private static let maximumPointsPerFrame = 3_500
        private static let maximumAccumulatedPoints = 42_000
        private static let minimumRegionPixelCount = 36
        private static let maximumRegionCoverage = 0.94

        private let processingQueue = DispatchQueue(
            label: "PackMeasure.scan.queue",
            qos: .userInitiated
        )
        private let segmenter = DepthRegionSegmenter(
            minimumConfidence: UInt8(ARConfidenceLevel.medium.rawValue)
        )

        // Accessed only on processingQueue.
        private var capture: CaptureAccumulator?

        @MainActor private weak var arView: ARView?
        @MainActor private var depthSupported = false
        @MainActor weak var scannerState: ScannerSheetView.ScannerStateModel?
        @MainActor var lastCaptureRequestID = 0

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
        func startCapture() {
            guard depthSupported else {
                scannerState?.phase = .unsupported(
                    "LiDAR scene depth is not available on this device."
                )
                return
            }

            let requestID = lastCaptureRequestID
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

            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
                depthSupported = true
            } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
                depthSupported = true
            }

            arView?.session.run(configuration)
            scannerState?.phase = depthSupported
                ? .ready
                : .unsupported("This app needs a LiDAR-capable iPhone or iPad.")
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // ARKit calls this method on processingQueue; never move ARFrame or
            // its pixel buffers across another concurrency boundary.
            guard var activeCapture = capture else { return }

            let now = CACurrentMediaTime()
            let progress = min(
                1,
                (now - activeCapture.startedAt)
                    / (activeCapture.deadline - activeCapture.startedAt)
            )
            publishProgress(progress, requestID: activeCapture.requestID)

            if now >= activeCapture.nextSampleAt,
               activeCapture.worldPoints.count < Self.maximumAccumulatedPoints {
                activeCapture.nextSampleAt = now + Self.sampleInterval
                let capacity = min(
                    Self.maximumPointsPerFrame,
                    Self.maximumAccumulatedPoints - activeCapture.worldPoints.count
                )
                let newPoints = sampleWorldPoints(from: frame, maximumCount: capacity)
                if !newPoints.isEmpty {
                    activeCapture.worldPoints.append(contentsOf: newPoints)
                    activeCapture.frameCount += 1
                }
            }

            if now >= activeCapture.deadline {
                capture = nil
                finalizeCapture(activeCapture)
            } else {
                capture = activeCapture
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
            guard let estimate = MeasurementEstimator.estimate(
                from: capture.worldPoints,
                frameCount: capture.frameCount
            ) else {
                publishFailure(
                    "Scan was too weak. Back up slightly and retake with the item centered.",
                    requestID: capture.requestID
                )
                return
            }

            publishEstimate(estimate, requestID: capture.requestID)
        }

        private func sampleWorldPoints(
            from frame: ARFrame,
            maximumCount: Int
        ) -> [SIMD3<Float>] {
            guard maximumCount > 0,
                  let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
                  let grid = depthGrid(from: depthData),
                  let region = segmenter.segment(grid),
                  region.pixelCount >= Self.minimumRegionPixelCount else {
                return []
            }

            let coverage = Double(region.pixelCount) / Double(grid.depths.count)
            guard coverage <= Self.maximumRegionCoverage else {
                // A nearly full-frame region is usually a wall or floor rather
                // than a centered object with visible separation around it.
                return []
            }

            let imageResolution = frame.camera.imageResolution
            let scaleX = imageResolution.width / CGFloat(grid.width)
            let scaleY = imageResolution.height / CGFloat(grid.height)
            guard scaleX > 0, scaleY > 0 else { return [] }

            var intrinsics = frame.camera.intrinsics
            intrinsics[0][0] /= Float(scaleX)
            intrinsics[1][1] /= Float(scaleY)
            intrinsics[2][0] /= Float(scaleX)
            intrinsics[2][1] /= Float(scaleY)
            guard intrinsics[0][0] > 0, intrinsics[1][1] > 0 else { return [] }

            let samplingStride = max(
                1,
                Int(ceil(sqrt(Double(region.pixelCount) / Double(maximumCount))))
            )
            let cameraTransform = frame.camera.transform
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(min(maximumCount, region.pixelCount))

            // Only pixels accepted by the centered connected-depth segment are
            // unprojected. The background ROI never reaches the geometry stage.
            for index in region.indices {
                let x = index % grid.width
                let y = index / grid.width
                guard x.isMultiple(of: samplingStride),
                      y.isMultiple(of: samplingStride) else {
                    continue
                }

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
                    continue
                }

                points.append(point)
                if points.count == maximumCount { break }
            }

            return points
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
                guard let state = self?.scannerState,
                      state.captureRequestID == requestID else {
                    return
                }
                state.estimate = estimate
                state.phase = .measured
            }
        }
    }
}
