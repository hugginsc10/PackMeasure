import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    private(set) var items: [MeasuredItem] = []
    var showingScanner = false
    var bannerMessage: String?
    private(set) var loadMix: PackingLoadMix = .mixedHousehold

    @ObservationIgnored private let store: InventoryStore
    @ObservationIgnored private var hasLoaded = false

    init(store: InventoryStore = InventoryStore()) {
        self.store = store
    }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true

        do {
            items = try store.load()
        } catch {
            bannerMessage = "Could not load saved inventory."
        }
    }

    func addItem(
        name: String,
        estimate: MeasurementEstimate,
        quantity: Int,
        stackability: ItemStackability = .notStackable,
        orientationPolicy: ItemOrientationPolicy = .keepUpright
    ) {
        items.append(
            MeasuredItem(
                name: normalizedName(name),
                lengthMeters: estimate.lengthMeters,
                widthMeters: estimate.widthMeters,
                heightMeters: estimate.heightMeters,
                quantity: max(1, quantity),
                confidence: estimate.confidence,
                stackability: stackability,
                orientationPolicy: orientationPolicy
            )
        )
        persist()
    }

    func updateItem(
        id: UUID,
        name: String,
        quantity: Int,
        stackability: ItemStackability,
        orientationPolicy: ItemOrientationPolicy
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }

        items[index].name = normalizedName(name)
        items[index].quantity = max(1, quantity)
        items[index].stackability = stackability
        items[index].orientationPolicy = orientationPolicy
        persist()
    }

    func setLoadMix(_ loadMix: PackingLoadMix) {
        self.loadMix = loadMix
    }

    func deleteItems(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        persist()
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
    /// safe stack layers. This is the floor estimate the home screen should use.
    var planningSummary: PackingSummary {
        let recommendation = vehicleRecommendation
        return recommendation.vehicle == nil
            ? packingSummary
            : recommendation.summary
    }

    var ignoredPackingItemCount: Int {
        items.count - packingItems.count
    }

    private func persist() {
        do {
            try store.save(items)
            bannerMessage = nil
        } catch {
            bannerMessage = "Could not save inventory."
        }
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Scanned Item" : trimmed
    }
}
