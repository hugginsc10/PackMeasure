import Foundation
import Observation

enum InventoryPersistenceError: Error, LocalizedError {
    case loadUnavailable, saveFailed

    var errorDescription: String? {
        switch self {
        case .loadUnavailable:
            "Could not read saved inventory. Your saved file has been kept. Try reading it again before changing items."
        case .saveFailed:
            "Could not save inventory. Your changes have not been saved. Please try again."
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var items: [MeasuredItem] = []
    var showingScanner = false
    var bannerMessage: String?
    private(set) var inventoryLoadFailed = false
    private(set) var loadMix: PackingLoadMix = .mixedHousehold

    @ObservationIgnored private let store: any InventoryStoring
    @ObservationIgnored private var hasLoaded = false

    init(store: any InventoryStoring = InventoryStore()) {
        self.store = store
        self.loadMix = store.loadLoadMix()
    }

    @discardableResult
    func loadIfNeeded() -> Bool {
        guard !hasLoaded else { return true }

        do {
            items = try store.load()
            loadMix = store.loadLoadMix()
            hasLoaded = true
            inventoryLoadFailed = false
            bannerMessage = nil
            return true
        } catch {
            inventoryLoadFailed = true
            bannerMessage = InventoryPersistenceError.loadUnavailable.localizedDescription
            return false
        }
    }

    @discardableResult
    func addItem(
        name: String,
        estimate: MeasurementEstimate,
        quantity: Int,
        stackability: ItemStackability = .notStackable,
        orientationPolicy: ItemOrientationPolicy = .keepUpright
    ) -> Bool {
        guard loadIfNeeded() else { return false }
        var next = items
        next.append(
            MeasuredItem(
                name: normalizedName(name),
                lengthMeters: estimate.lengthMeters,
                widthMeters: estimate.widthMeters,
                heightMeters: estimate.heightMeters,
                quantity: max(1, quantity),
                confidence: estimate.confidence,
                comparisonAngleCount: estimate.comparisonAngleCount,
                comparisonAgreementCount: estimate.comparisonAgreementCount,
                stackability: stackability,
                orientationPolicy: orientationPolicy
            )
        )
        return persist(next)
    }

    @discardableResult
    func updateItem(
        id: UUID,
        name: String,
        quantity: Int,
        stackability: ItemStackability,
        orientationPolicy: ItemOrientationPolicy,
        lengthMeters: Double? = nil,
        widthMeters: Double? = nil,
        heightMeters: Double? = nil
    ) -> Bool {
        guard loadIfNeeded() else { return false }
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }

        var next = items
        if lengthMeters != nil || widthMeters != nil || heightMeters != nil {
            let maxDimensionMeters = ManualEntryDraft.maximumDimensionInches * 0.0254
            guard let lengthMeters, let widthMeters, let heightMeters,
                  lengthMeters.isFinite, widthMeters.isFinite, heightMeters.isFinite,
                  lengthMeters > 0, widthMeters > 0, heightMeters > 0,
                  lengthMeters <= maxDimensionMeters,
                  widthMeters <= maxDimensionMeters,
                  heightMeters <= maxDimensionMeters else {
                return false
            }
            let current = next[index]
            let changed = abs(current.lengthMeters - lengthMeters) > 0.0001
                || abs(current.widthMeters - widthMeters) > 0.0001
                || abs(current.heightMeters - heightMeters) > 0.0001
            if changed {
                if let original = next[index].originalDimensions,
                   abs(original.lengthMeters - lengthMeters) <= 0.0001,
                   abs(original.widthMeters - widthMeters) <= 0.0001,
                   abs(original.heightMeters - heightMeters) <= 0.0001 {
                    next[index].originalDimensions = nil
                } else if next[index].originalDimensions == nil {
                    next[index].originalDimensions = OriginalItemDimensions(
                        lengthMeters: current.lengthMeters,
                        widthMeters: current.widthMeters,
                        heightMeters: current.heightMeters
                    )
                }
                next[index].lengthMeters = lengthMeters
                next[index].widthMeters = widthMeters
                next[index].heightMeters = heightMeters
            }
        }
        next[index].name = normalizedName(name)
        next[index].quantity = max(1, quantity)
        next[index].stackability = stackability
        next[index].orientationPolicy = orientationPolicy
        return persist(next)
    }

    @discardableResult
    func setLoadMix(_ loadMix: PackingLoadMix) -> Bool {
        guard loadIfNeeded() else { return false }
        do {
            try store.saveLoadMix(loadMix)
            self.loadMix = loadMix
            bannerMessage = nil
            return true
        } catch {
            bannerMessage = InventoryPersistenceError.saveFailed.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteItems(at offsets: IndexSet) -> Bool {
        guard loadIfNeeded(), offsets.allSatisfy({ items.indices.contains($0) }) else { return false }
        var next = items
        next.remove(atOffsets: offsets)
        return persist(next)
    }

    var packingItems: [PackingItem] {
        items.compactMap(\.packingItem)
    }

    var packingSummary: PackingSummary {
        PackingPlanner().summary(for: packingItems)
    }

    var vehicleRecommendation: PackingVehicleRecommendation {
        PackingPlanner().recommendVehicle(
            for: packingItems,
            from: PackingVehicleCatalog.conservativeMovingFleet(loadMix: loadMix)
        )
    }

    /// Once a vehicle is selected, its cargo height can reduce the number of
    /// safe stack layers. When no vehicle fits, the largest measured profile
    /// keeps stack layers bounded instead of assuming unlimited ceiling height.
    var planningSummary: PackingSummary {
        vehicleRecommendation.summary
    }

    var ignoredPackingItemCount: Int {
        items.count - packingItems.count
    }

    func shareText(units: MeasurementUnits) -> String {
        let summary = planningSummary
        let recommendation = vehicleRecommendation
        var lines = [
            "PackMeasure Moving Load",
            "Saved pieces: \(summary.pieceCount) (\(items.count) \(items.count == 1 ? "entry" : "entries"))",
            "Load mix: \(loadMix.displayName)",
            "Cargo floor needed: \(units.areaFromSquareFeet(summary.requiredFloorSquareFeet)) (unstacked \(units.areaFromSquareFeet(summary.rawFootprintSquareFeet)))",
            "Cargo volume needed: \(units.volumeFromCubicFeet(summary.requiredCubicFeet))"
        ]
        if let vehicle = recommendation.vehicle {
            lines.append("Recommended vehicle: \(vehicle.name)")
        } else if packingItems.isEmpty {
            lines.append("Recommended vehicle: \(recommendation.reason)")
        } else {
            lines.append("Recommended vehicle: \(PackingMeasurementCopy.recommendation(recommendation, units: units))")
        }
        if ignoredPackingItemCount > 0 {
            let count = ignoredPackingItemCount
            lines.append(
                count == 1
                    ? "Warning: 1 saved item could not be included in totals because its dimensions are invalid."
                    : "Warning: \(count) saved items could not be included in totals because their dimensions are invalid."
            )
        }
        if !items.isEmpty {
            lines.append("")
            lines.append("Items:")
            for item in items {
                let dims = [item.lengthMeters, item.widthMeters, item.heightMeters]
                    .map { units.length(meters: $0) }
                    .joined(separator: " × ")
                let stackText: String = switch item.stackability {
                case .notStackable: "no stack"
                case let .stackable(maxLayers): "stack \(maxLayers) high"
                }
                let orientText = item.orientationPolicy == .keepUpright ? "upright" : "can rotate"
                let excludedSuffix = item.packingItem == nil ? " [excluded from totals: invalid dimensions]" : ""
                lines.append("- \(item.name) ×\(item.quantity): \(dims) (\(stackText), \(orientText))\(excludedSuffix)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func persist(_ next: [MeasuredItem]) -> Bool {
        do {
            try store.save(next)
            items = next
            bannerMessage = nil
            return true
        } catch {
            bannerMessage = InventoryPersistenceError.saveFailed.localizedDescription
            return false
        }
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Scanned Item" : trimmed
    }
}
