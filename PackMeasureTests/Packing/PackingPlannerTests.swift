import XCTest
@testable import PackMeasure

final class PackingPlannerTests: XCTestCase {
    func testItemDimensionsConvertToFloorAndVolumeUnits() throws {
        let dimensions = try ItemDimensions(
            lengthInches: 48,
            widthInches: 24,
            heightInches: 30
        )

        XCTAssertEqual(dimensions.footprintSquareFeet, 8, accuracy: 0.000_001)
        XCTAssertEqual(dimensions.cubicFeet, 20, accuracy: 0.000_001)
    }

    func testItemDimensionsRejectNonPositiveMeasurements() {
        XCTAssertThrowsError(
            try ItemDimensions(lengthInches: 0, widthInches: 24, heightInches: 30)
        ) { error in
            XCTAssertEqual(error as? PackingDomainError, .nonPositiveDimension)
        }
    }

    func testPackingItemAppliesQuantityToRawSpace() throws {
        let item = try PackingItem(
            name: "Medium box",
            dimensions: try ItemDimensions(
                lengthInches: 24,
                widthInches: 18,
                heightInches: 18
            ),
            quantity: 3
        )

        XCTAssertEqual(item.totalRawFootprintSquareFeet, 9, accuracy: 0.000_001)
        XCTAssertEqual(item.totalRawCubicFeet, 13.5, accuracy: 0.000_001)
    }

    func testPackingItemRejectsInvalidQuantityAndStackLimit() throws {
        let dimensions = try ItemDimensions(
            lengthInches: 24,
            widthInches: 18,
            heightInches: 18
        )

        XCTAssertThrowsError(
            try PackingItem(name: "Box", dimensions: dimensions, quantity: 0)
        ) { error in
            XCTAssertEqual(error as? PackingDomainError, .invalidQuantity)
        }
        XCTAssertThrowsError(
            try PackingItem(
                name: "Box",
                dimensions: dimensions,
                stackability: .stackable(maxLayers: 0)
            )
        ) { error in
            XCTAssertEqual(error as? PackingDomainError, .invalidStackLimit)
        }
    }

    func testSummaryIncludesAllowanceAndStackAdjustedFloorArea() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0.10)
        )
        let box = try PackingItem(
            name: "Cube box",
            dimensions: try ItemDimensions(
                lengthInches: 24,
                widthInches: 24,
                heightInches: 12
            ),
            quantity: 5,
            stackability: .stackable(maxLayers: 3)
        )

        let summary = planner.summary(for: [box])

        XCTAssertEqual(summary.pieceCount, 5)
        XCTAssertEqual(summary.rawFootprintSquareFeet, 20, accuracy: 0.000_001)
        XCTAssertEqual(summary.stackAdjustedFootprintSquareFeet, 8, accuracy: 0.000_001)
        XCTAssertEqual(summary.requiredFloorSquareFeet, 8.8, accuracy: 0.000_001)
        XCTAssertEqual(summary.rawCubicFeet, 20, accuracy: 0.000_001)
        XCTAssertEqual(summary.requiredCubicFeet, 22, accuracy: 0.000_001)
    }

    func testNonStackableQuantityUsesOneFloorPositionPerPiece() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0.10)
        )
        let item = try PackingItem(
            name: "Fragile cube",
            dimensions: try ItemDimensions(
                lengthInches: 24,
                widthInches: 24,
                heightInches: 12
            ),
            quantity: 5
        )

        XCTAssertEqual(
            planner.summary(for: [item]).requiredFloorSquareFeet,
            22,
            accuracy: 0.000_001
        )
    }

    func testDefaultPolicyRequiresTwoInchesOfInteriorClearance() throws {
        let planner = PackingPlanner()
        let item = try PackingItem(
            name: "Nearly exact-length item",
            dimensions: try ItemDimensions(
                lengthInches: 99,
                widthInches: 40,
                heightInches: 40
            )
        )
        let vehicle = try makeVehicle(
            id: "tight-interior",
            name: "Tight interior",
            interior: (100, 60, 60),
            door: (60, 60),
            grossVolume: 500
        )

        let result = planner.recommendVehicle(for: [item], from: [vehicle])

        XCTAssertEqual(planner.policy.clearanceMarginInches, 2)
        XCTAssertNil(result.vehicle)
        XCTAssertEqual(
            result.rejections.first?.constraint,
            .interiorClearance(itemName: "Nearly exact-length item")
        )
    }

    func testDefaultPolicyRequiresDoorClearanceBeyondMeasuredObject() throws {
        let planner = PackingPlanner()
        let item = try PackingItem(
            name: "Door-tight cabinet",
            dimensions: try ItemDimensions(
                lengthInches: 40,
                widthInches: 49,
                heightInches: 49
            )
        )
        let vehicle = try makeVehicle(
            id: "tight-door",
            name: "Tight door",
            interior: (100, 100, 100),
            door: (50, 50),
            grossVolume: 500
        )

        let result = planner.recommendVehicle(for: [item], from: [vehicle])

        XCTAssertNil(result.vehicle)
        XCTAssertEqual(
            result.rejections.first?.constraint,
            .doorClearance(itemName: "Door-tight cabinet")
        )
    }

    func testClearanceMarginCanBeExplicitlyDisabled() throws {
        let policy = try PackingPolicy(
            packingAllowanceFraction: 0,
            clearanceMarginInches: 0
        )
        let planner = PackingPlanner(policy: policy)
        let item = try PackingItem(
            name: "Known exact-fit crate",
            dimensions: try ItemDimensions(
                lengthInches: 100,
                widthInches: 50,
                heightInches: 50
            )
        )
        let vehicle = try makeVehicle(
            id: "exact",
            name: "Exact-fit bay",
            interior: (100, 50, 50),
            door: (50, 50),
            grossVolume: 500
        )

        XCTAssertEqual(
            planner.recommendVehicle(for: [item], from: [vehicle]).vehicle?.id,
            "exact"
        )
    }

    func testVehicleHeightLimitsDeclaredStackingLayers() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0)
        )
        let boxes = try PackingItem(
            name: "Tall boxes",
            dimensions: try ItemDimensions(
                lengthInches: 24,
                widthInches: 24,
                heightInches: 24
            ),
            quantity: 6,
            stackability: .stackable(maxLayers: 3)
        )
        let lowRoof = try makeVehicle(
            id: "low",
            name: "Low roof",
            interior: (120, 72, 40),
            door: (70, 36),
            grossVolume: 500
        )
        let highRoof = try makeVehicle(
            id: "high",
            name: "High roof",
            interior: (120, 72, 72),
            door: (70, 70),
            grossVolume: 500
        )

        XCTAssertEqual(
            planner.summary(for: [boxes], in: lowRoof).requiredFloorSquareFeet,
            24,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            planner.summary(for: [boxes], in: highRoof).requiredFloorSquareFeet,
            12,
            accuracy: 0.000_001
        )
    }

    func testRecommendationChoosesSmallestSuitableProfileRegardlessOfInputOrder() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0.10)
        )
        let boxes = try PackingItem(
            name: "Moving boxes",
            dimensions: try ItemDimensions(
                lengthInches: 24,
                widthInches: 24,
                heightInches: 24
            ),
            quantity: 4,
            stackability: .stackable(maxLayers: 2)
        )
        let tooSmall = try makeVehicle(
            id: "small",
            name: "Small van",
            interior: (100, 60, 60),
            door: (55, 55),
            grossVolume: 40,
            utilization: 0.75
        )
        let suitable = try makeVehicle(
            id: "cargo",
            name: "Cargo van",
            interior: (114, 70, 52),
            door: (57, 49),
            grossVolume: 100,
            utilization: 0.75
        )
        let large = try makeVehicle(
            id: "truck",
            name: "Box truck",
            interior: (180, 92, 86),
            door: (87, 77),
            grossVolume: 500,
            utilization: 0.75
        )

        let result = planner.recommendVehicle(
            for: [boxes],
            from: [large, suitable, tooSmall]
        )

        XCTAssertEqual(result.vehicle?.id, "cargo")
        XCTAssertTrue(result.reason.contains("Cargo van"))
        XCTAssertTrue(result.reason.contains("8.8 ft²"))
        XCTAssertTrue(result.reason.contains("35.2 ft³"))
        XCTAssertTrue(result.reason.contains("10% packing allowance"))
        XCTAssertTrue(result.rejections.contains { rejection in
            guard rejection.vehicle.id == "small" else { return false }
            if case .insufficientVolume = rejection.constraint { return true }
            return false
        })
    }

    func testInteriorClearanceRejectsItemEvenWhenTotalVolumeFits() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0)
        )
        let longItem = try PackingItem(
            name: "Long sofa",
            dimensions: try ItemDimensions(
                lengthInches: 130,
                widthInches: 10,
                heightInches: 10
            )
        )
        let shortVan = try makeVehicle(
            id: "short",
            name: "Short van",
            interior: (120, 80, 80),
            door: (80, 80),
            grossVolume: 500
        )
        let longVan = try makeVehicle(
            id: "long",
            name: "Long van",
            interior: (140, 80, 80),
            door: (80, 80),
            grossVolume: 600
        )

        let result = planner.recommendVehicle(
            for: [longItem],
            from: [shortVan, longVan]
        )

        XCTAssertEqual(result.vehicle?.id, "long")
        XCTAssertTrue(result.rejections.contains { rejection in
            guard rejection.vehicle.id == "short" else { return false }
            if case .interiorClearance(itemName: "Long sofa") = rejection.constraint {
                return true
            }
            return false
        })
    }

    func testDoorOpeningRejectsItemThatFitsInsideCargoBay() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0)
        )
        let cube = try PackingItem(
            name: "Large cube",
            dimensions: try ItemDimensions(
                lengthInches: 50,
                widthInches: 50,
                heightInches: 50
            )
        )
        let narrowDoor = try makeVehicle(
            id: "narrow-door",
            name: "Narrow-door truck",
            interior: (100, 100, 100),
            door: (45, 45),
            grossVolume: 500
        )
        let wideDoor = try makeVehicle(
            id: "wide-door",
            name: "Wide-door truck",
            interior: (100, 100, 100),
            door: (60, 60),
            grossVolume: 600
        )

        let result = planner.recommendVehicle(
            for: [cube],
            from: [narrowDoor, wideDoor]
        )

        XCTAssertEqual(result.vehicle?.id, "wide-door")
        XCTAssertTrue(result.rejections.contains { rejection in
            guard rejection.vehicle.id == "narrow-door" else { return false }
            if case .doorClearance(itemName: "Large cube") = rejection.constraint {
                return true
            }
            return false
        })
    }

    func testMayRotateItemCanUseAValidSideOrientation() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0)
        )
        let item = try PackingItem(
            name: "Rotatable cabinet",
            dimensions: try ItemDimensions(
                lengthInches: 80,
                widthInches: 30,
                heightInches: 20
            ),
            orientationPolicy: .mayRotate
        )
        let vehicle = try makeVehicle(
            id: "upright-bay",
            name: "Tall cargo bay",
            interior: (60, 35, 85),
            door: (40, 85),
            grossVolume: 500
        )

        XCTAssertEqual(
            planner.recommendVehicle(for: [item], from: [vehicle]).vehicle?.id,
            "upright-bay"
        )
    }

    func testMissingDoorDataCannotProduceFalsePositiveRecommendation() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0)
        )
        let item = try PackingItem(
            name: "Chair",
            dimensions: try ItemDimensions(
                lengthInches: 30,
                widthInches: 30,
                heightInches: 36
            )
        )
        let incomplete = try PackingVehicleProfile(
            id: "unknown-door",
            name: "Unknown door van",
            interiorDimensions: try ItemDimensions(
                lengthInches: 120,
                widthInches: 72,
                heightInches: 72
            ),
            rearDoorOpening: nil,
            advertisedCargoVolumeCubicFeet: 300,
            usableVolumeFraction: 0.75
        )
        let complete = try makeVehicle(
            id: "complete",
            name: "Verified van",
            interior: (120, 72, 72),
            door: (60, 60),
            grossVolume: 400
        )

        let result = planner.recommendVehicle(
            for: [item],
            from: [complete, incomplete]
        )

        XCTAssertEqual(result.vehicle?.id, "complete")
        XCTAssertTrue(result.rejections.contains { rejection in
            rejection.vehicle.id == "unknown-door"
                && rejection.constraint == .missingDoorOpening
        })
    }

    func testNoSuitableVehicleExplainsBlockingItem() throws {
        let planner = PackingPlanner(
            policy: try PackingPolicy(packingAllowanceFraction: 0)
        )
        let item = try PackingItem(
            name: "Oversized sculpture",
            dimensions: try ItemDimensions(
                lengthInches: 200,
                widthInches: 100,
                heightInches: 100
            )
        )
        let vehicle = try makeVehicle(
            id: "truck",
            name: "Largest truck",
            interior: (180, 92, 86),
            door: (87, 77),
            grossVolume: 2_000
        )

        let result = planner.recommendVehicle(for: [item], from: [vehicle])

        XCTAssertNil(result.vehicle)
        XCTAssertTrue(result.reason.contains("Oversized sculpture"))
        XCTAssertTrue(result.reason.contains("Largest truck"))
    }

    func testEmptyInventoryDoesNotRecommendAVehicle() {
        let result = PackingPlanner().recommendVehicle(
            for: [],
            from: PackingVehicleCatalog.conservativeMovingFleet()
        )

        XCTAssertNil(result.vehicle)
        XCTAssertEqual(result.summary.pieceCount, 0)
        XCTAssertTrue(result.reason.contains("Add at least one item"))
    }

    func testLoadMixEfficienciesAreExplicit() {
        XCTAssertEqual(PackingLoadMix.boxes.usableVolumeFraction, 0.825)
        XCTAssertEqual(PackingLoadMix.mixedHousehold.usableVolumeFraction, 0.75)
        XCTAssertEqual(PackingLoadMix.bulkyFurniture.usableVolumeFraction, 0.65)
    }

    func testConservativeCatalogExposesPlanningAssumptions() {
        let fleet = PackingVehicleCatalog.conservativeMovingFleet(
            loadMix: .mixedHousehold
        )
        let cargoVan = fleet.first { $0.id == "cargo-van" }
        let tenFootTruck = fleet.first { $0.id == "uhaul-10-foot" }
        let pacifica = fleet.first { $0.id == "pacifica-minivan" }

        XCTAssertEqual(cargoVan?.advertisedCargoVolumeCubicFeet, 239)
        XCTAssertEqual(cargoVan?.usableVolumeFraction, 0.75)
        XCTAssertEqual(cargoVan?.interiorDimensions?.lengthInches, 114)
        XCTAssertEqual(cargoVan?.rearDoorOpening?.widthInches, 57)
        XCTAssertEqual(tenFootTruck?.advertisedCargoVolumeCubicFeet, 402)
        XCTAssertNil(pacifica?.interiorDimensions)
        XCTAssertTrue(cargoVan?.notes.contains("approximate") == true)
    }

    private func makeVehicle(
        id: String,
        name: String,
        interior: (length: Double, width: Double, height: Double),
        door: (width: Double, height: Double),
        grossVolume: Double,
        utilization: Double = 1
    ) throws -> PackingVehicleProfile {
        try PackingVehicleProfile(
            id: id,
            name: name,
            interiorDimensions: try ItemDimensions(
                lengthInches: interior.length,
                widthInches: interior.width,
                heightInches: interior.height
            ),
            rearDoorOpening: try DoorOpening(
                widthInches: door.width,
                heightInches: door.height
            ),
            advertisedCargoVolumeCubicFeet: grossVolume,
            usableVolumeFraction: utilization
        )
    }
}
