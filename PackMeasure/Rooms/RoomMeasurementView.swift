import AVFoundation
import RoomPlan
import SwiftUI

struct RoomMeasurementView: View {
    @State private var rooms: [MeasuredRoom] = []
    @State private var scanning = false
    @State private var errorMessage: String?
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
                    NavigationLink { RoomResultView(room: room) } label: {
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
        .task { reload() }
        .fullScreenCover(isPresented: $scanning, onDismiss: reload) {
            RoomScanSheet(store: store)
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
    @State private var detectedWallCount = 0
    @State private var scanID = UUID()
    @State private var diagnostics = "No RoomPlan result received yet."

    private var diagnosticReport: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "PackMeasure build \(build) room scan \(scanID)\nlive_wall_count=\(detectedWallCount)\n\(diagnostics)\nfailure=\(failure ?? "none")"
    }

    private func retry() {
        scanID = UUID()
        detectedWallCount = 0
        finishing = false
        result = nil
        failure = nil
        diagnostics = "No RoomPlan result received yet."
    }
    @State private var result: MeasuredRoom?
    @State private var failure: String?
    @State private var saveFailure: String?
    @State private var name = "Room"
    let store: RoomScanStore

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    VStack(spacing: 0) {
                        TextField("Room name", text: $name).textFieldStyle(.roundedBorder).padding()
                        RoomResultView(room: result)
                    }
                } else if let failure {
                    VStack {
                        ContentUnavailableView("Room scan needs another try", systemImage: "exclamationmark.triangle", description: Text(failure))
                        Button("Start new scan", action: retry).buttonStyle(MeasurePrimaryButton())
                        ShareLink("Share room diagnostics", item: diagnosticReport)
                            .padding(.bottom)
                    }
                } else if cameraReady {
                    RoomCaptureBridge(finishing: finishing, onProgress: { detectedWallCount = $0 },
                                      onDiagnostic: { diagnostics = $0 }) { outcome in
                        switch outcome {
                        case .success(let room): result = room
                        case .failure(let error): failure = error.localizedDescription
                        }
                    }
                    .id(scanID)
                    .overlay(alignment: .top) {
                        Text(detectedWallCount == 0
                             ? "Looking for walls — move slowly and follow the highlights"
                             : "\(detectedWallCount) wall(s) detected — include every corner")
                            .font(.subheadline).padding(10).background(.regularMaterial, in: Capsule()).padding()
                    }
                    .overlay(alignment: .bottom) {
                        if finishing {
                            ProgressView("Processing room…").padding().background(.regularMaterial, in: Capsule())
                                .padding(.bottom, 32)
                        }
                    }
                } else {
                    ProgressView("Checking camera access…")
                }
            }
            .measureScreen()
            .navigationTitle(result == nil ? "Scan room" : "Review room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    if result != nil {
                        HStack {
                            Button("Scan again", action: retry)
                            Spacer()
                            ShareLink("Diagnostics", item: diagnosticReport)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if var room = result {
                        Button(room.hasRoomExtent ? "Save" : "Save partial") {
                            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            room.name = trimmed.isEmpty ? "Room" : trimmed
                            do { try store.save(room); dismiss() }
                            catch { saveFailure = error.localizedDescription }
                        }
                    } else if cameraReady && failure == nil {
                        Button("Finish") { finishing = true }.disabled(finishing)
                    }
                }
            }
            .alert("Couldn’t save room", isPresented: Binding(
                get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } }
            )) { Button("OK") { saveFailure = nil } } message: { Text(saveFailure ?? "") }
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
                failure = "Room processing did not finish. Close this scan and try again."
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && cameraReady && result == nil {
                failure = "The app left the foreground. Close this scan and start again to keep the room measurements consistent."
            }
        }
    }
}

private struct RoomResultView: View {
    let room: MeasuredRoom
    @State private var exploring = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
                        Text("Zoom, pan, and select a wall.").font(.caption).foregroundStyle(.secondary)
                    }.measurePanel()
                }.buttonStyle(.plain).accessibilityLabel("Explore floorplan, zoom and select walls")
                VStack(alignment: .leading, spacing: 18) {
                    MeasureEyebrow(text: room.hasRoomExtent ? "Scanned extent" : "Partial scan")
                    Text(room.coverageMessage).font(.subheadline).foregroundStyle(.secondary)
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
                            LabeledContent("Height", value: MeasuredRoom.dimension(wall.height))
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
