import Foundation

struct InventoryStore {
    private let fileManager: FileManager
    private let explicitStorageURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileManager: FileManager = .default,
        storageURL: URL? = nil
    ) {
        self.fileManager = fileManager
        explicitStorageURL = storageURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [MeasuredItem] {
        let url = try storageURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode([MeasuredItem].self, from: data)
    }

    func save(_ items: [MeasuredItem]) throws {
        let url = try storageURL()
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(items)
        try data.write(to: url, options: .atomic)
    }

    func storageURL() throws -> URL {
        if let explicitStorageURL {
            return explicitStorageURL
        }

        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base
            .appendingPathComponent("PackMeasure", isDirectory: true)
            .appendingPathComponent("inventory.json")
    }
}
