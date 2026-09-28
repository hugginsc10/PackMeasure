import ARKit
import AVFoundation
import CoreImage
import SceneKit
import SwiftUI

struct WireShelfPhoto: Identifiable {
    let id = UUID()
    let generation: UUID
    let image: UIImage
    let imageSize: SIMD2<Float>
    let intrinsics: simd_float3x3
    let transform: simd_float4x4
    func ray(at point: CGPoint) throws -> ShelfCameraRay {
        try ShelfCameraRay(portraitPoint: [Float(point.x), Float(point.y)], imageSize: imageSize,
                           intrinsics: intrinsics, cameraTransform: transform)
    }
}

@MainActor @Observable
final class WireShelfScanState {
    private(set) var sequence = WireShelfSequence()
    private(set) var generation = UUID()
    private(set) var photoRequest: UUID?
    private(set) var photo: WireShelfPhoto?
    private(set) var firstPhoto: WireShelfPhoto?
    private(set) var firstPoint: CGPoint?
    var cursor: CGPoint?
    var ready = false
    var error: String?
    var movement: Float = 0

    var title: String {
        ["Shelf front edge · top", "Floor below the shelf", "Back edge · left end", "Back edge · right end", "Underside directly above"][min(sequence.stage, 4)]
    }
    var instruction: String {
        ["Choose a visible wire crossing at the shelf’s front edge, on top. This point will lock the shelf.",
         "Choose a visible mark or corner on the actual floor, below the shelf.",
         "Choose a wire crossing at the left end of the shelf’s back edge, on top.",
         "Choose a wire crossing at the right end of the same back edge. The back points must bracket the locked front point.",
         "Choose a visible point on the underside directly above the locked front point. Skip if it’s hidden."][min(sequence.stage, 4)]
    }
    func requestPhoto() {
        guard ready, photo == nil, photoRequest == nil, sequence.result == nil else { return }
        photoRequest = UUID(); error = nil
    }
    func receive(_ photo: WireShelfPhoto, request: UUID) {
        guard photoRequest == request, generation == photo.generation, sequence.result == nil else { return }
        photoRequest = nil; self.photo = photo; cursor = nil
    }
    func confirmPoint() {
        guard ready, let photo, photo.generation == generation, let cursor else { return }
        do {
            let ray = try photo.ray(at: cursor)
            if let firstPhoto, let firstPoint {
                let match = try ShelfPointMatch(first: firstPhoto.ray(at: firstPoint), second: ray)
                try sequence.append(match)
                self.firstPhoto = nil; self.firstPoint = nil; movement = 0
            } else {
                firstPhoto = photo; firstPoint = cursor
            }
            self.photo = nil; self.cursor = nil; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func retakePhoto() { photo = nil; cursor = nil; photoRequest = nil; error = nil }
    func restartPoint() {
        retakePhoto(); firstPhoto = nil; firstPoint = nil; movement = 0
    }
    func undo() { restartPoint(); sequence.undo() }
    func skipClearance() {
        do { try sequence.skipClearance(); restartPoint() }
        catch { self.error = error.localizedDescription }
    }
    func invalidate(_ reason: String) {
        guard sequence.result == nil else { return }
        generation = UUID(); sequence = WireShelfSequence(); restartPoint(); ready = false; error = reason
    }
    var diagnostics: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = ["PackMeasure build \(build) wire shelf · matched views", "generation=\(generation) stage=\(sequence.stage) ready=\(ready)",
                     "first_point=\(String(describing: firstPoint)) second_point=\(String(describing: cursor)) movement_m=\(movement)", "error=\(error ?? "none")"]
        for (index, match) in sequence.matches.enumerated() {
            lines.append("point=\(index) position=\(match.point) baseline_m=\(match.baseline) angle_deg=\(match.angleDegrees) ray_gap_m=\(match.rayGap)")
            lines.append("first_origin=\(match.first.origin) first_direction=\(match.first.direction) second_origin=\(match.second.origin) second_direction=\(match.second.direction)")
        }
        return lines.joined(separator: "\n")
    }
}

struct WireShelfCamera: UIViewRepresentable {
    let state: WireShelfScanState
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.backgroundColor = .black
        view.session.delegate = context.coordinator; view.session.delegateQueue = .main
        context.coordinator.view = view
        view.scene.rootNode.addChildNode(context.coordinator.markers)
        context.coordinator.start()
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) { context.coordinator.render() }
    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        coordinator.active = false; view.session.delegate = nil; view.session.pause()
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency ARSessionDelegate {
        let state: WireShelfScanState
        let markers = SCNNode()
        let imageContext = CIContext()
        weak var view: ARSCNView?
        var active = true
        var running = false
        var lastUpdate: TimeInterval = 0
        init(_ state: WireShelfScanState) { self.state = state }
        func start() {
            running = false
            Task { @MainActor [weak self] in
                guard let self, active else { return }
                state.invalidate("Move slowly while camera tracking starts.")
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard active else { return }
                guard allowed else { state.error = "Allow camera access in Settings, or enter measurements instead."; return }
                let config = ARWorldTrackingConfiguration(); config.worldAlignment = .gravity
                // Camera poses provide scale. Wire points do not use scene depth.
                view?.session.run(config, options: [.resetTracking, .removeExistingAnchors]); running = true
            }
        }
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard active, running, state.sequence.result == nil else { return }
            guard case .normal = frame.camera.trackingState else {
                state.ready = false
                if case .limited(.relocalizing) = frame.camera.trackingState {
                    state.invalidate("Tracking is relocating. Start the shelf again so its points share one coordinate system.")
                }
                return
            }
            state.ready = true
            if let first = state.firstPhoto, frame.timestamp - lastUpdate > 0.1 {
                lastUpdate = frame.timestamp
                let delta = frame.camera.transform.columns.3 - first.transform.columns.3
                state.movement = simd_length(SIMD3<Float>(delta.x, delta.y, delta.z))
            }
            guard let request = state.photoRequest, CACurrentMediaTime() - frame.timestamp < 0.25 else { return }
            let generation = state.generation
            let oriented = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            guard let image = imageContext.createCGImage(oriented, from: oriented.extent) else {
                state.retakePhoto(); state.error = "Couldn’t capture this view. Try again."; return
            }
            state.receive(WireShelfPhoto(generation: generation, image: UIImage(cgImage: image),
                imageSize: [Float(frame.camera.imageResolution.width), Float(frame.camera.imageResolution.height)],
                intrinsics: frame.camera.intrinsics, transform: frame.camera.transform), request: request)
        }
        func render() {
            markers.childNodes.forEach { $0.removeFromParentNode() }
            for (index, match) in state.sequence.matches.enumerated() {
                let node = SCNNode(geometry: SCNSphere(radius: index == 0 ? 0.012 : 0.007))
                node.geometry?.firstMaterial?.lightingModel = .constant
                node.geometry?.firstMaterial?.diffuse.contents = index == 0 ? UIColor.systemYellow : UIColor.systemTeal
                node.simdPosition = match.point; markers.addChildNode(node)
            }
            if let selected = state.sequence.selectedTop {
                let ring = SCNTorus(ringRadius: 0.06, pipeRadius: 0.002)
                ring.firstMaterial?.lightingModel = .constant; ring.firstMaterial?.diffuse.contents = UIColor.systemTeal
                let marker = SCNNode(geometry: ring); marker.simdPosition = selected + [0,0.003,0]
                markers.addChildNode(marker)
            }
        }
        func sessionWasInterrupted(_ session: ARSession) {
            running = false; state.invalidate("Camera tracking was interrupted. Start the shelf again.")
        }
        func sessionInterruptionEnded(_ session: ARSession) { if active { start() } }
        func session(_ session: ARSession, didFailWithError error: any Error) {
            running = false; state.invalidate("Camera tracking failed. Close and reopen the scanner.")
        }
    }
}

struct WireShelfScannerView: View {
    let onMeasured: (ShelfGeometry, [SIMD3<Float>], SIMD3<Float>, [ShelfPointMatch]) -> Void
    var automaticReason: String? = nil
    var onChooseMethod: (() -> Void)? = nil
    @State var state = WireShelfScanState()
    @State private var cameraID = UUID()
    @State private var restartOnForeground = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                if let result = state.sequence.result {
                    Form {
                        Section("Matched-point estimate") {
                            LabeledContent("Depth", value: RoomShelfMeasurement.dimension(result.depth))
                            LabeledContent("Top above floor", value: RoomShelfMeasurement.dimension(result.height))
                            LabeledContent("Clear space above", value: result.clearance.map(RoomShelfMeasurement.dimension) ?? "Not measured")
                            Text("Verify with a tape. Accuracy depends on choosing the same physical point in both views and stable camera tracking.").font(.footnote)
                        }
                        Button("Use shelf measurements") {
                            if let selected = state.sequence.selectedTop {
                                onMeasured(result, state.sequence.measurementPoints, selected, state.sequence.orderedMatches); dismiss()
                            }
                        }.accessibilityIdentifier("use-wire-shelf")
                        ShareLink("Shelf diagnostics", item: state.diagnostics)
                        Button("Scan again") { state = WireShelfScanState(); cameraID = UUID() }
                    }
                } else if !ARWorldTrackingConfiguration.isSupported {
                    ContentUnavailableView("Camera tracking unavailable", systemImage: "viewfinder",
                        description: Text("Enter the shelf measurements instead."))
                } else {
                    ZStack {
                        WireShelfCamera(state: state).id(cameraID)
                        if let photo = state.photo {
                            ShelfPhotoPointPicker(image: photo.image, point: $state.cursor).id(photo.id)
                                .accessibilityIdentifier("wire-photo-picker")
                        }
                    }.frame(maxHeight: .infinity).clipped()
                    controls
                }
            }
            .measureScreen().navigationTitle("Measure wire shelf").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let onChooseMethod { ToolbarItem(placement: .confirmationAction) { Button("Method", action: onChooseMethod) } }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && state.sequence.result == nil {
                    state.invalidate("The app left the foreground. Start the shelf again."); restartOnForeground = true
                } else if phase == .active && restartOnForeground {
                    restartOnForeground = false; cameraID = UUID()
                }
            }
        }.tint(MeasureStyle.accent).preferredColorScheme(.dark)
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let automaticReason, state.sequence.stage == 0 { Text(automaticReason).font(.caption).foregroundStyle(MeasureStyle.accent) }
                if state.sequence.selectedTop != nil { Label("Shelf front point locked", systemImage: "lock.fill").font(.caption).foregroundStyle(MeasureStyle.accent) }
                Text("\(state.sequence.stage + 1) of 5 · \(state.title)").font(.headline)
                Text(state.instruction).font(.subheadline)
                if let first = state.firstPhoto, let point = state.firstPoint {
                    HStack(alignment: .top) {
                        ShelfReferencePhoto(image: first.image, point: point).frame(width: 75, height: 95)
                        Text(state.photo == nil ? "Move sideways 20–40 cm, keeping this exact point visible. Movement: \(Int(state.movement * 100)) cm. Then freeze view 2." : "Match the same wire crossing or corner shown here. Pinch to zoom, then tap to place the cross.")
                            .font(.caption)
                    }
                } else {
                    Text(state.photo == nil ? "Freeze view 1, zoom in, and mark one identifiable point. Each point needs two viewpoints; you can measure bare wire without a board." : "Pinch to zoom. Tap the exact wire crossing or corner; tap again to adjust. Then confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange) }
                if state.photo != nil {
                    HStack {
                        Button("Retake view", action: state.retakePhoto)
                        Spacer()
                        Button("Use this point", action: state.confirmPoint).buttonStyle(.borderedProminent)
                            .disabled(state.cursor == nil || !state.ready).accessibilityIdentifier("confirm-wire-point")
                    }
                } else {
                    Button(state.photoRequest != nil ? "Capturing…" : state.firstPhoto == nil ? "Freeze view 1" : "Freeze view 2", action: state.requestPhoto)
                        .buttonStyle(.borderedProminent).disabled(!state.ready || state.photoRequest != nil)
                        .accessibilityIdentifier("freeze-wire-view")
                }
                HStack {
                    if state.firstPhoto != nil || state.photo != nil { Button("Restart this point", action: state.restartPoint) }
                    else if state.sequence.stage > 0 { Button("Undo point", action: state.undo) }
                    if state.sequence.stage == 4 { Button("Skip clear space", action: state.skipClearance) }
                }.font(.caption)
                ShareLink("Shelf diagnostics", item: state.diagnostics).font(.caption)
            }.padding(16)
        }.frame(maxHeight: 325)
    }
}
