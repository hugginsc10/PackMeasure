import Foundation

enum SupportContact {
    static let email = "hugginsc10@gmail.com"
}

/// An explicit, immutable snapshot. Creating a report neither logs nor sends it.
struct DiagnosticReport: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case app, room, object, interior, shelf
        case wireShelf = "wire-shelf"

        var title: String {
            switch self {
            case .app: "App"
            case .room: "Room scan"
            case .object: "Object scan"
            case .interior: "Interior scan"
            case .shelf: "Shelf scan"
            case .wireShelf: "Wire shelf scan"
            }
        }
    }

    let id: UUID
    let kind: Kind
    let createdAt: Date
    let appVersion: String
    let build: String
    let deviceModel: String
    let systemVersion: String
    let payload: String

    init(kind: Kind, payload: String, id: UUID = UUID(), createdAt: Date = .now,
         appVersion: String? = nil, build: String? = nil,
         deviceModel: String = "Unavailable", systemVersion: String = "Unavailable") {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.appVersion = appVersion ?? Self.bundleValue("CFBundleShortVersionString")
        self.build = build ?? Self.bundleValue("CFBundleVersion")
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.payload = payload
    }

    var filename: String {
        "PackMeasure-\(kind.rawValue)-\(id.uuidString.lowercased())-diagnostic.txt"
    }

    var createdAtISO8601: String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: createdAt)
    }

    var payloadData: Data { Data(payload.utf8) }

    func attachmentText(note: String = "") -> String {
        let availability = payload.isEmpty
            ? (kind == .app ? "No active scan diagnostics were provided." : "No capture diagnostics were provided.")
            : "Original diagnostics are included verbatim below."
        // The payload is the untouched suffix: no escaping, truncation, or extra
        // trailing newline can change JSON, Unicode, or the original line breaks.
        return """
        PackMeasure diagnostic report
        Report ID: \(id.uuidString)
        Created (UTC): \(createdAtISO8601)
        Context: \(kind.title)
        App version: \(appVersion)
        Build: \(build)
        Device: \(deviceModel)
        System version: \(systemVersion)
        Diagnostics: \(availability)

        User note:
        \(note.isEmpty ? "No note provided." : note)

        ----- BEGIN ORIGINAL DIAGNOSTICS -----

        """ + payload
    }

    func attachmentData(note: String = "") -> Data { Data(attachmentText(note: note).utf8) }

    var emailSubject: String {
        "PackMeasure \(kind.title) diagnostics | build \(build) | \(id.uuidString)"
    }

    func emailBody(note: String = "") -> String {
        let description = payload.isEmpty
            ? "The attached text file contains this PackMeasure diagnostic report. No \(kind == .app ? "active scan" : "capture") diagnostics were provided."
            : "The attached text file contains this PackMeasure diagnostic report and its original diagnostics."
        return """
        \(description)

        Report ID: \(id.uuidString)
        Context: \(kind.title)
        App version: \(appVersion) (build \(build))
        Created (UTC): \(createdAtISO8601)
        Attachment: \(filename)

        User note:
        \(note.isEmpty ? "No note provided." : note)
        """
    }

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown"
    }
}
