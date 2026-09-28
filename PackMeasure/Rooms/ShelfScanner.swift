import ARKit
import AVFoundation
import SceneKit
import SwiftUI

@MainActor @Observable
final class ShelfScanState {
    private(set) var selectedTop: SIMD3<Float>?
    private(set) var points: [SIMD3<Float>] = []
    private(set) var requestID = 0
    private(set) var isCapturing = false
    private(set) var target = SIMD2<Float>(0.5, 0.5)
    private var samples: [SIMD3<Float>] = []
    var error: String?
    var ready = false
    private(set) var needsMatchedViews = false
    var result: ShelfGeometry?

    var diagnosticSummary: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let lines = points.enumerated().map { "shelf_point=\($0.offset + 1) position=\($0.element)" }
        return (["PackMeasure build \(build) shelf measurement", "selected_top=\(String(describing: selectedTop))",
                 "step=\(stepTitle) ready=\(ready) capturing=\(isCapturing) target=\(target)",
                 "error=\(error ?? "none")"] + lines).joined(separator: "\n")
    }

    var stepTitle: String {
        guard selectedTop != nil else { return "Tap the shelf to lock it" }
        return ["Floor below the shelf", "Back edge · left end", "Back edge · right end", "Front edge · top", "Underside of shelf above"][min(points.count, 4)]
    }
    var instruction: String {
        guard selectedTop != nil else { return "Tap a visible, solid patch on top of the shelf—not a box. The shelf must be straight and level. Move around to expose its edges; wire gaps may read the wall behind them." }
        return ["Aim at the actual floor beneath the shelf. Keep the floor level with the area you’re measuring.",
                "Aim at the left end of the shelf’s back edge, on its top surface. Use the shelf edge, not the wall behind a rear gap.",
                "Aim at the right end of the same back edge. These two points must bracket the locked patch and be at least 20 cm apart.",
                "Aim at the shelf’s front edge, on top. Move to see bare shelf around stored items. Points on another level won’t be accepted.",
                "Aim directly above the front point, at the underside of the next shelf or lowest obstruction. This measures clear usable space above."][min(points.count, 4)]
    }
    func request(at point: SIMD2<Float> = [0.5, 0.5]) {
        guard ready, !isCapturing, result == nil, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        requestID += 1; target = point; samples = []; isCapturing = true; error = nil; needsMatchedViews = false
    }
    func reject(_ message: String, request: Int, useMatchedViews: Bool = false) {
        guard requestID == request, isCapturing else { return }
        isCapturing = false; samples = []; error = message
        needsMatchedViews = useMatchedViews && selectedTop == nil
    }
    func receive(_ point: SIMD3<Float>, horizontalSurface: Bool, request: Int) {
        guard requestID == request, isCapturing, result == nil else { return }
        guard [point.x, point.y, point.z].allSatisfy(\.isFinite) else {
            reject("No usable surface at that point. Try a clearer view.", request: request, useMatchedViews: true); return
        }
        if selectedTop == nil && !horizontalSurface {
            reject("Tap a solid, level patch on top of the shelf. A wire gap or vertical face can’t lock its top surface.", request: request, useMatchedViews: true); return
        }
        if selectedTop != nil && (points.isEmpty || points.count == 4) && !horizontalSurface {
            reject(points.isEmpty ? "Aim at a solid, level floor patch, not the wall or stored items." : "Aim at a solid, level underside directly above the front point, or skip clear space measurement.", request: request); return
        }
        if let first = samples.first, simd_distance(first, point) > 0.015 {
            reject("The selected surface moved in the depth readings. Hold still and try a solid patch.", request: request, useMatchedViews: true); return
        }
        samples.append(point)
        guard samples.count >= 5 else { return }
        let average = samples.reduce(SIMD3<Float>.zero, +) / Float(samples.count)
        isCapturing = false; samples = []
        guard let selectedTop else { self.selectedTop = average; return }
        if (1...3).contains(points.count), abs(average.y - selectedTop.y) > 0.03 {
            error = "That point is on a different level from the locked shelf. Aim at the top of the selected shelf."; return
        }
        var next = points; next.append(average)
        do {
            if next.count == 3 {
                let delta = SIMD2<Float>(next[2].x - next[1].x, next[2].z - next[1].z)
                guard simd_length(delta) >= 0.2 else { throw RoomDimensionError.wallReference }
            }
            if next.count >= 4 {
                let geometry = try ShelfGeometry(points: next, selectedTop: selectedTop)
                if next.count == 5 { result = geometry }
            }
            points = next; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func skipClearance() {
        guard !isCapturing, points.count == 4, let selectedTop else { return }
        do { result = try ShelfGeometry(points: points, selectedTop: selectedTop) }
        catch { self.error = error.localizedDescription }
    }
    func undo() {
        requestID += 1; isCapturing = false; samples = []; result = nil; error = nil
        if points.isEmpty { selectedTop = nil } else { points.removeLast() }
    }
    func invalidate(_ message: String) {
        guard result == nil else { return }
        requestID += 1; isCapturing = false; samples = []; points = []; selectedTop = nil
        ready = false; error = message; needsMatchedViews = false
    }
}

struct ShelfCamera: UIViewRepresentable {
    let state: ShelfScanState
    func makeCoordinator() -> Coordinator { Coordinator(state) }
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.backgroundColor = .black
        view.session.delegate = context.coordinator; view.session.delegateQueue = .main
        context.coordinator.view = view
        view.scene.rootNode.addChildNode(context.coordinator.markers)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.selectShelf(_:))))
        context.coordinator.start()
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) { context.coordinator.render() }
    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) {
        coordinator.active = false; view.session.delegate = nil; view.session.pause()
    }

    @MainActor final class Coordinator: NSObject, @preconcurrency ARSessionDelegate {
        let state: ShelfScanState
        let markers = SCNNode()
        weak var view: ARSCNView?
        var active = true
        var running = false
        var lastSampleTime: TimeInterval = 0
        var requestStartedAt: TimeInterval = 0
        var lastRequest = -1
        init(_ state: ShelfScanState) { self.state = state }
        func start() {
            running = false
            Task { @MainActor [weak self] in
                guard let self, active else { return }
                state.invalidate("Move slowly to start tracking, then tap the shelf.")
                guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
                    state.error = "Shelf scanning requires LiDAR. You can enter measurements instead."; return
                }
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard active else { return }
                guard allowed else { state.error = "Allow camera access in Settings, or enter measurements instead."; return }
                let config = ARWorldTrackingConfiguration()
                config.worldAlignment = .gravity; config.frameSemantics = .sceneDepth
                view?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                running = true
            }
        }
        @objc func selectShelf(_ gesture: UITapGestureRecognizer) {
            guard active, state.selectedTop == nil, let view, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let point = gesture.location(in: view)
            state.request(at: SIMD2(Float(point.x / view.bounds.width), Float(point.y / view.bounds.height)))
        }
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard active, running, state.result == nil else { return }
            guard case .normal = frame.camera.trackingState else {
                state.ready = false
                if state.isCapturing { state.reject("Wait for stable tracking, then try again.", request: state.requestID) }
                return
            }
            state.ready = true
            guard state.isCapturing else { return }
            if lastRequest != state.requestID {
                lastRequest = state.requestID; requestStartedAt = frame.timestamp
            }
            if frame.timestamp - requestStartedAt > 2 {
                state.reject("No stable depth at that point. Change your view or enter the measurement.", request: lastRequest, useMatchedViews: true); return
            }
            guard frame.timestamp - lastSampleTime >= 0.05, CACurrentMediaTime() - frame.timestamp < 0.3,
                  let view, let depth = frame.sceneDepth, let confidence = depth.confidenceMap else { return }
            lastSampleTime = frame.timestamp
            guard let reading = sample(frame: frame, depth: depth.depthMap, confidence: confidence, viewport: view.bounds.size) else {
                state.reject("No reliable depth at that exact point. Aim at a solid surface 15 cm–3 m away; wire gaps and covered edges may need manual measurement.", request: lastRequest, useMatchedViews: true); return
            }
            state.receive(reading.point, horizontalSurface: reading.horizontal, request: lastRequest)
        }
        private func sample(frame: ARFrame, depth: CVPixelBuffer, confidence: CVPixelBuffer, viewport: CGSize) -> (point: SIMD3<Float>, horizontal: Bool)? {
            guard viewport.width > 0, viewport.height > 0 else { return nil }
            let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
            guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32,
                  CVPixelBufferGetPixelFormatType(confidence) == kCVPixelFormatType_OneComponent8,
                  CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h else { return nil }
            CVPixelBufferLockBaseAddress(depth, .readOnly); CVPixelBufferLockBaseAddress(confidence, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(depth), let cbase = CVPixelBufferGetBaseAddress(confidence) else { return nil }
            var depths = [Float](), confidences = [UInt8]()
            depths.reserveCapacity(w*h); confidences.reserveCapacity(w*h)
            for y in 0..<h {
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(depth)).assumingMemoryBound(to: Float.self)
                let crow = cbase.advanced(by: y * CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
                depths.append(contentsOf: UnsafeBufferPointer(start: row, count: w))
                confidences.append(contentsOf: UnsafeBufferPointer(start: crow, count: w))
            }
            let grid = DepthGrid(width: w, height: h, depths: depths, confidences: confidences)
            let imagePoint = CGPoint(x: CGFloat(state.target.x), y: CGFloat(state.target.y))
                .applying(frame.displayTransform(for: .portrait, viewportSize: viewport).inverted())
            let sampler = ScannerFrameDepthSampler(minimumDepthMeters: 0.15, maximumDepthMeters: 3)
            func point(_ x: Float, _ y: Float) -> SIMD3<Float>? {
                guard (0..<1).contains(x), (0..<1).contains(y), let sample = sampler.sample(normalizedImagePoint: [x,y], grid: grid,
                    cameraImageResolutionPixels: [Int(frame.camera.imageResolution.width), Int(frame.camera.imageResolution.height)],
                    cameraIntrinsics: frame.camera.intrinsics, cameraTransform: frame.camera.transform), sample.confidence == .high else { return nil }
                return sample.worldPosition
            }
            let x = Float(imagePoint.x), y = Float(imagePoint.y)
            guard let center = point(x,y) else { return nil }
            // Lock only an observed local horizontal patch. No guessed plane,
            // enlarged search radius, or fallback to the image center.
            var horizontal = false
            if let left = point(x-2/Float(w),y), let right = point(x+2/Float(w),y),
               let top = point(x,y-2/Float(h)), let bottom = point(x,y+2/Float(h)) {
                let normal = simd_cross(right-left, bottom-top)
                horizontal = simd_length(normal) > 0.00001 && abs(simd_normalize(normal).y) > 0.94
                    && [left,right,top,bottom].allSatisfy { simd_distance($0,center) < 0.12 }
            }
            return (center,horizontal)
        }
        func render() {
            markers.childNodes.forEach { $0.removeFromParentNode() }
            if let selected = state.selectedTop {
                let ring = SCNTorus(ringRadius: 0.07, pipeRadius: 0.002)
                ring.firstMaterial?.lightingModel = .constant
                ring.firstMaterial?.diffuse.contents = UIColor.systemTeal
                let marker = SCNNode(geometry: ring)
                marker.simdPosition = selected + SIMD3<Float>(0,0.003,0)
                markers.addChildNode(marker)
            }
            let points = state.selectedTop.map { [$0] } ?? []
            for (index, point) in (points + state.points).enumerated() {
                let sphere = SCNSphere(radius: index == 0 ? 0.012 : 0.007)
                sphere.firstMaterial?.lightingModel = .constant
                sphere.firstMaterial?.diffuse.contents = index == 0 ? UIColor.systemYellow : UIColor.systemTeal
                let node = SCNNode(geometry: sphere); node.simdPosition = point
                markers.addChildNode(node)
            }
        }
        func sessionWasInterrupted(_ session: ARSession) {
            running = false
            state.invalidate("Tracking was interrupted. Lock the shelf again so every point shares one scan.")
        }
        func sessionInterruptionEnded(_ session: ARSession) { guard active else { return }; start() }
        func session(_ session: ARSession, didFailWithError error: any Error) {
            running = false
            state.invalidate("Tracking failed. Close and reopen the shelf scanner, or enter measurements.")
        }
    }
}

struct ShelfScannerView: View {
    let onMeasured: (ShelfGeometry, [SIMD3<Float>], SIMD3<Float>) -> Void
    var onUseMatchedViews: (() -> Void)? = nil
    var onChooseMethod: (() -> Void)? = nil
    @State var state = ShelfScanState()
    @State private var cameraID = UUID()
    @State private var restartOnForeground = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let result = state.result {
                    Form {
                        Section("Selected shelf · LiDAR estimate") {
                            LabeledContent("Depth", value: RoomShelfMeasurement.dimension(result.depth))
                            LabeledContent("Top above floor", value: RoomShelfMeasurement.dimension(result.height))
                            LabeledContent("Clear space above", value: result.clearance.map(RoomShelfMeasurement.dimension) ?? "Not measured")
                            Text("Verify these dimensions. Stored items and wire shelving can obscure the actual edges. You can correct the values before saving.").font(.footnote)
                        }
                        Button("Use shelf measurements") {
                            if let selected = state.selectedTop { onMeasured(result, state.points, selected); dismiss() }
                        }.accessibilityIdentifier("use-shelf-scan")
                        ShareLink("Shelf diagnostics", item: state.diagnosticSummary)
                        Button("Scan again") { state = ShelfScanState(); cameraID = UUID() }
                    }
                } else if !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    ContentUnavailableView("LiDAR unavailable", systemImage: "viewfinder",
                        description: Text("Shelf scanning requires LiDAR. You can enter measurements instead."))
                    Button("Return to manual entry") { dismiss() }.buttonStyle(.bordered).padding(.bottom)
                } else {
                    ZStack {
                        ShelfCamera(state: state).id(cameraID)
                        if state.selectedTop != nil {
                            Image(systemName: "plus").font(.largeTitle).foregroundStyle(.white).shadow(radius: 2).allowsHitTesting(false)
                        }
                    }.frame(maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if onUseMatchedViews != nil {
                                Text(state.selectedTop == nil ? "Auto · checking the shelf surface" : "Auto · solid-surface method")
                                    .font(.caption).foregroundStyle(MeasureStyle.accent)
                            }
                            if state.selectedTop != nil { Label("Shelf surface locked · move to see each edge", systemImage: "lock.fill").font(.caption).foregroundStyle(MeasureStyle.accent) }
                            Text(state.stepTitle).font(.headline)
                            Text(state.instruction).font(.subheadline)
                            if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange) }
                            if state.selectedTop != nil {
                                HStack {
                                    Button("Undo", action: state.undo).disabled(state.isCapturing)
                                    Spacer()
                                    Button(state.isCapturing ? "Hold still…" : "Capture point \(state.points.count + 1) of 5") { state.request() }
                                        .buttonStyle(.borderedProminent).disabled(!state.ready || state.isCapturing)
                                }
                                if state.points.count == 4 { Button("Skip clear space measurement", action: state.skipClearance).disabled(state.isCapturing) }
                            } else if state.isCapturing || state.ready || state.error == nil {
                                Text(state.isCapturing ? "Hold still to lock…" : state.ready ? "Tap a bare patch on the shelf top." : "Move slowly while tracking starts.").font(.caption)
                            }
                            ShareLink("Shelf diagnostics", item: state.diagnosticSummary).font(.caption)
                        }.padding(16)
                    }.frame(maxHeight: 280)
                }
            }
            .measureScreen().navigationTitle("Measure shelf").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if let onChooseMethod { ToolbarItem(placement: .confirmationAction) { Button("Method", action: onChooseMethod) } }
            }
            .onChange(of: state.needsMatchedViews, initial: true) { _, needed in
                if needed { onUseMatchedViews?() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background && state.result == nil {
                    state.invalidate("The app left the foreground. Lock the shelf again.")
                    restartOnForeground = true
                } else if phase == .active && restartOnForeground {
                    restartOnForeground = false; cameraID = UUID()
                }
            }
        }.tint(MeasureStyle.accent).preferredColorScheme(.dark)
    }
}
