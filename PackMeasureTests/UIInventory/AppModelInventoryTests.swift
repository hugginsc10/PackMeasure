import Foundation
import Testing
@testable import PackMeasure

@Suite("Inventory and packing integration", .serialized)
@MainActor
struct AppModelInventoryTests {
    @Test
    func failedLoadCannotReplaceSavedInventory() throws {
        let harness = try InventoryHarness()
        let original = Data("{ unreadable inventory".utf8)
        try original.write(to: harness.url, options: .atomic)
        let model = AppModel(store: harness.store)
        model.loadIfNeeded()
        #expect(model.bannerMessage != nil)

        model.addItem(name: "New box", estimate: recoveryEstimate, quantity: 1)
        model.deleteItems(at: [])

        #expect(model.items.isEmpty)
        #expect(try Data(contentsOf: harness.url) == original)
    }

    @Test
    func addingBeforeInitialLoadPreservesExistingItems() throws {
        let harness = try InventoryHarness()
        let saved = recoveryItem
        try harness.store.save([saved])
        let model = AppModel(store: harness.store)

        model.addItem(name: "New box", estimate: recoveryEstimate, quantity: 1)

        #expect(model.items.count == 2)
        #expect(model.items.first == saved)
        let reloaded = try harness.store.load()
        #expect(reloaded.map(\.id) == model.items.map(\.id))
        #expect(reloaded.first == saved)
        #expect(reloaded.last?.name == "New box")
        #expect(reloaded.last?.lengthMeters == recoveryEstimate.lengthMeters)
    }

    @Test
    func failedLoadCanRetryWithoutRestarting() throws {
        let harness = try InventoryHarness()
        try Data("unreadable".utf8).write(to: harness.url)
        let model = AppModel(store: harness.store)
        model.loadIfNeeded()
        #expect(model.bannerMessage != nil)
        let saved = recoveryItem
        try harness.store.save([saved])

        model.loadIfNeeded()

        #expect(model.items == [saved])
        #expect(model.bannerMessage == nil)
    }

    @Test
    func readFailureBlocksEveryMutationEvenAfterDismissingTheMessage() {
        let store = RecoveryTestStore()
        store.failReads = true
        let model = AppModel(store: store)
        #expect(!model.loadIfNeeded())
        model.bannerMessage = nil

        #expect(!model.addItem(name: "New box", estimate: recoveryEstimate, quantity: 1))
        #expect(!model.updateItem(id: recoveryItem.id, name: "Changed", quantity: 2,
                                 stackability: .notStackable, orientationPolicy: .keepUpright))
        #expect(!model.deleteItems(at: [0]))
        #expect(store.saveCalls == 0)
        #expect(model.inventoryLoadFailed)
    }

    @Test
    func failedSavesKeepTheCommittedInventoryAndCanBeRetried() throws {
        let store = RecoveryTestStore()
        let saved = recoveryItem
        store.items = [saved]
        let model = AppModel(store: store)
        #expect(model.loadIfNeeded())
        store.failWrites = true

        #expect(!model.addItem(name: "New box", estimate: recoveryEstimate, quantity: 1))
        #expect(model.items == [saved])
        #expect(!model.updateItem(id: saved.id, name: "Changed", quantity: 2,
                                 stackability: .stackable(maxLayers: 2), orientationPolicy: .mayRotate))
        #expect(model.items == [saved])
        #expect(!model.deleteItems(at: [0]))
        #expect(model.items == [saved])
        #expect(store.items == [saved])
        #expect(model.bannerMessage == InventoryPersistenceError.saveFailed.localizedDescription)

        store.failWrites = false
        #expect(model.addItem(name: "New box", estimate: recoveryEstimate, quantity: 1))
        #expect(model.items.count == 2)
        #expect(store.items == model.items)
        #expect(model.bannerMessage == nil)
    }

    @Test
    func manualEntryReportsPersistenceFailureInsteadOfSuccess() throws {
        let store = RecoveryTestStore()
        store.failWrites = true
        let model = AppModel(store: store)
        var draft = ManualEntryDraft()
        draft.name = "Unsaved box"
        draft.lengthInches = "24"
        draft.widthInches = "12"
        draft.heightInches = "18"

        #expect(throws: InventoryPersistenceError.self) { try draft.save(to: model) }
        #expect(model.items.isEmpty)
        #expect(store.items.isEmpty)
        #expect(draft.name == "Unsaved box")
        store.failWrites = false
        try draft.save(to: model)
        #expect(model.items.first?.name == "Unsaved box")
    }

    @Test
    func updateAndDeleteLoadExistingInventoryBeforeChangingIt() throws {
        let harness = try InventoryHarness()
        let first = recoveryItem
        let second = recoveryItem
        try harness.store.save([first, second])
        let model = AppModel(store: harness.store)
        #expect(model.updateItem(id: first.id, name: "Changed", quantity: 2,
                                stackability: .notStackable, orientationPolicy: .keepUpright))
        #expect(model.items.count == 2)
        #expect(model.items.first?.name == "Changed")

        let reloaded = AppModel(store: harness.store)
        #expect(reloaded.deleteItems(at: [0]))
        #expect(reloaded.items == [second])
        #expect(try harness.store.load() == [second])
    }

    private var recoveryEstimate: MeasurementEstimate {
        .init(lengthMeters: 0.6, widthMeters: 0.4, heightMeters: 0.3,
              confidence: .medium, sampleCount: 10, frameCount: 1)
    }

    private var recoveryItem: MeasuredItem {
        .init(name: "Previously saved box", lengthMeters: 0.6,
              widthMeters: 0.4, heightMeters: 0.3, confidence: .medium,
              capturedAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

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
        #expect(item.comparisonAngleCount == nil)
        #expect(item.comparisonAgreementCount == nil)
    }

    @Test
    func multiAngleProvenanceSurvivesSavingAndReload() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        model.addItem(
            name: "Suitcase",
            estimate: MeasurementEstimate(
                lengthMeters: meters(fromInches: 22),
                widthMeters: meters(fromInches: 15),
                heightMeters: meters(fromInches: 10),
                confidence: .high,
                sampleCount: 1_600,
                frameCount: 2,
                comparisonAngleCount: 3,
                comparisonAgreementCount: 2
            ),
            quantity: 1
        )

        #expect(model.items.first?.comparisonAngleCount == 3)
        #expect(model.items.first?.comparisonAgreementCount == 2)

        let reloaded = AppModel(store: harness.store)
        reloaded.loadIfNeeded()
        let item = try #require(reloaded.items.first)

        #expect(item.comparisonAngleCount == 3)
        #expect(item.comparisonAgreementCount == 2)
        #expect(
            SavedMeasurementCopy.qualitySummary(for: item)
                == "2 of 3 angles agree — approximate; verify tight clearances"
        )
    }

    @Test
    func savedMeasurementCopyDisclosesAgreementAndPreservesLegacyFallback() {
        let agreed = MeasuredItem(
            name: "Agreed scan",
            lengthMeters: 0.6,
            widthMeters: 0.4,
            heightMeters: 0.5,
            confidence: .high,
            comparisonAngleCount: 2,
            comparisonAgreementCount: 2
        )
        let legacy = MeasuredItem(
            name: "Legacy scan",
            lengthMeters: 0.6,
            widthMeters: 0.4,
            heightMeters: 0.5,
            confidence: .medium
        )

        #expect(
            SavedMeasurementCopy.qualitySummary(for: agreed)
                == "2-angle agreement — approximate; verify tight clearances"
        )
        #expect(SavedMeasurementCopy.qualitySummary(for: legacy) == "Medium confidence")
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

        let reloaded = AppModel(store: harness.store)
        reloaded.loadIfNeeded()
        #expect(reloaded.loadMix == .boxes)
        #expect(reloaded.vehicleRecommendation.vehicle?.usableVolumeFraction == PackingLoadMix.boxes.usableVolumeFraction)

        let failingStore = RecoveryTestStore()
        let failingModel = AppModel(store: failingStore)
        failingStore.failWrites = true
        #expect(!failingModel.setLoadMix(.bulkyFurniture))
        #expect(failingModel.loadMix == .mixedHousehold)
        #expect(failingModel.bannerMessage == InventoryPersistenceError.saveFailed.localizedDescription)
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

        let boxID = try #require(model.items.first?.id)
        model.updateItem(
            id: boxID,
            name: "Tall stackable box",
            quantity: 8,
            stackability: .stackable(maxLayers: 20),
            orientationPolicy: .keepUpright
        )
        model.addItem(
            name: "Oversized beam",
            estimate: MeasurementEstimate(
                lengthMeters: meters(fromInches: 400),
                widthMeters: meters(fromInches: 12),
                heightMeters: meters(fromInches: 12),
                confidence: .high,
                sampleCount: 900,
                frameCount: 12
            ),
            quantity: 1
        )

        #expect(model.vehicleRecommendation.vehicle == nil)
        #expect(model.planningSummary.requiredFloorSquareFeet > model.packingSummary.requiredFloorSquareFeet)
    }

    @Test func displayPreferencesDoNotRewriteInventoryOrChangePacking() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        model.addItem(name: "Metric box", estimate:.init(lengthMeters:0.6, widthMeters:0.4,
            heightMeters:0.35, confidence:.high, sampleCount:0, frameCount:0), quantity:2)
        let savedBytes = try Data(contentsOf:harness.url)
        let summary = model.planningSummary
        let suite = "inventory-units-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let preferences = AppPreferences(defaults:defaults)
        preferences.units = .centimeters
        let item = try #require(model.items.first)
        #expect(preferences.units.length(meters:item.lengthMeters) == "60.0 cm")
        let metricReason = PackingMeasurementCopy.recommendation(model.vehicleRecommendation, units:preferences.units)
        #expect(metricReason.contains("cm") && metricReason.contains("m²") && metricReason.contains("m³"))
        #expect(!metricReason.contains("ft²") && !metricReason.contains("ft³"))
        preferences.units = .both
        #expect(preferences.units.length(meters:item.lengthMeters).contains("60.0 cm"))
        #expect(model.planningSummary == summary)
        #expect(try Data(contentsOf:harness.url) == savedBytes)
        let reloaded = AppModel(store:harness.store)
        reloaded.loadIfNeeded()
        #expect(reloaded.items.first?.lengthMeters == 0.6)
        #expect(reloaded.items.first?.widthMeters == 0.4)
        #expect(reloaded.items.first?.heightMeters == 0.35)
    }

    @Test func packingRejectionCopyUsesStructuredValuesInSelectedUnits() throws {
        let vehicle = try #require(PackingVehicleCatalog.conservativeMovingFleet().first)
        let floor = PackingVehicleRejection(vehicle:vehicle,
            constraint:.insufficientFloor(requiredSquareFeet:100, availableSquareFeet:50),
            reason:"Old floor copy in ft²")
        let volume = PackingVehicleRejection(vehicle:vehicle,
            constraint:.insufficientVolume(requiredCubicFeet:100, availableCubicFeet:50),
            reason:"Old volume copy in ft³")
        let floorCopy = PackingMeasurementCopy.rejection(floor, units:.centimeters)
        #expect(floorCopy.contains("4.65 m²") && floorCopy.contains("9.29 m²"))
        #expect(!floorCopy.contains("ft"))
        let volumeCopy = PackingMeasurementCopy.rejection(volume, units:.centimeters)
        #expect(volumeCopy.contains("1.42 m³") && volumeCopy.contains("2.83 m³"))
        #expect(!volumeCopy.contains("ft"))
        let both = PackingMeasurementCopy.rejection(volume, units:.both)
        #expect(both.contains("cu ft") && both.contains("m³"))
        #expect(volume.constraint == .insufficientVolume(requiredCubicFeet:100, availableCubicFeet:50))
    }

    @Test func editingSavedItemDimensionsPreservesOriginalScanAndUpdatesQualitySummary() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        model.addItem(
            name: "Dresser",
            estimate: .init(
                lengthMeters: 1.2,
                widthMeters: 0.5,
                heightMeters: 0.9,
                confidence: .high,
                sampleCount: 1200,
                frameCount: 6,
                comparisonAngleCount: 3,
                comparisonAgreementCount: 3
            ),
            quantity: 1
        )
        let id = try #require(model.items.first?.id)
        #expect(model.items.first?.originalDimensions == nil)

        #expect(model.updateItem(
            id: id,
            name: "Dresser",
            quantity: 1,
            stackability: .notStackable,
            orientationPolicy: .keepUpright,
            lengthMeters: 1.25,
            widthMeters: 0.52,
            heightMeters: 0.91
        ))
        let firstEdit = try #require(model.items.first)
        #expect(firstEdit.lengthMeters == 1.25)
        #expect(firstEdit.originalDimensions == OriginalItemDimensions(lengthMeters: 1.2, widthMeters: 0.5, heightMeters: 0.9))
        #expect(SavedMeasurementCopy.qualitySummary(for: firstEdit) == "Dimensions edited manually · original dimensions preserved")

        // A second edit keeps the original scan dimensions rather than overwriting them with the first edit.
        #expect(model.updateItem(
            id: id,
            name: "Dresser",
            quantity: 1,
            stackability: .notStackable,
            orientationPolicy: .keepUpright,
            lengthMeters: 1.30,
            widthMeters: 0.55,
            heightMeters: 0.92
        ))
        #expect(model.items.first?.originalDimensions == OriginalItemDimensions(lengthMeters: 1.2, widthMeters: 0.5, heightMeters: 0.9))

        // Invalid dimensions are rejected without mutating saved state.
        #expect(!model.updateItem(
            id: id,
            name: "Dresser",
            quantity: 1,
            stackability: .notStackable,
            orientationPolicy: .keepUpright,
            lengthMeters: -1,
            widthMeters: 0.5,
            heightMeters: 0.9
        ))
        #expect(model.items.first?.lengthMeters == 1.30)
    }

    @Test func shareTextIncludesSummaryVehicleAndItemsInSelectedUnits() throws {
        let harness = try InventoryHarness()
        let model = AppModel(store: harness.store)
        model.addItem(
            name: "Moving box",
            estimate: .init(lengthMeters: 0.6, widthMeters: 0.4, heightMeters: 0.4, confidence: .high, sampleCount: 0, frameCount: 0),
            quantity: 3,
            stackability: .stackable(maxLayers: 3),
            orientationPolicy: .mayRotate
        )
        let metricShare = model.shareText(units: .centimeters)
        #expect(metricShare.contains("PackMeasure Moving Load"))
        #expect(metricShare.contains("Saved pieces: 3 (1 entry)"))
        #expect(metricShare.contains("Recommended vehicle: U-Haul cargo van"))
        #expect(metricShare.contains("- Moving box ×3: 60.0 cm × 40.0 cm × 40.0 cm (stack 3 high, can rotate)"))

        // When a saved item has invalid dimensions and is excluded from planningSummary,
        // shareText explicitly warns the recipient and tags the excluded item.
        model.addItem(
            name: "Zero-height corrupt item",
            estimate: .init(lengthMeters: 0.5, widthMeters: 0.5, heightMeters: 0, confidence: .low, sampleCount: 0, frameCount: 0),
            quantity: 1
        )
        let shareWithExcluded = model.shareText(units: .centimeters)
        #expect(shareWithExcluded.contains("Warning: 1 saved item could not be included in totals because its dimensions are invalid."))
        #expect(shareWithExcluded.contains("[excluded from totals: invalid dimensions]"))

        // When only invalid items remain, shareText preserves the planner's no-usable-items reason
        // instead of claiming that none of the listed vehicle profiles fit.
        model.deleteItems(at: IndexSet(integer: 0))
        let onlyInvalidShare = model.shareText(units: .centimeters)
        #expect(onlyInvalidShare.contains("Recommended vehicle: \(model.vehicleRecommendation.reason)"))
        #expect(!onlyInvalidShare.contains("No listed vehicle is suitable"))
    }

    private func meters(fromInches inches: Double) -> Double {
        inches / 39.370_078_740_157_48
    }
}

private final class RecoveryTestStore: InventoryStoring {
    var items: [MeasuredItem] = []
    var loadMix: PackingLoadMix = .mixedHousehold
    var failReads = false
    var failWrites = false
    private(set) var saveCalls = 0

    func load() throws -> [MeasuredItem] {
        if failReads { throw CocoaError(.fileReadNoPermission) }
        return items
    }

    func save(_ items: [MeasuredItem]) throws {
        saveCalls += 1
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        self.items = items
    }

    func loadLoadMix() -> PackingLoadMix {
        loadMix
    }

    func saveLoadMix(_ loadMix: PackingLoadMix) throws {
        saveCalls += 1
        if failWrites { throw CocoaError(.fileWriteOutOfSpace) }
        self.loadMix = loadMix
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
