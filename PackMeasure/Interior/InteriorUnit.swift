import Foundation

/// How interior lengths are shown and entered. Measurements stay in millimeters
/// underneath, and the insert SVG is always exported at 1:1 millimeter scale for CAD.
enum InteriorUnit: String, CaseIterable, Sendable {
    case inches, centimeters, millimeters

    /// Legacy preference key, retained for migration to the app-wide settings.
    static let storageKey = "interiorUnit"

    var title: String {
        switch self {
        case .inches: "Inches"
        case .centimeters: "Centimeters"
        case .millimeters: "Millimeters"
        }
    }
    var symbol: String {
        switch self {
        case .inches: "in"
        case .centimeters: "cm"
        case .millimeters: "mm"
        }
    }
    /// Hundredths of inches or centimeters; legacy millimeters retain tenths.
    var fractionDigits: Int { self == .millimeters ? 1 : 2 }

    func value(fromMillimeters millimeters: Double) -> Double { millimeters / millimetersPerUnit }
    func millimeters(from value: Double) -> Double { value * millimetersPerUnit }

    private var millimetersPerUnit: Double {
        switch self {
        case .inches: 25.4
        case .centimeters: 10
        case .millimeters: 1
        }
    }

    func format(millimeters: Double) -> String {
        "\(value(fromMillimeters: millimeters).formatted(.number.precision(.fractionLength(fractionDigits)))) \(symbol)"
    }
}

/// The height field keeps its input unit until its text has been converted.
/// Display rounding never changes the millimeters passed to the capture geometry.
struct InteriorHeightDraft {
    var text = ""
    private(set) var inputUnit: MeasurementInputUnit = .inches

    var millimeters: Double? {
        let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "."))
        guard let parsed, parsed.isFinite else { return nil }
        let value = interiorUnit.millimeters(from: parsed)
        return value.isFinite ? value : nil
    }

    @discardableResult mutating func changeInputUnit(to next: MeasurementInputUnit) -> Bool {
        guard next != inputUnit else { return true }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let millimeters else { return false }
            let unit: InteriorUnit = next == .inches ? .inches : .centimeters
            text = String(unit.value(fromMillimeters: millimeters))
        }
        inputUnit = next
        return true
    }

    private var interiorUnit: InteriorUnit { inputUnit == .inches ? .inches : .centimeters }
}
