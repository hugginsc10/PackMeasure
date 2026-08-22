import SwiftUI

struct ScannerSheetView: View {
    @MainActor
    @Observable
    final class ScannerStateModel {
        var captureRequestID = 0
        var previewRequestID = 0
        var phase: ScannerPhase = .checkingSupport
        var estimate: MeasurementEstimate?
        private(set) var isPreparingForAiming = false
        private(set) var measurementSeriesID = 0
        private(set) var measurementWorkflow = MultiAngleMeasurementWorkflow()

        var measurementProgress: MultiAngleMeasurementProgress {
            measurementWorkflow.progress
        }

        var capturedEstimates: [MeasurementEstimate] {
            measurementWorkflow.captures.map(\.evidence.estimate)
        }

        @discardableResult
        func receiveMeasurement(
            _ capture: MeasurementAngleCapture
        ) -> MultiAngleMeasurementProgress {
            isPreparingForAiming = false
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
            isPreparingForAiming = true
            previewRequestID += 1
        }

        func startMeasurement() {
            guard ScannerActionPolicy.canStartMeasurement(phase: phase) else { return }
            estimate = nil
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
                MeasurementARView(scannerState: scannerState)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 260, idealHeight: 360, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay {
                    if showsCameraGuide {
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
                && !ScannerActionPolicy.canStartMeasurement(phase: scannerState.phase)
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
        guard scannerState.estimate == nil else { return false }
        if case .unsupported = scannerState.phase { return false }
        return true
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
        measurementProgress: MultiAngleMeasurementProgress = .awaitingFirstAngle
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
            case .awaitingFirstAngle, .accepted:
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
        "Keep the item still; move left or right for another angle"

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
        case .dimensionsDisagree:
            "The first two angles differed. Take one final photo from another side."
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
        case let .maskAreaTooSmall(actual, minimum):
            "The isolated object covered only \(percent(actual, rounded: .down))% of the photo; this build needs at least \(percent(minimum, rounded: .up))%. Move closer or use a more contrasting background."
        case let .maskAreaTooLarge(actual, maximum):
            "The isolated object covered \(percent(actual, rounded: .up))% of the photo; this build allows at most \(percent(maximum, rounded: .down))%. Step back so the whole object has visible space around it."
        case .maskTouchesImageEdge:
            "The isolated object reached the edge of the photo. Keep it fully visible with space around every side and retake it."
        case let .insufficientDepthSamples(actual, minimum):
            "LiDAR found \(actual) usable depth points on the object; this build needs \(minimum). Hold steady at a three-quarter angle and retake it."
        case let .insufficientDepthCoverage(actual, minimum):
            "LiDAR covered \(percent(actual, rounded: .down))% of the isolated object; this build needs \(percent(minimum, rounded: .up))%. Hold steady at a three-quarter angle and retake it."
        case let .insufficientHorizontalDepthSupport(actual, minimum):
            "LiDAR covered \(percent(actual, rounded: .down))% of the isolated object's horizontal span in the photo; this build needs \(percent(minimum, rounded: .up))%. Hold steady at a three-quarter angle and retake it."
        case let .insufficientVerticalDepthSupport(actual, minimum):
            "LiDAR covered \(percent(actual, rounded: .down))% of the isolated object's vertical span in the photo; this build needs \(percent(minimum, rounded: .up))%. Hold steady at a three-quarter angle and retake it."
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
            "The object reached the edge of the photo. Keep it fully visible with space around it and retake it."
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
