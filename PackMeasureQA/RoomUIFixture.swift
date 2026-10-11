import SwiftUI

/// Synthetic rooms stay in the simulator-only QA target. The shipping app uses RoomPlan.
struct RoomUIFixture: View {
    enum Route { case library, review, comparison, spatialComparison }
    // A SwiftUI parent can recreate this view. Keep fixtures' identity stable
    // so review State and outline .id never refer to different synthetic walls.
    private static let wallIDs = (1...4).map {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))!
    }
    private static let roomID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
    private static let partialID = UUID(uuidString: "00000000-0000-4000-8000-000000000102")!
    private static let liveID = UUID(uuidString: "00000000-0000-4000-8000-000000000103")!
    let route: Route
    private let store: RoomScanStore
    private let room: MeasuredRoom
    private let partial: MeasuredRoom
    @State private var saved = false
    @State private var prepared = false

    init(route: Route) {
        self.route = route
        store = RoomScanStore(directory: URL.temporaryDirectory.appending(path: "room-ui-fixture"))
        room = try! MeasuredRoom(walls: [
            .init(id: Self.wallIDs[0], start: [0, 0], end: [5, 0], height: 2.4, confidence: "high"),
            .init(id: Self.wallIDs[1], start: [5, 0], end: [5, 4], height: 2.4, confidence: "high"),
            .init(id: Self.wallIDs[2], start: [5, 4], end: [0, 4], height: 2.4, confidence: "high"),
            .init(id: Self.wallIDs[3], start: [0, 4], end: [0, 0], height: 2.4, confidence: "high")
        ], name: "Practice room", date: Date(timeIntervalSince1970: 1_790_985_600),
                                 id: Self.roomID, captureSource: .processed)
        partial = try! MeasuredRoom(walls: Array(room.walls.prefix(2)), name: "Partial room",
                                   date: room.date, id: Self.partialID, captureSource: .processed)
    }

    var body: some View {
        Group {
            if prepared {
                NavigationStack {
                    if route == .library || saved {
                        RoomMeasurementView(store: store)
                    } else if route == .comparison || route == .spatialComparison {
                        RoomCaptureReviewView(comparison: comparison, store: store,
                                              diagnostics: "Synthetic room comparison",
                                              onSaved: { saved = true }, onScanAgain: {})
                    } else {
                        RoomScanReviewView(room: room, store: store, diagnostics: "Synthetic room review",
                                           onSaved: { saved = true }, onScanAgain: {})
                    }
                }
            } else {
                ProgressView("Preparing synthetic rooms…")
            }
        }.diagnosticSupport().task {
            guard !prepared else { return }
            try? FileManager.default.removeItem(at: store.directory)
            if route == .library {
                try! store.save(room)
                try! store.save(partial)
            }
            prepared = true
        }
    }

    private var comparison: RoomCaptureComparison {
        if route == .spatialComparison {
            // Replay the user-supplied Build 66 report. These are fixture
            // coordinates, not new sensor or dimensional-accuracy evidence.
            let live = try! MeasuredRoom(walls: Self.reportLiveWalls, name: "Report room", date: room.date,
                                        id: Self.liveID, captureSource: .liveSnapshot)
            let finished = try! MeasuredRoom(walls: Self.reportFinishedWalls, name: live.name, date: room.date,
                                            id: Self.roomID, captureSource: .processed)
            return RoomCaptureComparison(live: live, processed: finished, processingFailure: nil)
        }
        let live = try! MeasuredRoom(walls: room.walls, name: room.name, date: room.date,
                                    id: Self.liveID, captureSource: .liveSnapshot)
        return RoomCaptureComparison(live: live, processed: partial, processingFailure: nil)
    }

    private static func reportWall(_ id: String, _ start: SIMD2<Float>, _ end: SIMD2<Float>,
                                   height: Float, confidence: String = "high") -> MeasuredRoom.Wall {
        .init(id: UUID(uuidString: id)!, start: start, end: end, height: height, confidence: confidence)
    }

    private static let reportLiveWalls: [MeasuredRoom.Wall] = [
        reportWall("B77E5231-4717-43F5-A6C8-B21016607049", [1.7118312, 0.9347325], [0.6512946, 1.448025], height: 2.3886647, confidence: "medium"),
        reportWall("41ED80FB-CCC4-4C4E-BC49-A2BAE56BE710", [-0.7961388, 2.37172], [-2.143776, -0.46396965], height: 2.55093),
        reportWall("91E06355-B2FD-49C2-A6CD-BD68CC3ECF58", [0.22436583, 3.533479], [-1.6028551, 4.445547], height: 2.3886647),
        reportWall("BCF3F300-502F-433E-ACEF-6034296B6967", [0.46663254, -1.7119524], [1.7118311, 0.93473244], height: 2.55093),
        reportWall("81F39481-8D74-455A-9525-B513B0107377", [-2.143776, -0.46396947], [0.4666326, -1.7119524], height: 2.55093)
    ]

    private static let reportFinishedWalls: [MeasuredRoom.Wall] = [
        reportWall("41ED80FB-CCC4-4C4E-BC49-A2BAE56BE710", [-0.7777767, 2.3906348], [-2.1390243, -0.4682619], height: 2.5500002),
        reportWall("BCF3F300-502F-433E-ACEF-6034296B6967", [0.47232085, -1.711639], [1.8141024, 1.1063756], height: 2.5500002),
        reportWall("81F39481-8D74-455A-9525-B513B0107377", [-2.1390243, -0.4682619], [0.4723209, -1.7116389], height: 2.5500002),
        reportWall("9D6904AE-CDA9-416A-92A5-E010F18D06B9", [0.5768366, -0.9625462], [0.7823944, -1.0604213], height: 2.5500002),
        reportWall("1DB55BCF-A64D-4EB5-B0B9-FBDDA646B1FD", [0.97855663, 1.3604449], [-0.030340046, 1.8408252], height: 2.385),
        reportWall("F580E12A-B087-4348-A487-EC341C78C456", [0.6468361, -1.3451215], [0.5768365, -0.9625462], height: 2.5500002)
    ]
}
