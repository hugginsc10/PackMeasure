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

        func prepareForAiming() {
            switch phase {
            case .measured where estimate != nil, .failed:
                break
            default:
                return
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
                        Text(ScannerGuidanceCopy.previewTarget)
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
                Label(ScannerActionCopy.retryPhoto, systemImage: "arrow.clockwise")
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
            estimate: scannerState.estimate
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
            return "Ready"
        case .scanning:
            return ScannerActionCopy.processingPhoto
        case .measured:
            if scannerState.isPreparingForAiming {
                return ScannerActionCopy.preparingPreview
            }
            return switch reviewState {
            case .accepted:
                "Dimensions ready"
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
    case retryRequired(String)
    case unavailable(String)

    var canSave: Bool {
        self == .accepted
    }
}

enum ScannerCapturePolicy {
    static func reviewState(
        phase: ScannerPhase,
        estimate: MeasurementEstimate?
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

    static let lowConfidenceRetry =
        "We couldn't get clear dimensions from this photo. Keep one object fully visible and try again."

    static let missingEstimateRetry =
        "We couldn't measure this photo. Keep one object fully visible and try again."
}

enum ScannerResultCopy {
    static let sizeSectionTitle = "Estimated dimensions"

    static func qualitySummary(for estimate: MeasurementEstimate) -> String {
        "\(estimate.confidence.title) scan quality"
    }
}

enum ScannerActionCopy {
    static let checkingSupport = "Starting camera…"
    static let measureAgain = "Retake photo"
    static let retryPhoto = "Retake photo"
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
