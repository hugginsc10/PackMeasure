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
                    ContentUnavailableView("Scan interrupted", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else if cameraReady {
                    RoomCaptureBridge(finishing: finishing) { outcome in
                        switch outcome {
                        case .success(let room): result = room
                        case .failure(let error): failure = error.localizedDescription
                        }
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
                ToolbarItem(placement: .confirmationAction) {
                    if var room = result {
                        Button("Save") {
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

    var body: some View {
        List {
            Section("Scanned outline") {
                RoomOutlineView(walls: room.walls).frame(height: 240)
                    .accessibilityLabel("Top view of \(room.walls.count) captured walls; wall numbers match the list below")
            }
            Section("Approximate scanned extent") {
                LabeledContent("Long span", value: MeasuredRoom.dimension(room.spanLength))
                LabeledContent("Short span", value: MeasuredRoom.dimension(room.spanWidth))
                LabeledContent("Maximum wall height", value: MeasuredRoom.dimension(room.wallHeight))
                Text("Spans follow the longest captured wall. Missing walls can understate the room; recesses and irregular shapes affect the extent. This is not floor area or a verified ceiling height.")
                    .font(.footnote).foregroundStyle(.secondary)
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
    }
}

private struct RoomOutlineView: View {
    let walls: [MeasuredRoom.Wall]
    var body: some View {
        Canvas { context, size in
            let points = walls.flatMap { [$0.start, $0.end] }
            guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return }
            let scale = min((size.width - 40) / CGFloat(max(0.1, maxX - minX)),
                            (size.height - 40) / CGFloat(max(0.1, maxY - minY)))
            func point(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: size.width / 2 + CGFloat(p.x - (minX + maxX) / 2) * scale,
                        y: size.height / 2 + CGFloat(p.y - (minY + maxY) / 2) * scale)
            }
            for (index, wall) in walls.enumerated() {
                let start = point(wall.start), end = point(wall.end)
                var path = Path()
                path.move(to: start); path.addLine(to: end)
                context.stroke(path, with: .color(wall.confidence == "low" ? .orange : .blue), lineWidth: 3)
                context.draw(Text("\(index + 1)").font(.caption.bold()),
                             at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 10))
            }
        }
    }
}
