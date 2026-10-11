import Foundation
import simd

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
    var needsChoice: Bool { !choiceReasons.isEmpty }

    private var choiceReasons: [String] {
        guard let live else { return [] }
        guard let processed else { return ["processed_unavailable"] }
        var reasons: [String] = []
        if processed.walls.count < live.walls.count { reasons.append("wall_count_loss") }
        let before = live.walls.reduce(0) { $0 + $1.length }
        let after = processed.walls.reduce(0) { $0 + $1.length }
        if before - after > 0.25 && after < before * 0.75 { reasons.append("total_wall_length_loss") }
        if live.wallHeight - processed.wallHeight > 0.3 { reasons.append("wall_height_loss") }
        if !significantCoverageLoss.isEmpty { reasons.append("wall_coverage_loss") }
        return reasons
    }

    private struct WallCoverageLoss {
        let wallID: UUID
        let length: Double
        let uncovered: Double
        var fraction: Double { uncovered / length }
    }

    private var significantCoverageLoss: [WallCoverageLoss] {
        guard let live, let processed else { return [] }
        return live.walls.compactMap { wall in
            let loss = Self.coverageLoss(of: wall, in: processed.walls)
            return loss.uncovered > 0.25 && loss.fraction > 0.25 ? loss : nil
        }
    }

    private static let coverageLineTolerance = 0.10
    private static let coverageDirectionCosine = cos(5 * Double.pi / 180)

    /// Compare the reported coordinates without aligning or changing either outline.
    /// A wholesale frame shift also prompts review: these reports do not establish a
    /// common-frame guarantee, and matching each wall independently could hide loss.
    /// Nearby parallel segments can split or merge; their interval union counts each
    /// part of the live wall once, regardless of IDs, order, or endpoint direction.
    private static func coverageLoss(of wall: MeasuredRoom.Wall, in processed: [MeasuredRoom.Wall]) -> WallCoverageLoss {
        func point(_ value: SIMD2<Float>) -> SIMD2<Double> { [Double(value.x), Double(value.y)] }
        let origin = point(wall.start)
        let vector = point(wall.end) - origin
        let length = simd_length(vector)
        let axis = vector / length
        let normal = SIMD2<Double>(-axis.y, axis.x)
        var intervals: [(start: Double, end: Double)] = []

        for candidate in processed {
            let start = point(candidate.start) - origin
            let end = point(candidate.end) - origin
            let direction = simd_normalize(end - start)
            guard abs(simd_dot(axis, direction)) >= coverageDirectionCosine else { continue }
            let projectedStart = simd_dot(start, axis)
            let projectedEnd = simd_dot(end, axis)
            var lower = max(0, min(projectedStart, projectedEnd))
            var upper = min(length, max(projectedStart, projectedEnd))
            guard upper > lower else { continue }

            // Only the portion near this live supporting line contributes coverage.
            // Evaluate normal distance as a function of the projected position so a
            // long merged segment's distant extension cannot reject its nearby part.
            let startNormal = simd_dot(start, normal)
            let slope = (simd_dot(end, normal) - startNormal) / (projectedEnd - projectedStart)
            if abs(slope) < 1e-12 {
                guard abs(startNormal) <= coverageLineTolerance else { continue }
            } else {
                let a = projectedStart + (-coverageLineTolerance - startNormal) / slope
                let b = projectedStart + (coverageLineTolerance - startNormal) / slope
                lower = max(lower, min(a, b))
                upper = min(upper, max(a, b))
            }
            if upper > lower { intervals.append((lower, upper)) }
        }

        var covered = 0.0
        var coveredEnd = 0.0
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            let start = max(interval.start, coveredEnd)
            if interval.end > start {
                covered += interval.end - start
                coveredEnd = interval.end
            }
        }
        return WallCoverageLoss(wallID: wall.id, length: length, uncovered: max(0, length - covered))
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
        let reasons = choiceReasons
        var lines = [
            "comparison_live_walls=\(live?.walls.count ?? 0) processed_walls=\(processed?.walls.count ?? 0) requires_choice=\(!reasons.isEmpty)",
            "processing_failure=\(processingFailure ?? "none")",
            "comparison_choice_reasons=\(reasons.isEmpty ? "none" : reasons.joined(separator: ","))"
        ]
        for loss in significantCoverageLoss {
            let metrics = String(format: "uncovered_m=%.3f uncovered_fraction=%.3f", locale: Locale(identifier: "en_US_POSIX"),
                                 loss.uncovered, loss.fraction)
            lines.append("comparison_uncovered_live_wall=\(loss.wallID) \(metrics)")
        }
        return lines.joined(separator: "\n")
    }
}
