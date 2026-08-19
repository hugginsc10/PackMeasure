import Foundation
import Testing
@testable import PackMeasure

@Suite("Inventory and packing integration", .serialized)
@MainActor
struct AppModelInventoryTests {
    @Test
    func stackabilityReducesRequiredFloorAndSurvivesReload() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        let estimate = MeasurementEstimate(
            lengthMeters: meters(fromInches: 24),
            widthMeters: meters(fromInches: 12),
            heightMeters: meters(fromInches: 18),
            confidence: .high,
            sampleCount: 900,
            frameCount: 12
        )

        model.addItem(
            name: "Book box",
            estimate: estimate,
            quantity: 4,
            stackability: .stackable(maxLayers: 2),
            orientationPolicy: .keepUpright
        )

        #expect(model.packingSummary.pieceCount == 4)
        #expect(abs(model.packingSummary.rawFootprintSquareFeet - 8) < 0.001)
        #expect(abs(model.packingSummary.stackAdjustedFootprintSquareFeet - 4) < 0.001)
        #expect(abs(model.packingSummary.requiredFloorSquareFeet - 4.4) < 0.001)

        let reloaded = AppModel(store: harness.store)
        reloaded.loadIfNeeded()

        #expect(reloaded.items.count == 1)
        #expect(reloaded.items.first?.quantity == 4)
        #expect(reloaded.items.first?.stackability == .stackable(maxLayers: 2))
        #expect(reloaded.items.first?.orientationPolicy == .keepUpright)
        #expect(abs(reloaded.packingSummary.requiredFloorSquareFeet - 4.4) < 0.001)
    }

    @Test
    func editingPackingControlsUpdatesSummaryAndPersistence() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        model.addItem(
            name: "Lamp",
            estimate: MeasurementEstimate(
                lengthMeters: meters(fromInches: 12),
                widthMeters: meters(fromInches: 12),
                heightMeters: meters(fromInches: 48),
                confidence: .medium,
                sampleCount: 400,
                frameCount: 8
            ),
            quantity: 1
        )
        let id = try #require(model.items.first?.id)

        model.updateItem(
            id: id,
            name: "Floor lamp",
            quantity: 3,
            stackability: .notStackable,
            orientationPolicy: .mayRotate
        )

        #expect(model.items.first?.name == "Floor lamp")
        #expect(model.items.first?.quantity == 3)
        #expect(model.items.first?.orientationPolicy == .mayRotate)
        #expect(model.packingSummary.pieceCount == 3)

        let reloaded = AppModel(store: harness.store)
        reloaded.loadIfNeeded()
        #expect(reloaded.items.first?.name == "Floor lamp")
        #expect(reloaded.items.first?.quantity == 3)
        #expect(reloaded.items.first?.orientationPolicy == .mayRotate)
    }

    @Test
    func legacyInventoryDefaultsToConservativePackingControls() throws {
        let harness = try InventoryHarness()
        let legacyJSON = """
        [
          {
            "id": "805EF5CD-BAE7-47D1-947D-CA43A2CB7747",
            "name": "Legacy tote",
            "lengthMeters": 0.60,
            "widthMeters": 0.40,
            "heightMeters": 0.35,
            "quantity": 2,
            "confidence": "medium",
            "capturedAt": "2026-08-18T20:00:00Z"
          }
        ]
        """
        try Data(legacyJSON.utf8).write(to: harness.url, options: .atomic)

        let loaded = try harness.store.load()
        let item = try #require(loaded.first)

        #expect(item.stackability == .notStackable)
        #expect(item.orientationPolicy == .keepUpright)
        #expect(item.quantity == 2)
    }

    @Test
    func loadMixFlowsIntoVehicleCatalog() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        model.addItem(
            name: "Small box",
            estimate: MeasurementEstimate(
                lengthMeters: meters(fromInches: 18),
                widthMeters: meters(fromInches: 18),
                heightMeters: meters(fromInches: 18),
                confidence: .high,
                sampleCount: 800,
                frameCount: 10
            ),
            quantity: 2,
            stackability: .stackable(maxLayers: 4),
            orientationPolicy: .mayRotate
        )

        model.setLoadMix(.boxes)

        #expect(model.loadMix == .boxes)
        #expect(model.vehicleRecommendation.vehicle?.usableVolumeFraction == PackingLoadMix.boxes.usableVolumeFraction)
        #expect(model.vehicleRecommendation.vehicle?.id == "cargo-van")
    }

    @Test
    func dimensionFormattingCarriesTwelveInchesIntoNextFoot() {
        let almostOneFoot = meters(fromInches: 11.6)

        #expect(MeasurementMath.inchString(from: almostOneFoot) == "1 ft 0 in")
    }

    @Test
    func planningSummaryCapsStackLayersAtRecommendedVehicleHeight() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        model.addItem(
            name: "Tall stackable box",
            estimate: MeasurementEstimate(
                lengthMeters: meters(fromInches: 24),
                widthMeters: meters(fromInches: 12),
                heightMeters: meters(fromInches: 18),
                confidence: .high,
                sampleCount: 900,
                frameCount: 12
            ),
            quantity: 4,
            stackability: .stackable(maxLayers: 20),
            orientationPolicy: .keepUpright
        )

        #expect(model.vehicleRecommendation.vehicle?.id == "cargo-van")
        #expect(abs(model.packingSummary.requiredFloorSquareFeet - 2.2) < 0.001)
        #expect(abs(model.planningSummary.requiredFloorSquareFeet - 4.4) < 0.001)
    }

    private func meters(fromInches inches: Double) -> Double {
        inches / 39.370_078_740_157_48
    }
}

private struct InventoryHarness {
    let directory: URL
    let url: URL
    let store: InventoryStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("inventory.json")
        store = InventoryStore(storageURL: url)
    }
}
