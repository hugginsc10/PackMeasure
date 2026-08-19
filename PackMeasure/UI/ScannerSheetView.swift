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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                MeasurementARView(scannerState: scannerState)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 260, idealHeight: 360, maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .overlay {
                    ScanReticle()
                }
                .overlay(alignment: .topLeading) {
                    Text(statusText)
                        .padding(12)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding()
                }
                .overlay(alignment: .bottom) {
                    Text("Keep the center target on the object")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule())
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
                    .frame(maxHeight: 310)
                } else {
                    Text("Stand at a 3/4 angle so the front, side, and top are visible. Center one object, keep some floor around it, and hold steady while it measures.")
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
            HStack {
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button {
                    scannerState.estimate = nil
                    scannerState.captureRequestID += 1
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        default:
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
                }
            }
        }
    }

    private var measureButton: some View {
        Button {
            scannerState.estimate = nil
            scannerState.captureRequestID += 1
        } label: {
            Label(
                scannerState.estimate == nil ? "Measure object" : "Measure again",
                systemImage: "camera.aperture"
            )
        }
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
            scannerState.estimate?.confidence.guidance ?? "Scan complete"
        case .unsupported(let message):
            message
        case .failed(let message):
            message
        }
    }
}

private struct ScanReticle: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.95), lineWidth: 2)
                .frame(width: 52, height: 52)
            Circle()
                .fill(.white)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 76, height: 1)
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 1, height: 76)
        }
        .shadow(color: .black.opacity(0.75), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
