import Foundation

struct DoorOpening: Codable, Hashable, Sendable {
    let widthInches: Double
    let heightInches: Double

    init(widthInches: Double, heightInches: Double) throws {
        guard widthInches.isFinite,
              heightInches.isFinite,
              widthInches > 0,
              heightInches > 0
        else {
            throw PackingDomainError.invalidDoorOpening
        }

        self.widthInches = widthInches
        self.heightInches = heightInches
    }
}

enum PackingLoadMix: String, CaseIterable, Codable, Hashable, Sendable {
    case boxes
    case mixedHousehold
    case bulkyFurniture

    var usableVolumeFraction: Double {
        switch self {
        case .boxes:
            0.825
        case .mixedHousehold:
            0.75
        case .bulkyFurniture:
            0.65
        }
    }

    var displayName: String {
        switch self {
        case .boxes:
            "Mostly boxes"
        case .mixedHousehold:
            "Mixed household"
        case .bulkyFurniture:
            "Bulky furniture"
        }
    }
}

struct PackingVehicleProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let interiorDimensions: ItemDimensions?
    let rearDoorOpening: DoorOpening?
    let advertisedCargoVolumeCubicFeet: Double
    let usableVolumeFraction: Double
    let notes: String

    init(
        id: String,
        name: String,
        interiorDimensions: ItemDimensions?,
        rearDoorOpening: DoorOpening?,
        advertisedCargoVolumeCubicFeet: Double,
        usableVolumeFraction: Double,
        notes: String = ""
    ) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              !trimmedName.isEmpty,
              advertisedCargoVolumeCubicFeet.isFinite,
              advertisedCargoVolumeCubicFeet > 0
        else {
            throw PackingDomainError.invalidVehicleProfile
        }
        guard usableVolumeFraction.isFinite,
              usableVolumeFraction > 0,
              usableVolumeFraction <= 1
        else {
            throw PackingDomainError.invalidUsableVolumeFraction
        }

        self.id = trimmedID
        self.name = trimmedName
        self.interiorDimensions = interiorDimensions
        self.rearDoorOpening = rearDoorOpening
        self.advertisedCargoVolumeCubicFeet = advertisedCargoVolumeCubicFeet
        self.usableVolumeFraction = usableVolumeFraction
        self.notes = notes
    }

    var usableCargoVolumeCubicFeet: Double {
        advertisedCargoVolumeCubicFeet * usableVolumeFraction
    }

    var cargoFloorAreaSquareFeet: Double? {
        interiorDimensions?.footprintSquareFeet
    }
}

enum PackingVehicleCatalog {
    /// Conservative planning profiles. Rental dimensions vary by location and
    /// exact vehicle, so the app must still tell the user to verify before booking.
    static func conservativeMovingFleet(
        loadMix: PackingLoadMix = .mixedHousehold
    ) -> [PackingVehicleProfile] {
        let utilization = loadMix.usableVolumeFraction
        let approximate = "Cargo and door dimensions are approximate and model-variable; verify the assigned vehicle before booking."

        return [
            makeProfile(
                id: "pacifica-minivan",
                name: "Chrysler Pacifica minivan",
                interior: nil,
                door: nil,
                grossVolume: 140.5,
                utilization: utilization,
                notes: "Maximum reported cargo length is about 99.5 in, but complete interior and door dimensions are unavailable; this profile cannot be auto-selected."
            ),
            makeProfile(
                id: "cargo-van",
                name: "U-Haul cargo van",
                interior: (114, 70, 52),
                door: (57, 49),
                grossVolume: 239,
                utilization: utilization,
                notes: approximate
            ),
            makeProfile(
                id: "sprinter-144",
                name: "Sprinter 144 high-roof van",
                interior: (133, 53, 68),
                door: (61, 61),
                grossVolume: 319,
                utilization: utilization,
                notes: "Uses the conservative 53 in wheel-well width rather than the wider 70 in upper cargo bay. \(approximate)"
            ),
            makeProfile(
                id: "uhaul-10-foot",
                name: "U-Haul 10 ft truck",
                interior: (119, 75, 73),
                door: (71, 67),
                grossVolume: 402,
                utilization: utilization,
                notes: approximate
            ),
            makeProfile(
                id: "promaster-high-roof",
                name: "Ram ProMaster high-roof van",
                interior: (120, 75, 77),
                door: nil,
                grossVolume: 463,
                utilization: utilization,
                notes: "Rear-door dimensions are not verified, so this profile cannot be auto-selected. \(approximate)"
            ),
            makeProfile(
                id: "uhaul-15-foot",
                name: "U-Haul 15 ft truck",
                interior: (180, 92, 86),
                door: (87, 77),
                grossVolume: 764,
                utilization: utilization,
                notes: approximate
            ),
            makeProfile(
                id: "uhaul-20-foot",
                name: "U-Haul 20 ft truck",
                interior: (233, 92, 85),
                door: (87, 77),
                grossVolume: 1_016,
                utilization: utilization,
                notes: approximate
            ),
            makeProfile(
                id: "uhaul-26-foot",
                name: "U-Haul 26 ft truck",
                interior: (314, 97, 99),
                door: (93, 82),
                grossVolume: 1_682,
                utilization: utilization,
                notes: approximate
            )
        ]
    }

    private static func makeProfile(
        id: String,
        name: String,
        interior: (Double, Double, Double)?,
        door: (Double, Double)?,
        grossVolume: Double,
        utilization: Double,
        notes: String
    ) -> PackingVehicleProfile {
        do {
            let interiorDimensions: ItemDimensions?
            if let interior {
                interiorDimensions = try ItemDimensions(
                    lengthInches: interior.0,
                    widthInches: interior.1,
                    heightInches: interior.2
                )
            } else {
                interiorDimensions = nil
            }

            let rearDoorOpening: DoorOpening?
            if let door {
                rearDoorOpening = try DoorOpening(
                    widthInches: door.0,
                    heightInches: door.1
                )
            } else {
                rearDoorOpening = nil
            }

            return try PackingVehicleProfile(
                id: id,
                name: name,
                interiorDimensions: interiorDimensions,
                rearDoorOpening: rearDoorOpening,
                advertisedCargoVolumeCubicFeet: grossVolume,
                usableVolumeFraction: utilization,
                notes: notes
            )
        } catch {
            preconditionFailure("Invalid built-in packing vehicle profile: \(error)")
        }
    }
}

enum PackingDimensionProvenance: String, Codable, Hashable, Sendable {
    case catalog
    case measured
    case unmeasured

    var title: String {
        switch self {
        case .catalog:
            "Catalog profile"
        case .measured:
            "Entered measurements"
        case .unmeasured:
            "Not measured"
        }
    }
}

struct AssignedVehicleSpec: Codable, Equatable, Sendable {
    var name: String
    var interiorDimensions: ItemDimensions?
    var rearDoorOpening: DoorOpening?
    var interiorProvenance: PackingDimensionProvenance
    var doorProvenance: PackingDimensionProvenance

    init(
        name: String,
        interiorDimensions: ItemDimensions?,
        rearDoorOpening: DoorOpening?,
        interiorProvenance: PackingDimensionProvenance = .measured,
        doorProvenance: PackingDimensionProvenance? = nil
    ) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed.isEmpty ? "Assigned vehicle" : trimmed
        self.interiorDimensions = interiorDimensions
        self.rearDoorOpening = rearDoorOpening
        self.interiorProvenance = interiorDimensions == nil ? .unmeasured : interiorProvenance
        self.doorProvenance = rearDoorOpening == nil ? .unmeasured : (doorProvenance ?? .measured)
    }

    static func fromCatalog(_ profile: PackingVehicleProfile) -> AssignedVehicleSpec {
        AssignedVehicleSpec(
            name: profile.name,
            interiorDimensions: profile.interiorDimensions,
            rearDoorOpening: profile.rearDoorOpening,
            interiorProvenance: profile.interiorDimensions == nil ? .unmeasured : .catalog,
            doorProvenance: profile.rearDoorOpening == nil ? .unmeasured : .catalog
        )
    }

    func profile(loadMix: PackingLoadMix) -> PackingVehicleProfile {
        let grossVolume = max(0.1, interiorDimensions?.cubicFeet ?? 1)
        do {
            return try PackingVehicleProfile(
                id: "assigned-vehicle",
                name: name,
                interiorDimensions: interiorDimensions,
                rearDoorOpening: rearDoorOpening,
                advertisedCargoVolumeCubicFeet: grossVolume,
                usableVolumeFraction: loadMix.usableVolumeFraction,
                notes: "Passes listed dimensional checks only. Payload capacity, 3D arrangement, and maneuvering path remain unverified."
            )
        } catch {
            preconditionFailure("AssignedVehicleSpec produced invalid profile: \(error)")
        }
    }
}
