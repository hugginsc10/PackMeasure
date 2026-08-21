import Foundation

struct MeasuredItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var lengthMeters: Double
    var widthMeters: Double
    var heightMeters: Double
    var quantity: Int
    var confidence: ScanConfidence
    var comparisonAngleCount: Int?
    var comparisonAgreementCount: Int?
    var capturedAt: Date
    var stackability: ItemStackability
    var orientationPolicy: ItemOrientationPolicy

    init(
        id: UUID = UUID(),
        name: String,
        lengthMeters: Double,
        widthMeters: Double,
        heightMeters: Double,
        quantity: Int = 1,
        confidence: ScanConfidence,
        comparisonAngleCount: Int? = nil,
        comparisonAgreementCount: Int? = nil,
        capturedAt: Date = .now,
        stackability: ItemStackability = .notStackable,
        orientationPolicy: ItemOrientationPolicy = .keepUpright
    ) {
        self.id = id
        self.name = name
        self.lengthMeters = lengthMeters
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.quantity = max(1, quantity)
        self.confidence = confidence
        self.comparisonAngleCount = comparisonAngleCount
        self.comparisonAgreementCount = comparisonAgreementCount
        self.capturedAt = capturedAt
        self.stackability = stackability
        self.orientationPolicy = orientationPolicy
    }

    var footprintSquareFeet: Double {
        MeasurementMath.squareFeet(lengthMeters * widthMeters)
    }

    var volumeCubicFeet: Double {
        MeasurementMath.cubicFeet(lengthMeters * widthMeters * heightMeters)
    }

    var packingItem: PackingItem? {
        guard let dimensions = try? ItemDimensions(
            lengthInches: MeasurementMath.inches(from: lengthMeters),
            widthInches: MeasurementMath.inches(from: widthMeters),
            heightInches: MeasurementMath.inches(from: heightMeters)
        ) else {
            return nil
        }

        return try? PackingItem(
            id: id,
            name: name,
            dimensions: dimensions,
            quantity: quantity,
            stackability: stackability,
            orientationPolicy: orientationPolicy
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case lengthMeters
        case widthMeters
        case heightMeters
        case quantity
        case confidence
        case comparisonAngleCount
        case comparisonAgreementCount
        case capturedAt
        case stackability
        case orientationPolicy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Scanned Item"
        lengthMeters = try container.decode(Double.self, forKey: .lengthMeters)
        widthMeters = try container.decode(Double.self, forKey: .widthMeters)
        heightMeters = try container.decode(Double.self, forKey: .heightMeters)
        quantity = max(1, try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1)
        confidence = try container.decodeIfPresent(ScanConfidence.self, forKey: .confidence) ?? .low
        comparisonAngleCount = try container.decodeIfPresent(
            Int.self,
            forKey: .comparisonAngleCount
        )
        comparisonAgreementCount = try container.decodeIfPresent(
            Int.self,
            forKey: .comparisonAgreementCount
        )
        capturedAt = try container.decodeIfPresent(Date.self, forKey: .capturedAt) ?? .now
        stackability = try container.decodeIfPresent(ItemStackability.self, forKey: .stackability) ?? .notStackable
        orientationPolicy = try container.decodeIfPresent(
            ItemOrientationPolicy.self,
            forKey: .orientationPolicy
        ) ?? .keepUpright
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(lengthMeters, forKey: .lengthMeters)
        try container.encode(widthMeters, forKey: .widthMeters)
        try container.encode(heightMeters, forKey: .heightMeters)
        try container.encode(quantity, forKey: .quantity)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(comparisonAngleCount, forKey: .comparisonAngleCount)
        try container.encodeIfPresent(
            comparisonAgreementCount,
            forKey: .comparisonAgreementCount
        )
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(stackability, forKey: .stackability)
        try container.encode(orientationPolicy, forKey: .orientationPolicy)
    }
}

struct MeasurementEstimate: Equatable, Sendable {
    var lengthMeters: Double
    var widthMeters: Double
    var heightMeters: Double
    var confidence: ScanConfidence
    var sampleCount: Int
    var frameCount: Int
    var comparisonAngleCount: Int? = nil
    var comparisonAgreementCount: Int? = nil

    var sortedBaseEdges: [Double] {
        [lengthMeters, widthMeters].sorted(by: >)
    }
}

enum ScanConfidence: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    var title: String {
        rawValue.capitalized
    }

    var guidance: String {
        switch self {
        case .high:
            "Good scan quality"
        case .medium:
            "Usable, but a retake may tighten the estimate"
        case .low:
            "Low confidence. Retake before relying on this measurement"
        }
    }
}

enum ScannerPhase: Equatable {
    case checkingSupport
    case ready
    case scanning(progress: Double)
    case measured
    case unsupported(String)
    case failed(String)
}
