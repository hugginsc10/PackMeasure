import ARKit
import AVFoundation
import SceneKit
import SwiftUI

@MainActor @Observable
final class InteriorScanState {
    var loops: [[SIMD3<Float>]] = [[]]
    var takingHeight = false
    var requestID = 0
    var isCapturingPoint = false
    var error: String?
    var trackingInterrupted = false
    var result: InteriorMeasurement?

    var prompt: String {
        if takingHeight { return "Aim directly above the orange first point, at the lowest usable top edge. Capture height." }
        if loops.count == 1 { return "Trace the inside floor perimeter in order. Add points at every corner or bend, including notches. Do not repeat the first point." }
        return "Trace obstacle \(loops.count - 1) at floor level, in order around its base. Include its widest footprint over the insert height."
    }
    func requestPoint() {
        guard !isCapturingPoint, result == nil else { return }
        isCapturingPoint = true
        requestID += 1
    }
    func receive(_ point: SIMD3<Float>) {
        do {
            if takingHeight {
                result = try InteriorGeometry.project(loops, heightPoint: point)
            } else {
                guard loops.last!.count < 200 else { throw InteriorGeometryError.invalidOutline }
                if let origin = loops.first?.first, abs(point.y - origin.y) > 0.008 { throw InteriorGeometryError.nonPlanar }
                if let previous = loops.last?.last, simd_distance(previous, point) < 0.01 { throw InteriorGeometryError.invalidOutline }
                loops[loops.count - 1].append(point)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func finishLoop(addObstacle: Bool) {
        guard !isCapturingPoint else { return }
        guard let origin = loops.first?.first else { return }
        do {
            _ = try InteriorGeometry.project(loops, heightPoint: origin + SIMD3<Float>(0, 0.1, 0))
            if addObstacle {
                guard loops.count < 20 else { throw InteriorGeometryError.invalidOutline }
                loops.append([])
            } else { takingHeight = true }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func undo() {
        guard !isCapturingPoint else { return }
        error = nil
        if takingHeight { takingHeight = false }
        else if loops.last!.isEmpty && loops.count > 1 { loops.removeLast() }
        else if !loops.last!.isEmpty { loops[loops.count - 1].removeLast() }
    }
    func invalidate(_ message: String) {
        // A saved review result no longer depends on a live world coordinate system.
        guard result == nil else { return }
        requestID += 1
        isCapturingPoint = false
        loops = [[]]
        takingHeight = false
        error = message
    }
}

struct InteriorCamera: UIViewRepresentable {
    var state: InteriorScanState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session.delegate = context.coordinator
        view.session.delegateQueue = .main
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.lastRequest != state.requestID {
            coordinator.lastRequest = state.requestID
            // Avoid publishing observation changes during a SwiftUI update.
            let expectedRequest = state.requestID
            Task { @MainActor [weak coordinator] in coordinator?.capture(requestID: expectedRequest) }
        }
        view.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
        for (index, point) in state.loops.flatMap({ $0 }).enumerated() {
            let sphere = SCNSphere(radius: 0.004)
            sphere.firstMaterial?.diffuse.contents = index == 0 ? UIColor.orange : UIColor.systemTeal
            let node = SCNNode(geometry: sphere)
            node.simdPosition = point
            view.scene.rootNode.addChildNode(node)
        }
    }
    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        coordinator.active = false
        view.session.delegate = nil
        view.session.pause()
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency ARSessionDelegate {
        let state: InteriorScanState
        weak var view: ARSCNView?
        var lastRequest = 0
        var active = true
        init(state: InteriorScanState) { self.state = state; lastRequest = state.requestID }
        func start() {
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
                    state.error = "Interior scanning requires an iPhone or iPad with LiDAR."
                    return
                }
                let authorized: Bool
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: authorized = true
                case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
                default: authorized = false
                }
                guard active else { return }
                guard authorized else {
                    state.error = "Allow camera access in Settings to scan an interior."
                    return
                }
                let config = ARWorldTrackingConfiguration()
                config.frameSemantics = .sceneDepth
                view?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            }
        }
        func capture(requestID: Int) {
            guard state.isCapturingPoint, state.requestID == requestID else { return }
            defer { state.isCapturingPoint = false }
            guard active, !state.trackingInterrupted, state.result == nil, let view, let frame = view.session.currentFrame,
                  case .normal = frame.camera.trackingState,
                  CACurrentMediaTime() - frame.timestamp < 0.3,
                  let depth = frame.sceneDepth, let confidence = depth.confidenceMap else {
                state.error = "Wait for stable tracking and fresh LiDAR depth, then try again."
                return
            }
            let imagePoint = CGPoint(x: 0.5, y: 0.5).applying(
                frame.displayTransform(for: .portrait, viewportSize: view.bounds.size).inverted()
            )
            let map = depth.depthMap
            let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
            guard imagePoint.x.isFinite, imagePoint.y.isFinite,
                  (0..<1).contains(imagePoint.x), (0..<1).contains(imagePoint.y),
                  CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
                  CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h else { return }
            CVPixelBufferLockBaseAddress(map, .readOnly)
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer {
                CVPixelBufferUnlockBaseAddress(map, .readOnly)
                CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            }
            guard let base = CVPixelBufferGetBaseAddress(map), let confidenceBase = CVPixelBufferGetBaseAddress(confidence) else { return }
            var depths = [Float]()
            var confidences = [UInt8]()
            depths.reserveCapacity(w * h)
            confidences.reserveCapacity(w * h)
            for rowIndex in 0..<h {
                let row = base.advanced(by: rowIndex * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float.self)
                let confidenceRow = confidenceBase.advanced(by: rowIndex * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
                depths.append(contentsOf: UnsafeBufferPointer(start: row, count: w))
                confidences.append(contentsOf: UnsafeBufferPointer(start: confidenceRow, count: w))
            }
            let grid = DepthGrid(width: w, height: h, depths: depths, confidences: confidences)
            guard let sample = ScannerFrameDepthSampler(minimumDepthMeters: 0.15, maximumDepthMeters: 2.5).sample(
                normalizedImagePoint: SIMD2<Float>(Float(imagePoint.x), Float(imagePoint.y)),
                grid: grid,
                cameraImageResolutionPixels: SIMD2<Int>(Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)),
                cameraIntrinsics: frame.camera.intrinsics,
                cameraTransform: frame.camera.transform
            ), sample.confidence == .high else {
                state.error = "No high-confidence depth at the reticle. Aim at a solid inner surface, 15 cm–2.5 m away."
                return
            }
            state.receive(sample.worldPosition)
        }
        func sessionWasInterrupted(_ session: ARSession) {
            state.trackingInterrupted = true
            state.invalidate("Tracking was interrupted. Retrace the interior so all points share one coordinate system.")
        }
        func sessionInterruptionEnded(_ session: ARSession) {
            state.trackingInterrupted = false
            start()
        }
        func session(_ session: ARSession, didFailWithError error: any Error) {
            state.trackingInterrupted = true
            state.invalidate("Camera tracking failed. Close and reopen the interior scanner.")
        }
    }
}

struct InteriorScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var state = InteriorScanState()
    @State private var cameraID = UUID()
    var onSave: (InteriorMeasurement) throws -> Void
    var body: some View {
        NavigationStack {
            if let result = state.result {
                InteriorReviewView(record: result, onSave: { record in
                    try onSave(record)
                    dismiss()
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retake") { state = InteriorScanState(); cameraID = UUID() }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ZStack {
                        InteriorCamera(state: state).id(cameraID)
                        Image(systemName: "plus").font(.largeTitle).foregroundStyle(.white).shadow(radius: 2)
                    }
                    .frame(maxHeight: .infinity)
                    Text(state.prompt).font(.callout).padding(.horizontal)
                    Text("\(state.loops.last?.count ?? 0) points · \(state.loops.count - 1) obstacle outlines")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                    HStack {
                        Button("Undo", action: state.undo)
                        Button(state.takingHeight ? "Capture height" : "Add point", action: state.requestPoint)
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(state.isCapturingPoint)
                    if !state.takingHeight {
                        HStack {
                            Button("Add obstacle") { state.finishLoop(addObstacle: true) }
                            Button("Measure height") { state.finishLoop(addObstacle: false) }
                        }
                        .disabled(state.isCapturingPoint || (state.loops.last?.count ?? 0) < 3)
                    }
                    Text("Empty and secure the drawer. Keep it still. Trace a level floor; use extra points for curves. This captures a flat outline, not tapered walls or overhangs.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                .padding(.bottom)
                .navigationTitle("Scan interior")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { state.invalidate("The app left the camera. Retrace the interior after returning.") }
            else if state.result == nil { state.trackingInterrupted = false; cameraID = UUID() }
        }
    }
}
