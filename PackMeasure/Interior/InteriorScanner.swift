import ARKit
import AVFoundation
import SceneKit
import SwiftUI

@MainActor @Observable
final class InteriorScanState {
    var loops: [[SIMD3<Float>]] = [[]]
    var automatic = false
    var automaticSeed: SIMD3<Float>?
    var preview: [[SIMD3<Float>]] = []
    var previewTimestamp: TimeInterval = 0
    var stablePreviewFrames = 0
    var pinned = false
    var selectedCorner: (loop: Int, point: Int)?
    var takingHeight = false
    var requestID = 0
    var isCapturingPoint = false
    var error: String?
    var trackingInterrupted = false
    var result: InteriorMeasurement?

    var prompt: String {
        if automatic { return "Aim at the drawer floor from above. Keep every edge visible. Check the live corners, then pin the outline." }
        if selectedCorner != nil && !takingHeight { return "Aim the reticle at the corrected floor corner, then tap Move selected corner." }
        if loops == [[]] && !takingHeight { return "Aim at the drawer floor and tap Find corners for a live outline, or add points manually." }
        if pinned && !takingHeight { return "Tap a corner to adjust it, or measure height. Check every notch and cutout before continuing." }
        if takingHeight { return "Aim directly above the orange first point, at the lowest usable top edge. Capture height." }
        if loops.count == 1 { return "Trace the inside floor perimeter in order. Add points at every corner or bend, including notches. Do not repeat the first point." }
        return "Trace obstacle \(loops.count - 1) at floor level, in order around its base. Include its widest footprint over the insert height."
    }
    func findCorners() {
        guard !isCapturingPoint, result == nil else { return }
        automatic = true
        automaticSeed = nil
        preview = []
        previewTimestamp = 0
        stablePreviewFrames = 0
        loops = [[]]
        pinned = false
        selectedCorner = nil
        takingHeight = false
        error = nil
        requestPoint()
    }
    func updatePreview(_ candidate: [[SIMD3<Float>]], now: TimeInterval) {
        let oldPoints = preview.flatMap { $0 }, newPoints = candidate.flatMap { $0 }
        let matches = now - previewTimestamp < 0.6 && candidate.count == preview.count
            && newPoints.count == oldPoints.count && !oldPoints.isEmpty
            && newPoints.allSatisfy { p in oldPoints.contains { simd_distance(p, $0) <= 0.006 } }
            && oldPoints.allSatisfy { p in newPoints.contains { simd_distance(p, $0) <= 0.006 } }
        stablePreviewFrames = matches ? min(3, stablePreviewFrames + 1) : 1
        preview = candidate
        previewTimestamp = now
    }
    func pinOutline(now: TimeInterval = CACurrentMediaTime()) {
        guard automatic, !isCapturingPoint, !preview.isEmpty, stablePreviewFrames >= 3,
              now - previewTimestamp < 0.6, !trackingInterrupted else { return }
        loops = preview
        automatic = false
        pinned = true
        preview = []
        selectedCorner = nil
        error = nil
    }
    func useManual() {
        invalidate("")
        error = nil
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
            } else if let selectedCorner, pinned {
                guard let origin = loops.first?.first, abs(point.y - origin.y) <= 0.008 else {
                    throw InteriorGeometryError.nonPlanar
                }
                var updated = loops
                updated[selectedCorner.loop][selectedCorner.point] = point
                _ = try InteriorGeometry.project(updated, heightPoint: updated[0][0] + SIMD3<Float>(0, 0.1, 0))
                loops = updated
                self.selectedCorner = nil
            } else {
                guard !pinned else { return }
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
        else if pinned { useManual() }
        else if loops.last!.isEmpty && loops.count > 1 { loops.removeLast() }
        else if !loops.last!.isEmpty { loops[loops.count - 1].removeLast() }
    }
    func invalidate(_ message: String) {
        // A saved review result no longer depends on a live world coordinate system.
        guard result == nil else { return }
        requestID += 1
        isCapturingPoint = false
        loops = [[]]
        automatic = false
        automaticSeed = nil
        preview = []
        previewTimestamp = 0
        stablePreviewFrames = 0
        pinned = false
        selectedCorner = nil
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
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectCorner(_:))))
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
        coordinator.render()

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
        var lastPreviewTime: TimeInterval = 0
        @objc func selectCorner(_ gesture: UITapGestureRecognizer) {
            guard state.pinned, !state.takingHeight, !state.isCapturingPoint, let view else { return }
            for hit in view.hitTest(gesture.location(in: view), options: nil) {
                guard let parts = hit.node.name?.split(separator: ":"), parts.count == 2,
                      let loop = Int(parts[0]), let point = Int(parts[1]) else { continue }
                state.selectedCorner = (loop, point)
                return
            }
        }
        func render() {
            guard let view else { return }
            view.scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
            let loops = state.automatic ? state.preview : state.loops
            for (loopIndex, loop) in loops.enumerated() {
                for (pointIndex, point) in loop.enumerated() {
                    let selected = state.selectedCorner?.loop == loopIndex && state.selectedCorner?.point == pointIndex
                    let sphere = SCNSphere(radius: selected ? 0.007 : 0.004)
                    sphere.firstMaterial?.lightingModel = .constant
                    sphere.firstMaterial?.diffuse.contents = selected ? UIColor.yellow : (loopIndex == 0 && pointIndex == 0 ? UIColor.orange : UIColor.systemTeal)
                    let node = SCNNode(geometry: sphere)
                    node.name = "\(loopIndex):\(pointIndex)"
                    node.simdPosition = point
                    view.scene.rootNode.addChildNode(node)
                    let close = state.automatic || state.pinned || state.takingHeight || loopIndex < loops.count - 1
                    guard pointIndex > 0 || (close && loop.count > 2) else { continue }
                    let previous = loop[(pointIndex + loop.count - 1) % loop.count]
                    let length = simd_distance(point, previous)
                    guard length > 0 else { continue }
                    let cylinder = SCNCylinder(radius: 0.0015, height: CGFloat(length))
                    cylinder.firstMaterial?.lightingModel = .constant
                    cylinder.firstMaterial?.diffuse.contents = UIColor.systemTeal
                    let edge = SCNNode(geometry: cylinder)
                    edge.simdPosition = (point + previous) / 2
                    edge.simdOrientation = simd_quatf(from: SIMD3<Float>(0,1,0), to: (point-previous)/length)
                    view.scene.rootNode.addChildNode(edge)
                }
            }
        }
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard active, state.automatic, !state.isCapturingPoint,
                  frame.timestamp - lastPreviewTime >= 0.35 else { return }
            lastPreviewTime = frame.timestamp
            capture(requestID: state.requestID, preview: true)
        }
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
        func capture(requestID: Int, preview: Bool = false) {
            guard state.requestID == requestID, preview ? state.automatic : state.isCapturingPoint else { return }
            var previewSucceeded = false
            defer {
                if state.automatic && !previewSucceeded {
                    state.preview = []
                    state.previewTimestamp = 0
                    state.stablePreviewFrames = 0
                }
            }
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
            if state.automatic {
                let origin = state.automaticSeed ?? sample.worldPosition
                state.automaticSeed = origin
                let cameraOrigin = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                let sx = Float(w) / Float(frame.camera.imageResolution.width)
                let sy = Float(h) / Float(frame.camera.imageResolution.height)
                let fx = frame.camera.intrinsics[0][0] * sx, fy = frame.camera.intrinsics[1][1] * sy
                let cx = frame.camera.intrinsics[2][0] * sx, cy = frame.camera.intrinsics[2][1] * sy
                func ray(_ x: Float, _ y: Float) -> SIMD3<Float> {
                    let r = frame.camera.transform * SIMD4<Float>((x-cx)/fx, -(y-cy)/fy, -1, 0)
                    return SIMD3<Float>(r.x,r.y,r.z)
                }
                let cameraSeed = frame.camera.transform.inverse * SIMD4<Float>(origin.x, origin.y, origin.z, 1)
                guard cameraSeed.z < -0.15 else { return }
                let seedX = Int(cx + fx * cameraSeed.x / -cameraSeed.z)
                let seedY = Int(cy - fy * cameraSeed.y / -cameraSeed.z)
                guard (0..<w).contains(seedX), (0..<h).contains(seedY) else { return }
                var surface = [SIMD3<Float>?](repeating: nil, count: w*h)
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y*w+x, d = depths[i]
                        if confidences[i] == ARConfidenceLevel.high.rawValue, d.isFinite, (0.15...2.5).contains(d) {
                            surface[i] = cameraOrigin + ray(Float(x), Float(y)) * d
                        }
                    }
                }
                guard let seedPoint = surface[seedY*w+seedX], abs(seedPoint.y-origin.y) < 0.008 else { return }
                do {
                    let candidate = try InteriorCornerDetector.detect(width: w, height: h, surface: surface, seed: seedY*w+seedX) { x,y in
                        let direction = ray(x-0.5,y-0.5)
                        guard abs(direction.y) > 0.15 else { return nil }
                        let distance = (seedPoint.y-cameraOrigin.y)/direction.y
                        guard (0.15...2.5).contains(distance) else { return nil }
                        return cameraOrigin + direction * distance
                    }
                    // Validate in the same coordinate system used by review/export before enabling pinning.
                    _ = try InteriorGeometry.project(candidate, heightPoint: candidate[0][0] + SIMD3<Float>(0, 0.1, 0))
                    state.updatePreview(candidate, now: CACurrentMediaTime())
                    previewSucceeded = true
                    state.error = nil
                } catch { state.error = error.localizedDescription }
            } else { state.receive(sample.worldPosition) }
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
                    Text(state.automatic
                         ? "\(state.preview.first?.count ?? 0) corners · \(max(0, state.preview.count - 1)) cutouts · \(state.stablePreviewFrames >= 3 ? "Ready to pin" : "Finding stable edges")"
                         : "\(state.loops.last?.count ?? 0) points · \(state.loops.count - 1) obstacle outlines")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                    if state.automatic {
                        Button("Pin outline") { state.pinOutline() }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.preview.isEmpty || state.stablePreviewFrames < 3 || state.isCapturingPoint)
                        Button("Use manual points", action: state.useManual)
                    } else if state.loops == [[]] {
                        Button("Find corners", action: state.findCorners).buttonStyle(.borderedProminent)
                    }
                    HStack {
                        Button(state.pinned ? "Clear outline" : "Undo", action: state.undo)
                        Button(state.takingHeight ? "Capture height" : (state.pinned ? "Move selected corner" : "Add point"), action: state.requestPoint)
                            .disabled(state.pinned && !state.takingHeight && state.selectedCorner == nil)
                            .buttonStyle(.borderedProminent)
                    }
                    .disabled(state.isCapturingPoint || state.automatic)
                    if !state.takingHeight && !state.automatic {
                        HStack {
                            if !state.pinned { Button("Add obstacle") { state.finishLoop(addObstacle: true) } }
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
