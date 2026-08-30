import SwiftUI

/// Keeps the AR representable at one stable SwiftUI identity while allowing the
/// live camera to use its portrait ratio and a captured result to retain the
/// exact viewport aspect ratio from its measured frame.
private struct ScannerPreviewSizingLayout: Layout {
    let preferredAspectRatio: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return ScannerPreviewLayoutPolicy.fittedSize(
            proposedWidth: proposal.width,
            proposedHeight: proposal.height,
            fallbackSize: subview.sizeThatFits(proposal),
            preferredAspectRatio: preferredAspectRatio
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

enum ScannerPreviewLayoutPolicy {
    /// Used only until the first eligible AR frame publishes the active camera
    /// format. The live ratio is then derived from that frame rather than
    /// assuming every supported device selected a 4:3 format.
    static let fallbackLiveCameraAspectRatio: CGFloat = 3.0 / 4.0

    static func preferredAspectRatio(
        showsLiveCamera: Bool,
        liveCameraAspectRatio: CGFloat,
        capturedAspectRatio: CGFloat?
    ) -> CGFloat? {
        if showsLiveCamera {
            return liveCameraAspectRatio
        }
        return capturedAspectRatio
    }

    static func orientedLiveCameraAspectRatio(
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> CGFloat? {
        guard imageWidth.isFinite,
              imageHeight.isFinite,
              imageWidth > 0,
              imageHeight > 0 else {
            return nil
        }
        return imageHeight / imageWidth
    }

    static func fittedSize(
        proposedWidth: CGFloat?,
        proposedHeight: CGFloat?,
        fallbackSize: CGSize,
        preferredAspectRatio: CGFloat?
    ) -> CGSize {
        let fallback = CGSize(
            width: fallbackSize.width.isFinite && fallbackSize.width >= 0
                ? fallbackSize.width
                : 0,
            height: fallbackSize.height.isFinite && fallbackSize.height >= 0
                ? fallbackSize.height
                : 0
        )
        guard let preferredAspectRatio,
              preferredAspectRatio.isFinite,
              preferredAspectRatio > 0 else {
            return fallback
        }

        let width = proposedWidth.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        let height = proposedHeight.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        if width == 0 || height == 0 {
            return .zero
        }

        switch (width, height) {
        case let (.some(width), .some(height)):
            let fittedWidth = min(width, height * preferredAspectRatio)
            return CGSize(
                width: fittedWidth,
                height: fittedWidth / preferredAspectRatio
            )
        case let (.some(width), .none):
            return CGSize(width: width, height: width / preferredAspectRatio)
        case let (.none, .some(height)):
            return CGSize(width: height * preferredAspectRatio, height: height)
        case (.none, .none):
            return fallback
        }
    }

    static func showsReviewContent(showsLiveCamera: Bool) -> Bool {
        !showsLiveCamera
    }
}

enum ScannerCameraZoomPresentation: Equatable, Sendable {
    case hidden
    case checking
    case selectable(
        zooms: [ScannerCameraZoom],
        selected: ScannerCameraZoom,
        isApplying: Bool
    )
    case single(ScannerCameraZoom)
    case fixed
    case locked(ScannerCameraZoom)
}

struct ScannerSheetView: View {
    @MainActor
    @Observable
    final class ScannerStateModel {
        struct AutomaticPhotoCaptureAuthority: Equatable, Sendable {
            let captureRequestID: Int
            let identity: TargetLockIdentity
            let prompt: PhotoTargetSelectionPrompt
            let lockedContext: TargetCaptureContext?
            let cameraEvidenceReacquisitionID: Int
        }

        var captureRequestID = 0
        var previewRequestID = 0
        private(set) var cameraZoomRequestID = 0
        private(set) var cameraEvidenceReacquisitionID = 0
        var phase: ScannerPhase = .checkingSupport
        var estimate: MeasurementEstimate?
        var objectOverlay: MeasurementObjectOverlay?
        private(set) var cameraZoom = ScannerCameraZoom.standard
        private(set) var lastConfirmedCameraZoom = ScannerCameraZoom.standard
        private(set) var availableCameraZooms = [ScannerCameraZoom.standard]
        private(set) var cameraZoomUsesConfigurableDevice = false
        private(set) var hasResolvedCameraZoomAvailability = false
        private(set) var hasConfirmedExplicitCameraZoom = false
        private(set) var isApplyingCameraZoom = false
        private(set) var pendingFinalAngleFramingZoom: ScannerCameraZoom?
        private(set) var liveCameraAspectRatio =
            ScannerPreviewLayoutPolicy.fallbackLiveCameraAspectRatio
        private(set) var isPreparingForAiming = false
        private(set) var requiresFreshCameraEvidence = false
        private(set) var measurementSeriesID = 0
        private(set) var measurementWorkflow = MultiAngleMeasurementWorkflow()
        private(set) var capturedAngleRecords: [ScannerRecordedAngleCapture] = []
        private(set) var measurementSubject = TargetLockSubject.box
        private(set) var measurementMode = ScannerMeasurementMode.automaticPhotos
        private(set) var automaticTargetPrompt: PhotoTargetSelectionPrompt?
        private(set) var targetLockLifecycle = TargetLockLifecycle()
        private(set) var targetFrameValidationGate: TargetLockFrameValidationGate?
        private(set) var targetFrameValidationMessage: String?
        private(set) var lastAutomaticCaptureRejection: TargetLockFrameValidationFailure?
        private(set) var pendingAutomaticCaptureAuthority: AutomaticPhotoCaptureAuthority?
        private(set) var guidedCaptureSession: GuidedBoxCaptureSession?
        private(set) var guidedCaptureRequestID = 0
        private(set) var guidedPointCaptureIntentID = 0
        private(set) var guidedCaptureFeedback: GuidedBoxCaptureFeedback?

        var measurementProgress: MultiAngleMeasurementProgress {
            measurementWorkflow.progress
        }

        var capturedEstimates: [MeasurementEstimate] {
            capturedAngleRecords.map(\.evidence.estimate)
        }

        var activeTargetIdentity: TargetLockIdentity? {
            targetLockLifecycle.current?.identity
        }

        var activeTargetLock: TargetLock? {
            targetLockLifecycle.current
        }

        /// The public lock remains ambiguous after a T03 rejection. AR may use
        /// this restored copy to validate live frames against the accepted
        /// bounds without prematurely restoring capture authority.
        var automaticTargetValidationLockSnapshot: TargetLock? {
            guard measurementMode == .automaticPhotos,
                  var target = targetLockLifecycle.current,
                  target.identity.measurementSeriesID == measurementSeriesID,
                  target.ownsAcceptedEvidence else {
                return nil
            }
            if target.captureContext != nil {
                return target
            }
            guard target.state == .ambiguous,
                  target.restoreLocked() else {
                return nil
            }
            return target
        }

        var automaticPhotoMeasurement: PhotoObjectMeasurement {
            var measurement = PhotoObjectMeasurement()
            if measurementSubject == .generalItem {
                measurement.rigidItemMultiplicityGuard = nil
            }
            return measurement
        }

        var canChangeAutomaticTarget: Bool {
            guard measurementMode == .automaticPhotos,
                  let target = targetLockLifecycle.current,
                  target.canCancelBeforeAcceptedEvidence,
                  phase == .ready,
                  objectOverlay == nil,
                  !phase.isCapturing,
                  !isApplyingCameraZoom,
                  !isPreparingForAiming,
                  !requiresFreshCameraEvidence,
                  pendingAutomaticCaptureAuthority == nil else {
                return false
            }
            return true
        }

        var canStartAutomaticCapture: Bool {
            baseCanStartMeasurement
                && automaticTargetIsReady
                && pendingAutomaticCaptureAuthority == nil
        }

        var canRequestGuidedPointCapture: Bool {
            guard measurementMode == .guidedCorners,
                  phase == .ready,
                  let session = guidedCaptureSession,
                  session.isActive,
                  session.pendingRequest == nil,
                  session.step.point != nil else {
                return false
            }
            return true
        }

        var canChangeCameraZoom: Bool {
            let workflowAcceptsAnotherAngle = switch measurementWorkflow.progress {
            case .awaitingFirstAngle, .needsAnotherAngle:
                true
            case .accepted, .inconsistent:
                false
            }
            return availableCameraZooms.count > 1
                && workflowAcceptsAnotherAngle
                && phase == .ready
                && !isApplyingCameraZoom
                && !requiresFreshCameraEvidence
                && targetLockLifecycle.current?.canCancelBeforeAcceptedEvidence != true
        }

        var canStartMeasurement: Bool {
            guard baseCanStartMeasurement else { return false }
            guard targetLockLifecycle.current != nil else { return true }
            return automaticTargetIsReady
        }

        var shouldReapplyCameraZoomAfterSessionRun: Bool {
            cameraZoomUsesConfigurableDevice
                && hasConfirmedExplicitCameraZoom
        }

        var showsLiveCameraPreview: Bool {
            guard objectOverlay == nil else { return false }
            return switch phase {
            case .checkingSupport, .ready, .scanning:
                true
            case .measured, .failed:
                isPreparingForAiming
            case .unsupported:
                false
            }
        }

        var showsCameraGuide: Bool {
            guard objectOverlay == nil else { return false }
            return switch phase {
            case .checkingSupport, .ready, .scanning:
                true
            case .measured, .failed:
                isPreparingForAiming
            case .unsupported:
                false
            }
        }

        var cameraZoomPresentation: ScannerCameraZoomPresentation {
            guard showsCameraGuide, !phase.isCapturing else { return .hidden }
            guard hasResolvedCameraZoomAvailability else { return .checking }
            guard cameraZoomUsesConfigurableDevice else { return .fixed }
            if availableCameraZooms.count > 1 {
                return .selectable(
                    zooms: availableCameraZooms,
                    selected: cameraZoom,
                    isApplying: isApplyingCameraZoom
                )
            }
            if let onlyZoom = availableCameraZooms.first {
                return .single(onlyZoom)
            }
            return .fixed
        }

        @discardableResult
        func setMeasurementSubject(_ subject: TargetLockSubject) -> Bool {
            guard measurementMode == .automaticPhotos,
                  targetLockLifecycle.current == nil,
                  measurementWorkflow.captures.isEmpty,
                  capturedAngleRecords.isEmpty,
                  pendingAutomaticCaptureAuthority == nil,
                  !phase.isCapturing,
                  !isApplyingCameraZoom,
                  !isPreparingForAiming else {
                return false
            }
            measurementSubject = subject
            return true
        }

        @discardableResult
        func selectAutomaticTarget(
            rawCameraNormalizedPoint: SIMD2<Float>,
            id: UUID = UUID()
        ) -> TargetLockIdentity? {
            guard measurementMode == .automaticPhotos else { return nil }
            if let identity = targetLockLifecycle.current?.identity {
                return identity
            }
            guard phase == .ready,
                  objectOverlay == nil,
                  !phase.isCapturing,
                  !isApplyingCameraZoom,
                  !isPreparingForAiming,
                  !requiresFreshCameraEvidence,
                  pendingAutomaticCaptureAuthority == nil,
                  rawCameraNormalizedPoint.x.isFinite,
                  rawCameraNormalizedPoint.y.isFinite,
                  (0...1).contains(rawCameraNormalizedPoint.x),
                  (0...1).contains(rawCameraNormalizedPoint.y) else {
                return nil
            }

            let identity = targetLockLifecycle.select(
                measurementSeriesID: measurementSeriesID,
                id: id
            )
            automaticTargetPrompt = .target(
                normalizedImagePoint: rawCameraNormalizedPoint
            )
            targetFrameValidationGate = TargetLockFrameValidationGate(
                identity: identity
            )
            targetFrameValidationMessage = nil
            lastAutomaticCaptureRejection = nil
            pendingAutomaticCaptureAuthority = nil
            return identity
        }

        @discardableResult
        func changeAutomaticTarget() -> Bool {
            guard canChangeAutomaticTarget,
                  let identity = targetLockLifecycle.current?.identity,
                  targetLockLifecycle.cancelUnaccepted(identity: identity) else {
                return false
            }
            clearAutomaticTargetAuthority()
            return true
        }

        @discardableResult
        func beginAutomaticCapture() -> AutomaticPhotoCaptureAuthority? {
            guard canStartAutomaticCapture,
                  let identity = activeTargetIdentity,
                  identity.measurementSeriesID == measurementSeriesID,
                  let prompt = automaticTargetPrompt else {
                return nil
            }

            let currentTarget = targetLockLifecycle.current
            let lockedContext = currentTarget?.captureContext
            if currentTarget?.ownsAcceptedEvidence == true,
               lockedContext == nil {
                return nil
            }

            startMeasurementCore()
            let authority = AutomaticPhotoCaptureAuthority(
                captureRequestID: captureRequestID,
                identity: identity,
                prompt: prompt,
                lockedContext: lockedContext,
                cameraEvidenceReacquisitionID: cameraEvidenceReacquisitionID
            )
            pendingAutomaticCaptureAuthority = authority
            return authority
        }

        @discardableResult
        func automaticCaptureFailed(
            authority: AutomaticPhotoCaptureAuthority
        ) -> Bool {
            guard measurementMode == .automaticPhotos,
                  pendingAutomaticCaptureAuthority == authority else {
                return false
            }
            pendingAutomaticCaptureAuthority = nil
            if phase.isCapturing {
                phase = .ready
            }
            resetTargetFrameValidationGate()
            return true
        }

        /// Consumes an exact locked-target capture rejected by the T03 frame
        /// validator. Accepted angles and bounds remain owned by the target,
        /// but capture authority stays disabled until two new live frames pass.
        @discardableResult
        func rejectAutomaticCapture(
            authority: AutomaticPhotoCaptureAuthority,
            failure: TargetLockFrameValidationFailure
        ) -> Bool {
            guard measurementMode == .automaticPhotos,
                  pendingAutomaticCaptureAuthority == authority,
                  authority.captureRequestID == captureRequestID,
                  authority.cameraEvidenceReacquisitionID
                    == cameraEvidenceReacquisitionID,
                  authority.identity.measurementSeriesID == measurementSeriesID,
                  automaticTargetPrompt == authority.prompt else {
                return false
            }

            var candidateLifecycle = targetLockLifecycle
            guard let target = candidateLifecycle.current,
                  target.identity == authority.identity,
                  target.ownsAcceptedEvidence,
                  let lockedContext = candidateLifecycle.currentCaptureContext,
                  authority.lockedContext == lockedContext,
                  candidateLifecycle.markAmbiguous(identity: authority.identity) else {
                return false
            }

            pendingAutomaticCaptureAuthority = nil
            targetLockLifecycle = candidateLifecycle
            if phase.isCapturing {
                phase = .ready
            }
            resetTargetFrameValidationGate()
            targetFrameValidationMessage = failure.actionMessage
            lastAutomaticCaptureRejection = failure
            return true
        }

        @discardableResult
        func observeAutomaticTargetValidation(
            _ validation: TargetLockFrameValidation,
            identity: TargetLockIdentity
        ) -> TargetLockFrameReadinessUpdate {
            guard measurementMode == .automaticPhotos,
                  targetLockLifecycle.current?.identity == identity,
                  var gate = targetFrameValidationGate,
                  gate.identity == identity else {
                return .ignoredStaleIdentity
            }

            let update = gate.observe(validation, identity: identity)
            targetFrameValidationGate = gate
            switch update {
            case .waiting, .ready:
                targetFrameValidationMessage = nil
            case let .rejected(failure):
                targetFrameValidationMessage = failure.actionMessage
            case .ignoredStaleIdentity:
                break
            }
            return update
        }

        @discardableResult
        func receiveAutomaticTargetFrameEvidence(
            _ evidence: TargetLockFrameEvidence,
            validator: TargetLockFrameValidator = .init()
        ) -> TargetLockFrameReadinessUpdate {
            guard measurementMode == .automaticPhotos,
                  let target = automaticTargetValidationLockSnapshot,
                  target.identity == evidence.identity else {
                return .ignoredStaleIdentity
            }
            let validation = validator.validate(
                lock: target,
                subject: measurementSubject,
                evidence: evidence
            )
            let update = observeAutomaticTargetValidation(
                validation,
                identity: evidence.identity
            )
            if update == .ready,
               targetLockLifecycle.current?.state == .ambiguous {
                _ = targetLockLifecycle.restoreLocked(identity: evidence.identity)
            }
            return update
        }

        func beginCameraZoomAvailabilityDiscovery() {
            hasResolvedCameraZoomAvailability = false
            isApplyingCameraZoom = false
        }

        func updateCameraZoomAvailability(
            _ zooms: [ScannerCameraZoom],
            selected: ScannerCameraZoom,
            usesConfigurableDevice: Bool = true,
            confirmsExplicitSelection: Bool = false
        ) {
            let normalizedZooms = zooms.isEmpty ? [.standard] : zooms
            availableCameraZooms = normalizedZooms
            cameraZoom = normalizedZooms.contains(selected)
                ? selected
                : normalizedZooms[0]
            lastConfirmedCameraZoom = cameraZoom
            cameraZoomUsesConfigurableDevice = usesConfigurableDevice
            hasResolvedCameraZoomAvailability = true
            if confirmsExplicitSelection {
                hasConfirmedExplicitCameraZoom = true
            }
            isApplyingCameraZoom = false
            if confirmsExplicitSelection {
                applyPendingFinalAngleFramingZoomIfPossible()
            }
        }

        func cameraZoomApplicationFailed(message: String? = nil) {
            cameraZoom = lastConfirmedCameraZoom
            hasConfirmedExplicitCameraZoom = false
            isApplyingCameraZoom = false
            pendingFinalAngleFramingZoom = nil
            isPreparingForAiming = false
            requiresFreshCameraEvidence = true
            if let message {
                estimate = nil
                objectOverlay = nil
                phase = .failed(message)
            }
        }

        func beginCameraZoomApplication() {
            isApplyingCameraZoom = true
        }

        @discardableResult
        func selectCameraZoom(_ zoom: ScannerCameraZoom) -> Bool {
            guard canChangeCameraZoom,
                  availableCameraZooms.contains(zoom),
                  zoom != cameraZoom else {
                return false
            }
            cameraZoom = zoom
            hasConfirmedExplicitCameraZoom = false
            isApplyingCameraZoom = true
            cameraZoomRequestID += 1
            cameraEvidenceReacquisitionID += 1
            invalidateAutomaticTargetCameraEvidence()
            requiresFreshCameraEvidence = true
            estimate = nil
            objectOverlay = nil
            isPreparingForAiming = false
            phase = .checkingSupport
            previewRequestID += 1
            return true
        }

        @discardableResult
        func receiveMeasurement(
            _ recordedCapture: ScannerRecordedAngleCapture
        ) -> MultiAngleMeasurementProgress {
            guard measurementMode == .automaticPhotos,
                  targetLockLifecycle.current == nil else {
                return measurementWorkflow.progress
            }
            isPreparingForAiming = false
            let capture = recordedCapture.measurement
            objectOverlay = capture.objectOverlay
            guard capture.evidence.estimate.confidence != .low else {
                estimate = capture.evidence.estimate
                phase = .measured
                return measurementWorkflow.progress
            }

            let acceptedCount = measurementWorkflow.captures.count
            let progress = measurementWorkflow.record(capture)
            if measurementWorkflow.captures.count == acceptedCount + 1 {
                capturedAngleRecords.append(recordedCapture)
            }
            switch progress {
            case .accepted(let consensus):
                estimate = consensus
            case .awaitingFirstAngle, .needsAnotherAngle, .inconsistent:
                estimate = nil
            }
            phase = .measured
            return progress
        }

        /// Accepts only the exact automatic-photo request that produced the
        /// callback. The lifecycle and workflow are first updated in local
        /// copies so a missing bound, stale identity, or target mismatch cannot
        /// partially admit an angle.
        @discardableResult
        func receiveAutomaticMeasurement(
            _ recordedCapture: ScannerRecordedAngleCapture,
            authority: AutomaticPhotoCaptureAuthority
        ) -> MultiAngleMeasurementProgress? {
            guard measurementMode == .automaticPhotos,
                  pendingAutomaticCaptureAuthority == authority,
                  authority.captureRequestID == captureRequestID,
                  authority.cameraEvidenceReacquisitionID
                    == cameraEvidenceReacquisitionID,
                  authority.identity.measurementSeriesID == measurementSeriesID,
                  targetLockLifecycle.current?.identity == authority.identity,
                  automaticTargetPrompt == authority.prompt else {
                return nil
            }

            // A callback that owns the current pending request is terminal even
            // when its measurement evidence fails closed. A delayed callback
            // cannot consume a newer request because the full authority differs.
            pendingAutomaticCaptureAuthority = nil
            isPreparingForAiming = false
            let capture = recordedCapture.measurement
            objectOverlay = capture.objectOverlay

            guard capture.evidence.estimate.confidence != .low else {
                estimate = capture.evidence.estimate
                phase = .measured
                return nil
            }
            guard let bounds = capture.evidence.targetLockBounds else {
                estimate = nil
                objectOverlay = nil
                phase = .failed(
                    "The selected item could not be verified in this photo. Retake the photo."
                )
                return nil
            }

            var candidateLifecycle = targetLockLifecycle
            let ownedAcceptedEvidence = candidateLifecycle.current?.ownsAcceptedEvidence == true
            if ownedAcceptedEvidence {
                guard let context = candidateLifecycle.currentCaptureContext,
                      authority.lockedContext == context else {
                    return nil
                }
            } else {
                guard authority.lockedContext == nil,
                      candidateLifecycle.promote(
                          identity: authority.identity,
                          worldAnchor: capture.evidence.geometryCenter,
                          bounds: bounds
                      ) else {
                    return nil
                }
            }
            guard let captureContext = candidateLifecycle.currentCaptureContext else {
                return nil
            }

            var candidateWorkflow = measurementWorkflow
            let acceptedCount = candidateWorkflow.captures.count
            let progress = candidateWorkflow.record(capture)
            let admittedAngle = candidateWorkflow.captures.count == acceptedCount + 1
            if admittedAngle {
                guard candidateLifecycle.recordAcceptedAngle(using: captureContext) else {
                    return nil
                }
            }

            measurementWorkflow = candidateWorkflow
            targetLockLifecycle = candidateLifecycle
            if admittedAngle {
                capturedAngleRecords.append(recordedCapture)
                resetTargetFrameValidationGate()
                lastAutomaticCaptureRejection = nil
            }
            switch progress {
            case .accepted(let consensus):
                estimate = consensus
            case .awaitingFirstAngle, .needsAnotherAngle, .inconsistent:
                estimate = nil
            }
            phase = .measured
            return progress
        }

        func resetMeasurementSeries() {
            if var guidedCaptureSession {
                guidedCaptureSession.clear(for: .restart)
            }
            guidedCaptureSession = nil
            measurementMode = .automaticPhotos
            measurementWorkflow.reset()
            capturedAngleRecords = []
            measurementSeriesID += 1
            targetLockLifecycle.reset()
            clearAutomaticTargetAuthority()
            estimate = nil
            objectOverlay = nil
            isApplyingCameraZoom = false
            pendingFinalAngleFramingZoom = nil
            isPreparingForAiming = false
            requiresFreshCameraEvidence = false
            guidedCaptureFeedback = nil
        }

        func prepareForAiming() {
            guard measurementMode == .automaticPhotos,
                  !isPreparingForAiming else {
                return
            }
            let isMeasuredTransition: Bool
            switch phase {
            case .measured:
                isMeasuredTransition = true
            case .failed:
                isMeasuredTransition = false
            default:
                return
            }
            pendingFinalAngleFramingZoom = isMeasuredTransition
                ? preferredFinalAngleFramingZoom()
                : nil
            switch measurementWorkflow.progress {
            case .accepted, .inconsistent:
                resetMeasurementSeries()
            case .awaitingFirstAngle, .needsAnotherAngle:
                break
            }
            // A target selection belongs to one camera angle only. Preserve the
            // accepted measurements and series, but never project a prior
            // angle's world anchor into the next live preview. The next shutter
            // request must be authorized by a fresh tap in that angle's frame.
            targetLockLifecycle.reset()
            clearAutomaticTargetAuthority()
            estimate = nil
            objectOverlay = nil
            isPreparingForAiming = true
            previewRequestID += 1
        }

        /// ARKit, not `session.run`, decides when the preview can safely accept
        /// a photo. A normal-tracking frame with depth and a laid-out viewport
        /// calls this after initial startup and every preview resume.
        @discardableResult
        func previewBecameReady() -> Bool {
            guard phase == .checkingSupport || isPreparingForAiming else {
                return false
            }
            isPreparingForAiming = false
            requiresFreshCameraEvidence = false
            phase = .ready
            applyPendingFinalAngleFramingZoomIfPossible()
            return true
        }

        @discardableResult
        func updateLiveCameraAspectRatio(_ aspectRatio: CGFloat) -> Bool {
            guard aspectRatio.isFinite, aspectRatio > 0 else { return false }
            guard abs(liveCameraAspectRatio - aspectRatio) > 0.000_1 else {
                return false
            }
            liveCameraAspectRatio = aspectRatio
            return true
        }

        private func applyPendingFinalAngleFramingZoomIfPossible() {
            guard phase == .ready,
                  let pendingFinalAngleFramingZoom else {
                return
            }
            guard availableCameraZooms.contains(pendingFinalAngleFramingZoom) else {
                self.pendingFinalAngleFramingZoom = nil
                return
            }
            if cameraZoom == pendingFinalAngleFramingZoom {
                self.pendingFinalAngleFramingZoom = nil
                return
            }
            if selectCameraZoom(pendingFinalAngleFramingZoom) {
                self.pendingFinalAngleFramingZoom = nil
            }
        }

        private func preferredFinalAngleFramingZoom() -> ScannerCameraZoom? {
            guard capturedAngleRecords.count == 2,
                  case .needsAnotherAngle(_, acceptedCount: 2) =
                    measurementWorkflow.progress else {
                return nil
            }
            return availableCameraZooms
                .filter { $0.rawValue < cameraZoom.rawValue }
                .min { $0.rawValue < $1.rawValue }
        }

        func startMeasurement() {
            guard measurementMode == .automaticPhotos else { return }
            if targetLockLifecycle.current != nil {
                _ = beginAutomaticCapture()
                return
            }
            guard baseCanStartMeasurement else { return }
            startMeasurementCore()
        }

        @discardableResult
        func enterGuidedCorners(targetID: UUID = UUID()) -> Bool {
            guard measurementSubject == .box,
                  measurementMode == .automaticPhotos,
                  !phase.isCapturing,
                  !isApplyingCameraZoom else {
                return false
            }

            resetMeasurementSeries()
            measurementMode = .guidedCorners
            guidedCaptureSession = GuidedBoxCaptureSession(
                context: GuidedBoxCaptureContext(
                    measurementSeriesID: measurementSeriesID,
                    targetID: targetID
                )
            )
            guidedCaptureFeedback = nil
            requestFreshPreviewReadiness()
            return true
        }

        @discardableResult
        func requestGuidedPointCapture() -> Bool {
            guard canRequestGuidedPointCapture else { return false }
            guidedPointCaptureIntentID += 1
            return true
        }

        @discardableResult
        func beginGuidedCapture(
            requestedPose: GuidedBoxCapturePose
        ) -> GuidedBoxCaptureRequest? {
            guard measurementMode == .guidedCorners,
                  var session = guidedCaptureSession else {
                return nil
            }
            let nextRequestID = guidedCaptureRequestID + 1
            guard let request = session.beginRequest(
                requestID: nextRequestID,
                requestedPose: requestedPose
            ) else {
                return nil
            }
            guidedCaptureRequestID = nextRequestID
            guidedCaptureSession = session
            return request
        }

        @discardableResult
        func consumeGuidedCapture(
            _ sample: GuidedBoxPointSample
        ) -> GuidedBoxCaptureSessionUpdate {
            guard measurementMode == .guidedCorners,
                  var session = guidedCaptureSession else {
                return .ignored(.inactive)
            }
            let update = session.consume(sample)
            guidedCaptureSession = session
            switch update {
            case .ignored:
                break
            case let .rejected(rejection):
                guidedCaptureFeedback = .error(
                    guidedCaptureRejectionMessage(rejection)
                )
            case .workflow(.advanced), .workflow(.ready):
                guidedCaptureFeedback = nil
            case let .workflow(.needsReplacement(point, error)):
                guidedCaptureFeedback = .replacement(
                    point: point,
                    message: error.localizedDescription
                )
            case let .workflow(.failed(error)):
                guidedCaptureFeedback = .error(error.localizedDescription)
            case .workflow(.ignored):
                break
            }
            return update
        }

        @discardableResult
        func guidedCaptureFailed(
            request: GuidedBoxCaptureRequest,
            failure: GuidedBoxCaptureFailure
        ) -> Bool {
            guard measurementMode == .guidedCorners,
                  var session = guidedCaptureSession,
                  session.fail(request: request, failure: failure) else {
                return false
            }
            guidedCaptureSession = session
            guidedCaptureFeedback = .error(failure.actionMessage)
            return true
        }

        @discardableResult
        func guidedBack() -> Bool {
            guard measurementMode == .guidedCorners,
                  var session = guidedCaptureSession else {
                return false
            }
            session.back()
            guidedCaptureSession = session
            estimate = nil
            objectOverlay = nil
            guidedCaptureFeedback = nil
            return true
        }

        @discardableResult
        func confirmGuidedCapture() -> GuidedBoxMeasurementResult? {
            guard measurementMode == .guidedCorners,
                  var session = guidedCaptureSession,
                  let result = session.confirm(),
                  result.source == .guidedLidarCorners,
                  result.context == session.context else {
                return nil
            }
            guidedCaptureSession = session
            estimate = result.estimate
            objectOverlay = nil
            phase = .measured
            guidedCaptureFeedback = nil
            return result
        }

        func clearGuidedCapture(for boundary: GuidedBoxLifecycleBoundary) {
            guard measurementMode == .guidedCorners else { return }
            if var session = guidedCaptureSession {
                session.clear(for: boundary)
            }
            guidedCaptureSession = nil
            resetMeasurementSeries()
            requestFreshPreviewReadiness()
        }

        private var baseCanStartMeasurement: Bool {
            measurementMode == .automaticPhotos
                && ScannerActionPolicy.canStartMeasurement(phase: phase)
                && !isApplyingCameraZoom
                && !requiresFreshCameraEvidence
        }

        private var automaticTargetIsReady: Bool {
            guard let target = targetLockLifecycle.current,
                  target.identity.measurementSeriesID == measurementSeriesID,
                  automaticTargetPrompt != nil else {
                return false
            }
            guard target.ownsAcceptedEvidence else {
                return target.state == .provisional
            }
            return target.captureContext != nil
                && targetFrameValidationGate?.identity == target.identity
                && targetFrameValidationGate?.isReady == true
        }

        private func startMeasurementCore() {
            estimate = nil
            objectOverlay = nil
            isPreparingForAiming = false
            captureRequestID += 1
            phase = .scanning(progress: 0)
        }

        private func clearAutomaticTargetAuthority() {
            automaticTargetPrompt = nil
            targetFrameValidationGate = nil
            targetFrameValidationMessage = nil
            lastAutomaticCaptureRejection = nil
            pendingAutomaticCaptureAuthority = nil
        }

        private func guidedCaptureRejectionMessage(
            _ rejection: GuidedBoxCaptureRejection
        ) -> String {
            switch rejection {
            case .invalidCapturePose:
                GuidedBoxCaptureFailure.trackingTimeout.actionMessage
            case .cameraMoved:
                "The camera moved before the point was captured. Hold still and try again."
            case .inactive, .noPendingRequest, .requestMismatch,
                 .contextMismatch, .pointMismatch, .wrongEvidenceSource:
                "That point capture is no longer current. Try again."
            }
        }

        private func resetTargetFrameValidationGate() {
            guard let identity = targetLockLifecycle.current?.identity else {
                targetFrameValidationGate = nil
                targetFrameValidationMessage = nil
                return
            }
            targetFrameValidationGate = TargetLockFrameValidationGate(
                identity: identity
            )
            targetFrameValidationMessage = nil
        }

        private func invalidateAutomaticTargetCameraEvidence() {
            pendingAutomaticCaptureAuthority = nil
            resetTargetFrameValidationGate()
        }

        private func requestFreshPreviewReadiness() {
            estimate = nil
            objectOverlay = nil
            isPreparingForAiming = false
            requiresFreshCameraEvidence = true
            phase = .checkingSupport
            previewRequestID += 1
        }
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var scannerState = ScannerStateModel()
    @State private var draftName = ""
    @State private var quantity = 1
    @State private var isStackable = false
    @State private var maxStackLayers = 2
    @State private var mayRotate = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                cameraPreview

                if showsModeSelector {
                    ScannerModeSelector(
                        selection: ScannerModeSelection(
                            subject: scannerState.measurementSubject,
                            mode: scannerState.measurementMode
                        ),
                        canChangeSubject: canChangeMeasurementSetup,
                        canChangeMode: canChangeMeasurementSetup,
                        onSelectSubject: { subject in
                            _ = scannerState.setMeasurementSubject(subject)
                        },
                        onSelectMode: { mode in
                            guard mode == .guidedCorners else { return }
                            _ = scannerState.enterGuidedCorners()
                        }
                    )
                }

                if ScannerPreviewLayoutPolicy.showsReviewContent(
                    showsLiveCamera: scannerState.showsLiveCameraPreview
                ) {
                    if let estimate = scannerState.estimate {
                        Form {
                        if case let .retryRequired(message) = reviewState {
                            Section(retryPresentation.sectionTitle) {
                                retryDiagnosticLabel(message)
                            }
                        }

                        Section(ScannerResultCopy.sizeSectionTitle) {
                            Text(
                                "\(MeasurementMath.inchString(from: estimate.lengthMeters)) × " +
                                "\(MeasurementMath.inchString(from: estimate.widthMeters)) × " +
                                "\(MeasurementMath.inchString(from: estimate.heightMeters))"
                            )
                            Text(ScannerResultCopy.qualitySummary(for: estimate))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if scannerState.capturedEstimates.count > 1 {
                            Section(ScannerResultCopy.capturedAnglesSectionTitle) {
                                ForEach(
                                    Array(scannerState.capturedAngleRecords.enumerated()),
                                    id: \.offset
                                ) { index, capturedAngle in
                                    HStack {
                                        Text("Angle \(index + 1)")
                                        Spacer()
                                        Text(
                                            "\(dimensionString(capturedAngle.evidence.estimate))"
                                                + " · \(capturedAngle.cameraProvenance.cameraZoom.label)"
                                        )
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if reviewState.canSave {
                            Section("Save Item") {
                                TextField("Item name", text: $draftName)
                                Stepper("Quantity: \(quantity)", value: $quantity, in: 1...99)
                                Toggle("Safe to stack", isOn: $isStackable)
                                if isStackable {
                                    Stepper(
                                        "Maximum layers: \(maxStackLayers)",
                                        value: $maxStackLayers,
                                        in: 2 ... 20
                                    )
                                }
                                Toggle("Safe to turn on its side", isOn: $mayRotate)
                            }
                        }
                        }
                        .frame(
                            minHeight: showsRetainedAngleRetry ? 220 : nil,
                            idealHeight: showsRetainedAngleRetry ? 320 : nil,
                            maxHeight: 360
                        )
                        .layoutPriority(showsRetainedAngleRetry ? 1 : 0)
                    } else if !scannerState.capturedEstimates.isEmpty {
                        Form {
                        if case let .retryRequired(message) = reviewState {
                            Section(retryPresentation.sectionTitle) {
                                retryDiagnosticLabel(message)
                            }
                        }

                        Section(ScannerResultCopy.capturedAnglesSectionTitle) {
                            ForEach(
                                Array(scannerState.capturedAngleRecords.enumerated()),
                                id: \.offset
                            ) { index, capturedAngle in
                                HStack {
                                    Text("Angle \(index + 1)")
                                    Spacer()
                                    Text(
                                        "\(dimensionString(capturedAngle.evidence.estimate))"
                                            + " · \(capturedAngle.cameraProvenance.cameraZoom.label)"
                                    )
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let message = reviewState.additionalAngleMessage {
                            Section("Next step") {
                                Label(message, systemImage: "camera.rotate")
                                    .foregroundStyle(.blue)
                            }
                        }
                        }
                        .frame(
                            minHeight: showsRetainedAngleRetry ? 220 : nil,
                            idealHeight: showsRetainedAngleRetry ? 320 : nil,
                            maxHeight: showsRetainedAngleRetry ? 320 : 260
                        )
                        .layoutPriority(showsRetainedAngleRetry ? 1 : 0)
                    } else if case let .retryRequired(message) = reviewState {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(retryPresentation.sectionTitle)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            retryDiagnosticLabel(message)
                                .font(.footnote)
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                }

                actionBar
            }
            .padding()
            .navigationTitle("Scan Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        closeScanner()
                    }
                }
            }
        }
    }

    private var cameraPreview: some View {
        let isReviewingCapture = scannerState.objectOverlay != nil
        let compactRetryReview = showsRetainedAngleRetry
        let capturedAspectRatio = scannerState.objectOverlay.map {
            CGFloat($0.capturedPreviewAspectRatio)
        }
        let preferredAspectRatio = ScannerPreviewLayoutPolicy.preferredAspectRatio(
            showsLiveCamera: scannerState.showsLiveCameraPreview,
            liveCameraAspectRatio: scannerState.liveCameraAspectRatio,
            capturedAspectRatio: capturedAspectRatio
        )

        return ScannerPreviewSizingLayout(
            preferredAspectRatio: preferredAspectRatio
        ) {
            cameraPreviewSurface
        }
            .frame(maxWidth: .infinity)
            .frame(
                minHeight: isReviewingCapture || scannerState.showsLiveCameraPreview
                    ? nil
                    : (compactRetryReview ? 200 : 260),
                idealHeight: isReviewingCapture || scannerState.showsLiveCameraPreview
                    ? nil
                    : (compactRetryReview ? 240 : 360),
                maxHeight: isReviewingCapture || scannerState.showsLiveCameraPreview
                    ? nil
                    : (compactRetryReview ? 280 : 420)
            )
            .layoutPriority(scannerState.showsLiveCameraPreview ? 1 : 0)
    }

    private var cameraPreviewSurface: some View {
        MeasurementARView(scannerState: scannerState)
            .clipShape(ScannerPreviewClipShape())
            .overlay {
                if showsCameraGuide, scannerState.objectOverlay == nil {
                    if scannerState.measurementMode == .guidedCorners {
                        GuidedPointReticle()
                    } else {
                        CameraObjectFrame()
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack(alignment: .top, spacing: 8) {
                    if let target = scannerState.activeTargetLock,
                       ScannerPreviewOverlayPolicy.showsTargetStatus(
                           phase: scannerState.phase,
                           hasActiveTarget: true
                       ) {
                        ScannerTargetStatusBadge(
                            ownsAcceptedEvidence: target.ownsAcceptedEvidence
                        )
                    } else {
                        Text(statusText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.55), in: Capsule())
                    }

                    Spacer(minLength: 8)

                    cameraZoomOverlay
                }
                .padding()
            }
            .overlay(alignment: .bottom) {
                if showsCameraGuide, !scannerState.phase.isCapturing {
                    Text(previewGuidanceText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding()
                }
            }
    }

    @ViewBuilder
    private var actionBar: some View {
        if scannerState.measurementMode == .guidedCorners {
            guidedActionBar
        } else {
            automaticActionBar
        }
    }

    @ViewBuilder
    private var automaticActionBar: some View {
        switch scannerState.phase {
        case .checkingSupport:
            ProgressView(ScannerActionCopy.checkingSupport)
                .padding(.horizontal)
        case .scanning(let progress):
            ProgressView(ScannerActionCopy.processingPhoto, value: progress)
                .padding(.horizontal)
        case .unsupported:
            Button("Close") {
                closeScanner()
            }
            .buttonStyle(.borderedProminent)
        case .failed where scannerState.isPreparingForAiming:
            ProgressView(ScannerActionCopy.preparingPreview)
                .padding(.horizontal)
        case .failed:
            VStack(spacing: 10) {
                retryActionBar
                if showsGuidedEntryControl {
                    guidedEntryControl
                }
            }
        case .measured where scannerState.isPreparingForAiming:
            ProgressView(ScannerActionCopy.preparingPreview)
                .padding(.horizontal)
        case .measured where reviewState.additionalAngleMessage != nil:
            VStack(spacing: 10) {
                comparisonActionBar
                if showsGuidedEntryControl {
                    guidedEntryControl
                }
            }
        case .measured where !reviewState.canSave:
            VStack(spacing: 10) {
                retryActionBar
                if showsGuidedEntryControl {
                    guidedEntryControl
                }
            }
        default:
            measurementActionBar
        }
    }

    @ViewBuilder
    private var guidedActionBar: some View {
        switch scannerState.phase {
        case .checkingSupport:
            ProgressView(ScannerActionCopy.checkingSupport)
                .padding(.horizontal)
        case .unsupported:
            Button("Close") {
                closeScanner()
            }
            .buttonStyle(.borderedProminent)
        case .measured:
            measurementActionBar
        default:
            if let session = scannerState.guidedCaptureSession {
                ScannerGuidedCaptureControls(
                    presentation: ScannerGuidedCapturePresentation(
                        step: session.step,
                        feedback: guidedPresentationFeedback
                    ),
                    isTakingPoint: session.pendingRequest != nil,
                    actionsEnabled: guidedActionsEnabled,
                    onBack: {
                        _ = scannerState.guidedBack()
                    },
                    onTakePoint: {
                        _ = scannerState.requestGuidedPointCapture()
                    },
                    onConfirm: {
                        _ = scannerState.confirmGuidedCapture()
                    }
                )
            }
        }
    }

    private var measurementActionBar: some View {
        VStack(spacing: 10) {
            HStack {
                if scannerState.measurementMode == .automaticPhotos {
                    if scannerState.estimate == nil {
                        measureButton
                            .buttonStyle(.borderedProminent)
                    } else {
                        measureButton
                            .buttonStyle(.bordered)
                    }

                    if scannerState.canChangeAutomaticTarget {
                        Button("Change item") {
                            _ = scannerState.changeAutomaticTarget()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let estimate = scannerState.estimate {
                    Button("Save item") {
                        saveItem(estimate)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!reviewState.canSave)
                    .accessibilityHint(
                        reviewState.canSave
                            ? "Saves this measurement to the packing inventory"
                            : "Retake the measurement before saving this item"
                    )
                }
            }

            if showsGuidedEntryControl {
                guidedEntryControl
            }
        }
    }

    private var retryActionBar: some View {
        HStack {
            Button("Close") {
                closeScanner()
            }
            .buttonStyle(.bordered)

            Button {
                prepareForAiming()
            } label: {
                Label(retryPresentation.actionTitle, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(ScannerBuild33AccessibilityID.retryPrimaryAction)
            .accessibilityHint(retryPresentation.actionHint)
        }
    }

    private var comparisonActionBar: some View {
        HStack {
            Button("Close") {
                closeScanner()
            }
            .buttonStyle(.bordered)

            Button {
                prepareForAiming()
            } label: {
                Label(ScannerActionCopy.compareAnotherAngle, systemImage: "camera.rotate")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var measureButton: some View {
        Button {
            if scannerState.estimate == nil {
                guard automaticCapturePresentation.canCapture else { return }
                startMeasurement()
            } else {
                prepareForAiming()
            }
        } label: {
            Label(
                scannerState.estimate == nil
                    ? automaticCapturePresentation.actionTitle
                    : ScannerActionCopy.measureAgain,
                systemImage: scannerState.estimate == nil
                    ? "camera.fill"
                    : "arrow.clockwise"
            )
        }
        .disabled(
            scannerState.estimate == nil
                && !automaticCapturePresentation.canCapture
        )
    }

    private var reviewState: ScannerCaptureReviewState {
        ScannerBuild33RuntimePolicy.reviewState(
            phase: scannerState.phase,
            estimate: scannerState.estimate,
            measurementProgress: scannerState.measurementProgress,
            subject: scannerState.measurementSubject,
            mode: scannerState.measurementMode
        )
    }

    private var retryPresentation: ScannerRetryPresentation {
        ScannerRetryPresentation.presentation(
            capturedAngleCount: scannerState.capturedAngleRecords.count,
            measurementProgress: scannerState.measurementProgress
        )
    }

    private var reviewLayoutMode: ScannerReviewLayoutMode {
        ScannerReviewLayoutPolicy.mode(
            capturedAngleCount: scannerState.capturedAngleRecords.count,
            reviewState: reviewState
        )
    }

    private var showsRetainedAngleRetry: Bool {
        reviewLayoutMode == .retainedAngleRetry
    }

    private var automaticCapturePresentation: ScannerAutomaticCapturePresentation {
        ScannerBuild33RuntimePolicy.automaticCapture(
            hasTarget: scannerState.activeTargetLock != nil,
            ownsAcceptedEvidence:
                scannerState.activeTargetLock?.ownsAcceptedEvidence == true,
            acceptedAngleCount: scannerState.capturedAngleRecords.count,
            canCapture: scannerState.canStartAutomaticCapture,
            validationMessage: scannerState.targetFrameValidationMessage
        )
    }

    private var showsModeSelector: Bool {
        scannerState.measurementMode == .automaticPhotos
            && scannerState.activeTargetLock == nil
            && scannerState.capturedAngleRecords.isEmpty
            && scannerState.estimate == nil
            && !scannerState.phase.isCapturing
            && !scannerState.isPreparingForAiming
    }

    private var canChangeMeasurementSetup: Bool {
        showsModeSelector && !scannerState.isApplyingCameraZoom
    }

    private var showsGuidedEntryControl: Bool {
        guard scannerState.measurementMode == .automaticPhotos,
              scannerState.measurementSubject == .box,
              scannerState.estimate == nil,
              !scannerState.phase.isCapturing,
              !scannerState.isApplyingCameraZoom else {
            return false
        }
        return scannerState.activeTargetLock != nil
            || !scannerState.capturedAngleRecords.isEmpty
            || automaticCaptureFailed
    }

    private var automaticCaptureFailed: Bool {
        if case .failed = scannerState.phase { return true }
        return false
    }

    private var guidedEntryPresentation: ScannerGuidedEntryPresentation {
        ScannerGuidedEntryPresentation.presentation(
            for: ScannerBuild33RuntimePolicy.guidedEntrySituation(
                automaticAngleCount: scannerState.capturedAngleRecords.count,
                automaticCaptureFailed: automaticCaptureFailed
            )
        )
    }

    private var guidedEntryControl: some View {
        ScannerGuidedEntryControl(
            presentation: guidedEntryPresentation,
            isEnabled: scannerState.measurementSubject == .box
                && !scannerState.phase.isCapturing
                && !scannerState.isApplyingCameraZoom,
            onEnter: {
                _ = scannerState.enterGuidedCorners()
            }
        )
    }

    private var guidedActionsEnabled: Bool {
        guard scannerState.measurementMode == .guidedCorners,
              let session = scannerState.guidedCaptureSession else {
            return false
        }
        if session.step == .review {
            return session.pendingRequest == nil
        }
        return scannerState.phase == .ready
            && session.pendingRequest == nil
    }

    private var guidedPresentationFeedback: ScannerGuidedFeedback {
        switch scannerState.guidedCaptureFeedback {
        case nil:
            return .none
        case let .error(message):
            return .error(message)
        case let .replacement(point, message):
            return .replacement(point: point, message: message)
        }
    }

    private func prepareForAiming() {
        scannerState.prepareForAiming()
    }

    private func startMeasurement() {
        scannerState.startMeasurement()
    }

    private func saveItem(_ estimate: MeasurementEstimate) {
        guard reviewState.canSave else { return }
        appModel.addItem(
            name: draftName,
            estimate: estimate,
            quantity: quantity,
            stackability: isStackable
                ? .stackable(maxLayers: maxStackLayers)
                : .notStackable,
            orientationPolicy: mayRotate ? .mayRotate : .keepUpright
        )
        closeScanner()
    }

    private func closeScanner() {
        if scannerState.measurementMode == .guidedCorners {
            scannerState.clearGuidedCapture(for: .exit)
        }
        dismiss()
    }

    private var statusText: String {
        switch scannerState.phase {
        case .checkingSupport:
            if scannerState.isApplyingCameraZoom {
                return "Switching to \(scannerState.cameraZoom.label)…"
            }
            return ScannerActionCopy.checkingSupport
        case .ready:
            if !scannerState.hasResolvedCameraZoomAvailability {
                return "Checking zoom availability…"
            }
            if scannerState.isApplyingCameraZoom {
                return "Switching to \(scannerState.cameraZoom.label)…"
            }
            return scannerState.capturedEstimates.isEmpty
                ? "Ready"
                : "Ready for angle \(scannerState.capturedEstimates.count + 1)"
        case .scanning:
            return ScannerActionCopy.processingPhoto
        case .measured:
            if scannerState.isPreparingForAiming {
                return ScannerActionCopy.preparingPreview
            }
            return switch reviewState {
            case .accepted:
                "Dimensions ready"
            case .needsAnotherAngle:
                "Compare another angle"
            case .retryRequired:
                "Try another photo"
            default:
                "Review dimensions"
            }
        case .unsupported:
            return "Measurement unavailable"
        case .failed:
            return scannerState.isPreparingForAiming
                ? ScannerActionCopy.preparingPreview
                : "Try another photo"
        }
    }

    private var showsCameraGuide: Bool {
        scannerState.showsCameraGuide
    }

    @ViewBuilder
    private var cameraZoomOverlay: some View {
        switch scannerState.cameraZoomPresentation {
        case .hidden:
            EmptyView()
        case .checking:
            CameraZoomStatusBadge(text: "Checking zoom…", showsProgress: true)
        case let .selectable(zooms, selectedZoom, isApplying):
            CameraZoomControl(
                zooms: zooms,
                selectedZoom: selectedZoom,
                isEnabled: scannerState.canChangeCameraZoom,
                isApplying: isApplying,
                onSelect: scannerState.selectCameraZoom
            )
        case .single(let zoom):
            CameraZoomStatusBadge(text: "\(zoom.label) fixed for LiDAR")
        case .fixed:
            CameraZoomStatusBadge(text: "Zoom unavailable with LiDAR")
        case .locked(let zoom):
            CameraZoomStatusBadge(text: "\(zoom.label) locked")
        }
    }

    private var previewGuidanceText: String {
        if scannerState.measurementMode == .guidedCorners,
           let step = scannerState.guidedCaptureSession?.step {
            return ScannerGuidedCapturePresentation(
                step: step,
                feedback: guidedPresentationFeedback
            ).prompt
        }
        if let guidance = automaticCapturePresentation.guidance {
            return guidance
        }
        return scannerState.capturedEstimates.isEmpty
            ? ScannerGuidanceCopy.setup
            : ScannerGuidanceCopy.additionalAnglePreview(
                acceptedAngleCount: scannerState.capturedEstimates.count
            )
    }

    private func dimensionString(_ estimate: MeasurementEstimate) -> String {
        "\(MeasurementMath.inchString(from: estimate.lengthMeters)) × "
            + "\(MeasurementMath.inchString(from: estimate.widthMeters)) × "
            + "\(MeasurementMath.inchString(from: estimate.heightMeters))"
    }

    private func retryDiagnosticLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(ScannerBuild33AccessibilityID.retryMessage)
    }
}

private struct CameraZoomControl: View {
    let zooms: [ScannerCameraZoom]
    let selectedZoom: ScannerCameraZoom
    let isEnabled: Bool
    let isApplying: Bool
    let onSelect: (ScannerCameraZoom) -> Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(zooms) { zoom in
                Button {
                    _ = onSelect(zoom)
                } label: {
                    Text(zoom.label)
                        .font(.caption2.weight(.bold))
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(zoom == selectedZoom ? .black : .white)
                        .background(
                            zoom == selectedZoom
                                ? Color.cyan
                                : Color.black.opacity(0.55),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled || isApplying)
                .opacity(isEnabled && !isApplying ? 1 : 0.55)
                .accessibilityLabel("Camera zoom \(zoom.label)")
                .accessibilityIdentifier(zoom.controlIdentifier)
                .accessibilityValue(zoom == selectedZoom ? "Selected" : "Not selected")
                .accessibilityHint(
                    isEnabled
                        ? "Changes the camera field of view before the next photo"
                        : isApplying
                            ? "Camera zoom is changing"
                            : "Camera zoom is unavailable right now"
                )
            }

            if isApplying {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .padding(.leading, 2)
                    .accessibilityLabel("Changing camera zoom")
            }
        }
        .padding(4)
        .background(.black.opacity(0.38), in: Capsule())
    }
}

private struct CameraZoomStatusBadge: View {
    let text: String
    var showsProgress = false

    var body: some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
            Text(text)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white)
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .background(.black.opacity(0.55), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

private struct CameraObjectFrame: View {
    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .strokeBorder(.white.opacity(0.78), lineWidth: 2)
                .padding(.horizontal, proxy.size.width * CGFloat(
                    ScannerPreviewFramingPolicy.protectedInsetFraction
                ))
                .padding(.vertical, proxy.size.height * CGFloat(
                    ScannerPreviewFramingPolicy.protectedInsetFraction
                ))
                .shadow(color: .black.opacity(0.45), radius: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The protected rectangular guide is always fully visible. On normal phone
/// sizes this retains the 24-point camera corners; on a highly compressed
/// preview it reduces the outer radius rather than hiding a guide corner that
/// the rectangular framing validator would still accept.
private struct ScannerPreviewClipShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(
            cornerRadius: ScannerPreviewFramingPolicy.safePreviewCornerRadius(
                in: rect.size
            )
        ).path(in: rect)
    }
}

private struct GuidedPointReticle: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.cyan, lineWidth: 3)
                .frame(width: 40, height: 40)
            Rectangle()
                .fill(.cyan)
                .frame(width: 2, height: 52)
            Rectangle()
                .fill(.cyan)
                .frame(width: 52, height: 2)
            Circle()
                .fill(.cyan)
                .frame(width: 8, height: 8)
        }
        .shadow(color: .black.opacity(0.75), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum ScannerCaptureReviewState: Equatable, Sendable {
    case waiting
    case capturing
    case accepted
    case needsAnotherAngle(String)
    case retryRequired(String)
    case unavailable(String)

    var canSave: Bool {
        self == .accepted
    }

    var additionalAngleMessage: String? {
        guard case .needsAnotherAngle(let message) = self else { return nil }
        return message
    }
}

enum ScannerCapturePolicy {
    static func reviewState(
        phase: ScannerPhase,
        estimate: MeasurementEstimate?,
        measurementProgress: MultiAngleMeasurementProgress
    ) -> ScannerCaptureReviewState {
        switch phase {
        case .checkingSupport, .ready:
            return .waiting
        case .scanning:
            return .capturing
        case let .unsupported(message):
            return .unavailable(message)
        case let .failed(message):
            return .retryRequired(message)
        case .measured:
            if let estimate, estimate.confidence == .low {
                return .retryRequired(ScannerGuidanceCopy.lowConfidenceRetry)
            }
            switch measurementProgress {
            case .needsAnotherAngle(let reason, let acceptedCount):
                return .needsAnotherAngle(
                    ScannerGuidanceCopy.additionalAngleMessage(
                        for: reason,
                        acceptedAngleCount: acceptedCount
                    )
                )
            case .inconsistent(let failure):
                return .retryRequired(
                    ScannerGuidanceCopy.consensusFailureMessage(for: failure)
                )
            case .awaitingFirstAngle:
                return .retryRequired(ScannerGuidanceCopy.missingEstimateRetry)
            case .accepted:
                break
            }
            guard let estimate else {
                return .retryRequired(ScannerGuidanceCopy.missingEstimateRetry)
            }
            guard estimate.confidence != .low else {
                return .retryRequired(ScannerGuidanceCopy.lowConfidenceRetry)
            }
            return .accepted
        }
    }
}

enum ScannerGuidanceCopy {
    static let previewTarget =
        "Fit one object inside the frame"

    static let setup =
        "Keep the whole object visible, then take a photo."

    static func additionalAnglePreview(acceptedAngleCount: Int) -> String {
        switch acceptedAngleCount {
        case ...0:
            setup
        case 1:
            "Keep the item still. Move to another side and keep the whole item inside the frame."
        default:
            "Keep the item still. For the final photo, move left or right, raise or lower the phone, and keep the whole item inside the frame."
        }
    }

    static let lowConfidenceRetry =
        "We couldn't get clear dimensions from this photo. Keep one object fully visible and try again."

    static let missingEstimateRetry =
        "We couldn't measure this photo. Keep one object fully visible and try again."

    static func additionalAngleMessage(
        for reason: MeasurementAdditionalAngleReason,
        acceptedAngleCount: Int
    ) -> String {
        switch reason {
        case .firstAngleCaptured:
            "First angle captured. Keep the item still, move around it, and take a second photo."
        case .viewpointTooSimilar:
            if acceptedAngleCount >= 2 {
                "That view was still too similar to the saved angles. Keep the item still; move farther left or right and raise or lower the phone for the final photo."
            } else {
                "That view was too similar. Move farther left or right without moving the item."
            }
        case .thirdAngleRequired:
            "Good agreement so far. Take one final photo from another side with the phone higher or lower."
        case .elevationTooSimilar:
            "Change camera height for the final photo. Raise or lower the phone and move around the item."
        case .dimensionsDisagree:
            "The first two angles differed. Take one final photo from another side with the phone higher or lower."
        }
    }

    static func consensusFailureMessage(
        for failure: MeasurementConsensusFailure
    ) -> String {
        switch failure {
        case .dimensionsInconsistent:
            "The three angles did not agree enough for a reliable estimate. Restart with the item still."
        case .invalidMeasurement:
            "One photo produced invalid dimensions. Restart the scan."
        }
    }
}

enum ScannerPhotoFailureCopy {
    static func message(
        for failure: SingleShotCaptureFailure,
        fallbackResult: SingleShotFallbackResult = .notAttempted
    ) -> String {
        if let fallbackMessage = fallbackMessage(for: fallbackResult) {
            return fallbackMessage
        }
        return specificMessage(for: failure)
            ?? categoryMessage(for: failure.retryCategory)
    }

    private static func fallbackMessage(
        for result: SingleShotFallbackResult
    ) -> String? {
        switch result {
        case .notAttempted, .accepted:
            nil
        case .targetRejected(.floorSurface):
            "Foreground detection missed this shape, and the center-depth fallback found the floor. Keep the center of the frame on the object and retake the photo."
        case .targetRejected(.insufficientSurfaceEvidence):
            "Foreground detection missed this shape, and the center-depth fallback couldn't isolate enough of it. Keep the object centered and try a slightly lower three-quarter angle."
        case .unavailable:
            "Foreground detection missed this shape, and the center-depth fallback wasn't ready. Hold steady with the object centered and retake the photo."
        }
    }

    private static func specificMessage(for failure: SingleShotCaptureFailure) -> String? {
        switch failure {
        case .sceneDepthUnavailable:
            "The LiDAR depth frame wasn't ready. Hold steady for a moment and retake the photo."
        case .depthGridUnreadable:
            "PackMeasure couldn't read the LiDAR depth frame. Retake the photo; if this repeats, close and reopen the scanner."
        case .foreground(.noObservation):
            "PackMeasure couldn't find the selected item's outline in this photo. Keep the item still, move the phone closer while keeping every edge visible, and retake."
        case .foreground(.photo(_, .noForegroundInstance)):
            "Foreground detection couldn't separate the selected item from its surroundings. Keep the item still, show less floor, and retake from a clearer three-quarter angle."
        case .targetSelection(.noForegroundAtTargetPoint):
            "PackMeasure couldn't match the selected item in this frame. Retap the same item and retake the photo."
        case .targetSelection(.staleTargetSelectionPrompt):
            "That item selection is no longer current. Retap the same item before taking another photo."
        case .targetSelection(.invalidTargetSelectionPoint):
            nil
        case .targetLock(let reason):
            reason.actionMessage
        case .foreground(.photo(_, let error)), .photo(let error):
            photoErrorMessage(for: error)
        case .foreground, .unexpectedProcessingFailure:
            nil
        }
    }

    private static func photoErrorMessage(
        for error: PhotoObjectMeasurementError
    ) -> String? {
        switch error {
        case .ambiguousForegroundInstances:
            "PackMeasure found more than one foreground object. Center only the item you want to measure and retake the photo."
        case .noReticleDepthSurface:
            "PackMeasure couldn't isolate a depth-connected object under the center of the frame. Center the item and retake the photo."
        case let .maskAreaTooSmall(actual, minimum):
            "The selected item covered only \(percent(actual, rounded: .down))% of the photo; this build needs at least \(percent(minimum, rounded: .up))%. Move closer and keep a solid surface under the marker."
        case let .maskAreaTooLarge(actual, maximum):
            "The selected item covered \(percent(actual, rounded: .up))% of the photo; this build allows at most \(percent(maximum, rounded: .down))%. Step back until every item edge is visible."
        case .maskTouchesImageEdge(stage: .previewOutline):
            "The item was cropped by the visible camera frame. Switch to 0.5× if available, or step back until every edge is visible."
        case .maskTouchesImageEdge(stage: .sourceMask):
            "The detected outline ran into the photo edge. Step back, or retap a solid surface of the item and retake the photo."
        case .targetOwnershipAmbiguous:
            "PackMeasure couldn't separate the selected item from something touching it. Move the nearby item if practical, then retap a solid area—or use 4 points."
        case let .insufficientDepthSamples(actual, minimum):
            "LiDAR found \(actual) usable depth points on the object; this build needs \(minimum). Hold steady at a three-quarter angle and retake it."
        case let .insufficientDepthCoverage(actual, minimum):
            "LiDAR covered \(percent(actual, rounded: .down))% of the isolated object; this build needs \(percent(minimum, rounded: .up))%. Hold steady at a three-quarter angle and retake it."
        case let .insufficientHorizontalDepthSupport(actual, minimum):
            "LiDAR covered \(percent(actual, rounded: .down))% of the isolated object's horizontal span in the photo; this build needs \(percent(minimum, rounded: .up))%. Hold steady at a three-quarter angle and retake it."
        case let .insufficientVerticalDepthSupport(actual, minimum):
            "LiDAR covered \(percent(actual, rounded: .down))% of the isolated object's vertical span in the photo; this build needs \(percent(minimum, rounded: .up))%. Hold steady at a three-quarter angle and retake it."
        case let .insufficientHorizontalDepthEndpointCoverage(actual, minimum):
            "LiDAR depth covered \(percent(actual, rounded: .down))% of the least-covered horizontal endpoint band in the photo; this build needs \(percent(minimum, rounded: .up))% at both horizontal ends. Hold steady at a three-quarter angle and retake it."
        case let .insufficientVerticalDepthEndpointCoverage(actual, minimum):
            "LiDAR depth covered \(percent(actual, rounded: .down))% of the least-covered vertical endpoint band in the photo; this build needs \(percent(minimum, rounded: .up))% at both vertical ends. Hold steady at a three-quarter angle and retake it."
        case .multipleRigidItemsDetected:
            "The selected outline appears to include more than one box. Retap a solid face of the one box you want, or use 4 points if the boxes cannot be separated."
        case let .rigidItemMultiplicityUncertain(evaluation):
            switch evaluation.indeterminateReason {
            case .oneStrongBoundary:
                "The outline may include another box or an obstruction. Retap a solid face of the one box you want, or use 4 points."
            case .incompleteProfileCoverage, .noComparableSplit:
                "PackMeasure couldn't confirm enough of the box profile. Hold steady at a three-quarter angle and retake it, or use 4 points."
            case .footprintBelowMinimum:
                "This box is too small for automatic photo verification. Use 4 points."
            case .degenerateVerticalSpan:
                "LiDAR only saw a flat face. Retake at a three-quarter angle, or use 4 points."
            case .tooFewPoints:
                "LiDAR couldn't verify enough of the box. Hold steady at a three-quarter angle and retake it, or use 4 points."
            case .invalidConfiguration, .none:
                "PackMeasure couldn't confirm the selected outline is one box. Retap a solid face, or use 4 points."
            }
        case .noForegroundInstance:
            "Foreground detection didn't recognize the selected item. Tap a solid surface, show less floor, and retake from a clearer three-quarter angle."
        case .invalidLabelMaskDimensions,
             .invalidDepthMaskDimensions,
             .invalidPolicy,
             .unsupportedLabelMaskPixelFormat,
             .invalidLabelMaskPixelValue,
             .maskCalibrationAspectRatioMismatch,
             .depthGridResolutionMismatch,
             .invalidCameraCalibration,
             .invalidWorldPoint:
            nil
        }
    }

    private static func categoryMessage(
        for category: ScannerPhotoRetryCategory
    ) -> String {
        switch category {
        case .framing:
            "The selected item reached the edge of the camera view. Keep every item edge inside the view and retake it."
        case .isolation:
            "PackMeasure couldn't isolate the selected item. Tap a solid surface and retake the photo."
        case .depth:
            "PackMeasure couldn't get enough depth across the object. Hold steady at a three-quarter angle and retake it."
        case .processing:
            "The camera couldn't process this photo. Retake it; if this repeats, close and reopen the scanner."
        }
    }

    private static func percent(
        _ value: Float,
        rounded rule: FloatingPointRoundingRule
    ) -> String {
        let tenths = Int((value * 1_000).rounded(rule))
        guard !tenths.isMultiple(of: 10) else {
            return String(tenths / 10)
        }
        return "\(tenths / 10).\(abs(tenths % 10))"
    }
}

enum ScannerCrowdedSceneCopy {
    static let setupNote = "No clear space needed; nearby items may touch the box."
    static let enterGuidedAction = "Crowded box? Measure with 4 points"
    static let retryWithGuidedAction = "Use 4 points instead"
    static let restartWithGuidedAction = "Restart with 4 points"
    static let restartReplacementNote = "Replaces saved photo angles. No clear space needed."

    static func targetStatus(ownsAcceptedEvidence: Bool) -> String {
        ownsAcceptedEvidence
            ? "Item captured for this angle"
            : "Item selected for this angle"
    }
}

enum ScannerResultCopy {
    static let sizeSectionTitle = "Estimated dimensions"
    static let capturedAnglesSectionTitle = "Captured angles"

    static func qualitySummary(for estimate: MeasurementEstimate) -> String {
        if let angleCount = estimate.comparisonAngleCount,
           let agreementCount = estimate.comparisonAgreementCount {
            let agreement = agreementCount == angleCount
                ? "\(angleCount)-angle agreement"
                : "\(agreementCount) of \(angleCount) angles agree"
            return "\(agreement) — approximate; verify tight clearances"
        }
        if estimate.frameCount == 1, estimate.confidence != .low {
            return "Approximate single-photo estimate — compare another angle for tight fits"
        }
        return "\(estimate.confidence.title) scan quality"
    }
}

enum ScannerActionCopy {
    static let checkingSupport = "Starting camera…"
    static let measureAgain = "Retake photo"
    static let retryPhoto = "Retake photo"
    static let compareAnotherAngle = "Compare another angle"
    static let restartScan = "Restart scan"
    static let preparingPreview = "Opening camera…"
    static let processingPhoto = "Measuring…"
    static let startMeasurement = "Take photo"
}

enum ScannerActionPolicy {
    static func canStartMeasurement(phase: ScannerPhase) -> Bool {
        phase == .ready
    }
}

private extension ScannerPhase {
    var isCapturing: Bool {
        if case .scanning = self {
            return true
        }
        return false
    }
}
