import ARKit
import SwiftUI

enum ShelfCaptureMethod: String, CaseIterable { case automatic = "Auto", solid = "Solid shelf", wire = "Wire shelf" }

struct ShelfCaptureFlow: View {
    let onMeasured: (ShelfGeometry, [SIMD3<Float>], SIMD3<Float>, RoomShelfMeasurement.Source, [ShelfPointMatch]?) -> Void
    @State var solidState = ShelfScanState()
    @State private var method: ShelfCaptureMethod = .automatic
    @State private var usesMatchedViews = false
    @State private var choosingMethod = false
    @State private var captureID = UUID()

    var body: some View {
        Group {
            if method == .wire || usesMatchedViews {
                WireShelfScannerView(onMeasured: { result, points, selected, matches in
                    onMeasured(result, points, selected, .twoView, matches)
                }, automaticReason: usesMatchedViews ? "Auto switched to matched views: no reliable solid patch was found. Mark visible wire points in two photos." : nil,
                onChooseMethod: { choosingMethod = true })
            } else {
                ShelfScannerView(onMeasured: { result, points, selected in
                    onMeasured(result, points, selected, .lidar, nil)
                }, onUseMatchedViews: method == .automatic ? { usesMatchedViews = true; captureID = UUID() } : nil,
                onChooseMethod: { choosingMethod = true }, state: solidState)
            }
        }
        .id(captureID)
        .task {
            if method == .automatic && !ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
                && ARWorldTrackingConfiguration.isSupported { usesMatchedViews = true }
        }
        .confirmationDialog("Measurement method", isPresented: $choosingMethod, titleVisibility: .visible) {
            ForEach(ShelfCaptureMethod.allCases, id: \.self) { next in
                Button(next.rawValue) { method = next; usesMatchedViews = false; solidState = ShelfScanState(); captureID = UUID() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Changing method starts a fresh shelf scan. Auto tries a solid surface first and switches to matched views when it cannot lock one. Covered solid shelves may also need matched views.")
        }
    }
}
