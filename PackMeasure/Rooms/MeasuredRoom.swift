import Foundation
import simd

struct MeasuredRoom: Codable, Identifiable, Sendable {
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

    var hasRoomExtent: Bool {
        walls.count >= 3 && (excludedWallCount ?? 0) == 0
            && spanLength.isFinite && spanWidth.isFinite && min(spanLength, spanWidth) > 0.1
    }

    var coverageMessage: String {
        if hasRoomExtent { return "\(walls.count) walls captured. Check the outline for missing walls." }
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

    init(walls detectedWalls: [Wall], name: String = "Room", date: Date = .now) throws {
        let walls = detectedWalls.filter(\.isValid)
        guard let reference = walls.max(by: { $0.length < $1.length }) else {
            throw ValidationError.noValidWalls(detected: detectedWalls.count)
        }
        excludedWallCount = detectedWalls.count - walls.count
        let axis = simd_normalize(reference.end - reference.start)
        let perpendicular = SIMD2<Float>(-axis.y, axis.x)
        // Work relative to one wall to avoid translation-dependent rounding.
        let points = walls.flatMap { [$0.start - reference.start, $0.end - reference.start] }
        let x = points.map { simd_dot($0, axis) }
        let y = points.map { simd_dot($0, perpendicular) }
        let a = x.max()! - x.min()!
        let b = y.max()! - y.min()!
        id = UUID()
        self.date = date
        self.name = name
        self.walls = walls
        spanLength = a.isFinite && b.isFinite ? max(a, b) : 0
        spanWidth = a.isFinite && b.isFinite ? min(a, b) : 0
        wallHeight = walls.map(\.height).max()!
    }

    var shareText: String {
        var lines = [name, coverageMessage]
        if hasRoomExtent {
            lines += ["Scanned span: \(Self.dimension(spanLength)) × \(Self.dimension(spanWidth))",
                      "Maximum wall height: \(Self.dimension(wallHeight))",
                      "Approximate scanned extent; missing walls and recesses affect the result. Not floor area."]
        }
        lines += walls.enumerated().map { index, wall in
            "Wall \(index + 1): \(Self.dimension(wall.length)) long × \(Self.dimension(wall.height)) high (\(wall.confidence) confidence)"
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
