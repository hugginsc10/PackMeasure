import ARKit
import AVFoundation
import CoreImage
import SceneKit
import SwiftUI

@MainActor @Observable
final class InteriorScanState {
    var generation = UUID()
    var photo: InteriorPhoto?
    var photoRequested = false
    var photoCursor: CGPoint?
    var manualPlacement = false
    var ready = false
    var cameraStatus = "Starting camera…"
    var target = SIMD2<Float>(0.5, 0.5)
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
    var sweepEnabled = true
    var sweepSeed: SIMD3<Float>?
    var sweepResult = InteriorSweepResult()
    var stableSweepPreviews = 0
    var diagnosticsRequest = 0
    var sweepDiagnostics: String?
    var interruptionReason: String?
    var isSweeping: Bool { sweepEnabled && !manualPlacement && !automatic && !takingHeight && !pinned && result == nil }
    var canReviewSweep: Bool { isSweeping && ready && !trackingInterrupted && sweepResult.ready && stableSweepPreviews >= 2 }

    func receiveSweep(_ value: InteriorSweepResult, generation: UUID) {
        guard generation == self.generation, isSweeping, !trackingInterrupted else { return }
        if value.revision == sweepResult.revision { sweepResult.hint=value.hint; return }
        let old=sweepResult.loops.flatMap{$0}, new=value.loops.flatMap{$0}
        let matches = !old.isEmpty && old.count==new.count && value.loops.count==sweepResult.loops.count
            && old.allSatisfy { a in new.contains { simd_distance(a,$0)<0.008 } }
            && new.allSatisfy { a in old.contains { simd_distance(a,$0)<0.008 } }
        stableSweepPreviews = new.isEmpty ? 0 : matches ? stableSweepPreviews+1 : 1
        sweepResult=value; error=nil
    }
    func useSweepOutline() {
        guard canReviewSweep, let seed=sweepSeed else { return }
        loops=sweepResult.loops; pinned=true; sweepEnabled=false; selectedCorner=nil
        if let height=sweepResult.height {
            do { result=try InteriorGeometry.project(loops,heightPoint:seed+SIMD3(0,height,0)); error=nil }
            catch { self.error=error.localizedDescription; takingHeight=true }
        } else { takingHeight=true }
    }
    func chooseAnotherBase() {
        generation=UUID(); requestID += 1; isCapturingPoint=false
        sweepEnabled=true; sweepSeed=nil; sweepResult=InteriorSweepResult(); stableSweepPreviews=0
        sweepDiagnostics=nil; loops=[[]]; preview=[]; pinned=false; automatic=false
        manualPlacement=false; selectedCorner=nil; takingHeight=false; resumeCamera(); error=nil
    }

    var prompt: String {
        if isSweeping { return sweepSeed == nil ? "Tap the inside base of one drawer or shelf compartment. Then sweep slowly around it." : sweepResult.hint }
        if takingHeight { return "Choose a visible top edge above the traced base. Use the lowest height your insert must fit under." }
        if selectedCorner != nil { return photo == nil ? "Aim at the corrected floor corner, or freeze the view to place it precisely." : "Zoom in, then tap the correct location for the selected corner." }
        if automatic { return "Keep the whole base and its edges in view. Hold steady when the outline appears." }
        if pinned { return "Check the outline. Choose a corner below to correct it, or add a missed obstacle." }
        if photo != nil && loops.count > 1 { return "Zoom in and tap around this obstacle’s base in order. Include its widest footprint over the insert height." }
        if photo != nil { return "Pinch to zoom. Tap each floor corner in order, including every notch. Don’t repeat the first point." }
        if manualPlacement { return "Freeze a clear view to tap corners, or aim the cross and add them one at a time." }
        return "Point down at the clear inside base. Keep the drawer or cabinet still."
    }
    var hasOutline: Bool { (loops.first?.count ?? 0) >= 3 }
    var canFinish: Bool { (loops.last?.count ?? 0) >= 3 && !isCapturingPoint && !automatic }
    func freezeView() {
        guard ready, !automatic, result == nil, !isCapturingPoint else { return }
        photoRequested = true; error = nil
    }
    func receivePhoto(_ value: InteriorPhoto) {
        guard photoRequested, value.generation == generation, result == nil else { return }
        photo = value; photoRequested = false; photoCursor = nil
    }
    func resumeCamera() { photo = nil; photoRequested = false; photoCursor = nil }
    func placePhotoPoint(_ point: CGPoint) {
        guard let photo, photo.generation == generation, !trackingInterrupted, !isCapturingPoint,
              result == nil, !automatic else { return }
        if pinned && !takingHeight && selectedCorner == nil { return }
        photoCursor = point
        guard let world = photo.worldPoint(at: point) else {
            error = "No reliable depth at that exact spot. Resume camera for a clearer angle; your corners stay in place."; return
        }
        receive(world)
    }
    func selectCorner(loop: Int, point: Int) {
        guard !automatic, !takingHeight, !isCapturingPoint, loops.indices.contains(loop), loops[loop].indices.contains(point) else { return }
        selectedCorner = (loop, point); photoCursor = photo?.portraitPoint(loops[loop][point]); error = nil
    }
    func editOutline() { guard !isCapturingPoint else { return }; takingHeight = false; error = nil }
    func enterHeight(_ millimeters: Double) {
        guard takingHeight, !isCapturingPoint else { return }
        do { result = try InteriorGeometry.project(loops, enteredHeightMM: millimeters); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func useOutline(now: TimeInterval = CACurrentMediaTime()) {
        pinOutline(now: now)
        if pinned { finishLoop(addObstacle: false) }
    }
    func findCorners() {
        guard !isCapturingPoint, result == nil else { return }
        sweepEnabled=false
        resumeCamera(); manualPlacement = false
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
        guard !isCapturingPoint else { return }
        if isSweeping && canReviewSweep { loops=sweepResult.loops; pinned=true }
        sweepEnabled=false
        automatic = false; automaticSeed = nil; preview = []; stablePreviewFrames = 0
        manualPlacement = true; error = nil
    }
    func requestPoint(at point: SIMD2<Float> = SIMD2(0.5, 0.5)) {
        guard !isCapturingPoint, result == nil else { return }
        target = point
        isCapturingPoint = true
        requestID += 1
    }
    func receive(_ point: SIMD3<Float>) {
        guard result == nil else { return }
        do {
            if takingHeight {
                result = try InteriorGeometry.project(loops, heightPoint: point)
            } else if let selectedCorner {
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
                loops.append([]); pinned = false; manualPlacement = true; selectedCorner = nil
            } else {
                takingHeight = true; selectedCorner = nil; resumeCamera()
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    func undo() {
        guard !isCapturingPoint else { return }
        error = nil
        if takingHeight { takingHeight = false }
        else if pinned { selectedCorner = nil }
        else if selectedCorner != nil { selectedCorner = nil }
        else if loops.last!.isEmpty && loops.count > 1 { loops.removeLast() }
        else if !loops.last!.isEmpty { loops[loops.count - 1].removeLast() }
    }
    func invalidate(_ message: String) {
        // A saved review result no longer depends on a live world coordinate system.
        guard result == nil else { return }
        let wasSweep=isSweeping
        generation = UUID(); resumeCamera(); ready = false; manualPlacement = false
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
        sweepSeed=nil; sweepResult=InteriorSweepResult(); stableSweepPreviews=0; sweepEnabled=true
        sweepDiagnostics=nil; interruptionReason=message
        error = wasSweep ? "Camera tracking restarted. Tap the base when the camera is ready to begin a new sweep." : message
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
        view.scene.rootNode.addChildNode(context.coordinator.markers)
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
        if coordinator.lastDiagnosticsRequest != state.diagnosticsRequest {
            coordinator.lastDiagnosticsRequest=state.diagnosticsRequest
            let generation=state.generation
            Task { @MainActor [weak coordinator] in
                guard let coordinator else { return }
                let report=await coordinator.sweepWorker.diagnostics(generation:generation)
                guard coordinator.active, coordinator.state.generation==generation else { return }
                coordinator.state.sweepDiagnostics = "Build 59 interior sweep\nLast interruption: \(coordinator.state.interruptionReason ?? "none")\n" + report
            }
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
        let markers = SCNNode()
        let imageContext = CIContext()
        var lastRequest = 0
        var active = true
        var lastPreviewTime: TimeInterval = 0
        let sweepWorker=InteriorSweepWorker()
        var sweepBusy=false
        var lastDiagnosticsRequest=0
        var renderVersion=""
        @objc func selectCorner(_ gesture: UITapGestureRecognizer) {
            guard !state.automatic, !state.isCapturingPoint, state.photo == nil, let view else { return }
            if state.isSweeping {
                guard state.sweepSeed == nil, state.ready, view.bounds.width>0, view.bounds.height>0 else { return }
                let p=gesture.location(in:view)
                state.requestPoint(at:[Float(p.x/view.bounds.width),Float(p.y/view.bounds.height)])
                return
            }
            if !state.takingHeight {
                for hit in view.hitTest(gesture.location(in: view), options: nil) {
                    guard let parts = hit.node.name?.split(separator: ":"), parts.count == 2,
                          let loop = Int(parts[0]), let point = Int(parts[1]) else { continue }
                    state.selectCorner(loop: loop, point: point)
                    return
                }
            }
            guard state.ready, state.manualPlacement || state.takingHeight || state.selectedCorner != nil,
                  !state.pinned || state.takingHeight || state.selectedCorner != nil,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            let p = gesture.location(in: view)
            state.requestPoint(at: SIMD2(Float(p.x / view.bounds.width), Float(p.y / view.bounds.height)))
        }
        func render() {
            guard view != nil else { return }
            // Avoid rebuilding SceneKit geometry for unrelated state/UI updates.
            let version="\(state.generation)-\(state.sweepResult.revision)-\(state.stableSweepPreviews)-\(state.isSweeping)-\(String(describing:state.sweepSeed))-\(state.loops)-\(state.preview)-\(String(describing:state.selectedCorner))-\(state.pinned)-\(state.takingHeight)"
            guard renderVersion != version else { return }; renderVersion=version
            markers.childNodes.forEach { $0.removeFromParentNode() }
            let loops = state.isSweeping ? state.sweepResult.loops : state.automatic ? state.preview : state.loops
            if state.isSweeping {
                for point in state.sweepResult.coverage {
                    let tile=SCNBox(width:0.007,height:0.001,length:0.007,chamferRadius:0)
                    tile.firstMaterial?.lightingModel = .constant
                    tile.firstMaterial?.diffuse.contents=UIColor.systemTeal.withAlphaComponent(0.5)
                    let node=SCNNode(geometry:tile); node.simdPosition=point; markers.addChildNode(node)
                }
                if let seed=state.sweepSeed {
                    let sphere=SCNSphere(radius:0.009); sphere.firstMaterial?.diffuse.contents=UIColor.yellow
                    let node=SCNNode(geometry:sphere); node.simdPosition=seed; markers.addChildNode(node)
                }
            }
            for (loopIndex, loop) in loops.enumerated() {
                for (pointIndex, point) in loop.enumerated() {
                    let selected = state.selectedCorner?.loop == loopIndex && state.selectedCorner?.point == pointIndex
                    let sphere = SCNSphere(radius: selected ? 0.007 : 0.004)
                    sphere.firstMaterial?.lightingModel = .constant
                    sphere.firstMaterial?.diffuse.contents = selected ? UIColor.yellow : (loopIndex == 0 && pointIndex == 0 ? UIColor.orange : UIColor.systemTeal)
                    let node = SCNNode(geometry: sphere)
                    node.name = "\(loopIndex):\(pointIndex)"
                    node.simdPosition = point
                    markers.addChildNode(node)
                    let close = state.isSweeping || state.automatic || state.pinned || state.takingHeight || loopIndex < loops.count - 1
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
                    markers.addChildNode(edge)
                }
            }
        }
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard active, state.result == nil else { return }
            guard case .normal = frame.camera.trackingState else {
                state.ready = false
                state.cameraStatus = "Move slowly while tracking settles"
                if case .limited(.relocalizing) = frame.camera.trackingState {
                    state.invalidate("Tracking restarted. Capture the outline again.")
                }
                return
            }
            state.ready = true; state.cameraStatus = "Camera ready"
            if state.photoRequested { freeze(frame) }
            if state.isSweeping, let seed=state.sweepSeed, !sweepBusy, frame.timestamp-lastPreviewTime>=0.4,
               let snapshot=InteriorSweepFrame(frame:frame) {
                lastPreviewTime=frame.timestamp; sweepBusy=true
                let generation=state.generation
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let value=await sweepWorker.process(snapshot,seed:seed,generation:generation)
                    sweepBusy=false
                    guard active else { return }
                    state.receiveSweep(value,generation:generation)
                }
            }
            guard state.automatic, !state.isCapturingPoint,
                  frame.timestamp - lastPreviewTime >= 0.35 else { return }
            lastPreviewTime = frame.timestamp
            capture(requestID: state.requestID, preview: true)
        }
        private func freeze(_ frame: ARFrame) {
            guard CACurrentMediaTime() - frame.timestamp < 0.3,
                  let depth = frame.sceneDepth, let confidence = depth.confidenceMap else {
                state.photoRequested = false; state.error = "No depth for this view yet. Keep the base visible and try Freeze & zoom again."; return
            }
            let map = depth.depthMap, w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
            guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
                  CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h else { return }
            CVPixelBufferLockBaseAddress(map, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(map, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(map), let cbase = CVPixelBufferGetBaseAddress(confidence) else { return }
            var values = [Float](), confidences = [UInt8]()
            for y in 0..<h {
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float.self)
                let c = cbase.advanced(by: y * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
                values.append(contentsOf: UnsafeBufferPointer(start: row, count: w))
                confidences.append(contentsOf: UnsafeBufferPointer(start: c, count: w))
            }
            let oriented = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            guard let image = imageContext.createCGImage(oriented, from: oriented.extent) else {
                state.photoRequested = false; state.error = "Couldn’t freeze this view. Try again."; return
            }
            state.receivePhoto(InteriorPhoto(generation: state.generation, image: UIImage(cgImage: image),
                grid: DepthGrid(width: w, height: h, depths: values, confidences: confidences),
                imageSize: [Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)],
                intrinsics: frame.camera.intrinsics, transform: frame.camera.transform))
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
            if state.isSweeping {
                defer { state.isCapturingPoint=false }
                guard !state.trackingInterrupted, let view, let frame=view.session.currentFrame,
                      let snapshot=InteriorSweepFrame(frame:frame) else { state.error="Hold still while the camera gets depth."; return }
                let point=CGPoint(x:CGFloat(state.target.x),y:CGFloat(state.target.y)).applying(
                    frame.displayTransform(for:.portrait,viewportSize:view.bounds.size).inverted())
                guard let seed=snapshot.selectedBase(at:[Float(point.x),Float(point.y)]) else {
                    state.error="Tap a visible patch on the flat inside base. A wall or shelf edge can’t select the base."; return
                }
                state.sweepSeed=seed; state.error=nil
                return
            }
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
            let imagePoint = CGPoint(x: CGFloat(state.target.x), y: CGFloat(state.target.y)).applying(
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
            let sample = ScannerFrameDepthSampler(minimumDepthMeters: 0.15, maximumDepthMeters: 2.5).sample(
                normalizedImagePoint: SIMD2<Float>(Float(imagePoint.x), Float(imagePoint.y)),
                grid: grid,
                cameraImageResolutionPixels: SIMD2<Int>(Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)),
                cameraIntrinsics: frame.camera.intrinsics,
                cameraTransform: frame.camera.transform
            )
            // Once the floor seed is established, previews follow that world point,
            // even when the center cross is no longer over the original patch.
            if state.automatic {
                guard let origin = state.automaticSeed ?? (sample?.confidence == .high ? sample?.worldPosition : nil) else {
                    state.error = "Aim at a clear patch of the base, then try Find outline again."; return
                }
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
            } else {
                guard let sample, sample.confidence == .high else {
                    state.error = "No reliable depth at that exact spot. Try a clearer angle or freeze the view to zoom in."; return
                }
                state.receive(sample.worldPosition)
            }
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
