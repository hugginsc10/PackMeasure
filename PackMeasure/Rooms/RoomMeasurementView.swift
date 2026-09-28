import AVFoundation
import RoomPlan
import SwiftUI

struct RoomMeasurementView: View {
    @State private var rooms: [MeasuredRoom] = []
    @State private var scanning = false
    @State private var errorMessage: String?
    @State private var guidance: RoomCaptureGuidance = .room
    private let store = RoomScanStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    MeasureEyebrow(text: "Spatial capture")
                    Text("Your space, mapped.").font(.system(.title, design: .rounded).bold())
                    Text(RoomCaptureSession.isSupported
                         ? "Move through your room to capture its walls and dimensions."
                         : "Room capture needs a supported LiDAR iPhone. Saved floorplans are available below.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Picker("Scan guidance", selection: $guidance) {
                        ForEach(RoomCaptureGuidance.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented)
                    Text(guidance.preparation).font(.footnote).foregroundStyle(.secondary)
                    Button { scanning = true } label: {
                        Label("Scan a room", systemImage: "viewfinder")
                    }.buttonStyle(MeasurePrimaryButton()).disabled(!RoomCaptureSession.isSupported)
                }.measurePanel()
                HStack {
                    MeasureEyebrow(text: "Saved spaces")
                    Spacer()
                    Text("\(rooms.count)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                if rooms.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "square.dashed").font(.largeTitle).foregroundStyle(MeasureStyle.accent)
                        Text("Make room for your first scan.").font(.headline)
                        Text("Save a room to revisit its floorplan and individual wall measurements.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.measurePanel()
                }
                ForEach(rooms) { room in
                    NavigationLink { RoomSavedDetailView(room: room, store: store) } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            RoomFloorplanPreview(walls: room.walls).frame(height: 150)
                                .background(MeasureStyle.background, in: RoundedRectangle(cornerRadius: 16))
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(room.name).font(.headline).foregroundStyle(.primary)
                                    Text(room.hasRoomExtent ? "\(room.walls.count) wall segments" : "Partial scan · \(room.walls.count) segments")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(MeasureStyle.accent)
                            }
                            Text(room.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }.measurePanel()
                    }.buttonStyle(.plain)
                }
            }.padding(20)
        }
        .measureScreen()
        .navigationTitle("Rooms")
        .onAppear { reload() }
        .fullScreenCover(isPresented: $scanning, onDismiss: reload) {
            RoomScanSheet(store: store, guidance: guidance)
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

private struct RoomScanSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraReady = false
    @State private var finishing = false
    @State private var coaching = RoomCaptureCoaching()
    @State private var coachingTime = ProcessInfo.processInfo.systemUptime
    @State private var guidance: RoomCaptureGuidance
    @State private var scanID = UUID()
    @State private var recovery = RoomCaptureRecovery()
    @State private var diagnostics = "No RoomPlan result received yet."

    private var diagnosticReport: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "PackMeasure build \(build) room scan \(scanID)\nguidance=\(guidance.rawValue) live_wall_count=\(coaching.walls.count)\n\(coaching.diagnosticSummary(at: ProcessInfo.processInfo.systemUptime))\n\(diagnostics)\n\(recovery.diagnosticSummary)\nfailure=\(failure ?? "none")"
    }

    private func retry() {
        scanID = UUID()
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
        .task {
            guard RoomCaptureSession.isSupported else {
                failure = "This device does not support LiDAR room capture."
                return
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if Task.isCancelled { return }
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
                     ? "Looking for walls — move slowly and follow the highlights"
                     : "\(coaching.walls.count) wall(s) detected — include every corner")
                    .font(.subheadline).padding(10).background(.regularMaterial, in: Capsule()).padding()
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
            Text("\(coaching.validWallCount) usable wall(s) · \(coaching.lowConfidenceWallCount) low confidence. Hidden walls may remain missing.")
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

struct RoomResultView: View {
    let room: MeasuredRoom
    var onEditMeasurements: (() -> Void)? = nil
    @State private var exploring = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = room.captureSourceMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange).measurePanel()
                        .accessibilityIdentifier("live-outline-warning")
                }
                if onEditMeasurements != nil || room.ceilingHeight != nil || !(room.shelves ?? []).isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MeasureEyebrow(text: "Ceiling & shelves")
                        if let height = room.ceilingHeight {
                            LabeledContent("Entered ceiling height", value: MeasuredRoom.dimension(height.meters))
                            Text("Used for the 3D outline. Captured wall heights stay unchanged.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(room.shelves ?? []) { shelf in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(shelf.name).font(.headline)
                                LabeledContent("Depth", value: RoomShelfMeasurement.dimension(shelf.depth))
                                LabeledContent("Top above floor", value: RoomShelfMeasurement.dimension(shelf.heightAboveFloor))
                                LabeledContent("Clear space above", value: shelf.clearanceAbove.map(RoomShelfMeasurement.dimension) ?? "Not measured")
                                Text(shelf.sourceLabel).font(.caption).foregroundStyle(.secondary)
                            }.font(.subheadline)
                        }
                        if let onEditMeasurements {
                            Button("Edit ceiling & shelves", systemImage: "ruler", action: onEditMeasurements)
                                .buttonStyle(.bordered).accessibilityIdentifier("edit-room-measurements")
                        }
                    }.measurePanel()
                }
                Button { exploring = true } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            MeasureEyebrow(text: "Floorplan")
                            Spacer()
                            Image(systemName: "arrow.up.left.and.arrow.down.right").foregroundStyle(MeasureStyle.accent)
                        }
                        RoomFloorplanPreview(walls: room.walls).frame(height: 240)
                        HStack {
                            Text("Explore floorplan").font(.headline)
                            Spacer()
                            Image(systemName: "arrow.right")
                        }.foregroundStyle(MeasureStyle.accent)
                        Text("Explore in 2D or 3D. Select a wall for its length and height.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.measurePanel()
                }.buttonStyle(.plain).accessibilityLabel("Explore floorplan in 2D or 3D, zoom and select walls")
                VStack(alignment: .leading, spacing: 18) {
                    MeasureEyebrow(text: room.hasRoomExtent ? "Scanned extent" : "Partial scan")
                    Text(room.coverageMessage).font(.subheadline).foregroundStyle(.secondary)
                    if let omitted = room.omittedWallCount, omitted > 0 {
                        Text("\(omitted) wall(s) left out during review. These measurements use only the walls you kept.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message = room.heightReviewMessage {
                        Label(message, systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if room.hasRoomExtent {
                        MeasureMetric(title: "Long span", value: MeasuredRoom.dimension(room.spanLength))
                        Divider()
                        MeasureMetric(title: "Short span", value: MeasuredRoom.dimension(room.spanWidth))
                        Divider()
                        MeasureMetric(title: "Maximum wall height", value: MeasuredRoom.dimension(room.wallHeight))
                        Text("Approximate captured extent, not floor area or verified ceiling height. Missing walls and recesses can affect these spans.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.measurePanel()
                DisclosureGroup {
                    ForEach(Array(room.walls.enumerated()), id: \.element.id) { index, wall in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wall \(index + 1)").font(.headline)
                            LabeledContent("Length", value: MeasuredRoom.dimension(wall.length))
                            LabeledContent("Captured height", value: MeasuredRoom.dimension(wall.height))
                            Text("\(wall.confidence.capitalized) capture confidence").font(.caption).foregroundStyle(.secondary)
                        }.font(.subheadline).padding(.vertical, 12)
                        if index < room.walls.count - 1 { Divider() }
                    }
                } label: {
                    Label("Wall measurements · \(room.walls.count)", systemImage: "ruler").font(.headline)
                }.measurePanel()
                ShareLink(item: room.shareText) {
                    Label("Share measurements", systemImage: "square.and.arrow.up")
                }.buttonStyle(MeasurePrimaryButton())
                Text("Check dimensions with a tape or laser measure before relying on them. Room scans are separate from moving inventory.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }
        .measureScreen()
        .navigationTitle(room.name).navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $exploring) { RoomFloorplanView(room: room) }
    }
}
