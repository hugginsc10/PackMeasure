import Foundation

protocol InventoryStoring {
    func load() throws -> [MeasuredItem]
    func save(_ items: [MeasuredItem]) throws
    func loadLoadMix() -> PackingLoadMix
    func saveLoadMix(_ loadMix: PackingLoadMix) throws
}

extension InventoryStoring {
    func loadLoadMix() -> PackingLoadMix { .mixedHousehold }
    func saveLoadMix(_ loadMix: PackingLoadMix) throws {}
}

struct InventoryStore: InventoryStoring {
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
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970)
        }
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }

            let string = try container.decode(String.self)
            if let legacyDate = Self.decodeDate(string) {
                return legacyDate
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid inventory date value: \(string)"
            )
        }
    }

    func load() throws -> [MeasuredItem] {
        let url = try storageURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try decoder.decode([MeasuredItem].self, from: data)
    }

    func save(_ items: [MeasuredItem]) throws {
        let url = try storageURL()
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(items)
        try data.write(to: url, options: .atomic)
    }

    func loadLoadMix() -> PackingLoadMix {
        guard let url = try? loadMixURL(),
              let data = try? Data(contentsOf: url),
              let loadMix = try? decoder.decode(PackingLoadMix.self, from: data) else {
            return .mixedHousehold
        }
        return loadMix
    }

    func saveLoadMix(_ loadMix: PackingLoadMix) throws {
        let url = try loadMixURL()
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(loadMix)
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

    private func loadMixURL() throws -> URL {
        try storageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("load-mix.json")
    }

    private static func decodeDate(_ string: String) -> Date? {
        let preciseFormatter = ISO8601DateFormatter()
        preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let preciseDate = preciseFormatter.date(from: string) {
            return preciseDate
        }

        let legacyFormatter = ISO8601DateFormatter()
        legacyFormatter.formatOptions = [.withInternetDateTime]
        return legacyFormatter.date(from: string)
    }
}
