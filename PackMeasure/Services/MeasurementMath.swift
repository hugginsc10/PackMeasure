import Foundation

enum MeasurementMath {
    static func inches(from meters: Double) -> Double {
        meters * 39.370_078_740_157_48
    }

    static func feet(from meters: Double) -> Double {
        meters * 3.28084
    }

    static func squareFeet(_ squareMeters: Double) -> Double {
        squareMeters * 10.7639
    }

    static func cubicFeet(_ cubicMeters: Double) -> Double {
        cubicMeters * 35.3147
    }

    static func inchString(from meters: Double) -> String {
        let roundedTotalInches = max(0, Int(inches(from: meters).rounded()))
        let wholeFeet = roundedTotalInches / 12
        let remainingInches = roundedTotalInches % 12
        return "\(wholeFeet) ft \(remainingInches) in"
    }

    static func decimalFeetString(from meters: Double) -> String {
        String(format: "%.1f ft", feet(from: meters))
    }

    static func decimalSquareFeetString(_ value: Double) -> String {
        String(format: "%.1f sq ft", value)
    }

    static func decimalCubicFeetString(_ value: Double) -> String {
        String(format: "%.0f cu ft", value)
    }
}
