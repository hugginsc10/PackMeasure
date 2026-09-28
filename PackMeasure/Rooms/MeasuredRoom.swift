import Foundation
import simd

struct MeasuredRoom: Codable, Identifiable, Sendable {
    enum CaptureSource: String, Codable, Sendable {
        case processed
        case liveSnapshot
    }

    struct Wall: Codable, Identifiable, Sendable {
        let id: UUID
        let start: SIMD2<Float>
        let end: SIMD2<Float>
        let height: Float
        let confidence: String

        var length: Float { simd_distance(start, end) }
        var isValid: Bool {
            [start.x, start.y, end.x, end.y, height].allSatisfy(\.isFinite)
                && height > 0 && length.isFinite && length > 0.05
        }
    }

    let id: UUID
    let date: Date
    var name: String
    let walls: [Wall]
    let spanLength: Float
    let spanWidth: Float
    let wallHeight: Float
    let excludedWallCount: Int?
    let omittedWallCount: Int? // Walls deliberately left out during review; older saves omit this.

    let captureSource: CaptureSource? // Nil for rooms saved before outline recovery.

    var captureSourceMessage: String? {
        captureSource == .liveSnapshot
            ? "Live outline · unprocessed. Wall positions and heights may change during processing. Check the outline and verify dimensions."
            : nil
    }

    var ceilingHeight: RoomCeilingHeight?
    var shelves: [RoomShelfMeasurement]? // Optional for old saved-room compatibility.

    var renderedWalls: [Wall] {
        guard let ceilingHeight else { return walls }
        return walls.map { Wall(id: $0.id, start: $0.start, end: $0.end,
                                height: ceilingHeight.meters, confidence: $0.confidence) }
    }

    var displayedHeight: Float { ceilingHeight?.meters ?? wallHeight }

    var hasRoomExtent: Bool {
        walls.count >= 3 && (excludedWallCount ?? 0) == 0
            && spanLength.isFinite && spanWidth.isFinite && min(spanLength, spanWidth) > 0.1
    }

    var coverageMessage: String {
        if hasRoomExtent {
            let action = (omittedWallCount ?? 0) > 0 ? "kept" : "captured"
            return "\(walls.count) walls \(action). Check the outline for missing walls."
        }
        return "Partial scan: \(walls.count) valid wall(s), \(excludedWallCount ?? 0) unusable wall(s). Individual wall dimensions are available; the overall room size is not established."
    }

    enum ValidationError: LocalizedError {
        case noValidWalls(detected: Int)
        var errorDescription: String? {
            switch self {
            case .noValidWalls(let count):
                return "RoomPlan returned \(count) wall(s), but none had usable dimensions. Start a new scan. Share diagnostics if this repeats."
            }
        }
    }

    init(walls detectedWalls: [Wall], name: String = "Room", date: Date = .now,
         id: UUID = UUID(), previouslyExcludedWallCount: Int = 0, omittedWallCount: Int = 0,
         captureSource: CaptureSource? = nil, ceilingHeight: RoomCeilingHeight? = nil,
         shelves: [RoomShelfMeasurement]? = nil) throws {
        let walls = detectedWalls.filter(\.isValid)
        guard let reference = walls.max(by: { $0.length < $1.length }) else {
            throw ValidationError.noValidWalls(detected: detectedWalls.count)
        }
        excludedWallCount = previouslyExcludedWallCount + detectedWalls.count - walls.count
        self.omittedWallCount = omittedWallCount
        self.captureSource = captureSource
        self.ceilingHeight = ceilingHeight
        self.shelves = shelves
        let axis = simd_normalize(reference.end - reference.start)
        let perpendicular = SIMD2<Float>(-axis.y, axis.x)
        // Work relative to one wall to avoid translation-dependent rounding.
        let points = walls.flatMap { [$0.start - reference.start, $0.end - reference.start] }
        let x = points.map { simd_dot($0, axis) }
        let y = points.map { simd_dot($0, perpendicular) }
        let a = x.max()! - x.min()!
        let b = y.max()! - y.min()!
        self.id = id
        self.date = date
        self.name = name
        self.walls = walls
        spanLength = a.isFinite && b.isFinite ? max(a, b) : 0
        spanWidth = a.isFinite && b.isFinite ? min(a, b) : 0
        wallHeight = walls.map(\.height).max()!
    }

    /// Preserve captured wall identity and dimensions; only recalculate the kept extent.
    func keepingWalls(_ ids: Set<UUID>) throws -> MeasuredRoom {
        try MeasuredRoom(walls: walls.filter { ids.contains($0.id) }, name: name, date: date, id: id,
                         previouslyExcludedWallCount: excludedWallCount ?? 0,
                         omittedWallCount: (omittedWallCount ?? 0) + walls.filter { !ids.contains($0.id) }.count,
                         captureSource: captureSource, ceilingHeight: ceilingHeight,
                         shelves: shelves?.filter { $0.wallID.map(ids.contains) ?? true })
    }

    var heightReviewMessage: String? {
        guard let shortest = walls.map(\.height).min(), wallHeight - shortest > 0.2 else { return nil }
        return "Captured wall heights range from \(Self.dimension(shortest)) to \(Self.dimension(wallHeight)). Check the upper inside corners and exclude outside walls. Wall heights do not verify the ceiling."
    }

    var shareText: String {
        var lines = [name, coverageMessage]
        if let captureSourceMessage { lines.append(captureSourceMessage) }
        if let ceilingHeight {
            lines.append("Ceiling height: \(Self.dimension(ceilingHeight.meters)) (entered manually; used for 3D outline). Captured wall heights below are unchanged.")
        }
        if let omittedWallCount, omittedWallCount > 0 {
            lines.append("\(omittedWallCount) wall(s) left out during review.")
        }
        if let heightReviewMessage { lines.append(heightReviewMessage) }
        if hasRoomExtent {
            lines += ["Scanned span: \(Self.dimension(spanLength)) × \(Self.dimension(spanWidth))",
                      "Maximum wall height: \(Self.dimension(wallHeight))",
                      "Approximate scanned extent; missing walls and recesses affect the result. Not floor area."]
        }
        lines += walls.enumerated().map { index, wall in
            "Wall \(index + 1): \(Self.dimension(wall.length)) long × \(Self.dimension(wall.height)) high (\(wall.confidence) confidence)"
        }
        if let shelves, !shelves.isEmpty {
            lines.append("Shelves")
            lines += shelves.map(\.shareText)
        }
        return lines.joined(separator: "\n")
    }

    static func dimension(_ meters: Float) -> String {
        String(format: "%.2f m · %.1f ft", meters, meters * 3.28084)
    }
}

struct RoomScanStore {
    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appending(path: "PackMeasure/Rooms", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func save(_ room: MeasuredRoom) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(room)
        try data.write(to: directory.appendingPathComponent("\(room.id).json"), options: .atomic)
    }

    func load() throws -> [MeasuredRoom] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(MeasuredRoom.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}
