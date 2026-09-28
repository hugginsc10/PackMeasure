import Foundation

/// How interior lengths are shown and entered. Measurements stay in millimeters
/// underneath, and the insert SVG is always exported at 1:1 millimeter scale for CAD.
enum InteriorUnit: String, CaseIterable, Sendable {
    case inches, millimeters

    /// Shared by every interior screen so a choice made in one applies to all.
    static let storageKey = "interiorUnit"

    var title: String { self == .inches ? "Inches" : "Millimeters" }
    var symbol: String { self == .inches ? "in" : "mm" }
    /// Decimal places shown: hundredths of an inch, tenths of a millimeter.
    var fractionDigits: Int { self == .inches ? 2 : 1 }

    func value(fromMillimeters millimeters: Double) -> Double { self == .inches ? millimeters / 25.4 : millimeters }
    func millimeters(from value: Double) -> Double { self == .inches ? value * 25.4 : value }

    func format(millimeters: Double) -> String {
        "\(value(fromMillimeters: millimeters).formatted(.number.precision(.fractionLength(fractionDigits)))) \(symbol)"
    }
}
