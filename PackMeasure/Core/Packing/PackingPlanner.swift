import Foundation

enum PackingVehicleConstraint: Equatable, Sendable {
    case missingInteriorDimensions
    case missingDoorOpening
    case interiorClearance(itemName: String)
    case doorClearance(itemName: String)
    case insufficientFloor(requiredSquareFeet: Double, availableSquareFeet: Double)
    case insufficientVolume(requiredCubicFeet: Double, availableCubicFeet: Double)
}

struct PackingVehicleRejection: Equatable, Sendable {
    let vehicle: PackingVehicleProfile
    let constraint: PackingVehicleConstraint
    let reason: String
}

struct PackingVehicleRecommendation: Equatable, Sendable {
    let vehicle: PackingVehicleProfile?
    let summary: PackingSummary
    let reason: String
    let rejections: [PackingVehicleRejection]
}

struct PackingPlanner: Sendable {
    let policy: PackingPolicy

    init(policy: PackingPolicy = .conservative) {
        self.policy = policy
    }

    func summary(for items: [PackingItem]) -> PackingSummary {
        makeSummary(for: items, interior: nil)
    }

    func summary(
        for items: [PackingItem],
        in vehicle: PackingVehicleProfile
    ) -> PackingSummary {
        makeSummary(for: items, interior: vehicle.interiorDimensions)
    }

    func recommendVehicle(
        for items: [PackingItem],
        from profiles: [PackingVehicleProfile] = PackingVehicleCatalog.conservativeMovingFleet()
    ) -> PackingVehicleRecommendation {
        let baseSummary = summary(for: items)
        guard !items.isEmpty else {
            return PackingVehicleRecommendation(
                vehicle: nil,
                summary: baseSummary,
                reason: "Add at least one item before choosing a vehicle.",
                rejections: []
            )
        }
        guard !profiles.isEmpty else {
            return PackingVehicleRecommendation(
                vehicle: nil,
                summary: baseSummary,
                reason: "No vehicle profiles were provided.",
                rejections: []
            )
        }

        let orderedProfiles = profiles.sorted { left, right in
            if left.advertisedCargoVolumeCubicFeet == right.advertisedCargoVolumeCubicFeet {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return left.advertisedCargoVolumeCubicFeet < right.advertisedCargoVolumeCubicFeet
        }
        var rejections: [PackingVehicleRejection] = []

        for vehicle in orderedProfiles {
            if let rejection = firstRejection(
                for: vehicle,
                carrying: items
            ) {
                rejections.append(rejection)
                continue
            }

            let vehicleSummary = summary(for: items, in: vehicle)
            return PackingVehicleRecommendation(
                vehicle: vehicle,
                summary: vehicleSummary,
                reason: recommendationReason(
                    vehicle: vehicle,
                    summary: vehicleSummary
                ),
                rejections: rejections
            )
        }

        let finalFailure = rejections.last?.reason
            ?? "Every listed profile failed at least one hard packing constraint."
        return PackingVehicleRecommendation(
            vehicle: nil,
            summary: baseSummary,
            reason: "No listed vehicle is suitable. \(finalFailure)",
            rejections: rejections
        )
    }

    private func makeSummary(
        for items: [PackingItem],
        interior: ItemDimensions?
    ) -> PackingSummary {
        guard !items.isEmpty else {
            return .empty(allowanceFraction: policy.packingAllowanceFraction)
        }

        let pieceCount = items.reduce(0) { $0 + $1.quantity }
        let rawFootprint = items.reduce(0.0) {
            $0 + $1.totalRawFootprintSquareFeet
        }
        let rawVolume = items.reduce(0.0) {
            $0 + $1.totalRawCubicFeet
        }
        let stackAdjustedFootprint = items.reduce(0.0) { partial, item in
            partial + floorRequirement(for: item, interior: interior)
        }
        let multiplier = 1 + policy.packingAllowanceFraction

        return PackingSummary(
            pieceCount: pieceCount,
            rawFootprintSquareFeet: rawFootprint,
            stackAdjustedFootprintSquareFeet: stackAdjustedFootprint,
            requiredFloorSquareFeet: stackAdjustedFootprint * multiplier,
            rawCubicFeet: rawVolume,
            requiredCubicFeet: rawVolume * multiplier,
            packingAllowanceFraction: policy.packingAllowanceFraction
        )
    }

    private func floorRequirement(
        for item: PackingItem,
        interior: ItemDimensions?
    ) -> Double {
        guard let interior else {
            return floorRequirement(
                quantity: item.quantity,
                orientation: PackingOrientation(
                    length: item.dimensions.lengthInches,
                    width: item.dimensions.widthInches,
                    height: item.dimensions.heightInches
                ),
                stackability: item.stackability,
                vehicleHeight: nil
            )
        }

        let fittingOrientations = item.allowedOrientations.filter {
            orientation($0, fitsInside: interior)
        }
        guard !fittingOrientations.isEmpty else {
            return floorRequirement(
                quantity: item.quantity,
                orientation: PackingOrientation(
                    length: item.dimensions.lengthInches,
                    width: item.dimensions.widthInches,
                    height: item.dimensions.heightInches
                ),
                stackability: item.stackability,
                vehicleHeight: nil
            )
        }

        return fittingOrientations.map { orientation in
            floorRequirement(
                quantity: item.quantity,
                orientation: orientation,
                stackability: item.stackability,
                vehicleHeight: interior.heightInches
            )
        }.min() ?? item.totalRawFootprintSquareFeet
    }

    private func floorRequirement(
        quantity: Int,
        orientation: PackingOrientation,
        stackability: ItemStackability,
        vehicleHeight: Double?
    ) -> Double {
        let declaredLayers = stackability.declaredLayers
        let actualLayers: Int
        if let vehicleHeight {
            let usableStackHeight = max(
                0,
                vehicleHeight - policy.clearanceMarginInches
            )
            let heightLimitedLayers = max(
                1,
                Int(floor(usableStackHeight / orientation.height))
            )
            actualLayers = min(declaredLayers, heightLimitedLayers)
        } else {
            actualLayers = declaredLayers
        }

        let floorPositions = Int(
            ceil(Double(quantity) / Double(actualLayers))
        )
        return orientation.footprintSquareFeet * Double(floorPositions)
    }

    private func firstRejection(
        for vehicle: PackingVehicleProfile,
        carrying items: [PackingItem]
    ) -> PackingVehicleRejection? {
        guard let interior = vehicle.interiorDimensions else {
            return rejection(
                vehicle: vehicle,
                constraint: .missingInteriorDimensions,
                reason: "\(vehicle.name) is missing complete interior dimensions, so clearance cannot be verified."
            )
        }
        guard let door = vehicle.rearDoorOpening else {
            return rejection(
                vehicle: vehicle,
                constraint: .missingDoorOpening,
                reason: "\(vehicle.name) is missing door-opening dimensions, so loading clearance cannot be verified."
            )
        }

        if let item = items.first(where: { !item($0, fitsInside: interior) }) {
            let itemName = displayName(for: item)
            return rejection(
                vehicle: vehicle,
                constraint: .interiorClearance(itemName: itemName),
                reason: "\(vehicle.name) cannot fit “\(itemName)” inside its measured cargo bay."
            )
        }

        if let item = items.first(where: { !item($0, fitsThrough: door) }) {
            let itemName = displayName(for: item)
            return rejection(
                vehicle: vehicle,
                constraint: .doorClearance(itemName: itemName),
                reason: "\(vehicle.name) cannot load “\(itemName)” through its measured rear door."
            )
        }

        let vehicleSummary = summary(for: items, in: vehicle)
        let availableFloor = interior.footprintSquareFeet
        if vehicleSummary.requiredFloorSquareFeet > availableFloor {
            return rejection(
                vehicle: vehicle,
                constraint: .insufficientFloor(
                    requiredSquareFeet: vehicleSummary.requiredFloorSquareFeet,
                    availableSquareFeet: availableFloor
                ),
                reason: "\(vehicle.name) has \(oneDecimal(availableFloor)) ft² of cargo floor, below the \(oneDecimal(vehicleSummary.requiredFloorSquareFeet)) ft² estimate."
            )
        }

        let availableVolume = vehicle.usableCargoVolumeCubicFeet
        if vehicleSummary.requiredCubicFeet > availableVolume {
            return rejection(
                vehicle: vehicle,
                constraint: .insufficientVolume(
                    requiredCubicFeet: vehicleSummary.requiredCubicFeet,
                    availableCubicFeet: availableVolume
                ),
                reason: "\(vehicle.name) has \(oneDecimal(availableVolume)) usable ft³, below the \(oneDecimal(vehicleSummary.requiredCubicFeet)) ft³ estimate."
            )
        }

        return nil
    }

    private func item(
        _ item: PackingItem,
        fitsInside interior: ItemDimensions
    ) -> Bool {
        item.allowedOrientations.contains {
            orientation($0, fitsInside: interior)
        }
    }

    private func item(
        _ item: PackingItem,
        fitsThrough door: DoorOpening
    ) -> Bool {
        switch item.orientationPolicy {
        case .keepUpright:
            return item.dimensions.heightInches + policy.clearanceMarginInches
                    <= door.heightInches
                && min(
                    item.dimensions.lengthInches,
                    item.dimensions.widthInches
                ) + policy.clearanceMarginInches <= door.widthInches
        case .mayRotate:
            return item.dimensions.allOrientations.contains { orientation in
                orientation.width + policy.clearanceMarginInches
                        <= door.widthInches
                    && orientation.height + policy.clearanceMarginInches
                        <= door.heightInches
            }
        }
    }

    private func orientation(
        _ orientation: PackingOrientation,
        fitsInside interior: ItemDimensions
    ) -> Bool {
        orientation.length + policy.clearanceMarginInches
                <= interior.lengthInches
            && orientation.width + policy.clearanceMarginInches
                <= interior.widthInches
            && orientation.height + policy.clearanceMarginInches
                <= interior.heightInches
    }

    private func rejection(
        vehicle: PackingVehicleProfile,
        constraint: PackingVehicleConstraint,
        reason: String
    ) -> PackingVehicleRejection {
        PackingVehicleRejection(
            vehicle: vehicle,
            constraint: constraint,
            reason: reason
        )
    }

    private func recommendationReason(
        vehicle: PackingVehicleProfile,
        summary: PackingSummary
    ) -> String {
        let availableFloor = vehicle.cargoFloorAreaSquareFeet ?? 0
        let allowancePercent = Int(
            (policy.packingAllowanceFraction * 100).rounded()
        )
        let utilizationPercent = Int(
            (vehicle.usableVolumeFraction * 100).rounded()
        )

        return "\(vehicle.name) is the smallest listed profile that clears every item and its rear door with a \(oneDecimal(policy.clearanceMarginInches)) in fit buffer: \(oneDecimal(summary.requiredFloorSquareFeet)) ft² of \(oneDecimal(availableFloor)) ft² floor, and \(oneDecimal(summary.requiredCubicFeet)) ft³ of \(oneDecimal(vehicle.usableCargoVolumeCubicFeet)) usable ft³. Includes a \(allowancePercent)% packing allowance and assumes \(utilizationPercent)% of advertised cargo volume is usable."
    }

    private func displayName(for item: PackingItem) -> String {
        item.name.isEmpty ? "Unnamed item" : item.name
    }

    private func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
