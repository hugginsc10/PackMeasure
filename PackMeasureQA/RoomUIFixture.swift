import SwiftUI

/// Synthetic rooms stay in the simulator-only QA target. The shipping app uses RoomPlan.
struct RoomUIFixture: View {
    enum Route { case library, review, comparison }
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
                    } else if route == .comparison {
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
        }.task {
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
        let live = try! MeasuredRoom(walls: room.walls, name: room.name, date: room.date,
                                    id: Self.liveID, captureSource: .liveSnapshot)
        return RoomCaptureComparison(live: live, processed: partial, processingFailure: nil)
    }
}
