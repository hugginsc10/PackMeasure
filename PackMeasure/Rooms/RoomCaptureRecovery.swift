import Foundation

/// Retain the latest complete snapshot, never a union or the peak wall count.
/// Freeze at Finish so queued updates cannot replace the user's live outline.
struct RoomCaptureRecovery {
    private(set) var latestWalls: [MeasuredRoom.Wall] = []
    private(set) var frozenWalls: [MeasuredRoom.Wall]?

    mutating func receive(_ walls: [MeasuredRoom.Wall]) {
        guard frozenWalls == nil else { return }
        latestWalls = walls
    }

    mutating func freeze() {
        guard frozenWalls == nil else { return }
        frozenWalls = latestWalls
    }

    func comparison(processed: MeasuredRoom?, failure: String?) -> RoomCaptureComparison? {
        let live = try? MeasuredRoom(walls: frozenWalls ?? latestWalls, captureSource: .liveSnapshot)
        guard live != nil || processed != nil else { return nil }
        return RoomCaptureComparison(live: live, processed: processed, processingFailure: failure)
    }

    var diagnosticSummary: String {
        let walls = frozenWalls ?? latestWalls
        let header = "live_snapshot_frozen=\(frozenWalls != nil) detected_walls=\(walls.count) valid_walls=\(walls.filter(\.isValid).count)"
        let details = walls.enumerated().map { index, wall in
            "live_wall=\(index + 1) id=\(wall.id) length_m=\(wall.length) height_m=\(wall.height) start_xz=\(wall.start) end_xz=\(wall.end) confidence=\(wall.confidence)"
        }
        return ([header] + details).joined(separator: "\n")
    }
}

struct RoomCaptureComparison: Identifiable {
    let id = UUID()
    let live: MeasuredRoom?
    let processed: MeasuredRoom?
    let processingFailure: String?

    // These thresholds trigger a review, not a claim about sensor accuracy.
    var needsChoice: Bool {
        guard let live else { return false }
        guard let processed else { return true }
        if processed.walls.count < live.walls.count { return true }
        let before = live.walls.reduce(0) { $0 + $1.length }
        let after = processed.walls.reduce(0) { $0 + $1.length }
        return (before - after > 0.25 && after < before * 0.75)
            || live.wallHeight - processed.wallHeight > 0.3
    }

    var title: String {
        guard let processed else { return "The live outline is still available" }
        if let live, processed.walls.count < live.walls.count {
            return "Fewer walls after Finish"
        }
        return needsChoice ? "The outline changed after Finish" : "Compare captured outlines"
    }

    var message: String {
        guard let processed else {
            return "A usable finished outline wasn’t returned. You can review the unprocessed live outline or scan again."
        }
        let liveCount = live?.walls.count ?? 0
        let finalCount = processed.walls.count
        return "Live: \(liveCount) \(liveCount == 1 ? "wall" : "walls") · Finished: \(finalCount) \(finalCount == 1 ? "wall" : "walls"). Processing can merge or remove segments. Choose the outline that matches your room, then select which walls to save."
    }

    var diagnosticSummary: String {
        "comparison_live_walls=\(live?.walls.count ?? 0) processed_walls=\(processed?.walls.count ?? 0) requires_choice=\(needsChoice)\nprocessing_failure=\(processingFailure ?? "none")"
    }
}
