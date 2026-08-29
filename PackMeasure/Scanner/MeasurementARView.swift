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
    case double = 2

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .half:
            "0.5×"
        case .standard:
            "1×"
        case .double:
            "2×"
        }
    }

    var controlIdentifier: String {
        switch self {
        case .half:
            "scanner.zoom.0_5"
        case .standard:
            "scanner.zoom.1_0"
        case .double:
            "scanner.zoom.2_0"
        }
    }
}

/// Camera calibration retained with one accepted angle. Mixed-zoom series are
/// valid only when every measurement remains attributable to the exact lens
/// state and AR-frame calibration that produced its point cloud.
struct ScannerCameraCaptureProvenance: Equatable, Sendable {
    private static let zoomFactorTolerance = 0.02

    let cameraZoom: ScannerCameraZoom
    let appliedDisplayZoomFactor: Double
    let imageResolutionPixels: SIMD2<Int>
    let normalizedFocalLength: Double
    let horizontalFieldOfViewRadians: Double
    let verticalFieldOfViewRadians: Double

    private let intrinsicsColumn0: SIMD3<Float>
    private let intrinsicsColumn1: SIMD3<Float>
    private let intrinsicsColumn2: SIMD3<Float>

    var intrinsics: simd_float3x3 {
        simd_float3x3(columns: (
            intrinsicsColumn0,
            intrinsicsColumn1,
            intrinsicsColumn2
        ))
    }

    init?(
        cameraZoom: ScannerCameraZoom,
        appliedDisplayZoomFactor: Double,
        intrinsics: simd_float3x3,
        imageResolutionPixels: SIMD2<Int>
    ) {
        let columns = intrinsics.columns
        let components = [
            columns.0.x, columns.0.y, columns.0.z,
            columns.1.x, columns.1.y, columns.1.z,
            columns.2.x, columns.2.y, columns.2.z,
        ]
        guard appliedDisplayZoomFactor.isFinite,
              appliedDisplayZoomFactor > 0,
              abs(appliedDisplayZoomFactor - cameraZoom.rawValue)
                <= Self.zoomFactorTolerance,
              imageResolutionPixels.x > 0,
              imageResolutionPixels.y > 0,
              components.allSatisfy(\.isFinite) else {
            return nil
        }

        let focalX = Double(columns.0.x)
        let focalY = Double(columns.1.y)
        let width = Double(imageResolutionPixels.x)
        let height = Double(imageResolutionPixels.y)
        guard focalX > 0, focalY > 0 else { return nil }

        let normalizedFocalLength = focalX / width
        let horizontalFieldOfViewRadians = 2 * atan(width / (2 * focalX))
        let verticalFieldOfViewRadians = 2 * atan(height / (2 * focalY))
        guard normalizedFocalLength.isFinite,
              normalizedFocalLength > 0,
              horizontalFieldOfViewRadians.isFinite,
              horizontalFieldOfViewRadians > 0,
              horizontalFieldOfViewRadians < .pi,
              verticalFieldOfViewRadians.isFinite,
              verticalFieldOfViewRadians > 0,
              verticalFieldOfViewRadians < .pi else {
            return nil
        }

        self.cameraZoom = cameraZoom
        self.appliedDisplayZoomFactor = appliedDisplayZoomFactor
        self.imageResolutionPixels = imageResolutionPixels
        self.normalizedFocalLength = normalizedFocalLength
        self.horizontalFieldOfViewRadians = horizontalFieldOfViewRadians
        self.verticalFieldOfViewRadians = verticalFieldOfViewRadians
        intrinsicsColumn0 = columns.0
        intrinsicsColumn1 = columns.1
        intrinsicsColumn2 = columns.2
    }
}

/// Scanner-owned wrapper that keeps camera provenance aligned with every
/// accepted measurement without coupling the geometry workflow to ARKit.
struct ScannerRecordedAngleCapture: Equatable, Sendable {
    let measurement: MeasurementAngleCapture
    let cameraProvenance: ScannerCameraCaptureProvenance

    var evidence: MeasurementCaptureEvidence { measurement.evidence }
    var viewpoint: MeasurementCameraViewpoint { measurement.viewpoint }
    var objectOverlay: MeasurementObjectOverlay? { measurement.objectOverlay }
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
        maxDeviceFactor: Double
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
            return true
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

enum ScannerCameraFrameZoomPolicy {
    private static let transitionTolerance = 0.15
    private static let referenceTolerance = 0.12

    static func normalizedFocalLength(
        focalLengthPixels: Double,
        imageWidthPixels: Double
    ) -> Double? {
        guard focalLengthPixels.isFinite,
              imageWidthPixels.isFinite,
              focalLengthPixels > 0,
              imageWidthPixels > 0 else {
            return nil
        }
        return focalLengthPixels / imageWidthPixels
    }

    static func confirmsVisibleTransition(
        from previousZoom: ScannerCameraZoom,
        baselineNormalizedFocalLength: Double,
        to requestedZoom: ScannerCameraZoom,
        currentNormalizedFocalLength: Double,
        confirmedReferenceNormalizedFocalLength: Double? = nil
    ) -> Bool {
        guard baselineNormalizedFocalLength.isFinite,
              currentNormalizedFocalLength.isFinite,
              baselineNormalizedFocalLength > 0,
              currentNormalizedFocalLength > 0 else {
            return false
        }

        if let confirmedReferenceNormalizedFocalLength,
           confirmedReferenceNormalizedFocalLength.isFinite,
           confirmedReferenceNormalizedFocalLength > 0 {
            let relativeError = abs(
                currentNormalizedFocalLength
                    / confirmedReferenceNormalizedFocalLength - 1
            )
            return relativeError <= referenceTolerance
        }

        guard previousZoom != requestedZoom else { return false }

        let observedRatio = currentNormalizedFocalLength
            / baselineNormalizedFocalLength
        let requestedRatio = requestedZoom.rawValue / previousZoom.rawValue
        let relativeError = abs(observedRatio / requestedRatio - 1)
        return relativeError <= transitionTolerance
    }
}

struct ScannerCameraZoomConfirmationGate: Equatable, Sendable {
    let minimumFrameSequence: UInt64?
    let requiredMatchingFrameCount: Int
    private(set) var matchingFrameCount = 0
    private(set) var lastMatchingFrameSequence: UInt64?

    init(
        minimumFrameSequence: UInt64?,
        requiredMatchingFrameCount: Int = 2
    ) {
        self.minimumFrameSequence = minimumFrameSequence
        self.requiredMatchingFrameCount = max(1, requiredMatchingFrameCount)
    }

    mutating func observe(
        frameSequence: UInt64,
        hasNormalDepth: Bool,
        zoomMatches: Bool
    ) -> Bool {
        guard hasNormalDepth,
              zoomMatches,
              minimumFrameSequence.map({ frameSequence > $0 }) ?? true,
              lastMatchingFrameSequence.map({ frameSequence > $0 }) ?? true else {
            matchingFrameCount = 0
            lastMatchingFrameSequence = nil
            return false
        }

        matchingFrameCount += 1
        lastMatchingFrameSequence = frameSequence
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

    init(previewRequestID: Int = 0, captureRequestID: Int = 0) {
        lastPreviewRequestID = previewRequestID
        lastCaptureRequestID = captureRequestID
    }

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

enum ScannerPreviewReadinessPolicy {
    static func isFrameFresh(
        timestamp: TimeInterval,
        after baselineTimestamp: TimeInterval?
    ) -> Bool {
        guard timestamp.isFinite else { return false }
        guard let baselineTimestamp else { return true }
        return baselineTimestamp.isFinite && timestamp > baselineTimestamp
    }

    static func isReady(
        trackingIsNormal: Bool,
        hasDepth: Bool,
        viewportSize: SIMD2<Float>?
    ) -> Bool {
        guard trackingIsNormal,
              hasDepth,
              let viewportSize else {
            return false
        }
        return viewportSize.x.isFinite
            && viewportSize.y.isFinite
            && viewportSize.x > 0
            && viewportSize.y > 0
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
    var viewportDidLayout: ((SIMD2<Float>) -> Void)?
    var previewTapHandler: ((SIMD2<Float>) -> Void)?
    var targetMarkerPoint: SIMD2<Float>? {
        didSet {
            guard oldValue != targetMarkerPoint else { return }
            setNeedsLayout()
        }
    }
    var projectedGuidedOverlay = ScannerProjectedGuidedOverlay.empty {
        didSet {
            guard oldValue != projectedGuidedOverlay else { return }
            setNeedsLayout()
        }
    }

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
    private let targetMarkerLayer = CAShapeLayer()
    private let guidedLineLayer = CAShapeLayer()
    private let guidedMarkerLayer = CAShapeLayer()
    private var guidedNumberLayers: [CATextLayer] = []

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
        let viewportSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
        if viewportSize.x > 0, viewportSize.y > 0 {
            viewportDidLayout?(viewportSize)
        }
        renderObjectOutline()
        renderCaptureGuides()
    }

    private func configureOutlineLayers() {
        isAccessibilityElement = true
        accessibilityLabel = "Measurement camera preview"
        accessibilityValue = "Live camera preview"
        isUserInteractionEnabled = true
        addGestureRecognizer(
            UITapGestureRecognizer(
                target: self,
                action: #selector(previewWasTapped(_:))
            )
        )

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
        layer.addSublayer(guidedLineLayer)
        layer.addSublayer(targetMarkerLayer)
        layer.addSublayer(guidedMarkerLayer)
        configureColorsAndWidths()
    }

    @objc
    private func previewWasTapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        previewTapHandler?(
            SIMD2<Float>(Float(point.x), Float(point.y))
        )
    }

    private func configureColorsAndWidths() {
        let highContrast = traitCollection.accessibilityContrast == .high
        let fillAlpha: CGFloat = UIAccessibility.isReduceTransparencyEnabled ? 0.18 : 0.11
        fillLayer.fillColor = UIColor.systemCyan.withAlphaComponent(fillAlpha).cgColor
        haloLayer.strokeColor = UIColor.black.withAlphaComponent(0.82).cgColor
        haloLayer.lineWidth = highContrast ? 8 : 6
        strokeLayer.strokeColor = UIColor.systemCyan.cgColor
        strokeLayer.lineWidth = highContrast ? 4 : 3
        targetMarkerLayer.fillColor = UIColor.systemCyan.cgColor
        targetMarkerLayer.strokeColor = UIColor.black.withAlphaComponent(0.82).cgColor
        targetMarkerLayer.lineWidth = highContrast ? 4 : 3
        guidedLineLayer.fillColor = nil
        guidedLineLayer.strokeColor = UIColor.systemBlue.cgColor
        guidedLineLayer.lineCap = .round
        guidedLineLayer.lineJoin = .round
        guidedLineLayer.lineWidth = highContrast ? 5 : 4
        guidedMarkerLayer.fillColor = UIColor.systemBlue.cgColor
        guidedMarkerLayer.strokeColor = UIColor.white.cgColor
        guidedMarkerLayer.lineWidth = highContrast ? 3 : 2
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

    private func renderCaptureGuides() {
        configureColorsAndWidths()
        [targetMarkerLayer, guidedLineLayer, guidedMarkerLayer].forEach {
            $0.frame = bounds
        }

        let targetPath = targetMarkerPoint.flatMap(viewPoint)
            .map { point -> CGPath in
                UIBezierPath(
                    ovalIn: CGRect(
                        x: point.x - 13,
                        y: point.y - 13,
                        width: 26,
                        height: 26
                    )
                ).cgPath
            }
        targetMarkerLayer.path = targetPath

        let linePath = CGMutablePath()
        for line in projectedGuidedOverlay.lines {
            guard let start = viewPoint(line.normalizedReferencePoint),
                  let end = viewPoint(line.normalizedEndpointPoint) else {
                continue
            }
            linePath.move(to: start)
            linePath.addLine(to: end)
        }
        guidedLineLayer.path = linePath.isEmpty ? nil : linePath

        let markerPath = CGMutablePath()
        guidedNumberLayers.forEach { $0.removeFromSuperlayer() }
        guidedNumberLayers.removeAll(keepingCapacity: true)
        for marker in projectedGuidedOverlay.markers {
            guard let point = viewPoint(marker.normalizedPreviewPoint) else { continue }
            markerPath.addEllipse(
                in: CGRect(
                    x: point.x - 13,
                    y: point.y - 13,
                    width: 26,
                    height: 26
                )
            )
            let numberLayer = CATextLayer()
            numberLayer.string = String(marker.number)
            numberLayer.alignmentMode = .center
            numberLayer.contentsScale = window?.screen.scale ?? UIScreen.main.scale
            numberLayer.foregroundColor = UIColor.white.cgColor
            numberLayer.fontSize = 16
            numberLayer.frame = CGRect(
                x: point.x - 13,
                y: point.y - 10,
                width: 26,
                height: 22
            )
            layer.addSublayer(numberLayer)
            guidedNumberLayers.append(numberLayer)
        }
        guidedMarkerLayer.path = markerPath.isEmpty ? nil : markerPath
    }

    private func viewPoint(_ normalizedPoint: SIMD2<Float>) -> CGPoint? {
        guard normalizedPoint.x.isFinite,
              normalizedPoint.y.isFinite,
              (0...1).contains(normalizedPoint.x),
              (0...1).contains(normalizedPoint.y),
              !bounds.isEmpty else {
            return nil
        }
        return CGPoint(
            x: CGFloat(normalizedPoint.x) * bounds.width,
            y: CGFloat(normalizedPoint.y) * bounds.height
        )
    }
}

struct MeasurementARView: UIViewRepresentable {
    @Bindable var scannerState: ScannerSheetView.ScannerStateModel

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.scannerState = scannerState
        coordinator.baselineRequests(
            previewRequestID: scannerState.previewRequestID,
            captureRequestID: scannerState.captureRequestID,
            cameraZoomRequestID: scannerState.cameraZoomRequestID,
            guidedCaptureIntentID: scannerState.guidedPointCaptureIntentID
        )
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
        context.coordinator.synchronizeCaptureState(
            targetLock: scannerState.automaticTargetValidationLockSnapshot,
            targetPrompt: scannerState.automaticTargetPrompt,
            targetSubject: scannerState.measurementSubject,
            cameraEvidenceReacquisitionID:
                scannerState.cameraEvidenceReacquisitionID,
            guidedRequest: scannerState.guidedCaptureSession?.pendingRequest,
            guidedOverlay: scannerState.guidedCaptureSession?.overlay ?? .empty
        )
        context.coordinator.handleRequests(
            previewRequestID: scannerState.previewRequestID,
            captureRequestID: scannerState.captureRequestID,
            cameraZoomRequestID: scannerState.cameraZoomRequestID,
            cameraZoom: scannerState.cameraZoom,
            guidedCaptureIntentID: scannerState.guidedPointCaptureIntentID
        )
    }

    static func dismantleUIView(_ uiView: MeasurementPreviewARView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// `ARSessionDelegate` invokes this object on `processingQueue`. The unchecked
    /// conformance is constrained by keeping AR/capture mutations on that serial
    /// queue and isolating all view-model/ARView access to `MainActor`.
    final class Coordinator: NSObject, ARSessionDelegate, @unchecked Sendable {
        private typealias AutomaticCaptureAuthority =
            ScannerSheetView.ScannerStateModel.AutomaticPhotoCaptureAuthority

        private struct TargetTrackingSnapshot: Equatable, Sendable {
            let lock: TargetLock
            let subject: TargetLockSubject
            let cameraEvidenceReacquisitionID: Int
        }

        private struct CaptureVisualSnapshot: Equatable, Sendable {
            let targetLock: TargetLock?
            let targetPrompt: PhotoTargetSelectionPrompt?
            let guidedOverlay: GuidedBoxOverlay
        }

        private struct PendingGuidedCapture: Sendable {
            let request: GuidedBoxCaptureRequest
            var attemptGate: ScannerGuidedFrameAttemptGate
            var settledFrameGate: SettledFrameCaptureGate
        }

        private struct ExactTargetFrameSample: Sendable {
            let evidence: TargetLockFrameEvidence
            let rawImagePoint: SIMD2<Float>?
        }

        private struct PendingCameraZoom: Sendable {
            let applicationID: Int
            let lifecycleGeneration: Int
            let requestID: Int
            let measurementSeriesID: Int
            let previousZoom: ScannerCameraZoom
            let zoom: ScannerCameraZoom
            let baselineNormalizedFocalLength: Double
            let confirmedReferenceNormalizedFocalLength: Double?
            var confirmationGate: ScannerCameraZoomConfirmationGate
            var observedFrameCount = 0
            var trackingNotNormalCount = 0
            var missingDepthCount = 0
            var snapshotUnavailableCount = 0
            var factorMismatchCount = 0
            var frameFieldOfViewMismatchCount = 0
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
            let previewViewportSize: SIMD2<Float>
            let cameraZoom: ScannerCameraZoom
            let automaticAuthority: AutomaticCaptureAuthority?
            let targetLock: TargetLock?
            let targetSubject: TargetLockSubject
            let photoMeasurement: PhotoObjectMeasurement
            var settledFrameGate: SettledFrameCaptureGate
            var cameraViewpoint: MeasurementCameraViewpoint?
            var cameraProvenance: ScannerCameraCaptureProvenance?
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
            let rigidItemMultiplicityEvaluation: PhotoRigidItemMultiplicityEvaluation?

            init(
                rawRegionPixelCount: Int,
                retainedRegionPixelCount: Int,
                regionCoverage: Float,
                absoluteUpNormal: Float?,
                elevationAboveFloorMeters: Float?,
                floorEstimate: SceneFloorEstimate?,
                rigidItemMultiplicityEvaluation: PhotoRigidItemMultiplicityEvaluation? = nil
            ) {
                self.rawRegionPixelCount = rawRegionPixelCount
                self.retainedRegionPixelCount = retainedRegionPixelCount
                self.regionCoverage = regionCoverage
                self.absoluteUpNormal = absoluteUpNormal
                self.elevationAboveFloorMeters = elevationAboveFloorMeters
                self.floorEstimate = floorEstimate
                self.rigidItemMultiplicityEvaluation = rigidItemMultiplicityEvaluation
            }
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
                "The photo appears to target the floor. Point the marker at a solid face of the selected box and retake it."
            case .targetRejected(.insufficientSurfaceEvidence), .insufficientFrames:
                "The photo did not contain enough box depth. Tap a solid face, hold steady, and retake it."
            case .geometry(.groundPlaneContamination):
                "Too much floor entered the photo. Show less floor and keep every box edge inside the camera view."
            case .geometry:
                "The object could not be measured reliably from this photo. Try a clearer three-quarter angle."
            }
        }

        private static let settledFramePolicy = SettledFrameCapturePolicy()
        private static let maximumTrackingWait: TimeInterval = 2
        private static let maximumCameraZoomWait: TimeInterval = 2.5
        private static let maximumGuidedCaptureWait: TimeInterval = 2.5
        private static let maximumGuidedFailedSamples = 3
        private static let cameraZoomConfirmationTolerance = 0.02
        private static let maximumPointsPerFrame = 3_500
        private static let maximumAccumulatedPoints = 42_000
        private static let minimumRegionPixelCount = 36
        private static let maximumRegionCoverage = 0.94
        private static let peripheralSampleTarget = 1_200
        private static let edgeMarginPixels = 2
        private static let protectedPreviewInsetFraction: Float = 0.02
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
        private let targetFrameValidator = TargetLockFrameValidator()
        private let targetFrameEvidenceAdapter = ScannerTargetFrameEvidenceAdapter()
        private let guidedFrameSampler = ScannerGuidedFrameSampler()
        private let singleShotFrameRoutePolicy = ScannerSingleShotFrameRoutePolicy()
        private let automaticCaptureAuthorityTerminator =
            ScannerAutomaticCaptureAuthorityTerminator()

        private let lifecycleLock = NSLock()
        private var lifecycleGeneration = 0
        private var lifecycleIsAttached = false
        private var previewRunGeneration = 0
        private var previewRunMinimumFrameTimestamp: TimeInterval?
        private let previewViewportLock = NSLock()
        private var previewViewportSize: SIMD2<Float>?

        // Accessed only on processingQueue.
        private var capture: CaptureAccumulator?
        private var pendingCameraZoom: PendingCameraZoom?
        private var targetTrackingSnapshot: TargetTrackingSnapshot?
        private var captureVisualSnapshot = CaptureVisualSnapshot(
            targetLock: nil,
            targetPrompt: nil,
            guidedOverlay: .empty
        )
        private var targetFrameAuthorityTracker =
            ScannerTargetFrameAuthorityTracker()
        private var pendingGuidedCapture: PendingGuidedCapture?
        private var guidedFrameRequestTracker = ScannerGuidedFrameRequestTracker()
        private var cameraZoomApplicationSequence = 0
        private var cameraFrameSequence: UInt64 = 0
        private var latestCameraNormalizedFocalLength: Double?
        private var confirmedCameraNormalizedFocalLengths: [ScannerCameraZoom: Double] = [:]
        private var didPublishInitialCameraZoom = false
        private var sessionEventSequence = 0
        private var previewReadinessNeeded = true

        @MainActor private weak var arView: MeasurementPreviewARView?
        @MainActor private var depthSupported = false
        @MainActor private var previewLifecycle = ScannerPreviewLifecycle()
        @MainActor private var sessionConfiguration: ARWorldTrackingConfiguration?
        @MainActor private var sessionEventGate = ScannerSessionEventGate()
        @MainActor private var requestTracker = ScannerViewRequestTracker()
        @MainActor private var lastCameraZoomRequestID = 0
        @MainActor private var lastGuidedCaptureIntentID = 0
        @MainActor private var isAttached = false
        @MainActor private var latestPreviewViewportSize: SIMD2<Float>?
        @MainActor weak var scannerState: ScannerSheetView.ScannerStateModel?

        @MainActor
        func baselineRequests(
            previewRequestID: Int,
            captureRequestID: Int,
            cameraZoomRequestID: Int,
            guidedCaptureIntentID: Int
        ) {
            requestTracker = ScannerViewRequestTracker(
                previewRequestID: previewRequestID,
                captureRequestID: captureRequestID
            )
            lastCameraZoomRequestID = cameraZoomRequestID
            lastGuidedCaptureIntentID = guidedCaptureIntentID
        }

        @MainActor
        func attach(to view: MeasurementPreviewARView) {
            beginLifecycle()
            isAttached = true
            arView = view
            view.viewportDidLayout = { [weak self] viewportSize in
                self?.previewDidLayout(viewportSize)
            }
            view.previewTapHandler = { [weak self] previewPoint in
                self?.selectAutomaticTarget(at: previewPoint)
            }
            view.automaticallyConfigureSession = false
            view.session.delegate = self
            view.session.delegateQueue = processingQueue
            configureSession()
        }

        @MainActor
        func stop() {
            endLifecycle()
            isAttached = false
            arView?.viewportDidLayout = nil
            arView?.previewTapHandler = nil
            arView?.targetMarkerPoint = nil
            arView?.projectedGuidedOverlay = .empty
            arView?.session.pause()
            arView?.session.delegate = nil
            processingQueue.async { [weak self] in
                guard let self, activeLifecycleGeneration() == nil else { return }
                capture = nil
                pendingCameraZoom = nil
                targetTrackingSnapshot = nil
                captureVisualSnapshot = CaptureVisualSnapshot(
                    targetLock: nil,
                    targetPrompt: nil,
                    guidedOverlay: .empty
                )
                targetFrameAuthorityTracker.reset()
                pendingGuidedCapture = nil
                guidedFrameRequestTracker.synchronize(nil)
                previewReadinessNeeded = false
            }
            scannerState?.clearGuidedCapture(for: .teardown)
            setCurrentPreviewViewportSize(nil)
            latestPreviewViewportSize = nil
            arView = nil
        }

        @MainActor
        func synchronizeCaptureState(
            targetLock: TargetLock?,
            targetPrompt: PhotoTargetSelectionPrompt?,
            targetSubject: TargetLockSubject,
            cameraEvidenceReacquisitionID: Int,
            guidedRequest: GuidedBoxCaptureRequest?,
            guidedOverlay: GuidedBoxOverlay
        ) {
            let targetSnapshot = targetLock.flatMap { lock in
                lock.captureContext.map { _ in
                    TargetTrackingSnapshot(
                        lock: lock,
                        subject: targetSubject,
                        cameraEvidenceReacquisitionID:
                            cameraEvidenceReacquisitionID
                    )
                }
            }
            processingQueue.async { [weak self] in
                guard let self else { return }
                captureVisualSnapshot = CaptureVisualSnapshot(
                    targetLock: targetLock,
                    targetPrompt: targetPrompt,
                    guidedOverlay: guidedOverlay
                )
                if targetTrackingSnapshot != targetSnapshot {
                    targetTrackingSnapshot = targetSnapshot
                    if let targetSnapshot {
                        targetFrameAuthorityTracker.synchronize(
                            identity: targetSnapshot.lock.identity,
                            cameraEvidenceReacquisitionID:
                                targetSnapshot.cameraEvidenceReacquisitionID
                        )
                    } else {
                        targetFrameAuthorityTracker.reset()
                    }
                    if let activeCapture = capture,
                       let authority = activeCapture.automaticAuthority,
                       authority.cameraEvidenceReacquisitionID
                            != cameraEvidenceReacquisitionID {
                        capture = nil
                    }
                }

                let previousGuidedRequest =
                    guidedFrameRequestTracker.pendingRequest
                guidedFrameRequestTracker.synchronize(guidedRequest)
                guard previousGuidedRequest != guidedRequest else { return }
                pendingGuidedCapture = guidedRequest.map { request in
                    let now = CACurrentMediaTime()
                    return PendingGuidedCapture(
                        request: request,
                        attemptGate: ScannerGuidedFrameAttemptGate(
                            startedAt: now,
                            maximumWait: Self.maximumGuidedCaptureWait,
                            maximumFailedSamples:
                                Self.maximumGuidedFailedSamples
                        ),
                        settledFrameGate: SettledFrameCaptureGate(
                            requestedAt: now,
                            policy: Self.settledFramePolicy
                        )
                    )
                }
            }
        }

        @MainActor
        private func previewDidLayout(_ viewportSize: SIMD2<Float>) {
            guard viewportSize.x.isFinite,
                  viewportSize.y.isFinite,
                  viewportSize.x > 0,
                  viewportSize.y > 0 else {
                return
            }
            setCurrentPreviewViewportSize(viewportSize)
            latestPreviewViewportSize = viewportSize
            markPreviewNeedsReadiness()
        }

        @MainActor
        private func selectAutomaticTarget(at previewPoint: SIMD2<Float>) {
            guard let state = scannerState,
                  state.measurementMode == .automaticPhotos,
                  let arView,
                  let frame = arView.session.currentFrame else {
                return
            }
            let viewportSize = SIMD2<Float>(
                Float(arView.bounds.width),
                Float(arView.bounds.height)
            )
            guard viewportSize.x > 0,
                  viewportSize.y > 0 else {
                return
            }
            let displayTransform = frame.displayTransform(
                for: .portrait,
                viewportSize: arView.bounds.size
            )
            guard let rawImagePoint =
                    ScannerTargetProjection.normalizedImagePoint(
                        previewPoint: previewPoint,
                        viewportSize: viewportSize,
                        displayTransform: displayTransform
                    ) else {
                return
            }
            _ = state.selectAutomaticTarget(
                rawCameraNormalizedPoint: rawImagePoint
            )
        }

        private func setCurrentPreviewViewportSize(_ viewportSize: SIMD2<Float>?) {
            previewViewportLock.lock()
            self.previewViewportSize = viewportSize
            previewViewportLock.unlock()
        }

        private func currentPreviewViewportSize() -> SIMD2<Float>? {
            previewViewportLock.lock()
            defer { previewViewportLock.unlock() }
            return previewViewportSize
        }

        private func markPreviewNeedsReadiness() {
            processingQueue.async { [weak self] in
                self?.previewReadinessNeeded = true
            }
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

        private struct PreviewRunToken: Equatable, Sendable {
            let lifecycleGeneration: Int
            let previewRunGeneration: Int
            let minimumFrameTimestamp: TimeInterval?
        }

        private func beginPreviewRun(after frameTimestamp: TimeInterval?) -> PreviewRunToken? {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            guard lifecycleIsAttached else { return nil }
            previewRunGeneration += 1
            previewRunMinimumFrameTimestamp = frameTimestamp?.isFinite == true
                ? frameTimestamp
                : nil
            return PreviewRunToken(
                lifecycleGeneration: lifecycleGeneration,
                previewRunGeneration: previewRunGeneration,
                minimumFrameTimestamp: previewRunMinimumFrameTimestamp
            )
        }

        private func activePreviewRunToken() -> PreviewRunToken? {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            guard lifecycleIsAttached else { return nil }
            return PreviewRunToken(
                lifecycleGeneration: lifecycleGeneration,
                previewRunGeneration: previewRunGeneration,
                minimumFrameTimestamp: previewRunMinimumFrameTimestamp
            )
        }

        private func isPreviewRunActive(_ token: PreviewRunToken) -> Bool {
            lifecycleLock.lock()
            defer { lifecycleLock.unlock() }
            return lifecycleIsAttached
                && lifecycleGeneration == token.lifecycleGeneration
                && previewRunGeneration == token.previewRunGeneration
        }

        @MainActor
        func handleRequests(
            previewRequestID: Int,
            captureRequestID: Int,
            cameraZoomRequestID: Int,
            cameraZoom: ScannerCameraZoom,
            guidedCaptureIntentID: Int
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

            if guidedCaptureIntentID != lastGuidedCaptureIntentID {
                lastGuidedCaptureIntentID = guidedCaptureIntentID
                beginGuidedCaptureFromCurrentPose()
            }
        }

        @MainActor
        private func beginGuidedCaptureFromCurrentPose() {
            guard let state = scannerState,
                  state.measurementMode == .guidedCorners,
                  let frame = arView?.session.currentFrame,
                  case .normal = frame.camera.trackingState,
                  let pose = guidedFrameSampler.capturePose(
                      from: frame.camera.transform
                  ),
                  let request = state.beginGuidedCapture(
                      requestedPose: pose
                  ) else {
                return
            }

            processingQueue.async { [weak self] in
                guard let self else { return }
                guidedFrameRequestTracker.synchronize(request)
                let now = CACurrentMediaTime()
                pendingGuidedCapture = PendingGuidedCapture(
                    request: request,
                    attemptGate: ScannerGuidedFrameAttemptGate(
                        startedAt: now,
                        maximumWait: Self.maximumGuidedCaptureWait,
                        maximumFailedSamples: Self.maximumGuidedFailedSamples
                    ),
                    settledFrameGate: SettledFrameCaptureGate(
                        requestedAt: now,
                        policy: Self.settledFramePolicy
                    )
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
            markPreviewNeedsReadiness()
            _ = beginPreviewRun(after: arView?.session.currentFrame?.timestamp)
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

                let previousSnapshot = cameraZoomSnapshot()
                guard let baselineNormalizedFocalLength = latestCameraNormalizedFocalLength,
                      previousSnapshot.appliedDisplayFactor != nil else {
                    publishCameraZoomFailure(
                        cameraZoomSnapshot(),
                        requestID: requestID,
                        measurementSeriesID: measurementSeriesID,
                        lifecycleGeneration: lifecycleGeneration
                    )
                    return
                }
                let previousZoom = previousSnapshot.selectedZoom
                let confirmedReferenceNormalizedFocalLength =
                    confirmedCameraNormalizedFocalLengths[zoom]

                var zoomWasApplied = false
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
                        zoomWasApplied = true
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
                      zoomWasApplied else { return }
                cameraZoomApplicationSequence += 1
                pendingCameraZoom = PendingCameraZoom(
                    applicationID: cameraZoomApplicationSequence,
                    lifecycleGeneration: lifecycleGeneration,
                    requestID: requestID,
                    measurementSeriesID: measurementSeriesID,
                    previousZoom: previousZoom,
                    zoom: zoom,
                    baselineNormalizedFocalLength: baselineNormalizedFocalLength,
                    confirmedReferenceNormalizedFocalLength:
                        confirmedReferenceNormalizedFocalLength,
                    confirmationGate: ScannerCameraZoomConfirmationGate(
                        minimumFrameSequence: cameraFrameSequence
                    )
                )
                Self.calibrationLogger.notice(
                    "camera_zoom_requested request_id=\(requestID, privacy: .public) from=\(previousZoom.label, privacy: .public) to=\(zoom.label, privacy: .public) baseline_focal=\(baselineNormalizedFocalLength, privacy: .public) target_reference=\(confirmedReferenceNormalizedFocalLength ?? -1, privacy: .public)"
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
                restoreCameraZoom(pending.previousZoom)
                let snapshot = cameraZoomSnapshot()
                Self.calibrationLogger.error(
                    "camera_zoom_timeout request_id=\(pending.requestID, privacy: .public) observed_frames=\(pending.observedFrameCount, privacy: .public) tracking_not_normal=\(pending.trackingNotNormalCount, privacy: .public) missing_depth=\(pending.missingDepthCount, privacy: .public) snapshot_unavailable=\(pending.snapshotUnavailableCount, privacy: .public) factor_mismatch=\(pending.factorMismatchCount, privacy: .public) frame_fov_mismatch=\(pending.frameFieldOfViewMismatchCount, privacy: .public) matched_frames=\(pending.confirmationGate.matchingFrameCount, privacy: .public) baseline_focal=\(pending.baselineNormalizedFocalLength, privacy: .public) current_focal=\(self.latestCameraNormalizedFocalLength ?? -1, privacy: .public)"
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
                  state.shouldReapplyCameraZoomAfterSessionRun else {
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
                markPreviewNeedsReadiness()
                _ = beginPreviewRun(after: arView?.session.currentFrame?.timestamp)
                arView?.session.run(sessionConfiguration)
                _ = reapplyCameraZoomAfterSessionRun()
            } else {
                markPreviewNeedsReadiness()
            }
        }

        @MainActor
        func startCapture() {
            guard let state = scannerState,
                  case .scanning = state.phase else {
                return
            }
            guard depthSupported else {
                automaticCaptureAuthorityTerminator.terminatePending(in: state)
                scannerState?.phase = .unsupported(
                    "LiDAR scene depth is not available on this device."
                )
                return
            }

            if previewLifecycle.scanRequested() == .resume,
               let sessionConfiguration {
                automaticCaptureAuthorityTerminator.terminatePending(in: state)
                markPreviewNeedsReadiness()
                _ = beginPreviewRun(after: arView?.session.currentFrame?.timestamp)
                arView?.session.run(sessionConfiguration)
                _ = reapplyCameraZoomAfterSessionRun()
                state.phase = .checkingSupport
                return
            }

            let requestID = requestTracker.lastCaptureRequestID
            let measurementSeriesID = scannerState?.measurementSeriesID ?? 0
            guard let previewViewportSize = latestPreviewViewportSize else {
                automaticCaptureAuthorityTerminator.terminatePending(in: state)
                state.phase = .checkingSupport
                markPreviewNeedsReadiness()
                return
            }

            beginCapture(
                requestID: requestID,
                measurementSeriesID: measurementSeriesID,
                previewViewportSize: previewViewportSize
            )
        }

        @MainActor
        private func beginCapture(
            requestID: Int,
            measurementSeriesID: Int,
            previewViewportSize: SIMD2<Float>
        ) {
            guard let state = scannerState,
                  case .scanning = state.phase,
                  state.captureRequestID == requestID,
                  state.measurementSeriesID == measurementSeriesID else {
                return
            }
            let now = CACurrentMediaTime()
            let cameraZoom = state.cameraZoom
            let automaticAuthority = state.pendingAutomaticCaptureAuthority
            let targetLock = automaticAuthority.flatMap { authority in
                state.activeTargetLock.flatMap { lock in
                    lock.identity == authority.identity ? lock : nil
                }
            }
            let targetSubject = state.measurementSubject
            let photoMeasurement = state.automaticPhotoMeasurement
            state.estimate = nil
            state.phase = .scanning(progress: 0)

            processingQueue.async { [weak self] in
                self?.capture = CaptureAccumulator(
                    requestID: requestID,
                    measurementSeriesID: measurementSeriesID,
                    previewViewportSize: previewViewportSize,
                    cameraZoom: cameraZoom,
                    automaticAuthority: automaticAuthority,
                    targetLock: targetLock,
                    targetSubject: targetSubject,
                    photoMeasurement: photoMeasurement,
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
                scannerState?.beginCameraZoomAvailabilityDiscovery()
            }
            scannerState?.phase = depthSupported
                ? .checkingSupport
                : .unsupported("This app needs a LiDAR-capable iPhone or iPad.")
            if depthSupported {
                markPreviewNeedsReadiness()
            }
            _ = beginPreviewRun(after: arView?.session.currentFrame?.timestamp)
            arView?.session.run(configuration)
            if depthSupported {
                _ = reapplyCameraZoomAfterSessionRun()
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // ARKit calls this method on processingQueue; never move ARFrame or
            // its pixel buffers across another concurrency boundary.
            cameraFrameSequence &+= 1
            latestCameraNormalizedFocalLength = normalizedFocalLength(for: frame)
            publishInitialCameraZoomIfNeeded(with: frame)
            confirmPendingCameraZoom(
                with: frame,
                frameSequence: cameraFrameSequence
            )
            publishPreviewReadyIfPossible(with: frame)
            publishProjectedCaptureGuides(with: frame)
            observeLiveTargetFrameIfNeeded(with: frame)
            if processPendingGuidedCaptureIfNeeded(with: frame) {
                return
            }

            guard var activeCapture = capture else { return }
            guard case .normal = frame.camera.trackingState else {
                activeCapture.settledFrameGate.trackingWasNotNormal()
                if CACurrentMediaTime() - activeCapture.settledFrameGate.requestedAt
                    >= Self.maximumTrackingWait {
                    capture = nil
                    publishFailure(
                        "Camera tracking wasn't ready. Hold steady and try the photo again.",
                        requestID: activeCapture.requestID,
                        measurementSeriesID: activeCapture.measurementSeriesID,
                        automaticAuthority: activeCapture.automaticAuthority
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
            guard let cameraProvenance = cameraCaptureProvenance(
                from: frame,
                expectedZoom: activeCapture.cameraZoom
            ) else {
                publishFailure(
                    "The camera calibration changed before the photo. Hold steady and retake it.",
                    requestID: activeCapture.requestID,
                    measurementSeriesID: activeCapture.measurementSeriesID,
                    automaticAuthority: activeCapture.automaticAuthority
                )
                return
            }
            activeCapture.cameraProvenance = cameraProvenance
            publishProgress(0.5, requestID: activeCapture.requestID)
            // The action bar can resize the live preview after the tap. Measure
            // and render against the viewport visible for this settled frame,
            // not the dimensions cached before SwiftUI finished that relayout.
            let settledPreviewViewportSize = currentPreviewViewportSize()
                ?? activeCapture.previewViewportSize

            var exactPrompt = activeCapture.automaticAuthority?.prompt
            if let authority = activeCapture.automaticAuthority,
               let lockedContext = authority.lockedContext {
                guard let targetLock = activeCapture.targetLock,
                      targetLock.captureContext == lockedContext else {
                    let failure = TargetLockFrameValidationFailure
                        .invalidTargetEvidence
                    rejectAutomaticTargetFrame(
                        failure,
                        capture: activeCapture,
                        authority: authority
                    )
                    return
                }
                let exactSample = exactTargetFrameSample(
                    from: frame,
                    lock: targetLock,
                    viewportSize: settledPreviewViewportSize
                )
                let validation = targetFrameValidator.validate(
                    lock: targetLock,
                    subject: activeCapture.targetSubject,
                    evidence: exactSample.evidence
                )
                let authoritativeValidation =
                    targetFrameAuthorityTracker.exactFrameValidation(
                        validation,
                        identity: authority.identity,
                        cameraEvidenceReacquisitionID:
                            authority.cameraEvidenceReacquisitionID
                    )
                guard case .valid = authoritativeValidation,
                      let rawImagePoint = exactSample.rawImagePoint else {
                    let failure: TargetLockFrameValidationFailure =
                        if case .rejected(let reason) = authoritativeValidation {
                            reason
                        } else {
                            .projectionUnavailable
                        }
                    rejectAutomaticTargetFrame(
                        failure,
                        capture: activeCapture,
                        authority: authority
                    )
                    return
                }
                // The anchor projection on this exact settled frame becomes the
                // immutable prompt shared by both Vision passes below.
                exactPrompt = .target(normalizedImagePoint: rawImagePoint)
            }

            let photoProcessor = exactPrompt.map {
                ScannerAutomaticPhotoFrameProcessor(
                    prompt: $0,
                    measurement: activeCapture.photoMeasurement
                )
            }
            // Freeze the exact RGB/depth pair being measured before Vision runs.
            session.pause()

            switch sampleSingleShotFrame(
                from: frame,
                processor: photoProcessor
            ) {
            case .accepted(let points, let diagnostics, let outline, let route):
                let objectOverlay = outline.flatMap {
                    measurementObjectOverlay(
                        from: $0,
                        frame: frame,
                        previewViewportSize: settledPreviewViewportSize
                    )
                }
                if let objectOverlay,
                   let previewFramingFailure = objectOverlay.previewFramingFailure(
                       in: settledPreviewViewportSize,
                       protectedInsetFraction: Self.protectedPreviewInsetFraction
                   ) {
                    let photoFailure = SingleShotCaptureFailure.photo(
                        previewFramingFailure
                    )
                    activeCapture.lastPhotoFailure = photoFailure
                    activeCapture.lastCalibration = diagnostics
                    activeCapture.rejectedFrameCount = 1
                    activeCapture.lastRejection = .insufficientSurfaceEvidence
                    apply(route, to: &activeCapture)
                    logCalibrationSummary(
                        activeCapture,
                        result: .failure(.targetRejected(.insufficientSurfaceEvidence))
                    )
                    publishFailure(
                        ScannerPhotoFailureCopy.message(
                            for: photoFailure,
                            fallbackResult: route.fallbackResult
                        ),
                        requestID: activeCapture.requestID,
                        measurementSeriesID: activeCapture.measurementSeriesID,
                        automaticAuthority: activeCapture.automaticAuthority
                    )
                    return
                }
                activeCapture.worldPoints = points
                activeCapture.frameCount = 1
                activeCapture.lastCalibration = diagnostics
                activeCapture.objectOverlay = objectOverlay
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
                    measurementSeriesID: activeCapture.measurementSeriesID,
                    automaticAuthority: activeCapture.automaticAuthority
                )
            }
        }

        private func observeLiveTargetFrameIfNeeded(with frame: ARFrame) {
            guard capture == nil,
                  pendingCameraZoom == nil,
                  let snapshot = targetTrackingSnapshot else {
                return
            }

            let validation: TargetLockFrameValidation
            let evidence: TargetLockFrameEvidence?
            if case .normal = frame.camera.trackingState,
               let viewportSize = currentPreviewViewportSize() {
                let sample = exactTargetFrameSample(
                    from: frame,
                    lock: snapshot.lock,
                    viewportSize: viewportSize
                )
                evidence = sample.evidence
                validation = targetFrameValidator.validate(
                    lock: snapshot.lock,
                    subject: snapshot.subject,
                    evidence: sample.evidence
                )
            } else {
                evidence = nil
                validation = .rejected(.cameraPoseUnavailable)
            }

            _ = targetFrameAuthorityTracker.observe(
                validation,
                identity: snapshot.lock.identity,
                cameraEvidenceReacquisitionID:
                    snapshot.cameraEvidenceReacquisitionID
            )
            publishLiveTargetValidation(
                validation,
                evidence: evidence,
                snapshot: snapshot
            )
        }

        private func publishProjectedCaptureGuides(with frame: ARFrame) {
            guard let viewportSize = currentPreviewViewportSize(),
                  viewportSize.x > 0,
                  viewportSize.y > 0 else {
                return
            }
            let snapshot = captureVisualSnapshot
            let targetMarkerPoint: SIMD2<Float>?
            if let worldAnchor = snapshot.targetLock?.worldAnchor {
                targetMarkerPoint = normalizedPreviewPoint(
                    worldPoint: worldAnchor,
                    frame: frame,
                    viewportSize: viewportSize
                )
            } else if case .target(let rawImagePoint) = snapshot.targetPrompt {
                let transform = frame.displayTransform(
                    for: .portrait,
                    viewportSize: CGSize(
                        width: CGFloat(viewportSize.x),
                        height: CGFloat(viewportSize.y)
                    )
                )
                let mapped = CGPoint(
                    x: CGFloat(rawImagePoint.x),
                    y: CGFloat(rawImagePoint.y)
                ).applying(transform)
                let point = SIMD2<Float>(Float(mapped.x), Float(mapped.y))
                targetMarkerPoint = point.x.isFinite && point.y.isFinite
                    ? point
                    : nil
            } else {
                targetMarkerPoint = nil
            }

            let markers = snapshot.guidedOverlay.markers.compactMap { marker in
                normalizedPreviewPoint(
                    worldPoint: marker.worldPosition,
                    frame: frame,
                    viewportSize: viewportSize
                ).map {
                    ScannerProjectedGuidedMarker(
                        number: marker.number,
                        point: marker.point,
                        normalizedPreviewPoint: $0
                    )
                }
            }
            let lines: [ScannerProjectedGuidedLine] =
                snapshot.guidedOverlay.lines.compactMap { line in
                guard let reference = normalizedPreviewPoint(
                    worldPoint: line.referenceWorldPosition,
                    frame: frame,
                    viewportSize: viewportSize
                ), let endpoint = normalizedPreviewPoint(
                    worldPoint: line.endpointWorldPosition,
                    frame: frame,
                    viewportSize: viewportSize
                ) else {
                    return nil
                }
                return ScannerProjectedGuidedLine(
                    reference: line.reference,
                    endpoint: line.endpoint,
                    normalizedReferencePoint: reference,
                    normalizedEndpointPoint: endpoint
                )
            }
            let guidedOverlay = ScannerProjectedGuidedOverlay(
                markers: markers,
                lines: lines
            )

            Task { @MainActor [weak self] in
                guard let self, isAttached, let arView else { return }
                arView.targetMarkerPoint = targetMarkerPoint
                arView.projectedGuidedOverlay = guidedOverlay
            }
        }

        private func normalizedPreviewPoint(
            worldPoint: SIMD3<Float>,
            frame: ARFrame,
            viewportSize: SIMD2<Float>
        ) -> SIMD2<Float>? {
            guard worldPoint.x.isFinite,
                  worldPoint.y.isFinite,
                  worldPoint.z.isFinite else {
                return nil
            }
            let point = frame.camera.projectPoint(
                worldPoint,
                orientation: .portrait,
                viewportSize: CGSize(
                    width: CGFloat(viewportSize.x),
                    height: CGFloat(viewportSize.y)
                )
            )
            let normalized = SIMD2<Float>(
                Float(point.x) / viewportSize.x,
                Float(point.y) / viewportSize.y
            )
            guard normalized.x.isFinite, normalized.y.isFinite else { return nil }
            return normalized
        }

        /// Isolated handoff for state-owned T03 ambiguity and live revalidation.
        private func rejectAutomaticTargetFrame(
            _ failure: TargetLockFrameValidationFailure,
            capture: CaptureAccumulator,
            authority: AutomaticCaptureAuthority
        ) {
            targetFrameAuthorityTracker.invalidate()
            publishAutomaticTargetFrameRejection(
                failure,
                requestID: capture.requestID,
                measurementSeriesID: capture.measurementSeriesID,
                authority: authority
            )
        }

        private func publishAutomaticTargetFrameRejection(
            _ failure: TargetLockFrameValidationFailure,
            requestID: Int,
            measurementSeriesID: Int,
            authority: AutomaticCaptureAuthority
        ) {
            let diagnosticCopy = ScannerPhotoFailureCopy.message(
                for: .targetLock(failure)
            )
            Task { @MainActor [weak self] in
                guard let self,
                      let state = scannerState,
                      state.captureRequestID == requestID,
                      state.measurementSeriesID == measurementSeriesID,
                      state.rejectAutomaticCapture(
                          authority: authority,
                          failure: failure
                      ) else {
                    return
                }
                Self.calibrationLogger.notice(
                    "automatic_target_rejected request_id=\(requestID, privacy: .public) measurement_series_id=\(measurementSeriesID, privacy: .public) failure=\(String(describing: failure), privacy: .public) copy=\(diagnosticCopy, privacy: .public)"
                )
            }
        }

        private func exactTargetFrameSample(
            from frame: ARFrame,
            lock: TargetLock,
            viewportSize: SIMD2<Float>
        ) -> ExactTargetFrameSample {
            guard let context = lock.captureContext,
                  viewportSize.x.isFinite,
                  viewportSize.y.isFinite,
                  viewportSize.x > 0,
                  viewportSize.y > 0 else {
                return ExactTargetFrameSample(
                    evidence: TargetLockFrameEvidence(
                        identity: lock.identity,
                        projectedPreviewPoint: nil,
                        cameraWorldPosition: nil,
                        observedSurface: nil
                    ),
                    rawImagePoint: nil
                )
            }

            let viewportCGSize = CGSize(
                width: CGFloat(viewportSize.x),
                height: CGFloat(viewportSize.y)
            )
            let projectedPoint = frame.camera.projectPoint(
                context.worldAnchor,
                orientation: .portrait,
                viewportSize: viewportCGSize
            )
            let projectedPreviewPoint = SIMD2<Float>(
                Float(projectedPoint.x),
                Float(projectedPoint.y)
            )
            let displayTransform = frame.displayTransform(
                for: .portrait,
                viewportSize: viewportCGSize
            )
            let rawImagePoint =
                ScannerTargetProjection.normalizedImagePoint(
                    previewPoint: projectedPreviewPoint,
                    viewportSize: viewportSize,
                    displayTransform: displayTransform
                )
            let depthGrid = (frame.smoothedSceneDepth ?? frame.sceneDepth)
                .flatMap(depthGrid(from:))
            let imageResolution = frame.camera.imageResolution
            let evidence = targetFrameEvidenceAdapter.makeEvidence(
                identity: context.identity,
                projectedPreviewPointPixels: projectedPreviewPoint,
                viewportSizePixels: viewportSize,
                rawImagePoint: rawImagePoint,
                grid: depthGrid,
                cameraImageResolutionPixels: SIMD2<Int>(
                    Int(imageResolution.width.rounded()),
                    Int(imageResolution.height.rounded())
                ),
                cameraIntrinsics: frame.camera.intrinsics,
                cameraTransform: frame.camera.transform
            )
            return ExactTargetFrameSample(
                evidence: evidence,
                rawImagePoint: rawImagePoint
            )
        }

        private func publishLiveTargetValidation(
            _ validation: TargetLockFrameValidation,
            evidence: TargetLockFrameEvidence?,
            snapshot: TargetTrackingSnapshot
        ) {
            Task { @MainActor [weak self] in
                guard let state = self?.scannerState,
                      state.activeTargetIdentity == snapshot.lock.identity,
                      state.cameraEvidenceReacquisitionID
                        == snapshot.cameraEvidenceReacquisitionID else {
                    return
                }
                if let evidence {
                    _ = state.receiveAutomaticTargetFrameEvidence(evidence)
                } else {
                    _ = state.observeAutomaticTargetValidation(
                        validation,
                        identity: snapshot.lock.identity
                    )
                }
            }
        }

        /// Returns true while a guided request owns the exact-frame path, even
        /// if the current frame still needs to settle or regain usable depth.
        private func processPendingGuidedCaptureIfNeeded(
            with frame: ARFrame
        ) -> Bool {
            guard var pendingGuidedCapture else { return false }
            guard capture == nil, pendingCameraZoom == nil else { return true }
            let now = CACurrentMediaTime()
            if pendingGuidedCapture.attemptGate.hasExpired(at: now) {
                finishGuidedCaptureFailure(
                    .depthUnavailable,
                    pending: pendingGuidedCapture
                )
                return true
            }
            guard case .normal = frame.camera.trackingState else {
                pendingGuidedCapture.settledFrameGate.trackingWasNotNormal()
                self.pendingGuidedCapture = pendingGuidedCapture
                return true
            }

            switch pendingGuidedCapture.settledFrameGate.frameArrived(
                at: now
            ) {
            case .wait:
                self.pendingGuidedCapture = pendingGuidedCapture
                return true
            case .completed:
                self.pendingGuidedCapture = nil
                return true
            case .capture:
                break
            }

            guard let viewportSize = currentPreviewViewportSize() else {
                handleGuidedSamplingFailure(
                    .projectionUnavailable,
                    pending: pendingGuidedCapture
                )
                return true
            }
            let previewCenter = viewportSize / 2
            let displayTransform = frame.displayTransform(
                for: .portrait,
                viewportSize: CGSize(
                    width: CGFloat(viewportSize.x),
                    height: CGFloat(viewportSize.y)
                )
            )
            guard let rawImagePoint =
                    ScannerTargetProjection.normalizedImagePoint(
                        previewPoint: previewCenter,
                        viewportSize: viewportSize,
                        displayTransform: displayTransform
                    ) else {
                handleGuidedSamplingFailure(
                    .projectionUnavailable,
                    pending: pendingGuidedCapture
                )
                return true
            }
            let grid = (frame.smoothedSceneDepth ?? frame.sceneDepth)
                .flatMap(depthGrid(from:))
            let imageResolution = frame.camera.imageResolution
            let result = guidedFrameSampler.sample(
                request: pendingGuidedCapture.request,
                normalizedImagePoint: rawImagePoint,
                grid: grid,
                cameraImageResolutionPixels: SIMD2<Int>(
                    Int(imageResolution.width.rounded()),
                    Int(imageResolution.height.rounded())
                ),
                cameraIntrinsics: frame.camera.intrinsics,
                cameraTransform: frame.camera.transform,
                gravity: SIMD3<Float>(0, -1, 0)
            )
            guard case .success(let sample) = result else {
                let failure: ScannerGuidedFrameSamplingFailure =
                    if case .failure(let reason) = result {
                        reason
                    } else {
                        .depthUnavailable
                    }
                handleGuidedSamplingFailure(
                    failure,
                    pending: pendingGuidedCapture
                )
                return true
            }
            guard guidedFrameRequestTracker.consumeCompletion(
                for: pendingGuidedCapture.request
            ) else {
                self.pendingGuidedCapture = nil
                return true
            }
            self.pendingGuidedCapture = nil
            publishGuidedFrameSample(
                sample,
                request: pendingGuidedCapture.request
            )
            return true
        }

        private func handleGuidedSamplingFailure(
            _ failure: ScannerGuidedFrameSamplingFailure,
            pending: PendingGuidedCapture
        ) {
            var next = pending
            let now = CACurrentMediaTime()
            guard next.attemptGate.recordFailure(at: now) == .retry else {
                finishGuidedCaptureFailure(failure, pending: pending)
                return
            }
            next.settledFrameGate = SettledFrameCaptureGate(
                requestedAt: now,
                policy: Self.settledFramePolicy
            )
            pendingGuidedCapture = next
        }

        private func finishGuidedCaptureFailure(
            _ failure: ScannerGuidedFrameSamplingFailure,
            pending: PendingGuidedCapture
        ) {
            guard guidedFrameRequestTracker.consumeCompletion(
                for: pending.request
            ) else {
                pendingGuidedCapture = nil
                return
            }
            pendingGuidedCapture = nil
            publishGuidedFrameFailure(
                failure,
                request: pending.request
            )
        }

        private func publishGuidedFrameSample(
            _ sample: GuidedBoxPointSample,
            request: GuidedBoxCaptureRequest
        ) {
            Task { @MainActor [weak self] in
                guard let state = self?.scannerState,
                      state.guidedCaptureSession?.pendingRequest == request else {
                    return
                }
                _ = state.consumeGuidedCapture(sample)
            }
        }

        private func publishGuidedFrameFailure(
            _ failure: ScannerGuidedFrameSamplingFailure,
            request: GuidedBoxCaptureRequest
        ) {
            Task { @MainActor [weak self] in
                guard let self,
                      let state = scannerState,
                      state.guidedCaptureSession?.pendingRequest == request else {
                    return
                }
                _ = state.guidedCaptureFailed(
                    request: request,
                    failure: failure.captureFailure
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
                if snapshot.appliedDisplayFactor != nil,
                   let normalizedFocalLength = normalizedFocalLength(for: frame) {
                    confirmedCameraNormalizedFocalLengths[snapshot.selectedZoom] =
                        normalizedFocalLength
                }
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

        private func confirmPendingCameraZoom(
            with frame: ARFrame,
            frameSequence: UInt64
        ) {
            guard var pendingCameraZoom else { return }
            guard isLifecycleActive(pendingCameraZoom.lifecycleGeneration) else {
                self.pendingCameraZoom = nil
                return
            }
            pendingCameraZoom.observedFrameCount += 1
            let trackingIsNormal: Bool = if case .normal = frame.camera.trackingState {
                true
            } else {
                false
            }
            if !trackingIsNormal {
                pendingCameraZoom.trackingNotNormalCount += 1
            }
            let hasDepth = frame.smoothedSceneDepth ?? frame.sceneDepth != nil
            if trackingIsNormal, !hasDepth {
                pendingCameraZoom.missingDepthCount += 1
            }
            let hasNormalDepth = trackingIsNormal && hasDepth
            let snapshot = hasNormalDepth ? cameraZoomSnapshot() : .unavailable
            if hasNormalDepth, snapshot.appliedDisplayFactor == nil {
                pendingCameraZoom.snapshotUnavailableCount += 1
            }
            let wasApplied = snapshot.appliedDisplayFactor.map {
                abs($0 - pendingCameraZoom.zoom.rawValue)
                    <= Self.cameraZoomConfirmationTolerance
            } ?? false
            if snapshot.appliedDisplayFactor != nil, !wasApplied {
                pendingCameraZoom.factorMismatchCount += 1
            }
            let currentNormalizedFocalLength = normalizedFocalLength(for: frame)
            let frameFieldOfViewMatches = currentNormalizedFocalLength.map {
                ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                    from: pendingCameraZoom.previousZoom,
                    baselineNormalizedFocalLength:
                        pendingCameraZoom.baselineNormalizedFocalLength,
                    to: pendingCameraZoom.zoom,
                    currentNormalizedFocalLength: $0,
                    confirmedReferenceNormalizedFocalLength:
                        pendingCameraZoom.confirmedReferenceNormalizedFocalLength
                )
            } ?? false
            if hasNormalDepth, !frameFieldOfViewMatches {
                pendingCameraZoom.frameFieldOfViewMismatchCount += 1
            }
            guard pendingCameraZoom.confirmationGate.observe(
                frameSequence: frameSequence,
                hasNormalDepth: hasNormalDepth,
                zoomMatches: wasApplied && frameFieldOfViewMatches
            ) else {
                self.pendingCameraZoom = pendingCameraZoom
                return
            }

            self.pendingCameraZoom = nil
            if let currentNormalizedFocalLength {
                confirmedCameraNormalizedFocalLengths[pendingCameraZoom.zoom] =
                    currentNormalizedFocalLength
            }
            didPublishInitialCameraZoom = true
            Self.calibrationLogger.notice(
                "camera_zoom_applied display=\(pendingCameraZoom.zoom.label, privacy: .public) confirmed_frames=\(pendingCameraZoom.confirmationGate.matchingFrameCount, privacy: .public) baseline_focal=\(pendingCameraZoom.baselineNormalizedFocalLength, privacy: .public) confirmed_focal=\(currentNormalizedFocalLength ?? -1, privacy: .public)"
            )
            publishCameraZoomSnapshot(
                snapshot,
                requestID: pendingCameraZoom.requestID,
                measurementSeriesID: pendingCameraZoom.measurementSeriesID,
                lifecycleGeneration: pendingCameraZoom.lifecycleGeneration,
                confirmsExplicitSelection: true
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

        private func normalizedFocalLength(for frame: ARFrame) -> Double? {
            ScannerCameraFrameZoomPolicy.normalizedFocalLength(
                focalLengthPixels: Double(frame.camera.intrinsics.columns.0.x),
                imageWidthPixels: Double(frame.camera.imageResolution.width)
            )
        }

        private func cameraCaptureProvenance(
            from frame: ARFrame,
            expectedZoom: ScannerCameraZoom
        ) -> ScannerCameraCaptureProvenance? {
            let snapshot = cameraZoomSnapshot()
            let appliedDisplayZoomFactor: Double
            if snapshot.usesConfigurableDevice {
                guard snapshot.selectedZoom == expectedZoom,
                      let appliedFactor = snapshot.appliedDisplayFactor else {
                    return nil
                }
                appliedDisplayZoomFactor = appliedFactor
            } else {
                guard expectedZoom == .standard else { return nil }
                appliedDisplayZoomFactor = ScannerCameraZoom.standard.rawValue
            }

            let imageResolution = frame.camera.imageResolution
            guard imageResolution.width.isFinite,
                  imageResolution.height.isFinite else {
                return nil
            }
            return ScannerCameraCaptureProvenance(
                cameraZoom: expectedZoom,
                appliedDisplayZoomFactor: appliedDisplayZoomFactor,
                intrinsics: frame.camera.intrinsics,
                imageResolutionPixels: SIMD2<Int>(
                    Int(imageResolution.width.rounded()),
                    Int(imageResolution.height.rounded())
                )
            )
        }

        private func restoreCameraZoom(_ zoom: ScannerCameraZoom) {
            guard let device = ARWorldTrackingConfiguration
                .configurableCaptureDeviceForPrimaryCamera else {
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard let factor = ScannerCameraZoomPolicy.deviceFactor(
                    for: zoom,
                    displayMultiplier: Double(device.displayVideoZoomFactorMultiplier)
                ), factor >= Double(device.minAvailableVideoZoomFactor),
                   factor <= Double(device.maxAvailableVideoZoomFactor) else {
                    return
                }
                device.videoZoomFactor = CGFloat(factor)
            } catch {
                Self.calibrationLogger.error(
                    "camera_zoom_restore_failed zoom=\(zoom.label, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
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
            // AVCapture depth-data delivery is a separate pipeline from ARKit
            // scene depth. Limit candidates to factors the live configurable
            // capture device can apply, then let the existing AR-frame gate
            // prove tracking, scene depth, and the visible field-of-view change.
            return ScannerCameraZoomPolicy.supportedZooms(
                displayMultiplier: multiplier,
                minDeviceFactor: Double(device.minAvailableVideoZoomFactor),
                maxDeviceFactor: Double(device.maxAvailableVideoZoomFactor)
            )
        }

        private func publishCameraZoomSnapshot(
            _ snapshot: CameraZoomSnapshot,
            requestID: Int?,
            measurementSeriesID: Int? = nil,
            lifecycleGeneration: Int,
            confirmsExplicitSelection: Bool = false
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
                    usesConfigurableDevice: snapshot.usesConfigurableDevice,
                    confirmsExplicitSelection: confirmsExplicitSelection
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
                state.cameraZoomApplicationFailed(
                    message: "Camera zoom could not be confirmed with depth. Retake the photo to try again."
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
            let automaticAuthority = capture?.automaticAuthority
            capture = nil
            pendingCameraZoom = nil
            pendingGuidedCapture = nil
            guidedFrameRequestTracker.synchronize(nil)
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
                resetMeasurementSeries: true,
                automaticAuthority: automaticAuthority,
                guidedLifecycleBoundary: .sessionReset
            )
        }

        func sessionWasInterrupted(_ session: ARSession) {
            let requestID = capture?.requestID
            let automaticAuthority = capture?.automaticAuthority
            capture = nil
            pendingCameraZoom = nil
            pendingGuidedCapture = nil
            guidedFrameRequestTracker.synchronize(nil)
            sessionEventSequence += 1
            publishFailure(
                "The camera was interrupted. Wait for it to return, then scan the item again.",
                requestID: requestID,
                sessionEventSequence: sessionEventSequence,
                resetMeasurementSeries: false,
                automaticAuthority: automaticAuthority,
                guidedLifecycleBoundary: .interruption
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
                    measurementSeriesID: capture.measurementSeriesID,
                    automaticAuthority: capture.automaticAuthority
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
                    measurementSeriesID: capture.measurementSeriesID,
                    automaticAuthority: capture.automaticAuthority
                )
                return
            }

            guard let cameraProvenance = capture.cameraProvenance else {
                publishFailure(
                    "The camera calibration was unavailable for this photo. Hold steady and retake it.",
                    requestID: capture.requestID,
                    measurementSeriesID: capture.measurementSeriesID,
                    automaticAuthority: capture.automaticAuthority
                )
                return
            }

            let angleCapture = ScannerRecordedAngleCapture(
                measurement: MeasurementAngleCapture(
                    evidence: evidence,
                    viewpoint: cameraViewpoint,
                    objectOverlay: capture.objectOverlay
                ),
                cameraProvenance: cameraProvenance
            )

            logCalibrationSummary(capture, result: .success(evidence.estimate))
            publishMeasurementCapture(
                angleCapture,
                requestID: capture.requestID,
                measurementSeriesID: capture.measurementSeriesID,
                automaticAuthority: capture.automaticAuthority
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

        private func sampleSingleShotFrame(
            from frame: ARFrame,
            processor: ScannerAutomaticPhotoFrameProcessor?
        ) -> SingleShotFrameSample {
            guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else {
                return .failed(.sceneDepthUnavailable, nil, .visionMask)
            }
            guard let grid = depthGrid(from: depthData) else {
                return .failed(.depthGridUnreadable, nil, .visionMask)
            }

            let labelMask: PhotoInstanceLabelMask
            do {
                labelMask = try foregroundInstanceLabelMask(
                    from: frame.capturedImage,
                    processor: processor
                )
            } catch let error as PhotoTargetSelectionError {
                return .failed(.targetSelection(error), nil, .visionMask)
            } catch let error as ForegroundMaskAdapterError {
                return frameSample(
                    after: .foreground(error),
                    from: frame,
                    grid: grid,
                    hasExplicitTarget: processor != nil
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
                let pointCloud: PhotoObjectPointCloud
                if let processor {
                    pointCloud = try processor.makePointCloud(
                        labelMask: labelMask,
                        depthGrid: grid,
                        calibration: calibration,
                        protectedEdgeMarginPixels:
                            policy.protectedEdgeMarginPixels
                    )
                } else {
                    pointCloud = try PhotoObjectMeasurement(policy: policy)
                        .makePointCloud(
                            labelMask: labelMask,
                            depthGrid: grid,
                            calibration: calibration
                        )
                }
                let diagnostics = FrameCalibrationDiagnostics(
                    rawRegionPixelCount: pointCloud.maskQuality.selectedPixelCount,
                    retainedRegionPixelCount: pointCloud.depthSupport.supportedSampleCount,
                    regionCoverage: pointCloud.depthSupport.coverage,
                    absoluteUpNormal: nil,
                    elevationAboveFloorMeters: nil,
                    floorEstimate: nil,
                    rigidItemMultiplicityEvaluation:
                        pointCloud.rigidItemMultiplicityEvaluation
                )
                return .accepted(
                    pointCloud.worldPoints,
                    diagnostics,
                    pointCloud.objectOutline,
                    .visionMask
                )
            } catch let error as PhotoTargetSelectionError {
                return .failed(.targetSelection(error), nil, .visionMask)
            } catch let error as PhotoObjectMeasurementError {
                return frameSample(
                    after: .photo(error),
                    from: frame,
                    grid: grid,
                    hasExplicitTarget: processor != nil
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
            frame: ARFrame,
            previewViewportSize: SIMD2<Float>
        ) -> MeasurementObjectOverlay? {
            let imageResolution = frame.camera.imageResolution
            let orientedSize = CGSize(
                width: imageResolution.height,
                height: imageResolution.width
            )
            guard orientedSize.width > 0, orientedSize.height > 0 else { return nil }

            let transform = frame.displayTransform(
                for: .portrait,
                viewportSize: orientedSize
            )

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
                outline: displayOutline,
                capturedPreviewAspectRatio: previewViewportSize.x / previewViewportSize.y
            )
            return overlay.isRenderable ? overlay : nil
        }

        private func publishPreviewReadyIfPossible(with frame: ARFrame) {
            guard previewReadinessNeeded,
                  pendingCameraZoom == nil,
                  let previewRunToken = activePreviewRunToken() else {
                return
            }
            guard ScannerPreviewReadinessPolicy.isFrameFresh(
                timestamp: frame.timestamp,
                after: previewRunToken.minimumFrameTimestamp
            ) else {
                return
            }
            let trackingIsNormal: Bool
            if case .normal = frame.camera.trackingState {
                trackingIsNormal = true
            } else {
                trackingIsNormal = false
            }
            let hasDepth = frame.smoothedSceneDepth != nil || frame.sceneDepth != nil
            guard trackingIsNormal, hasDepth else { return }

            previewReadinessNeeded = false
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard isPreviewRunActive(previewRunToken),
                      isAttached,
                      depthSupported,
                      let state = scannerState,
                      let arView else {
                    markPreviewNeedsReadiness()
                    return
                }
                let viewportSize = SIMD2<Float>(
                    Float(arView.bounds.width),
                    Float(arView.bounds.height)
                )
                guard
                      ScannerPreviewReadinessPolicy.isReady(
                          trackingIsNormal: trackingIsNormal,
                          hasDepth: hasDepth,
                          viewportSize: viewportSize
                ) else {
                    markPreviewNeedsReadiness()
                    return
                }
                setCurrentPreviewViewportSize(viewportSize)
                latestPreviewViewportSize = viewportSize
                _ = state.previewBecameReady()
            }
        }

        private func frameSample(
            after failure: SingleShotCaptureFailure,
            from frame: ARFrame,
            grid: DepthGrid,
            hasExplicitTarget: Bool = false
        ) -> SingleShotFrameSample {
            guard singleShotFrameRoutePolicy.shouldAttemptReticleDepthFallback(
                after: failure,
                hasExplicitTarget: hasExplicitTarget
            ) else {
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
            from pixelBuffer: CVPixelBuffer,
            processor: ScannerAutomaticPhotoFrameProcessor?
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
                    if let processor {
                        selected = try processor.selectForeground(
                            in: lowResolutionMask
                        )
                    } else {
                        selected = try PhotoForegroundInstanceSelector().select(
                            in: lowResolutionMask
                        )
                    }
                } catch let error as PhotoTargetSelectionError {
                    throw error
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
            let multiplicityEvaluation = diagnostics?.rigidItemMultiplicityEvaluation
                ?? multiplicityEvaluation(from: capture.lastPhotoFailure)
            let multiplicityGuardEnabled = capture.photoMeasurement
                .rigidItemMultiplicityGuard != nil
            let multiplicityAssessment: String = if let multiplicityEvaluation {
                multiplicityEvaluation.assessment.diagnosticLabel
            } else if !multiplicityGuardEnabled {
                "disabled"
            } else {
                "not_attempted"
            }
            let multiplicityRoute = multiplicityEvaluation?.diagnosticRoute ?? "none"
            let multiplicityFinitePoints = multiplicityEvaluation
                .map { String($0.finitePointCount) } ?? "none"
            let multiplicityMinimumPoints = multiplicityEvaluation
                .map { String($0.minimumPointCount) } ?? "none"
            let multiplicityUsableBins = multiplicityEvaluation
                .map { String($0.usableBinCount) } ?? "none"
            let multiplicityEligibleSplits = multiplicityEvaluation
                .map { String($0.eligibleSplitCount) } ?? "none"
            let multiplicityComparableSplits = multiplicityEvaluation
                .map { String($0.comparableSplitCount) } ?? "none"
            let multiplicityComparableSplitFraction = diagnosticString(
                multiplicityEvaluation?.comparableSplitFraction
            )
            let multiplicityIndeterminateReason = multiplicityEvaluation?
                .indeterminateReason?.rawValue ?? "none"
            var multiplicityEvidence = multiplicityEvaluation?.candidateEvidence
            if let multiplicityEvaluation,
               case .multipleRigidItems(let acceptedEvidence) =
                multiplicityEvaluation.assessment {
                multiplicityEvidence = acceptedEvidence
            }
            let multiplicityBoundaryBasis = multiplicityEvidence?.basis.rawValue ?? "none"
            let multiplicityMaximumBoundaryShift = diagnosticString(
                multiplicityEvidence?.maximumBoundaryShiftMeters
            )
            let multiplicityMaximumQualifyingNoise = diagnosticString(
                multiplicityEvidence?.maximumQualifyingNoiseMeters
            )
            let multiplicityBoundaryCount = multiplicityEvidence
                .map { String($0.significantBoundaryCount) } ?? "none"
            let multiplicityLowerBodyHeightFraction = diagnosticString(
                multiplicityEvidence?.lowerBodyHeightFraction
            )
            let multiplicityUpperBodyHeightFraction = diagnosticString(
                multiplicityEvidence?.upperBodyHeightFraction
            )
            let multiplicityLowerBodyPointFraction = diagnosticString(
                multiplicityEvidence?.lowerBodyPointFraction
            )
            let multiplicityUpperBodyPointFraction = diagnosticString(
                multiplicityEvidence?.upperBodyPointFraction
            )
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
            let cameraProvenance = capture.cameraProvenance
            let cameraZoom = cameraProvenance?.cameraZoom.label ?? "none"
            let appliedZoom = diagnosticString(
                cameraProvenance?.appliedDisplayZoomFactor
            )
            let normalizedFocalLength = diagnosticString(
                cameraProvenance?.normalizedFocalLength
            )
            let horizontalFieldOfView = diagnosticString(
                cameraProvenance?.horizontalFieldOfViewRadians
            )
            let verticalFieldOfView = diagnosticString(
                cameraProvenance?.verticalFieldOfViewRadians
            )
            let intrinsics = cameraProvenance?.intrinsics
            let focalX = diagnosticString(intrinsics?.columns.0.x)
            let focalY = diagnosticString(intrinsics?.columns.1.y)
            let principalX = diagnosticString(intrinsics?.columns.2.x)
            let principalY = diagnosticString(intrinsics?.columns.2.y)
            let imageWidth = cameraProvenance
                .map { String($0.imageResolutionPixels.x) } ?? "none"
            let imageHeight = cameraProvenance
                .map { String($0.imageResolutionPixels.y) } ?? "none"

            Self.calibrationLogger.notice(
                "scan_calibration request_id=\(capture.requestID, privacy: .public) measurement_series_id=\(capture.measurementSeriesID, privacy: .public) result=\(resultDescription, privacy: .public) attempts=\(capture.sampleAttemptCount, privacy: .public) accepted_frames=\(capture.frameCount, privacy: .public) rejected_frames=\(capture.rejectedFrameCount, privacy: .public) floor_rejected_frames=\(capture.floorRejectedFrameCount, privacy: .public) unavailable_frames=\(capture.unavailableFrameCount, privacy: .public) points=\(capture.worldPoints.count, privacy: .public) length_m=\(lengthMeters, privacy: .public) width_m=\(widthMeters, privacy: .public) height_m=\(heightMeters, privacy: .public) point_cloud_confidence=\(pointCloudConfidence, privacy: .public) camera_x=\(cameraX, privacy: .public) camera_y=\(cameraY, privacy: .public) camera_z=\(cameraZ, privacy: .public) camera_forward_x=\(cameraForwardX, privacy: .public) camera_forward_z=\(cameraForwardZ, privacy: .public) camera_zoom=\(cameraZoom, privacy: .public) camera_applied_display_zoom=\(appliedZoom, privacy: .public) camera_image_width=\(imageWidth, privacy: .public) camera_image_height=\(imageHeight, privacy: .public) camera_focal_x=\(focalX, privacy: .public) camera_focal_y=\(focalY, privacy: .public) camera_principal_x=\(principalX, privacy: .public) camera_principal_y=\(principalY, privacy: .public) camera_normalized_focal=\(normalizedFocalLength, privacy: .public) camera_horizontal_fov_rad=\(horizontalFieldOfView, privacy: .public) camera_vertical_fov_rad=\(verticalFieldOfView, privacy: .public) target_center_x=\(centerX, privacy: .public) target_center_y=\(centerY, privacy: .public) target_center_z=\(centerZ, privacy: .public) raw_region_pixels=\(rawRegionPixels, privacy: .public) retained_region_pixels=\(retainedRegionPixels, privacy: .public) coverage=\(coverage, privacy: .public) seed_abs_up_normal=\(seedUpNormal, privacy: .public) elevation_m=\(elevation, privacy: .public) background_floor_y_m=\(floorY, privacy: .public) floor_source=\(floorSource, privacy: .public) multiplicity_guard_enabled=\(multiplicityGuardEnabled, privacy: .public) multiplicity_assessment=\(multiplicityAssessment, privacy: .public) multiplicity_assessment_route=\(multiplicityRoute, privacy: .public) multiplicity_finite_points=\(multiplicityFinitePoints, privacy: .public) multiplicity_minimum_points=\(multiplicityMinimumPoints, privacy: .public) multiplicity_usable_bins=\(multiplicityUsableBins, privacy: .public) multiplicity_eligible_splits=\(multiplicityEligibleSplits, privacy: .public) multiplicity_comparable_splits=\(multiplicityComparableSplits, privacy: .public) multiplicity_comparable_split_fraction=\(multiplicityComparableSplitFraction, privacy: .public) multiplicity_indeterminate_reason=\(multiplicityIndeterminateReason, privacy: .public) multiplicity_boundary_basis=\(multiplicityBoundaryBasis, privacy: .public) multiplicity_boundary_count=\(multiplicityBoundaryCount, privacy: .public) multiplicity_maximum_boundary_shift_m=\(multiplicityMaximumBoundaryShift, privacy: .public) multiplicity_maximum_qualifying_noise_m=\(multiplicityMaximumQualifyingNoise, privacy: .public) multiplicity_lower_body_height_fraction=\(multiplicityLowerBodyHeightFraction, privacy: .public) multiplicity_upper_body_height_fraction=\(multiplicityUpperBodyHeightFraction, privacy: .public) multiplicity_lower_body_point_fraction=\(multiplicityLowerBodyPointFraction, privacy: .public) multiplicity_upper_body_point_fraction=\(multiplicityUpperBodyPointFraction, privacy: .public) target_reason=\(finalTargetReasonDescription, privacy: .public) last_frame_rejection=\(lastRejectionDescription, privacy: .public) capture_path=\(capturePath, privacy: .public) fallback_trigger_code=\(fallbackTriggerCode, privacy: .public) fallback_trigger_detail=\(fallbackTriggerDetail, privacy: .public) fallback_result=\(fallbackResult, privacy: .public) photo_failure_code=\(photoFailureCode, privacy: .public) photo_failure_detail=\(photoFailureDetail, privacy: .public) estimation_failure=\(failureDescription, privacy: .public) geometry_error=\(geometryErrorDescription, privacy: .public)"
            )
        }

        private func multiplicityEvaluation(
            from failure: SingleShotCaptureFailure?
        ) -> PhotoRigidItemMultiplicityEvaluation? {
            let photoError: PhotoObjectMeasurementError? = switch failure {
            case .photo(let error):
                error
            case .foreground(.photo(_, let error)):
                error
            default:
                nil
            }
            return switch photoError {
            case .multipleRigidItemsDetected(let evaluation),
                 .rigidItemMultiplicityUncertain(let evaluation):
                evaluation
            default:
                nil
            }
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
            resetMeasurementSeries: Bool = false,
            automaticAuthority: AutomaticCaptureAuthority? = nil,
            guidedLifecycleBoundary: GuidedBoxLifecycleBoundary? = nil
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
                if let automaticAuthority {
                    let cleared = state.automaticCaptureFailed(
                        authority: automaticAuthority
                    )
                    if !cleared, !resetMeasurementSeries { return }
                }
                if previewLifecycle.measurementFinalized() == .pause {
                    arView?.session.pause()
                }
                if let guidedLifecycleBoundary {
                    state.clearGuidedCapture(for: guidedLifecycleBoundary)
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
                state.resetMeasurementSeries()
                state.estimate = nil
                state.phase = .checkingSupport
                markPreviewNeedsReadiness()
                _ = beginPreviewRun(after: arView?.session.currentFrame?.timestamp)
                arView?.session.run(sessionConfiguration)
                _ = reapplyCameraZoomAfterSessionRun()
            }
        }

        private func publishMeasurementCapture(
            _ capture: ScannerRecordedAngleCapture,
            requestID: Int,
            measurementSeriesID: Int,
            automaticAuthority: AutomaticCaptureAuthority?
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
                let progress: MultiAngleMeasurementProgress
                if let automaticAuthority {
                    guard let automaticProgress =
                            state.receiveAutomaticMeasurement(
                                capture,
                                authority: automaticAuthority
                            ) else {
                        return
                    }
                    progress = automaticProgress
                } else {
                    progress = state.receiveMeasurement(capture)
                }
                Self.calibrationLogger.notice(
                    "multi_angle measurement_series_id=\(measurementSeriesID, privacy: .public) request_id=\(requestID, privacy: .public) decision=\(progress.diagnosticDescription, privacy: .public)"
                )
            }
        }

    }
}
