import Foundation

enum PackingDomainError: Error, Equatable, Sendable {
    case nonPositiveDimension
    case invalidQuantity
    case invalidStackLimit
    case invalidPackingAllowance
    case invalidClearanceMargin
    case invalidDoorOpening
    case invalidVehicleProfile
    case invalidUsableVolumeFraction
}

extension PackingDomainError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .nonPositiveDimension:
            "Every object dimension must be greater than zero."
        case .invalidQuantity:
            "Quantity must be at least one."
        case .invalidStackLimit:
            "A stackable item must allow at least one layer."
        case .invalidPackingAllowance:
            "Packing allowance must be between 0% and 100%."
        case .invalidClearanceMargin:
            "Clearance margin cannot be negative."
        case .invalidDoorOpening:
            "Door-opening measurements must be greater than zero."
        case .invalidVehicleProfile:
            "Vehicle profiles need an ID, a name, and positive cargo volume."
        case .invalidUsableVolumeFraction:
            "Usable vehicle volume must be greater than 0% and no more than 100%."
        }
    }
}

struct ItemDimensions: Codable, Hashable, Sendable {
    let lengthInches: Double
    let widthInches: Double
    let heightInches: Double

    init(lengthInches: Double, widthInches: Double, heightInches: Double) throws {
        guard lengthInches.isFinite,
              widthInches.isFinite,
              heightInches.isFinite,
              lengthInches > 0,
              widthInches > 0,
              heightInches > 0
        else {
            throw PackingDomainError.nonPositiveDimension
        }

        self.lengthInches = lengthInches
        self.widthInches = widthInches
        self.heightInches = heightInches
    }

    var footprintSquareFeet: Double {
        lengthInches * widthInches / 144
    }

    var cubicFeet: Double {
        lengthInches * widthInches * heightInches / 1_728
    }

    var allOrientations: [PackingOrientation] {
        let values = [lengthInches, widthInches, heightInches]
        let permutations = [
            (values[0], values[1], values[2]),
            (values[0], values[2], values[1]),
            (values[1], values[0], values[2]),
            (values[1], values[2], values[0]),
            (values[2], values[0], values[1]),
            (values[2], values[1], values[0])
        ]

        return permutations.map {
            PackingOrientation(length: $0.0, width: $0.1, height: $0.2)
        }
    }

    var uprightOrientations: [PackingOrientation] {
        [
            PackingOrientation(
                length: lengthInches,
                width: widthInches,
                height: heightInches
            ),
            PackingOrientation(
                length: widthInches,
                width: lengthInches,
                height: heightInches
            )
        ]
    }
}

enum ItemStackability: Codable, Hashable, Sendable {
    case notStackable
    case stackable(maxLayers: Int)

    var declaredLayers: Int {
        switch self {
        case .notStackable:
            1
        case let .stackable(maxLayers):
            maxLayers
        }
    }
}

enum ItemOrientationPolicy: String, Codable, Hashable, Sendable {
    /// The conservative default for furniture and unknown objects.
    case keepUpright

    /// Use only when the object is safe to tip or turn onto another side.
    case mayRotate
}

struct PackingItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var dimensions: ItemDimensions
    var quantity: Int
    var stackability: ItemStackability
    var orientationPolicy: ItemOrientationPolicy

    init(
        id: UUID = UUID(),
        name: String,
        dimensions: ItemDimensions,
        quantity: Int = 1,
        stackability: ItemStackability = .notStackable,
        orientationPolicy: ItemOrientationPolicy = .keepUpright
    ) throws {
        guard quantity > 0 else {
            throw PackingDomainError.invalidQuantity
        }
        if case let .stackable(maxLayers) = stackability, maxLayers < 1 {
            throw PackingDomainError.invalidStackLimit
        }

        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dimensions = dimensions
        self.quantity = quantity
        self.stackability = stackability
        self.orientationPolicy = orientationPolicy
    }

    var totalRawFootprintSquareFeet: Double {
        dimensions.footprintSquareFeet * Double(quantity)
    }

    var totalRawCubicFeet: Double {
        dimensions.cubicFeet * Double(quantity)
    }

    var allowedOrientations: [PackingOrientation] {
        switch orientationPolicy {
        case .keepUpright:
            dimensions.uprightOrientations
        case .mayRotate:
            dimensions.allOrientations
        }
    }
}

struct PackingPolicy: Equatable, Hashable, Sendable {
    static let conservative = PackingPolicy(
        uncheckedAllowanceFraction: 0.10,
        clearanceMarginInches: 2
    )

    let packingAllowanceFraction: Double
    let clearanceMarginInches: Double

    init(
        packingAllowanceFraction: Double,
        clearanceMarginInches: Double = 2
    ) throws {
        guard packingAllowanceFraction.isFinite,
              (0 ... 1).contains(packingAllowanceFraction)
        else {
            throw PackingDomainError.invalidPackingAllowance
        }
        guard clearanceMarginInches.isFinite,
              clearanceMarginInches >= 0
        else {
            throw PackingDomainError.invalidClearanceMargin
        }
        self.packingAllowanceFraction = packingAllowanceFraction
        self.clearanceMarginInches = clearanceMarginInches
    }

    private init(
        uncheckedAllowanceFraction: Double,
        clearanceMarginInches: Double
    ) {
        packingAllowanceFraction = uncheckedAllowanceFraction
        self.clearanceMarginInches = clearanceMarginInches
    }
}

struct PackingSummary: Equatable, Sendable {
    let pieceCount: Int
    let rawFootprintSquareFeet: Double
    let stackAdjustedFootprintSquareFeet: Double
    let requiredFloorSquareFeet: Double
    let rawCubicFeet: Double
    let requiredCubicFeet: Double
    let packingAllowanceFraction: Double

    static func empty(allowanceFraction: Double) -> PackingSummary {
        PackingSummary(
            pieceCount: 0,
            rawFootprintSquareFeet: 0,
            stackAdjustedFootprintSquareFeet: 0,
            requiredFloorSquareFeet: 0,
            rawCubicFeet: 0,
            requiredCubicFeet: 0,
            packingAllowanceFraction: allowanceFraction
        )
    }
}

struct PackingOrientation: Equatable, Hashable, Sendable {
    let length: Double
    let width: Double
    let height: Double

    var footprintSquareFeet: Double {
        length * width / 144
    }
}
