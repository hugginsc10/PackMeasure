import Foundation
import simd

enum RoomCaptureGuidance: String, CaseIterable, Sendable {
    case room = "Room"
    case tightCloset = "Tight closet"

    var preparation: String {
        switch self {
        case .room: "Move slowly around the room and include every corner."
        case .tightCloset: "Start at the open doorway with the light on. Aim across the closet at clear wall sections above and below shelves, then cover each corner. Finish with a slow upward sweep along the inside wall-to-ceiling edges."
        }
    }
}

enum RoomCoachingInstruction: String, CaseIterable, Sendable {
    case normal, moveAwayFromWall, moveCloseToWall, slowDown, turnOnLight, lowTexture, unknown
}

struct RoomCaptureObservation: Sendable {
    let walls: [MeasuredRoom.Wall]
    var tracking: String = "unavailable"
}

/// Monotonic, session-local coaching evidence. Elapsed time never proves coverage.
struct RoomCaptureCoaching {
    private(set) var isActive = false
    private(set) var instruction: RoomCoachingInstruction = .normal
    private(set) var walls: [MeasuredRoom.Wall] = []
    private(set) var wallUpdates = 0
    private(set) var peakWallCount = 0
    private(set) var tracking = "unavailable"
    private var hasStarted = false
    private var startedAt: TimeInterval = 0
    private var endedAt: TimeInterval?
    private var instructionChangedAt: TimeInterval = 0
    private var lastGeometryChangeAt: TimeInterval = 0
    private var progressBaseline: [MeasuredRoom.Wall] = []
    private var durations: [RoomCoachingInstruction: TimeInterval] = [:]
    private var events: [String] = []

    var validWallCount: Int { walls.filter(\.isValid).count }
    var lowConfidenceWallCount: Int { walls.filter { $0.isValid && $0.confidence == "low" }.count }

    mutating func begin(at time: TimeInterval) {
        self = Self()
        hasStarted = true
        isActive = true
        startedAt = time
        instructionChangedAt = time
        lastGeometryChangeAt = time
    }

    mutating func receive(_ next: RoomCoachingInstruction, at time: TimeInterval) {
        guard isActive, next != instruction else { return }
        durations[instruction, default: 0] += max(0, time - instructionChangedAt)
        instruction = next
        instructionChangedAt = time
        record("t=\(seconds(time - startedAt)) instruction=\(next.rawValue)")
    }

    mutating func receive(_ observation: RoomCaptureObservation, at time: TimeInterval) {
        guard isActive else { return }
        wallUpdates += 1
        walls = observation.walls
        peakWallCount = max(peakWallCount, walls.count)
        tracking = observation.tracking
        let usable = walls.filter(\.isValid)
        if Self.geometryChanged(from: progressBaseline, to: usable) {
            progressBaseline = usable
            lastGeometryChangeAt = time
            record("t=\(seconds(time - startedAt)) walls=\(walls.count) valid=\(usable.count) low=\(lowConfidenceWallCount) tracking=\(tracking)")
        }
    }

    mutating func end(at time: TimeInterval) {
        guard isActive else { return }
        durations[instruction, default: 0] += max(0, time - instructionChangedAt)
        isActive = false
        endedAt = time
    }

    func persistentCloseWarning(at time: TimeInterval) -> Bool {
        isActive && instruction == .moveAwayFromWall && time - instructionChangedAt >= 8
    }

    func outlineUnchanged(at time: TimeInterval) -> Bool {
        isActive && time - startedAt >= 20 && time - lastGeometryChangeAt >= 15
    }

    func showsGuidance(_ guidance: RoomCaptureGuidance, at time: TimeInterval) -> Bool {
        isActive && (guidance == .tightCloset || persistentCloseWarning(at: time))
    }

    func offersReview(at time: TimeInterval) -> Bool {
        validWallCount > 0 && (persistentCloseWarning(at: time) || outlineUnchanged(at: time))
    }

    func advice(at time: TimeInterval) -> (title: String, message: String) {
        switch instruction {
        case .turnOnLight:
            return ("Light the closet", "Turn on the light and keep the camera clear of your shadow. Then scan visible wall sections and corners.")
        case .slowDown:
            return ("Sweep more slowly", "Pause your steps and turn the phone gently from one corner to the next.")
        case .lowTexture:
            return ("Include a clear corner", "Aim where two walls meet, or at a wall-to-floor edge. A blank patch of wall gives the scanner less to track.")
        case .moveCloseToWall:
            return ("Bring the far wall into view", "Aim at a visible wall across the closet. Move closer only where there is room, keeping its corners in view.")
        case .moveAwayFromWall:
            return (persistentCloseWarning(at: time) ? "No room to step back?" : "Try the doorway",
                    "Move to the doorway if you can, and aim across the closet instead of at the nearest shelf. Lower the phone and tilt up toward the inside upper corners. Then sweep visible walls above and below shelving. Exclude outside walls when you review.")
        case .normal, .unknown:
            if outlineUnchanged(at: time) {
                return ("The outline hasn’t changed recently", "Try a different view of a clear wall or corner. If walls stay hidden, review what was captured and keep the scan partial.")
            }
            return ("Scan from the doorway", "Aim across the closet and cover each visible corner. Sweep above and below shelves, then look up along the inside wall-to-ceiling edges. Lower the phone if you need more distance.")
        }
    }

    func diagnosticSummary(at time: TimeInterval) -> String {
        guard hasStarted else { return "Capture has not started." }
        let end = endedAt ?? time
        let durationLines = RoomCoachingInstruction.allCases.map { kind in
            let active = isActive && kind == instruction ? max(0, end - instructionChangedAt) : 0
            return "instruction_\(kind.rawValue)_s=\(seconds(durations[kind, default: 0] + active))"
        }
        return (["capture_duration_s=\(seconds(end - startedAt)) wall_updates=\(wallUpdates) peak_wall_count=\(peakWallCount)",
                 "valid_walls=\(validWallCount) low_confidence_walls=\(lowConfidenceWallCount) tracking=\(tracking)",
                 "last_wall_geometry_change_s_ago=\(seconds(end - lastGeometryChangeAt))",
                 "latest_instruction=\(instruction.rawValue)"] + durationLines + events).joined(separator: "\n")
    }

    private mutating func record(_ event: String) {
        events.append(event)
        if events.count > 40 { events.removeFirst(events.count - 40) }
    }

    private func seconds(_ time: TimeInterval) -> String { String(format: "%.1f", max(0, time)) }

    private static func geometryChanged(from old: [MeasuredRoom.Wall], to new: [MeasuredRoom.Wall]) -> Bool {
        guard old.count == new.count else { return true }
        // Compare with the last meaningful geometry, not the last frame: slow
        // refinement accumulates. Reordering and sub-5 cm jitter are not progress.
        return new.contains { wall in
            guard let prior = old.first(where: { $0.id == wall.id }) else { return true }
            let direct = max(simd_distance(prior.start, wall.start), simd_distance(prior.end, wall.end))
            let reversed = max(simd_distance(prior.start, wall.end), simd_distance(prior.end, wall.start))
            return min(direct, reversed) >= 0.05 || abs(prior.height - wall.height) >= 0.05 || prior.confidence != wall.confidence
        }
    }
}
