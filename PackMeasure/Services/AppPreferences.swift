import SwiftUI

enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "Follow iPhone"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Display preferences never change a measurement's stored metric geometry.
enum MeasurementUnits: String, CaseIterable, Sendable {
    case inches, centimeters, both

    var title: String {
        switch self {
        case .inches: "Inches"
        case .centimeters: "Centimeters"
        case .both: "Both"
        }
    }

    var inputUnit: MeasurementInputUnit { self == .centimeters ? .centimeters : .inches }

    func length(meters: Double) -> String {
        combine(imperial: MeasurementMath.inchString(from: meters), metric: String(format: "%.1f cm", meters * 100))
    }

    func preciseLength(millimeters: Double) -> String {
        combine(imperial: String(format: "%.2f in", millimeters / 25.4), metric: String(format: "%.2f cm", millimeters / 10))
    }

    func area(squareMeters: Double) -> String {
        combine(imperial: String(format: "%.1f sq ft", MeasurementMath.squareFeet(squareMeters)), metric: String(format: "%.2f m²", squareMeters))
    }

    func volume(cubicMeters: Double, imperialDecimalPlaces: Int = 0, metricDecimalPlaces: Int = 2) -> String {
        combine(imperial: String(format: "%.*f cu ft", imperialDecimalPlaces, MeasurementMath.cubicFeet(cubicMeters)), metric: String(format: "%.*f m³", metricDecimalPlaces, cubicMeters))
    }

    func areaFromSquareFeet(_ value: Double) -> String { area(squareMeters: value / 10.7639) }
    func volumeFromCubicFeet(_ value: Double, imperialDecimalPlaces: Int = 0, metricDecimalPlaces: Int = 2) -> String {
        volume(cubicMeters: value / 35.3147, imperialDecimalPlaces: imperialDecimalPlaces, metricDecimalPlaces: metricDecimalPlaces)
    }

    private func combine(imperial: String, metric: String) -> String {
        switch self {
        case .inches: imperial
        case .centimeters: metric
        case .both: "\(imperial) · \(metric)"
        }
    }
}

enum MeasurementInputUnit: String, CaseIterable, Sendable {
    case inches, centimeters

    var title: String { self == .inches ? "Inches" : "Centimeters" }
    var symbol: String { self == .inches ? "in" : "cm" }
    func value(fromMeters meters: Double) -> Double { self == .inches ? meters / 0.0254 : meters * 100 }
    func meters(from value: Double) -> Double { self == .inches ? value * 0.0254 : value / 100 }
    func converted(value: Double, to unit: Self) -> Double { unit.value(fromMeters: meters(from: value)) }
}

@MainActor @Observable
final class AppPreferences {
    enum Keys {
        static let appearance = "appearance"
        static let units = "measurementUnits"
        static let roomGuidance = "defaultRoomGuidance"
        static let floorplanLabels = "defaultFloorplanLabels"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var appearance: AppAppearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    var units: MeasurementUnits { didSet { defaults.set(units.rawValue, forKey: Keys.units) } }
    var roomGuidance: RoomCaptureGuidance { didSet { defaults.set(roomGuidance.rawValue, forKey: Keys.roomGuidance) } }
    var floorplanLabels: FloorplanLabelMode { didSet { defaults.set(floorplanLabels.rawValue, forKey: Keys.floorplanLabels) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .system
        // Honor an existing interior metric preference when installing the shared settings.
        let migratedUnits: MeasurementUnits = defaults.string(forKey: InteriorUnit.storageKey) == "millimeters" ? .centimeters : .inches
        units = defaults.string(forKey: Keys.units).flatMap(MeasurementUnits.init(rawValue:)) ?? migratedUnits
        roomGuidance = defaults.string(forKey: Keys.roomGuidance).flatMap(RoomCaptureGuidance.init(rawValue:)) ?? .room
        floorplanLabels = defaults.string(forKey: Keys.floorplanLabels).flatMap(FloorplanLabelMode.init(rawValue:)) ?? .lengths
    }
}
