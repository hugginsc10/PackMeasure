import ARKit
import SwiftUI

struct InteriorScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State var state = InteriorScanState()
    @State private var cameraID = UUID()
    @State private var restartOnForeground = false
    @State private var enteringHeight = false
    @State private var showingHelp = false
    @State private var confirmingReset = false
    @State private var showingDiagnostics = false
    var onSave: (InteriorMeasurement) throws -> Void

    private var supported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }
    var body: some View {
        NavigationStack {
            Group {
                if let result = state.result {
                    InteriorReviewView(record: result, onSave: { record in try onSave(record); dismiss() })

                } else if !supported && state.photo == nil && !state.hasOutline && state.sweepSeed == nil {
                    ContentUnavailableView("LiDAR needed for interiors", systemImage: "viewfinder",
                        description: Text("Use a LiDAR-equipped iPhone or iPad to capture the inside outline."))
                } else {
                    VStack(spacing: 0) {
                        steps.padding(.horizontal, 20).padding(.vertical, 10)
                        ZStack(alignment: .topLeading) {
                            if supported { InteriorCamera(state: state).id(cameraID) }
                            else { Color.black }
                            if let photo = state.photo {
                                ShelfPhotoPointPicker(image: photo.image,
                                    point: Binding(get: { state.photoCursor }, set: { if let point = $0 { state.placePhotoPoint(point) } }),
                                    outlines: state.loops.enumerated().map { index, loop in
                                        PhotoOutline(points: loop.map(photo.portraitPoint),
                                            closed: state.pinned || state.takingHeight || index < state.loops.count - 1)
                                    })
                                    .id(photo.id).accessibilityIdentifier("interior-frozen-photo")
                            } else {
                                Image(systemName: "plus").font(.title).foregroundStyle(.white).shadow(radius: 2)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                            }
                            Text(state.photo != nil ? "FROZEN · PINCH TO ZOOM" : state.ready ? "LIVE" : state.cameraStatus)
                                .font(.caption.weight(.semibold)).padding(8).background(.black.opacity(0.7), in: Capsule())
                                .padding(12).allowsHitTesting(false)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        controls
                    }
                    .navigationTitle(state.isSweeping ? "Scan compartment" : state.takingHeight ? "Usable height" : "Inside outline")
                }
            }
            .measureScreen().navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("How to scan", systemImage: "questionmark.circle") { showingHelp = true }
                            Button("Scan diagnostics", systemImage: "waveform.path.ecg") {
                                state.sweepDiagnostics=supported ? nil : "Interior sweep requires a LiDAR device."
                                state.diagnosticsStorage=nil; showingDiagnostics=true
                                if supported { Task { await state.prepareDiagnostics() } }
                            }
                            if state.isSweeping {
                                Button("Place corners myself", systemImage: "hand.point.up.left") { state.useManual() }
                                Button("Single-view outline", systemImage: "viewfinder") { state.findCorners() }
                            }
                            Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { confirmingReset = true }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Scan options")
                }
            }
            .confirmationDialog("Start this scan over?", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("Start over", role: .destructive) { reset() }
            } message: { Text("This clears the unfinished outline and its points.") }
            .sheet(isPresented: $enteringHeight) {
                InteriorHeightEntry { millimeters in state.enterHeight(millimeters) }
            }
            .sheet(isPresented: $showingHelp) { help }
            .sheet(isPresented: $showingDiagnostics) {
                NavigationStack {
                    VStack(spacing:20) {
                        Text("Share the captured geometry to help investigate this scan. Camera photographs are not included.")
                        if let report=state.sweepDiagnostics {
                            ShareLink("Share scan diagnostics", item:report).buttonStyle(.borderedProminent)
                            if let storage=state.diagnosticsStorage { Text(storage).font(.footnote).foregroundStyle(.secondary) }
                        } else { ProgressView("Preparing diagnostics…") }
                    }.padding().navigationTitle("Scan diagnostics").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Done") { showingDiagnostics=false } } }
                }.preferredColorScheme(.dark)
            }
        }.tint(MeasureStyle.accent).preferredColorScheme(.dark)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && state.result == nil { state.invalidate("The camera session ended. Start a fresh outline after returning."); restartOnForeground = true }
            else if phase == .active && state.result == nil && restartOnForeground {
                restartOnForeground = false; state.trackingInterrupted = false; cameraID = UUID()
            }
        }
    }
    private var steps: some View {
        HStack {
            Text(state.isSweeping ? "1  Choose" : "1  Outline").foregroundStyle(state.takingHeight || (state.isSweeping && state.sweepSeed != nil) ? .secondary : MeasureStyle.accent)
            Image(systemName: "chevron.right").font(.caption2)
            Text(state.isSweeping ? "2  Sweep" : "2  Height").foregroundStyle(state.takingHeight || (state.isSweeping && state.sweepSeed != nil) ? MeasureStyle.accent : .secondary)
            Image(systemName: "chevron.right").font(.caption2)
            Text("3  Review").foregroundStyle(.secondary)
        }.font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(state.isSweeping ? (state.sweepSeed == nil ? "Choose one compartment" : state.canReviewSweep ? "Outline captured" : "Sweep this compartment") : state.takingHeight ? "Set the usable height" : state.automatic ? "Finding the inside edges" : state.selectedCorner != nil ? "Move selected corner" : state.pinned ? "Outline captured" : state.loops.count > 1 ? "Trace obstacle \(state.loops.count - 1)" : "Capture the inside outline")
                        .font(.headline)
                    Spacer()
                    if state.isSweeping, state.sweepSeed != nil {
                        Label(state.canReviewSweep ? "Captured" : "Collecting", systemImage:state.canReviewSweep ? "checkmark.circle.fill" : "viewfinder")
                            .font(.caption).foregroundStyle(MeasureStyle.accent).accessibilityIdentifier("sweep-status")
                    } else if !state.takingHeight {
                        Text("\((state.automatic ? state.preview : state.loops).flatMap { $0 }.count) corners")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(state.prompt).font(.subheadline)
                if let error = state.error, !error.isEmpty {
                    Text(error).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("interior-error")
                }
                if state.isSweeping {
                    if state.sweepSeed == nil {
                        Button("Scan base at cross") { state.requestPoint() }
                            .buttonStyle(.borderedProminent).disabled(!state.ready || state.isCapturingPoint)
                            .accessibilityIdentifier("sweep-select-base")
                        Button("Place corners myself") { state.useManual() }.font(.subheadline).accessibilityIdentifier("manual-interior")
                    } else {
                        Button(state.canReviewSweep ? (state.sweepResult.height == nil ? "Use outline · set height" : "Review dimensions") : "Collecting inside edges…") { state.useSweepOutline() }
                            .buttonStyle(.borderedProminent).disabled(!state.canReviewSweep)
                            .accessibilityIdentifier("sweep-review")
                        Button("Choose another base") { state.chooseAnotherBase() }.font(.subheadline).accessibilityIdentifier("sweep-reselect")
                    }
                } else if state.takingHeight {
                    if state.photo == nil {
                        Button("Capture height at cross") { state.requestPoint() }
                            .buttonStyle(.borderedProminent).disabled(!state.ready || state.isCapturingPoint)
                    }
                    HStack {
                        Button("Edit outline", action: state.editOutline)
                        Spacer()
                        Button("Enter measured height") { enteringHeight = true }.accessibilityIdentifier("enter-interior-height")
                    }.font(.subheadline)
                } else if state.automatic {
                    Button(state.stablePreviewFrames >= 3 ? "Use this outline" : "Hold for a stable outline") { state.useOutline() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.ready || state.preview.isEmpty || state.stablePreviewFrames < 3 || state.isCapturingPoint)
                        .accessibilityIdentifier("use-interior-outline")
                    HStack {
                        Button("Place corners myself") { state.useManual() }.accessibilityIdentifier("manual-interior")
                        Spacer()
                        if state.error != nil { Button("Retry from cross") { state.findCorners() }.disabled(!state.ready || state.isCapturingPoint) }
                    }.font(.subheadline)
                } else if !state.manualPlacement && !state.pinned {
                    Button("Find outline") { state.findCorners() }
                        .buttonStyle(.borderedProminent).disabled(!state.ready || state.isCapturingPoint)
                    Button("Place corners myself") { state.useManual() }.accessibilityIdentifier("manual-interior")
                } else {
                    if state.canFinish { cornerPicker }
                    HStack {
                        if !state.pinned || state.selectedCorner != nil {
                            Button(state.selectedCorner == nil ? "Undo" : "Cancel move", action: state.undo)
                        }
                        Spacer()
                        if state.canFinish {
                            Button("Next: height") { state.finishLoop(addObstacle: false) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("interior-next-height")
                        }
                    }
                    if state.canFinish {
                        Button("Add obstacle", systemImage: "square.dashed") { state.finishLoop(addObstacle: true) }
                            .font(.subheadline).accessibilityIdentifier("interior-add-obstacle")
                    }
                }
                if !state.isSweeping && !state.automatic && (state.manualPlacement || state.pinned || state.takingHeight) {
                    HStack {
                        if state.photo != nil {
                            Button("Resume camera", systemImage: "camera", action: state.resumeCamera)
                                .accessibilityIdentifier("interior-resume")
                        } else {
                            Button(state.photoRequested ? "Freezing…" : "Freeze & zoom", systemImage: "viewfinder", action: state.freezeView)
                                .disabled(!state.ready || state.photoRequested || state.isCapturingPoint)
                            Spacer()
                            if !state.takingHeight && (!state.pinned || state.selectedCorner != nil) {
                                Button(state.selectedCorner == nil ? "Add at cross" : "Move to cross") { state.requestPoint() }
                                    .disabled(!state.ready || state.isCapturingPoint)
                            }
                        }
                    }.font(.subheadline)
                }
            }.padding(16)
        }.frame(height: state.isSweeping ? 230 : state.takingHeight ? 240 : 300)
            .background(MeasureStyle.panel)
    }
    private var cornerPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(state.loops.indices, id: \.self) { loop in
                    ForEach(state.loops[loop].indices, id: \.self) { point in
                        Button(loop == 0 ? "\(point + 1)" : "O\(loop)·\(point + 1)") { state.selectCorner(loop: loop, point: point) }
                            .buttonStyle(.bordered)
                            .tint(state.selectedCorner?.loop == loop && state.selectedCorner?.point == point ? .yellow : MeasureStyle.accent)
                            .accessibilityLabel(loop == 0 ? "Move corner \(point + 1)" : "Move obstacle \(loop) corner \(point + 1)")
                    }
                }
            }
        }.accessibilityIdentifier("interior-corners")
    }
    private var help: some View {
        NavigationStack {
            List {
                Label("Empty and steady the drawer or cabinet compartment.", systemImage: "1.circle")
                Label("Tap a visible patch on the inside base to select one compartment. Keep it still while you move the phone.", systemImage: "2.circle")
                Label("Sweep slowly across the base, sides and front edge. The highlighted patches show what has been captured; follow the prompt for missing areas.", systemImage: "3.circle")
                Label("Tilt up to capture the underside of the shelf above. Review becomes available when the inside edges agree across views. Height can also be entered from a measurement.", systemImage: "4.circle")
                Label("Inspect the outline before saving. Use Place corners myself in Scan options for corrections, notches or areas the sweep cannot capture. Account for drawer closure, hinges and overhangs.", systemImage: "5.circle")
                Text("This captures a level footprint and usable height. Check dimensions before making an insert.").font(.footnote)
            }.navigationTitle("Scan an interior").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingHelp = false } } }
        }.tint(MeasureStyle.accent).preferredColorScheme(.dark)
    }
    private func reset() { state = InteriorScanState(); cameraID = UUID() }
}

struct InteriorHeightEntry: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var inches = true
    @State private var error: String?
    let onApply: (Double) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Available space above the base") {
                    Picker("Units", selection: Binding(get: { inches }, set: changeUnits)) {
                        Text("Inches").tag(true); Text("Millimeters").tag(false)
                    }.pickerStyle(.segmented)
                    TextField(inches ? "Height in inches" : "Height in millimeters", text: $value)
                        .keyboardType(.decimalPad).accessibilityIdentifier("interior-height-value")
                    Text("Enter a measured height that clears the drawer opening, shelf or lowest overhead obstruction.").font(.footnote)
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }.navigationTitle("Enter height").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Use height") {
                        guard let number = number, (10...3000).contains(number * (inches ? 25.4 : 1)) else {
                            error = "Enter a height from 10 to 3,000 mm (about 0.4–118 inches)."; return
                        }
                        onApply(number * (inches ? 25.4 : 1)); dismiss()
                    }.accessibilityIdentifier("apply-interior-height") }
                }
        }.tint(MeasureStyle.accent).preferredColorScheme(.dark)
    }
    private var number: Double? {
        let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        return parsed?.isFinite == true ? parsed : nil
    }
    private func changeUnits(_ next: Bool) {
        guard next != inches else { return }
        if !value.isEmpty {
            guard let number else { error = "Check the height before changing units."; return }
            value = String(format: "%.3f", number * (next ? 1 / 25.4 : 25.4))
        }
        inches = next; error = nil
    }
}
