import AVFoundation
import RoomPlan
import SwiftUI

struct RoomMeasurementView: View {
    @State private var rooms: [MeasuredRoom] = []
    @State private var scanning = false
    @State private var errorMessage: String?
    private let store = RoomScanStore()

    var body: some View {
        List {
            Section {
                Button("Scan a room", systemImage: "viewfinder") { scanning = true }
                    .disabled(!RoomCaptureSession.isSupported)
                Text(RoomCaptureSession.isSupported
                     ? "Walk slowly around one room. Capture every wall, corner, and floor edge."
                     : "Room scanning requires a supported LiDAR iPhone. It is unavailable in the simulator.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Saved rooms") {
                if rooms.isEmpty { Text("No room scans yet.").foregroundStyle(.secondary) }
                ForEach(rooms) { room in
                    NavigationLink {
                        RoomResultView(room: room)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(room.name)
                            Text(room.hasRoomExtent ? "\(room.walls.count) walls" : "Partial scan · \(room.walls.count) walls")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(room.date, style: .date).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Room dimensions")
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
                        Button("Start new scan", action: retry).buttonStyle(.borderedProminent)
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
        List {
            Section("Scanned outline") {
                Button { exploring = true } label: {
                    VStack {
                        RoomFloorplanPreview(walls: room.walls).frame(height: 240)
                        Label("Explore floorplan", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Explore floorplan, zoom and select walls")
            }
            Section(room.hasRoomExtent ? "Approximate scanned extent" : "Partial room scan") {
                Text(room.coverageMessage).font(.subheadline)
                if room.hasRoomExtent {
                    LabeledContent("Long span", value: MeasuredRoom.dimension(room.spanLength))
                    LabeledContent("Short span", value: MeasuredRoom.dimension(room.spanWidth))
                    LabeledContent("Maximum wall height", value: MeasuredRoom.dimension(room.wallHeight))
                    Text("Spans follow the longest captured wall. Missing walls can understate the room; recesses and irregular shapes affect the extent. This is not floor area or a verified ceiling height.")
                        .font(.footnote).foregroundStyle(.secondary)
            }
            }
            Section("Wall dimensions") {
                ForEach(Array(room.walls.enumerated()), id: \.element.id) { index, wall in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Wall \(index + 1)").font(.headline)
                        Text("Length: \(MeasuredRoom.dimension(wall.length))")
                        Text("Height: \(MeasuredRoom.dimension(wall.height))")
                        Text("\(wall.confidence.capitalized) confidence").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ShareLink("Share measurements", item: room.shareText)
                Text("Compare with a tape or laser measure before relying on these dimensions. Room scans are saved separately from moving inventory.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(room.name)
        .fullScreenCover(isPresented: $exploring) { RoomFloorplanView(room: room) }
    }
}
