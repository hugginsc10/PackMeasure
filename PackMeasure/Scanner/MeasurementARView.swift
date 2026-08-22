@preconcurrency import ARKit
@preconcurrency import AVFoundation
import Foundation
import OSLog
import QuartzCore
import RealityKit
import SwiftUI
import Vision
import simd

enum ScannerCameraZoom: Double, CaseIterable, Identifiable, Sendable {
    case half = 0.5
    case standard = 1

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .half:
            "0.5×"
        case .standard:
            "1×"
        }
    }
}

enum ScannerCameraZoomPolicy {
    private static let factorTolerance = 0.000_1

    static func deviceFactor(
        for zoom: ScannerCameraZoom,
        displayMultiplier: Double
    ) -> Double? {
        guard displayMultiplier.isFinite, displayMultiplier > 0 else { return nil }
        let factor = zoom.rawValue / displayMultiplier
        return factor.isFinite && factor >= 1 ? factor : nil
    }

    static func supportedZooms(
        displayMultiplier: Double,
        minDeviceFactor: Double,
        maxDeviceFactor: Double,
        depthCompatibleDeviceFactorRanges: [ClosedRange<Double>]? = nil
    ) -> [ScannerCameraZoom] {
        guard displayMultiplier.isFinite,
              minDeviceFactor.isFinite,
              maxDeviceFactor.isFinite,
              displayMultiplier > 0,
              minDeviceFactor >= 1,
              maxDeviceFactor >= minDeviceFactor else {
            return []
        }

        return ScannerCameraZoom.allCases.filter { zoom in
            guard let factor = deviceFactor(
                for: zoom,
                displayMultiplier: displayMultiplier
            ) else {
                return false
            }
            guard factor >= minDeviceFactor - factorTolerance,
                  factor <= maxDeviceFactor + factorTolerance else {
                return false
            }
            guard let depthCompatibleDeviceFactorRanges,
                  !depthCompatibleDeviceFactorRanges.isEmpty else {
                return true
            }
            return depthCompatibleDeviceFactorRanges.contains { $0.contains(factor) }
        }
    }

    static func selectedZoom(
        deviceFactor: Double,
        displayMultiplier: Double,
        supportedZooms: [ScannerCameraZoom]
    ) -> ScannerCameraZoom? {
        guard deviceFactor.isFinite,
              displayMultiplier.isFinite,
              displayMultiplier > 0,
              !supportedZooms.isEmpty else {
            return nil
        }
        let displayedFactor = deviceFactor * displayMultiplier
        guard displayedFactor.isFinite else { return nil }
        guard let nearest = supportedZooms.min(by: { lhs, rhs in
            abs(lhs.rawValue - displayedFactor) < abs(rhs.rawValue - displayedFactor)
        }), abs(nearest.rawValue - displayedFactor) <= 0.02 else {
            return nil
        }
        return nearest
    }
}

struct ScannerCameraZoomConfirmationGate: Equatable, Sendable {
    let minimumFrameTimestamp: TimeInterval?
    let requiredMatchingFrameCount: Int
    private(set) var matchingFrameCount = 0
    private(set) var lastMatchingFrameTimestamp: TimeInterval?

    init(
        minimumFrameTimestamp: TimeInterval?,
        requiredMatchingFrameCount: Int = 2
    ) {
        self.minimumFrameTimestamp = minimumFrameTimestamp
        self.requiredMatchingFrameCount = max(1, requiredMatchingFrameCount)
    }

    mutating func observe(
        frameTimestamp: TimeInterval,
        hasNormalDepth: Bool,
        zoomMatches: Bool
    ) -> Bool {
        guard frameTimestamp.isFinite,
              hasNormalDepth,
              zoomMatches,
              minimumFrameTimestamp.map({ frameTimestamp > $0 }) ?? true,
              lastMatchingFrameTimestamp.map({ frameTimestamp > $0 }) ?? true else {
            matchingFrameCount = 0
            lastMatchingFrameTimestamp = nil
            return false
        }

        matchingFrameCount += 1
        lastMatchingFrameTimestamp = frameTimestamp
        return matchingFrameCount >= requiredMatchingFrameCount
    }
}

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

@MainActor
final class MeasurementPreviewARView: ARView {
    var objectOverlay: MeasurementObjectOverlay? {
        didSet {
            guard oldValue != objectOverlay else { return }
            accessibilityValue = objectOverlay == nil
                ? "Live camera preview"
                : "Object outline detected and used for measurement"
            setNeedsLayout()
        }
    }

    private let fillLayer = CAShapeLayer()
    private let haloLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()

    required init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        configureOutlineLayers()
    }

    required init?(coder decoder: NSCoder) {
        super.init(coder: decoder)
        configureOutlineLayers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderObjectOutline()
    }

    private func configureOutlineLayers() {
        isAccessibilityElement = true
        accessibilityLabel = "Measurement camera preview"
        accessibilityValue = "Live camera preview"

        fillLayer.fillRule = .evenOdd
        haloLayer.fillColor = nil
        haloLayer.lineCap = .round
        haloLayer.lineJoin = .round
        strokeLayer.fillColor = nil
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        layer.addSublayer(fillLayer)
        layer.addSublayer(haloLayer)
        layer.addSublayer(strokeLayer)
        configureColorsAndWidths()
    }

    private func configureColorsAndWidths() {
        let highContrast = traitCollection.accessibilityContrast == .high
        let fillAlpha: CGFloat = UIAccessibility.isReduceTransparencyEnabled ? 0.18 : 0.11
        fillLayer.fillColor = UIColor.systemCyan.withAlphaComponent(fillAlpha).cgColor
        haloLayer.strokeColor = UIColor.black.withAlphaComponent(0.82).cgColor
        haloLayer.lineWidth = highContrast ? 8 : 6
        strokeLayer.strokeColor = UIColor.systemCyan.cgColor
        strokeLayer.lineWidth = highContrast ? 4 : 3
    }

    private func renderObjectOutline() {
        configureColorsAndWidths()
        let layers = [fillLayer, haloLayer, strokeLayer]
        layers.forEach { $0.frame = bounds }

        guard !bounds.isEmpty,
              let objectOverlay,
              objectOverlay.isRenderable else {
            setOutlinePath(nil)
            return
        }

        let path = CGMutablePath()
        for loop in objectOverlay.outline.loops {
            guard let first = loop.first,
                  let firstViewPoint = viewPoint(first, overlay: objectOverlay) else {
                continue
            }
            path.move(to: firstViewPoint)
            for point in loop.dropFirst() {
                guard let mappedPoint = viewPoint(point, overlay: objectOverlay) else {
                    continue
                }
                path.addLine(to: mappedPoint)
            }
            path.closeSubpath()
        }
        setOutlinePath(path.isEmpty ? nil : path)
    }

    private func viewPoint(
        _ normalizedImagePoint: SIMD2<Float>,
        overlay: MeasurementObjectOverlay
    ) -> CGPoint? {
        guard let normalizedViewPoint = overlay.normalizedPreviewPoint(
            normalizedImagePoint,
            viewportSize: SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        ) else {
            return nil
        }
        return CGPoint(
            x: CGFloat(normalizedViewPoint.x) * bounds.width,
            y: CGFloat(normalizedViewPoint.y) * bounds.height
        )
    }

    private func setOutlinePath(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.path = path
        haloLayer.path = path
        strokeLayer.path = path
        CATransaction.commit()
    }
}

struct MeasurementARView: UIViewRepresentable {
    @Bindable var scannerState: ScannerSheetView.ScannerStateModel

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.scannerState = scannerState
        return coordinator
    }

    func makeUIView(context: Context) -> MeasurementPreviewARView {
        let view = MeasurementPreviewARView(frame: .zero)
        view.cameraMode = .ar
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MeasurementPreviewARView, context: Context) {
        context.coordinator.scannerState = scannerState
        uiView.objectOverlay = scannerState.objectOverlay
        context.coordinator.handleRequests(
            previewRequestID: scannerState.previewRequestID,
            captureRequestID: scannerState.captureRequestID,
            cameraZoomRequestID: scannerState.cameraZoomRequestID,
            cameraZoom: scannerState.cameraZoom
        )
    }

    static func dismantleUIView(_ uiView: MeasurementPreviewARView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// `ARSessionDelegate` invokes this object on `processingQueue`. The unchecked
    /// conformance is constrained by keeping AR/capture mutations on that serial
    /// queue and isolating all view-model/ARView access to `MainActor`.
    final class Coordinator: NSObject, ARSessionDelegate, @unchecked Sendable {
        private struct PendingCameraZoom: Sendable {
            let applicationID: Int
            let lifecycleGeneration: Int
            let requestID: Int
            let measurementSeriesID: Int
            let zoom: ScannerCameraZoom
            var confirmationGate: ScannerCameraZoomConfirmationGate
        }

        private struct CameraZoomSnapshot: Sendable {
            let availableZooms: [ScannerCameraZoom]
            let selectedZoom: ScannerCameraZoom
            let appliedDisplayFactor: Double?
            let usesConfigurableDevice: Bool

            static let unavailable = CameraZoomSnapshot(
                availableZooms: [.standard],
                selectedZoom: .standard,
                appliedDisplayFactor: nil,
                usesConfigurableDevice: false
            )
        }

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
            var objectOverlay: MeasurementObjectOverlay?
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
            case accepted(
                [SIMD3<Float>],
                FrameCalibrationDiagnostics,
                MeasurementObjectOutline?
            )
            case rejected(CenteredTargetRejection, FrameCalibrationDiagnostics?)
            case unavailable(FrameCalibrationDiagnostics?)
        }

        private enum SingleShotFrameSample {
            case accepted(
                [SIMD3<Float>],
                FrameCalibrationDiagnostics,
                MeasurementObjectOutline?,
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
        private static let maximumCameraZoomWait: TimeInterval = 2.5
        private static let cameraZoomConfirmationTolerance = 0.02
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

        private let lifecycleLock = NSLock()
        private var lifecycleGeneration = 0
        private var lifecycleIsAttached = false

        // Accessed only on processingQueue.
        private var capture: CaptureAccumulator?
        private var pendingCameraZoom: PendingCameraZoom?
        private var cameraZoomApplicationSequence = 0
        private var didPublishInitialCameraZoom = false
        private var sessionEventSequence = 0

        @MainActor private weak var arView: ARView?
        @MainActor private var depthSupported = false
        @MainActor private var previewLifecycle = ScannerPreviewLifecycle()
        @MainActor private var sessionConfiguration: ARWorldTrackingConfiguration?
        @MainActor private var sessionEventGate = ScannerSessionEventGate()
        @MainActor private var requestTracker = ScannerViewRequestTracker()
        @MainActor private var lastCameraZoomRequestID = 0
        @MainActor private var isAttached = false
        @MainActor weak var scannerState: ScannerSheetView.ScannerStateModel?

        @MainActor
        func attach(to view: ARView) {
            beginLifecycle()
            isAttached = true
            arView = view
            view.automaticallyConfigureSession = false
            view.session.delegate = self
            view.session.delegateQueue = processingQueue
            configureSession()
        }

        @MainActor
        func stop() {
            endLifecycle()
            isAttached = false
            arView?.session.pause()
            arView?.session.delegate = nil
            processingQueue.async { [weak self] in
                guard let self, activeLifecycleGeneration() == nil else { return }
                capture = nil
                pendingCameraZoom = nil
            }
            arView = nil
        }

        private func beginLifecycle() {
            lifecycleLock.lock()
            lifecycleGeneration += 1
            lifecycleIsAttached = true
            lifecycleLock.unlock()
        }

        private func endLifecycle() {
            lifecycleLock.lock()
            lifecycleGeneration += 1
            lifecycleIsAttached = false
            lifecycleLock.unlock()
        }

        private func activeLifecycleGeneration() -> Int? {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return lifecycleIsAttached ? lifecycleGeneration : nil
        }

        private func isLifecycleActive(_ generation: Int) -> Bool {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return lifecycleIsAttached && lifecycleGeneration == generation
        }

        @MainActor
        func handleRequests(
            previewRequestID: Int,
            captureRequestID: Int,
            cameraZoomRequestID: Int,
            cameraZoom: ScannerCameraZoom
        ) {
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

            if cameraZoomRequestID != lastCameraZoomRequestID {
                lastCameraZoomRequestID = cameraZoomRequestID
                requestCameraZoom(
                    cameraZoom,
                    requestID: cameraZoomRequestID,
                    measurementSeriesID: scannerState?.measurementSeriesID ?? 0
                )
            }
        }

        @MainActor
        private func requestCameraZoom(
            _ zoom: ScannerCameraZoom,
            requestID: Int,
            measurementSeriesID: Int
        ) {
            guard let lifecycleGeneration = activeLifecycleGeneration() else { return }
            processingQueue.async { [weak self] in
                guard let self,
                      isLifecycleActive(lifecycleGeneration) else {
                    return
                }
                guard capture == nil else {
                    publishCameraZoomFailure(
                        cameraZoomSnapshot(),
                        requestID: requestID,
                        measurementSeriesID: measurementSeriesID,
                        lifecycleGeneration: lifecycleGeneration
                    )
                    return
                }

                guard let device = ARWorldTrackingConfiguration
                    .configurableCaptureDeviceForPrimaryCamera else {
                    publishCameraZoomFailure(
                        .unavailable,
                        requestID: requestID,
                        measurementSeriesID: measurementSeriesID,
                        lifecycleGeneration: lifecycleGeneration
                    )
                    return
                }

                var zoomAppliedAt: TimeInterval?
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    guard isLifecycleActive(lifecycleGeneration) else { return }
                    let supportedZooms = supportedCameraZooms(
                        forLockedDevice: device
                    )
                    guard supportedZooms.contains(zoom),
                          let targetFactor = ScannerCameraZoomPolicy.deviceFactor(
                              for: zoom,
                              displayMultiplier: Double(
                                  device.displayVideoZoomFactorMultiplier
                              )
                        ) else {
                        publishCameraZoomFailure(
                            cameraZoomSnapshot(forLockedDevice: device),
                            requestID: requestID,
                            measurementSeriesID: measurementSeriesID,
                            lifecycleGeneration: lifecycleGeneration
                        )
                        return
                    }
                    lifecycleLock.lock()
                    let mayApply = lifecycleIsAttached
                        && self.lifecycleGeneration == lifecycleGeneration
                    if mayApply {
                        device.videoZoomFactor = CGFloat(targetFactor)
                        zoomAppliedAt = CACurrentMediaTime()
                    }
                    lifecycleLock.unlock()
                    guard mayApply else { return }
                } catch {
                    Self.calibrationLogger.error(
                        "camera_zoom_failed requested=\(zoom.label, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    publishCameraZoomFailure(
                        .unavailable,
                        requestID: requestID,
                        measurementSeriesID: measurementSeriesID,
                        lifecycleGeneration: lifecycleGeneration
                    )
                    return
                }

                guard isLifecycleActive(lifecycleGeneration),
                      let zoomAppliedAt else { return }
                cameraZoomApplicationSequence += 1
                pendingCameraZoom = PendingCameraZoom(
                    applicationID: cameraZoomApplicationSequence,
                    lifecycleGeneration: lifecycleGeneration,
                    requestID: requestID,
                    measurementSeriesID: measurementSeriesID,
                    zoom: zoom,
                    confirmationGate: ScannerCameraZoomConfirmationGate(
                        minimumFrameTimestamp: zoomAppliedAt
                    )
                )
                scheduleCameraZoomTimeout(
                    applicationID: cameraZoomApplicationSequence,
                    lifecycleGeneration: lifecycleGeneration
                )
            }
        }

        private func scheduleCameraZoomTimeout(
            applicationID: Int,
            lifecycleGeneration: Int
        ) {
            processingQueue.asyncAfter(
                deadline: .now() + Self.maximumCameraZoomWait
            ) { [weak self] in
                guard let self,
                      isLifecycleActive(lifecycleGeneration),
                      let pending = pendingCameraZoom,
                      pending.applicationID == applicationID else {
                    return
                }
                pendingCameraZoom = nil
                let snapshot = cameraZoomSnapshot()
                Self.calibrationLogger.error(
                    "camera_zoom_timeout request_id=\(pending.requestID, privacy: .public)"
                )
                publishCameraZoomFailure(
                    snapshot,
                    requestID: pending.requestID,
                    measurementSeriesID: pending.measurementSeriesID,
                    lifecycleGeneration: lifecycleGeneration
                )
            }
        }

        @MainActor
        @discardableResult
        private func reapplyCameraZoomAfterSessionRun() -> Bool {
            guard let state = scannerState,
                  state.cameraZoomUsesConfigurableDevice else {
                return false
            }
            state.beginCameraZoomApplication()
            requestCameraZoom(
                state.cameraZoom,
                requestID: state.cameraZoomRequestID,
                measurementSeriesID: state.measurementSeriesID
            )
            return true
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
                _ = reapplyCameraZoomAfterSessionRun()
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
                if reapplyCameraZoomAfterSessionRun() {
                    scannerState?.phase = .ready
                    return
                }
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
            if depthSupported {
                scannerState?.beginCameraZoomApplication()
            }
            arView?.session.run(configuration)
            scannerState?.phase = depthSupported
                ? .ready
                : .unsupported("This app needs a LiDAR-capable iPhone or iPad.")
            if depthSupported {
                _ = reapplyCameraZoomAfterSessionRun()
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // ARKit calls this method on processingQueue; never move ARFrame or
            // its pixel buffers across another concurrency boundary.
            publishInitialCameraZoomIfNeeded(with: frame)
            confirmPendingCameraZoom(with: frame)

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
            case .accepted(let points, let diagnostics, let outline, let route):
                activeCapture.worldPoints = points
                activeCapture.frameCount = 1
                activeCapture.lastCalibration = diagnostics
                activeCapture.objectOverlay = outline.flatMap {
                    measurementObjectOverlay(from: $0, frame: frame)
                }
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

        private func publishInitialCameraZoomIfNeeded(with frame: ARFrame) {
            guard !didPublishInitialCameraZoom,
                  pendingCameraZoom == nil else {
                return
            }
            guard case .normal = frame.camera.trackingState,
                  frame.smoothedSceneDepth ?? frame.sceneDepth != nil else {
                return
            }
            guard let lifecycleGeneration = activeLifecycleGeneration() else { return }
            if ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera != nil {
                let snapshot = cameraZoomSnapshot()
                // ARKit scene depth is independent from AVFoundation depth-data
                // formats. This depth-bearing frame proves baseline scanning is
                // usable even when zoom capabilities cannot be mapped. In that
                // case, hide the selector without mutating the camera factor.
                didPublishInitialCameraZoom = true
                publishCameraZoomSnapshot(
                    snapshot,
                    requestID: nil,
                    lifecycleGeneration: lifecycleGeneration
                )
                return
            }
            didPublishInitialCameraZoom = true
            publishCameraZoomSnapshot(
                .unavailable,
                requestID: nil,
                lifecycleGeneration: lifecycleGeneration
            )
        }

        private func confirmPendingCameraZoom(with frame: ARFrame) {
            guard var pendingCameraZoom else { return }
            guard isLifecycleActive(pendingCameraZoom.lifecycleGeneration) else {
                self.pendingCameraZoom = nil
                return
            }
            let hasNormalDepth: Bool = if case .normal = frame.camera.trackingState {
                frame.smoothedSceneDepth ?? frame.sceneDepth != nil
            } else {
                false
            }
            let snapshot = hasNormalDepth ? cameraZoomSnapshot() : .unavailable
            let wasApplied = snapshot.appliedDisplayFactor.map {
                abs($0 - pendingCameraZoom.zoom.rawValue)
                    <= Self.cameraZoomConfirmationTolerance
            } ?? false
            guard pendingCameraZoom.confirmationGate.observe(
                frameTimestamp: frame.timestamp,
                hasNormalDepth: hasNormalDepth,
                zoomMatches: wasApplied
            ) else {
                self.pendingCameraZoom = pendingCameraZoom
                return
            }

            self.pendingCameraZoom = nil
            didPublishInitialCameraZoom = true
            Self.calibrationLogger.notice(
                "camera_zoom_applied display=\(pendingCameraZoom.zoom.label, privacy: .public) confirmed_frames=\(pendingCameraZoom.confirmationGate.matchingFrameCount, privacy: .public)"
            )
            publishCameraZoomSnapshot(
                snapshot,
                requestID: pendingCameraZoom.requestID,
                measurementSeriesID: pendingCameraZoom.measurementSeriesID,
                lifecycleGeneration: pendingCameraZoom.lifecycleGeneration
            )
        }

        private func cameraZoomSnapshot() -> CameraZoomSnapshot {
            guard let device = ARWorldTrackingConfiguration
                .configurableCaptureDeviceForPrimaryCamera else {
                return .unavailable
            }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                return cameraZoomSnapshot(forLockedDevice: device)
            } catch {
                return .unavailable
            }
        }

        private func cameraZoomSnapshot(
            forLockedDevice device: AVCaptureDevice
        ) -> CameraZoomSnapshot {
            let multiplier = Double(device.displayVideoZoomFactorMultiplier)
            let appliedDisplayFactor = Double(device.videoZoomFactor) * multiplier
            let availableZooms = supportedCameraZooms(forLockedDevice: device)
            guard let selectedZoom = ScannerCameraZoomPolicy.selectedZoom(
                deviceFactor: Double(device.videoZoomFactor),
                displayMultiplier: multiplier,
                supportedZooms: availableZooms
            ) else {
                return .unavailable
            }
            return CameraZoomSnapshot(
                availableZooms: availableZooms,
                selectedZoom: selectedZoom,
                appliedDisplayFactor: appliedDisplayFactor,
                usesConfigurableDevice: true
            )
        }

        private func supportedCameraZooms(
            forLockedDevice device: AVCaptureDevice
        ) -> [ScannerCameraZoom] {
            let multiplier = Double(device.displayVideoZoomFactorMultiplier)
            let depthRanges = device.activeFormat
                .supportedVideoZoomRangesForDepthDataDelivery
                .map { Double($0.lowerBound) ... Double($0.upperBound) }
            return ScannerCameraZoomPolicy.supportedZooms(
                displayMultiplier: multiplier,
                minDeviceFactor: Double(device.minAvailableVideoZoomFactor),
                maxDeviceFactor: Double(device.maxAvailableVideoZoomFactor),
                depthCompatibleDeviceFactorRanges: depthRanges
            )
        }

        private func publishCameraZoomSnapshot(
            _ snapshot: CameraZoomSnapshot,
            requestID: Int?,
            measurementSeriesID: Int? = nil,
            lifecycleGeneration: Int
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      isAttached,
                      isLifecycleActive(lifecycleGeneration),
                      let state = scannerState else {
                    return
                }
                if let requestID,
                   state.cameraZoomRequestID != requestID {
                    return
                }
                if let measurementSeriesID,
                   state.measurementSeriesID != measurementSeriesID {
                    return
                }
                state.updateCameraZoomAvailability(
                    snapshot.availableZooms,
                    selected: snapshot.selectedZoom,
                    usesConfigurableDevice: snapshot.usesConfigurableDevice
                )
            }
        }

        private func publishCameraZoomFailure(
            _ snapshot: CameraZoomSnapshot,
            requestID: Int,
            measurementSeriesID: Int,
            lifecycleGeneration: Int
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      isAttached,
                      isLifecycleActive(lifecycleGeneration),
                      let state = scannerState,
                      state.cameraZoomRequestID == requestID,
                      state.measurementSeriesID == measurementSeriesID else {
                    return
                }
                if previewLifecycle.measurementFinalized() == .pause {
                    arView?.session.pause()
                }
                if snapshot.usesConfigurableDevice,
                   snapshot.appliedDisplayFactor != nil {
                    state.updateCameraZoomAvailability(
                        snapshot.availableZooms,
                        selected: snapshot.selectedZoom,
                        usesConfigurableDevice: true
                    )
                }
                state.resetMeasurementSeries()
                state.phase = .failed(
                    "Camera zoom could not be confirmed with depth. Retake the photo to try again."
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
            pendingCameraZoom = nil
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
            pendingCameraZoom = nil
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
            pendingCameraZoom = nil
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
                viewpoint: cameraViewpoint,
                objectOverlay: capture.objectOverlay
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
                : .accepted(
                    points,
                    diagnostics,
                    MeasurementObjectOutline(
                        width: grid.width,
                        height: grid.height,
                        selectedIndices: region.indices
                    )
                )
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
                return .accepted(
                    pointCloud.worldPoints,
                    diagnostics,
                    pointCloud.objectOutline,
                    .visionMask
                )
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

        /// Converts raw camera-image contours into a portrait-oriented image
        /// space while the measured ARFrame is still alive. Using a viewport
        /// with the rotated image's native aspect ratio isolates orientation
        /// from cropping; the ARView applies its current aspect-fill crop later.
        private func measurementObjectOverlay(
            from outline: MeasurementObjectOutline,
            frame: ARFrame
        ) -> MeasurementObjectOverlay? {
            let imageResolution = frame.camera.imageResolution
            let orientedSize = CGSize(
                width: imageResolution.height,
                height: imageResolution.width
            )
            guard orientedSize.width > 0, orientedSize.height > 0 else { return nil }

            let transform: CGAffineTransform
            if #available(iOS 27.0, *) {
                // PackMeasure is portrait-only, and ARKit expresses this angle
                // in degrees for the iOS 27 display-transform API.
                transform = frame.displayTransform(
                    viewRotationAngle: 90,
                    viewportSize: orientedSize
                )
            } else {
                transform = frame.displayTransform(
                    for: .portrait,
                    viewportSize: orientedSize
                )
            }

            let displayOutline = outline.mappingPoints { point in
                let mapped = CGPoint(
                    x: CGFloat(point.x),
                    y: CGFloat(point.y)
                ).applying(transform)
                return SIMD2<Float>(Float(mapped.x), Float(mapped.y))
            }
            let overlay = MeasurementObjectOverlay(
                displayOrientedImageSize: SIMD2<Float>(
                    Float(orientedSize.width),
                    Float(orientedSize.height)
                ),
                outline: displayOutline
            )
            return overlay.isRenderable ? overlay : nil
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
            case .accepted(let points, let diagnostics, let outline):
                return .accepted(
                    points,
                    diagnostics,
                    outline,
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
                state.objectOverlay = nil
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
                _ = reapplyCameraZoomAfterSessionRun()
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
