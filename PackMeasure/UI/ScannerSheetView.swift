import SwiftUI

struct ScannerSheetView: View {
    @MainActor
    @Observable
    final class ScannerStateModel {
        var captureRequestID = 0
        var phase: ScannerPhase = .checkingSupport
        var estimate: MeasurementEstimate?
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var scannerState = ScannerStateModel()
    @State private var draftName = ""
    @State private var quantity = 1
    @State private var isStackable = false
    @State private var maxStackLayers = 2
    @State private var mayRotate = false
    @State private var targetConfirmed = false

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
                        Section("Measured Size") {
                            Text(
                                "\(MeasurementMath.inchString(from: estimate.lengthMeters)) × " +
                                "\(MeasurementMath.inchString(from: estimate.widthMeters)) × " +
                                "\(MeasurementMath.inchString(from: estimate.heightMeters))"
                            )
                            Text("\(estimate.confidence.title) confidence • \(estimate.sampleCount) points")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        if case let .retryRequired(message) = reviewState {
                            Section("Try another scan") {
                                Label(message, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Section {
                                Toggle(
                                    ScannerGuidanceCopy.targetConfirmation,
                                    isOn: $targetConfirmed
                                )
                                if reviewState == .confirmTarget {
                                    Label(
                                        ScannerGuidanceCopy.targetConfirmationDetail,
                                        systemImage: "scope"
                                    )
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                } else if reviewState == .accepted {
                                    Label("Target confirmed", systemImage: "checkmark.circle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.green)
                                }
                            } header: {
                                Text("Target check")
                            }

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
        case .measured where !reviewState.canSave:
            if case .confirmTarget = reviewState {
                measurementActionBar
            } else {
                retryActionBar
            }
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
                        : "Confirm that the center dot stayed on a clear object face first"
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
                requestCapture()
            } label: {
                Label("Scan again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var measureButton: some View {
        Button {
            requestCapture()
        } label: {
            Label(
                scannerState.estimate == nil ? "Measure object" : "Measure again",
                systemImage: "camera.aperture"
            )
        }
    }

    private var reviewState: ScannerCaptureReviewState {
        ScannerCapturePolicy.reviewState(
            phase: scannerState.phase,
            estimate: scannerState.estimate,
            targetConfirmed: targetConfirmed
        )
    }

    private func requestCapture() {
        targetConfirmed = false
        scannerState.estimate = nil
        scannerState.captureRequestID += 1
    }

    private var statusText: String {
        switch scannerState.phase {
        case .checkingSupport:
            "Checking LiDAR support..."
        case .ready:
            "Ready to scan"
        case .scanning:
            "Scanning..."
        case .measured:
            switch reviewState {
            case .accepted:
                "Target confirmed"
            case .confirmTarget:
                "Check the target before saving"
            case .retryRequired:
                "Try another scan"
            default:
                "Review measurement"
            }
        case .unsupported:
            "LiDAR unavailable"
        case .failed:
            "Try another scan"
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
    case confirmTarget
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
        estimate: MeasurementEstimate?,
        targetConfirmed: Bool
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
            return targetConfirmed ? .accepted : .confirmTarget
        }
    }
}

enum ScannerGuidanceCopy {
    static let previewTarget =
        "Put center dot on a clear object face — keep floor and background outside the object"

    static let setup =
        "Stand at a 3/4 angle so the front, side, and top are visible. Put the whole object inside the yellow frame, place the center dot on a clear object face, and keep visible floor or background around the object's edges."

    static let targetConfirmation =
        "Center dot stayed on a clear object face"

    static let targetConfirmationDetail =
        "Confirm only if the yellow center dot was on the object—not the floor, wall, or background."

    static let lowConfidenceRetry =
        "This scan could not isolate a reliable object measurement. Keep the object inside the frame, put the center dot on a clear object face, and scan again."

    static let missingEstimateRetry =
        "No object measurement was produced. Keep the object inside the frame, put the center dot on a clear object face, and scan again."
}
