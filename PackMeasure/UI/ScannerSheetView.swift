import SwiftUI

/// Keeps the AR representable at one stable SwiftUI identity while allowing a
/// captured result to use the exact viewport aspect ratio from its live frame.
/// The live preview retains its flexible 260...420 point height instead of
/// passing a nil aspect ratio, which can collapse a UIViewRepresentable.
private struct ScannerPreviewSizingLayout: Layout {
    let capturedAspectRatio: CGFloat?

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        guard let capturedAspectRatio,
              capturedAspectRatio.isFinite,
              capturedAspectRatio > 0,
              let width = proposal.width,
              width.isFinite,
              width > 0 else {
            return subview.sizeThatFits(proposal)
        }
        return CGSize(width: width, height: width / capturedAspectRatio)
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
        var captureRequestID = 0
        var previewRequestID = 0
        private(set) var cameraZoomRequestID = 0
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
        private(set) var isPreparingForAiming = false
        private(set) var measurementSeriesID = 0
        private(set) var measurementWorkflow = MultiAngleMeasurementWorkflow()

        var measurementProgress: MultiAngleMeasurementProgress {
            measurementWorkflow.progress
        }

        var capturedEstimates: [MeasurementEstimate] {
            measurementWorkflow.captures.map(\.evidence.estimate)
        }

        var canChangeCameraZoom: Bool {
            availableCameraZooms.count > 1
                && capturedEstimates.isEmpty
                && phase == .ready
                && !isApplyingCameraZoom
        }

        var canStartMeasurement: Bool {
            ScannerActionPolicy.canStartMeasurement(phase: phase)
                && !isApplyingCameraZoom
        }

        var shouldReapplyCameraZoomAfterSessionRun: Bool {
            cameraZoomUsesConfigurableDevice
                && hasConfirmedExplicitCameraZoom
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
            if !capturedEstimates.isEmpty {
                return .locked(cameraZoom)
            }
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
        }

        func cameraZoomApplicationFailed() {
            cameraZoom = lastConfirmedCameraZoom
            hasConfirmedExplicitCameraZoom = false
            isApplyingCameraZoom = false
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
            return true
        }

        @discardableResult
        func receiveMeasurement(
            _ capture: MeasurementAngleCapture
        ) -> MultiAngleMeasurementProgress {
            isPreparingForAiming = false
            objectOverlay = capture.objectOverlay
            guard capture.evidence.estimate.confidence != .low else {
                estimate = capture.evidence.estimate
                phase = .measured
                return measurementWorkflow.progress
            }

            let progress = measurementWorkflow.record(capture)
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
            measurementWorkflow.reset()
            measurementSeriesID += 1
            estimate = nil
            objectOverlay = nil
            isApplyingCameraZoom = false
            isPreparingForAiming = false
        }

        func prepareForAiming() {
            switch phase {
            case .measured, .failed:
                break
            default:
                return
            }
            switch measurementWorkflow.progress {
            case .accepted, .inconsistent:
                resetMeasurementSeries()
            case .awaitingFirstAngle, .needsAnotherAngle:
                break
            }
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
            phase = .ready
            return true
        }

        func startMeasurement() {
            guard canStartMeasurement else { return }
            estimate = nil
            objectOverlay = nil
            isPreparingForAiming = false
            captureRequestID += 1
            phase = .scanning(progress: 0)
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

                if let estimate = scannerState.estimate {
                    Form {
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
                                    Array(scannerState.capturedEstimates.enumerated()),
                                    id: \.offset
                                ) { index, capturedEstimate in
                                    HStack {
                                        Text("Angle \(index + 1)")
                                        Spacer()
                                        Text(dimensionString(capturedEstimate))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if case let .retryRequired(message) = reviewState {
                            Section("Try another photo") {
                                Label(message, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        } else {
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
                    .frame(maxHeight: 360)
                } else if !scannerState.capturedEstimates.isEmpty {
                    Form {
                        Section(ScannerResultCopy.capturedAnglesSectionTitle) {
                            ForEach(
                                Array(scannerState.capturedEstimates.enumerated()),
                                id: \.offset
                            ) { index, capturedEstimate in
                                HStack {
                                    Text("Angle \(index + 1)")
                                    Spacer()
                                    Text(dimensionString(capturedEstimate))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let message = reviewState.additionalAngleMessage {
                            Section("Next step") {
                                Label(message, systemImage: "camera.rotate")
                                    .foregroundStyle(.blue)
                            }
                        } else if case let .retryRequired(message) = reviewState {
                            Section("Restart scan") {
                                Label(message, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                } else if case let .retryRequired(message) = reviewState {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                }

                actionBar
            }
            .padding()
            .navigationTitle("Scan Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var cameraPreview: some View {
        let isReviewingCapture = scannerState.objectOverlay != nil
        let capturedAspectRatio = scannerState.objectOverlay.map {
            CGFloat($0.capturedPreviewAspectRatio)
        }

        return ScannerPreviewSizingLayout(
            capturedAspectRatio: capturedAspectRatio
        ) {
            cameraPreviewSurface
        }
            .frame(maxWidth: .infinity)
            .frame(
                minHeight: isReviewingCapture ? nil : 260,
                idealHeight: isReviewingCapture ? nil : 360,
                maxHeight: isReviewingCapture ? nil : 420
            )
    }

    private var cameraPreviewSurface: some View {
        MeasurementARView(scannerState: scannerState)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay {
                if showsCameraGuide, scannerState.objectOverlay == nil {
                    CameraObjectFrame()
                }
            }
            .overlay(alignment: .top) {
                Text(statusText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding()
            }
            .overlay(alignment: .topTrailing) {
                cameraZoomOverlay
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
        switch scannerState.phase {
        case .checkingSupport:
            ProgressView(ScannerActionCopy.checkingSupport)
                .padding(.horizontal)
        case .scanning(let progress):
            ProgressView(ScannerActionCopy.processingPhoto, value: progress)
                .padding(.horizontal)
        case .unsupported:
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        case .failed where scannerState.isPreparingForAiming:
            ProgressView(ScannerActionCopy.preparingPreview)
                .padding(.horizontal)
        case .failed:
            retryActionBar
        case .measured where scannerState.isPreparingForAiming:
            ProgressView(ScannerActionCopy.preparingPreview)
                .padding(.horizontal)
        case .measured where reviewState.additionalAngleMessage != nil:
            comparisonActionBar
        case .measured where !reviewState.canSave:
            retryActionBar
        default:
            measurementActionBar
        }
    }

    private var measurementActionBar: some View {
        HStack {
            if scannerState.estimate == nil {
                measureButton
                    .buttonStyle(.borderedProminent)
            } else {
                measureButton
                    .buttonStyle(.bordered)
            }

            if let estimate = scannerState.estimate {
                Button("Save item") {
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
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!reviewState.canSave)
                .accessibilityHint(
                    reviewState.canSave
                        ? "Saves this measurement to the packing inventory"
                        : "Retake the photo before saving this item"
                )
            }
        }
    }

    private var retryActionBar: some View {
        HStack {
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.bordered)

            Button {
                prepareForAiming()
            } label: {
                Label(retryActionTitle, systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var comparisonActionBar: some View {
        HStack {
            Button("Close") {
                dismiss()
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
                startMeasurement()
            } else {
                prepareForAiming()
            }
        } label: {
            Label(
                scannerState.estimate == nil
                    ? ScannerActionCopy.startMeasurement
                    : ScannerActionCopy.measureAgain,
                systemImage: scannerState.estimate == nil
                    ? "camera.fill"
                    : "arrow.clockwise"
            )
        }
        .disabled(
            scannerState.estimate == nil
                && !scannerState.canStartMeasurement
        )
    }

    private var reviewState: ScannerCaptureReviewState {
        ScannerCapturePolicy.reviewState(
            phase: scannerState.phase,
            estimate: scannerState.estimate,
            measurementProgress: scannerState.measurementProgress
        )
    }

    private func prepareForAiming() {
        scannerState.prepareForAiming()
    }

    private func startMeasurement() {
        scannerState.startMeasurement()
    }

    private var statusText: String {
        switch scannerState.phase {
        case .checkingSupport:
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
        scannerState.capturedEstimates.isEmpty
            ? ScannerGuidanceCopy.previewTarget
            : ScannerGuidanceCopy.additionalAnglePreview
    }

    private var retryActionTitle: String {
        if case .inconsistent = scannerState.measurementProgress {
            return ScannerActionCopy.restartScan
        }
        return ScannerActionCopy.retryPhoto
    }

    private func dimensionString(_ estimate: MeasurementEstimate) -> String {
        "\(MeasurementMath.inchString(from: estimate.lengthMeters)) × "
            + "\(MeasurementMath.inchString(from: estimate.widthMeters)) × "
            + "\(MeasurementMath.inchString(from: estimate.heightMeters))"
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
                        ? "Changes the camera field of view before the first angle"
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
        RoundedRectangle(cornerRadius: 24)
            .strokeBorder(.white.opacity(0.78), lineWidth: 2)
            .padding(.horizontal, 28)
            .padding(.vertical, 36)
            .shadow(color: .black.opacity(0.45), radius: 2)
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
            case .needsAnotherAngle(let reason, _):
                return .needsAnotherAngle(
                    ScannerGuidanceCopy.additionalAngleMessage(for: reason)
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

    static let additionalAnglePreview =
        "Keep the item still; move around it and change camera height"

    static let lowConfidenceRetry =
        "We couldn't get clear dimensions from this photo. Keep one object fully visible and try again."

    static let missingEstimateRetry =
        "We couldn't measure this photo. Keep one object fully visible and try again."

    static func additionalAngleMessage(
        for reason: MeasurementAdditionalAngleReason
    ) -> String {
        switch reason {
        case .firstAngleCaptured:
            "First angle captured. Keep the item still, move around it, and take a second photo."
        case .viewpointTooSimilar:
            "That view was too similar. Move farther left or right without moving the item."
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
            return "\(fallbackMessage) Diagnostic \(failure.diagnosticCode)."
        }
        let message = specificMessage(for: failure) ?? categoryMessage(for: failure.retryCategory)
        return "\(message) Diagnostic \(failure.diagnosticCode)."
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
        case .foreground(.noObservation),
             .foreground(.photo(_, .noForegroundInstance)):
            "Foreground detection didn't recognize this object. Try a lower three-quarter angle or place it against a plain wall."
        case .targetSelection(.noForegroundAtTargetPoint):
            "PackMeasure couldn't match the selected item in this frame. Retap the same item, or use 4 points if it cannot be isolated."
        case .targetSelection(.staleTargetSelectionPrompt):
            "That item selection is no longer current. Retap the same item before taking another photo."
        case .targetSelection(.invalidTargetSelectionPoint):
            nil
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
            "The isolated object covered only \(percent(actual, rounded: .down))% of the photo; this build needs at least \(percent(minimum, rounded: .up))%. Move closer or use a more contrasting background."
        case let .maskAreaTooLarge(actual, maximum):
            "The isolated object covered \(percent(actual, rounded: .up))% of the photo; this build allows at most \(percent(maximum, rounded: .down))%. Step back so the whole object has visible space around it."
        case .maskTouchesImageEdge:
            "The isolated object reached the edge of the camera view. Keep it fully visible with space around every side and retake it."
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
        case .noForegroundInstance:
            "Foreground detection didn't recognize this object. Try a lower three-quarter angle or place it against a plain wall."
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
            "The object reached the edge of the camera view. Keep it fully visible with space around it and retake it."
        case .isolation:
            "PackMeasure couldn't isolate one clear object from the background. Center one object against a contrasting background and retake it."
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
