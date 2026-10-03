import AVFoundation
import RoomPlan
import SwiftUI

struct RoomMeasurementView: View {
    @Environment(AppPreferences.self) private var preferences
    @State private var rooms: [MeasuredRoom] = []
    @State private var scanning = false
    @State private var errorMessage: String?
    private let store: RoomScanStore

    init(store: RoomScanStore = RoomScanStore()) {
        self.store = store
    }

    var body: some View {
        @Bindable var preferences = preferences
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Button { scanning = true } label: {
                        Label("Scan a room", systemImage: "viewfinder")
                    }
                    .buttonStyle(MeasurePrimaryButton())
                    .disabled(!RoomCaptureSession.isSupported)
                    .accessibilityIdentifier("start-room-scan")
                    if !RoomCaptureSession.isSupported {
                        Text("Room capture needs a LiDAR iPhone. You can still open saved rooms below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Scan guidance", selection: $preferences.roomGuidance) {
                        ForEach(RoomCaptureGuidance.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented)
                        .accessibilityIdentifier("room-scan-guidance")
                    Text(preferences.roomGuidance.preparation).font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Saved rooms").font(.headline)
                    Spacer()
                    Text("\(rooms.count)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if rooms.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "square.dashed").font(.title2).foregroundStyle(MeasureStyle.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("No saved rooms yet").font(.headline)
                            Text("Scan and save a room to revisit its floorplan and wall measurements.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.measurePanel()
                }
                ForEach(rooms) { room in
                    NavigationLink { RoomSavedDetailView(room: room, store: store) } label: {
                        HStack(spacing: 14) {
                            RoomFloorplanPreview(walls: room.walls).frame(width: 82, height: 76)
                                .background(MeasureStyle.background, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(room.name).font(.headline).foregroundStyle(.primary)
                                Text(room.hasRoomExtent
                                     ? "\(room.walls.count) wall \(room.walls.count == 1 ? "segment" : "segments")"
                                     : "Partial scan · \(room.walls.count) \(room.walls.count == 1 ? "segment" : "segments")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(room.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.measurePanel()
                    }.buttonStyle(.plain).accessibilityIdentifier("saved-room-\(room.id)")
                }
            }.padding(20)
        }
        .measureScreen()
        .navigationTitle("Rooms")
        .onAppear { reload() }
        .fullScreenCover(isPresented: $scanning, onDismiss: reload) {
            RoomScanSheet(store: store, guidance: preferences.roomGuidance)
        }
        .alert("Couldn’t load room scans", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() {
        do { rooms = try store.load() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct RoomScanSheet: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraReady = false
    @State private var finishing = false
    @State private var coaching = RoomCaptureCoaching()
    @State private var coachingTime = ProcessInfo.processInfo.systemUptime
    @State private var guidance: RoomCaptureGuidance
    @State private var scanID = UUID()
    @State private var accessCheckedScan: UUID?
    @State private var recovery = RoomCaptureRecovery()
    @State private var diagnostics = "No RoomPlan result received yet."

    private var diagnosticReport: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "PackMeasure build \(build) room scan \(scanID)\nguidance=\(guidance.rawValue) live_wall_count=\(coaching.walls.count)\n\(coaching.diagnosticSummary(at: ProcessInfo.processInfo.systemUptime))\n\(diagnostics)\n\(recovery.diagnosticSummary)\nfailure=\(failure ?? "none")"
    }

    private func retry() {
        scanID = UUID()
        cameraReady = false
        accessCheckedScan = nil
        coaching = RoomCaptureCoaching()
        recovery = RoomCaptureRecovery()
        coachingTime = ProcessInfo.processInfo.systemUptime
        finishing = false
        result = nil
        failure = nil
        diagnostics = "No RoomPlan result received yet."
    }
    @State private var result: RoomCaptureComparison?
    @State private var failure: String?
    let store: RoomScanStore

    init(store: RoomScanStore, guidance: RoomCaptureGuidance) {
        self.store = store
        _guidance = State(initialValue: guidance)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    RoomCaptureReviewView(comparison: result, store: store, diagnostics: diagnosticReport,
                                       onSaved: { dismiss() }, onScanAgain: retry)
                        .id(result.id)
                } else if let failure {
                    VStack {
                        ContentUnavailableView("Room scan needs another try", systemImage: "exclamationmark.triangle", description: Text(failure))
                        Button("Start new scan", action: retry).buttonStyle(MeasurePrimaryButton())
                        ShareLink("Share room diagnostics", item: diagnosticReport)
                            .padding(.bottom)
                    }
                    // Names the scan the access gate last evaluated, so UI tests can
                    // prove a retry re-ran the gate. Identifiers are not spoken.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("room-scan-failure-\(accessCheckedScan?.uuidString ?? "unchecked")")
                } else if cameraReady {
                    liveCapture
                } else {
                    ProgressView("Checking camera access…")
                }
            }
            .measureScreen()
            .navigationTitle(result == nil ? "Scan room" : "Review room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if result == nil && cameraReady && failure == nil {
                        Button("Finish", action: finish).disabled(finishing)
                    }
                }
            }
        }
        // Keyed to the scan so Start new scan re-runs the gate; otherwise a
        // denied first check leaves the sheet on "Checking camera access…".
        .task(id: scanID) {
            guard RoomCaptureSession.isSupported else {
                accessCheckedScan = scanID
                failure = "This device does not support LiDAR room capture."
                return
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if Task.isCancelled { return }
            accessCheckedScan = scanID
            if allowed { cameraReady = true }
            else { failure = "Allow camera access for PackMeasure in Settings, then start a new scan." }
        }
        .task(id: finishing) {
            guard finishing else { return }
            do { try await Task.sleep(for: .seconds(45)) }
            catch { return }
            if result == nil && failure == nil {
                completeProcessing(room: nil, error: "Room processing did not finish within 45 seconds.")
            }
        }
        .task(id: scanID) {
            while !Task.isCancelled && result == nil && failure == nil && !finishing {
                coachingTime = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: guidance) { _, mode in preferences.roomGuidance = mode }
        .onChange(of: failure) { _, error in
            if error != nil { coaching.end(at: ProcessInfo.processInfo.systemUptime) }
        }
        .onDisappear { coaching.end(at: ProcessInfo.processInfo.systemUptime) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && cameraReady && result == nil {
                failure = "The app left the foreground. Close this scan and start again to keep the room measurements consistent."
            }
        }
    }

    private func finish() {
        recovery.freeze()
        coaching.end(at: ProcessInfo.processInfo.systemUptime)
        finishing = true
    }

    private func completeProcessing(room: MeasuredRoom?, error: String?) {
        // Only explicit Finish can recover a failed/empty result. Capture errors
        // and background interruptions must not revive an earlier scan.
        if room != nil || finishing {
            recovery.freeze()
            if let comparison = recovery.comparison(processed: room, failure: error) {
                result = comparison
                return
            }
        }
        failure = error ?? "No usable walls were captured. Start a new scan."
    }

    private func acceptsEvent(for id: UUID) -> Bool { id == scanID && result == nil && failure == nil }

    private var liveCapture: some View {
        // Capture this generation so a queued callback from a retry cannot
        // update the next scan's coaching, dimensions, or diagnostics.
        let id = scanID
        return VStack(spacing: 0) {
            RoomCaptureBridge(finishing: finishing, onStart: {
                guard acceptsEvent(for: id), !finishing else { return }
                coaching.begin(at: ProcessInfo.processInfo.systemUptime)
            }, onProgress: { observation in
                guard acceptsEvent(for: id) else { return }
                recovery.receive(observation.walls)
                coaching.receive(observation, at: ProcessInfo.processInfo.systemUptime)
            }, onInstruction: { instruction in
                guard acceptsEvent(for: id) else { return }
                coaching.receive(instruction, at: ProcessInfo.processInfo.systemUptime)
            }, onDiagnostic: { report in
                guard acceptsEvent(for: id) else { return }
                diagnostics = report
            }) { outcome in
                guard acceptsEvent(for: id) else { return }
                coaching.end(at: ProcessInfo.processInfo.systemUptime)
                switch outcome {
                case .success(let room): completeProcessing(room: room, error: nil)
                case .failure(let error): completeProcessing(room: nil, error: error.localizedDescription)
                }
            }
            .id(id)
            .overlay(alignment: .top) {
                Text(coaching.walls.isEmpty
                     ? "Move slowly to find the walls"
                     : "\(coaching.walls.count) \(coaching.walls.count == 1 ? "wall" : "walls") detected · include every corner")
                    .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding()
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                if finishing {
                    ProgressView("Processing room…").padding().background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 32)
                }
            }
            if !finishing && coaching.showsGuidance(guidance, at: coachingTime) {
                RoomCaptureGuidanceCard(coaching: coaching, guidance: $guidance, time: coachingTime,
                                        diagnosticReport: diagnosticReport, onReview: finish)
            }
        }
    }
}

struct RoomCaptureGuidanceCard: View {
    let coaching: RoomCaptureCoaching
    @Binding var guidance: RoomCaptureGuidance
    let time: TimeInterval
    let diagnosticReport: String
    let onReview: () -> Void

    var body: some View {
        let advice = coaching.advice(at: time)
        VStack(alignment: .leading, spacing: 10) {
            Label(advice.title, systemImage: "door.left.hand.open").font(.headline).foregroundStyle(MeasureStyle.accent)
            Text(advice.message).font(.subheadline)
            Text("\(coaching.validWallCount) usable walls · \(coaching.lowConfidenceWallCount) low confidence. Hidden walls may be missing.")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }.buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MeasureStyle.panel)
    }

    @ViewBuilder private var actions: some View {
        if coaching.offersReview(at: time) {
            Button("Review captured walls", action: onReview)
        } else if guidance == .room {
            Button("Use closet guidance") { guidance = .tightCloset }
        }
        ShareLink("Diagnostics", item: diagnosticReport)
    }
}

struct RoomResultView<Header: View>: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let room: MeasuredRoom
    var onEditMeasurements: (() -> Void)? = nil
    let header: Header
    @State private var exploring = false

    init(room: MeasuredRoom, onEditMeasurements: (() -> Void)? = nil,
         @ViewBuilder header: () -> Header) {
        self.room = room
        self.onEditMeasurements = onEditMeasurements
        self.header = header()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let message = room.captureSourceMessage {
                    Label {
                        Text(message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }.font(.footnote).measurePanel()
                        .accessibilityIdentifier("live-outline-warning")
                }
                Button { exploring = true } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Floorplan").font(.headline).foregroundStyle(.primary)
                            Spacer()
                            Label("Explore", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline).foregroundStyle(MeasureStyle.accent)
                        }
                        RoomFloorplanPreview(walls: room.walls).frame(height: 190)
                    }.measurePanel()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Explore floorplan in 2D or 3D, zoom and select walls")
                .accessibilityIdentifier("explore-room-floorplan")
                VStack(alignment: .leading, spacing: 12) {
                    Text(room.hasRoomExtent ? "Scanned extent" : "Partial scan").font(.headline)
                    Text(room.coverageMessage).font(.subheadline).foregroundStyle(.secondary)
                    if let omitted = room.omittedWallCount, omitted > 0 {
                        Text("\(omitted) \(omitted == 1 ? "wall" : "walls") excluded. Measurements use only the walls you kept.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = room.heightReviewMessage(units: preferences.units) {
                        Label {
                            Text(message)
                        } icon: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(.orange)
                        }.font(.footnote)
                    }
                    if room.hasRoomExtent {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 16) { spanMetrics }
                        } else {
                            HStack(alignment: .top, spacing: 16) { spanMetrics }
                        }
                        Divider()
                        LabeledContent("Maximum captured wall height", value: MeasuredRoom.dimension(room.wallHeight, units: preferences.units))
                            .font(.footnote)
                        Text("Approximate extent, not floor area or verified ceiling height. Missing walls and recesses affect these spans.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.measurePanel().accessibilityIdentifier("room-coverage-summary")
                if onEditMeasurements != nil || room.ceilingHeight != nil || !(room.shelves ?? []).isEmpty {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            if let height = room.ceilingHeight {
                                LabeledContent("Entered ceiling height", value: MeasuredRoom.dimension(height.meters, units: preferences.units))
                                Text("Used for the 3D outline. Captured wall heights stay unchanged.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(room.shelves ?? []) { shelf in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(shelf.name).font(.headline)
                                    LabeledContent("Depth", value: RoomShelfMeasurement.dimension(shelf.depth, units: preferences.units))
                                    LabeledContent("Top above floor", value: RoomShelfMeasurement.dimension(shelf.heightAboveFloor, units: preferences.units))
                                    LabeledContent("Clear space above", value: shelf.clearanceAbove.map { RoomShelfMeasurement.dimension($0, units: preferences.units) } ?? "Not measured")
                                    Text(shelf.sourceLabel).font(.caption).foregroundStyle(.secondary)
                                }.font(.subheadline)
                            }
                            if let onEditMeasurements {
                                Button("Edit ceiling & shelves", systemImage: "ruler", action: onEditMeasurements)
                                    .buttonStyle(.bordered).accessibilityIdentifier("edit-room-measurements")
                            }
                        }.padding(.top, 12)
                    } label: {
                        Label("Ceiling & shelves", systemImage: "square.3.layers.3d").font(.headline)
                    }.measurePanel().accessibilityIdentifier("room-extra-measurements")
                }
                DisclosureGroup {
                    ForEach(Array(room.walls.enumerated()), id: \.element.id) { index, wall in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wall \(index + 1)").font(.headline)
                            LabeledContent("Length", value: MeasuredRoom.dimension(wall.length, units: preferences.units))
                            LabeledContent("Captured height", value: MeasuredRoom.dimension(wall.height, units: preferences.units))
                            Text("\(wall.confidence.capitalized) capture confidence").font(.caption).foregroundStyle(.secondary)
                        }.font(.subheadline).padding(.vertical, 12)
                        if index < room.walls.count - 1 { Divider() }
                    }
                } label: {
                    Label("Wall measurements · \(room.walls.count)", systemImage: "ruler").font(.headline)
                }.measurePanel()
                ShareLink(item: room.shareText(units: preferences.units)) {
                    Label("Share measurements", systemImage: "square.and.arrow.up")
                }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                Text("Verify dimensions with a tape or laser measure. Room scans are separate from moving inventory.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }
        .measureScreen()
        .navigationTitle(room.name).navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $exploring) { RoomFloorplanView(room: room) }
    }

    @ViewBuilder private var spanMetrics: some View {
        MeasureMetric(title: "Long span", value: MeasuredRoom.dimension(room.spanLength, units: preferences.units))
        MeasureMetric(title: "Short span", value: MeasuredRoom.dimension(room.spanWidth, units: preferences.units))
    }
}

extension RoomResultView where Header == EmptyView {
    init(room: MeasuredRoom, onEditMeasurements: (() -> Void)? = nil) {
        self.init(room: room, onEditMeasurements: onEditMeasurements) { EmptyView() }
    }
}
