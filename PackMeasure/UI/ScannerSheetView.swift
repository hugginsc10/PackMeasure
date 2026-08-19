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
            guard phase == .measured, estimate != nil else { return }
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
                    ObjectTargetGuide(phase: scannerState.phase)
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
                    Text(ScannerGuidanceCopy.previewTarget)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.yellow, in: Capsule())
                        .padding()
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
                            Section("Try another scan") {
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
                } else if scannerState.isPreparingForAiming {
                    Text(ScannerGuidanceCopy.setup)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
                } else if case let .retryRequired(message) = reviewState {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal)
                } else {
                    Text(ScannerGuidanceCopy.setup)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .multilineTextAlignment(.center)
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
            ProgressView(value: progress)
                .padding(.horizontal)
        case .unsupported:
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
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
                if scannerState.estimate == nil {
                    requestCaptureAfterFailure()
                } else {
                    prepareForAiming()
                }
            } label: {
                Label("Scan again", systemImage: "arrow.clockwise")
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
                systemImage: "camera.aperture"
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

    private func requestCaptureAfterFailure() {
        scannerState.estimate = nil
        scannerState.captureRequestID += 1
    }

    private var statusText: String {
        switch scannerState.phase {
        case .checkingSupport:
            return ScannerActionCopy.checkingSupport
        case .ready:
            return "Ready to scan"
        case .scanning:
            return "Scanning..."
        case .measured:
            if scannerState.isPreparingForAiming {
                return ScannerActionCopy.preparingPreview
            }
            return switch reviewState {
            case .accepted:
                "Measurement ready"
            case .retryRequired:
                "Try another scan"
            default:
                "Review measurement"
            }
        case .unsupported:
            return "LiDAR unavailable"
        case .failed:
            return "Try another scan"
        }
    }
}

private struct ObjectTargetGuide: View {
    let phase: ScannerPhase

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(.yellow.opacity(0.06))
                .overlay {
                    RoundedRectangle(cornerRadius: 26)
                        .strokeBorder(
                            guideColor,
                            style: StrokeStyle(lineWidth: 4, dash: [18, 8])
                        )
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 62)

            VStack {
                Text("OBJECT IN FRAME • DOT ON CLEAR FACE")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(guideColor, in: Capsule())
                Spacer()
            }
            .padding(.top, 48)

            Circle()
                .stroke(.black.opacity(0.8), lineWidth: 5)
                .frame(width: 28, height: 28)
            Circle()
                .fill(guideColor)
                .frame(width: 18, height: 18)
            Rectangle()
                .fill(guideColor)
                .frame(width: 74, height: 4)
            Rectangle()
                .fill(guideColor)
                .frame(width: 4, height: 74)
        }
        .shadow(color: .black.opacity(0.85), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var guideColor: Color {
        if case .scanning = phase {
            return .green
        }
        return .yellow
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
        "Keep one whole item inside the frame with a little space around it"

    static let setup =
        "Point the camera at one object so the whole item is visible with a little floor or background around its edges. Tap Take measurement to capture one frame and estimate its overall size."

    static let lowConfidenceRetry =
        "This photo produced a weak depth sample. Retake it with one whole object in frame and clearer separation from the room."

    static let missingEstimateRetry =
        "No usable object measurement was produced from this photo. Retake it with one whole object in frame."
}

enum ScannerResultCopy {
    static let sizeSectionTitle = "Estimated size"

    static func qualitySummary(for estimate: MeasurementEstimate) -> String {
        "\(estimate.confidence.title) point-cloud quality • \(estimate.sampleCount) points"
    }
}

enum ScannerActionCopy {
    static let checkingSupport = "Checking LiDAR support…"
    static let measureAgain = "Measure again"
    static let preparingPreview = "Returning to camera…"
    static let startMeasurement = "Take measurement"
}

enum ScannerActionPolicy {
    static func canStartMeasurement(phase: ScannerPhase) -> Bool {
        phase == .ready
    }
}
