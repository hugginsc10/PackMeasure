import Foundation
import Testing
@testable import PackMeasure

@Suite("Manual dimension entry", .serialized)
@MainActor
struct ManualEntryTests {
    @Test
    func validDimensionsPreviewAndPersistThroughAppModel() throws {
        let harness = try ManualEntryInventoryHarness()
        let model = AppModel(store: harness.store)
        var draft = ManualEntryDraft()
        draft.name = "  Home Depot box  "
        draft.quantity = 3
        draft.lengthInches = "24"
        draft.widthInches = "20"
        draft.heightInches = "20"
        draft.isStackable = true
        draft.maxStackLayers = 2
        draft.mayRotate = true

        let preview = try #require(draft.preview)
        #expect(abs(preview.perItemFootprintSquareFeet - (24 * 20 / 144)) < 0.000_001)
        #expect(abs(preview.totalFootprintSquareFeet - 10) < 0.000_001)
        #expect(abs(preview.totalCubicFeet - (24 * 20 * 20 * 3 / 1_728)) < 0.000_001)

        try draft.save(to: model)

        let item = try #require(model.items.first)
        #expect(item.name == "Home Depot box")
        #expect(item.quantity == 3)
        #expect(item.stackability == .stackable(maxLayers: 2))
        #expect(item.orientationPolicy == .mayRotate)
        #expect(abs(MeasurementMath.inches(from: item.lengthMeters) - 24) < 0.000_001)
        #expect(abs(MeasurementMath.inches(from: item.widthMeters) - 20) < 0.000_001)
        #expect(abs(MeasurementMath.inches(from: item.heightMeters) - 20) < 0.000_001)

        let reloaded = AppModel(store: harness.store)
        reloaded.loadIfNeeded()
        let reloadedItem = try #require(reloaded.items.first)
        #expect(abs(reloadedItem.capturedAt.timeIntervalSince(item.capturedAt)) < 0.001)
        var normalizedReloadedItem = reloadedItem
        normalizedReloadedItem.capturedAt = item.capturedAt
        #expect(normalizedReloadedItem == item)
    }

    @Test
    func blankNameGetsManualItemDefault() throws {
        var draft = validDraft
        draft.name = " \n "

        #expect(try draft.validatedSubmission().name == "Manual item")
    }

    @Test
    func rejectsMissingNonNumericAndNonPositiveDimensions() {
        var draft = validDraft
        draft.lengthInches = ""
        #expect(validationError(for: draft) == .missingDimensions)

        draft = validDraft
        draft.widthInches = "twenty"
        #expect(validationError(for: draft) == .missingDimensions)

        draft = validDraft
        draft.heightInches = "0"
        #expect(validationError(for: draft) == .nonPositiveDimensions)

        draft.heightInches = "-1"
        #expect(validationError(for: draft) == .nonPositiveDimensions)
    }

    @Test
    func rejectsImplausiblyLargeDimensionsAndInvalidCounts() {
        var draft = validDraft
        draft.lengthInches = "481"
        #expect(validationError(for: draft) == .dimensionsTooLarge)

        draft = validDraft
        draft.quantity = 0
        #expect(validationError(for: draft) == .invalidQuantity)

        draft = validDraft
        draft.quantity = 1_000
        #expect(validationError(for: draft) == .invalidQuantity)

        draft = validDraft
        draft.isStackable = true
        draft.maxStackLayers = 1
        #expect(validationError(for: draft) == .invalidStackLimit)
    }

    @Test
    func acceptsDecimalInchesAtRealisticBoundary() throws {
        var draft = validDraft
        draft.lengthInches = " 24.5 "
        draft.widthInches = "0.25"
        draft.heightInches = "480"

        let submission = try draft.validatedSubmission()
        #expect(submission.dimensions.lengthInches == 24.5)
        #expect(submission.dimensions.widthInches == 0.25)
        #expect(submission.dimensions.heightInches == 480)
    }

    @Test func centimetersPersistAsTheSameMetricGeometry() throws {
        let harness = try ManualEntryInventoryHarness()
        let model = AppModel(store: harness.store)
        var draft = ManualEntryDraft(inputUnit: MeasurementUnits.centimeters.inputUnit)
        draft.lengthText = "60"
        draft.widthText = "40"
        draft.heightText = "35"
        draft.quantity = 2
        let submission = try draft.validatedSubmission()
        #expect(abs(submission.dimensions.lengthInches * 0.0254 - 0.6) < 1e-12)
        #expect(abs(submission.dimensions.widthInches * 0.0254 - 0.4) < 1e-12)
        #expect(abs(submission.dimensions.heightInches * 0.0254 - 0.35) < 1e-12)
        let preview = try #require(draft.preview)
        #expect(MeasurementUnits.centimeters.areaFromSquareFeet(preview.totalFootprintSquareFeet) == "0.48 m²")

        try draft.save(to: model)
        let reloaded = AppModel(store: harness.store)
        reloaded.loadIfNeeded()
        let item = try #require(reloaded.items.first)
        #expect(abs(item.lengthMeters - 0.6) < 1e-12)
        #expect(abs(item.widthMeters - 0.4) < 1e-12)
        #expect(abs(item.heightMeters - 0.35) < 1e-12)
        #expect(item.quantity == 2)
    }

    @Test func switchingInputUnitsConvertsValuesWithoutChangingDimensionsOrLimit() throws {
        var draft = validDraft
        draft.heightInches = "480"
        let before = try draft.validatedSubmission().dimensions
        for _ in 0..<5 {
            draft.changeInputUnit(to: .centimeters)
            #expect(abs(try #require(Double(draft.lengthText)) - 60.96) < 1e-10)
            #expect(draft.canSave)
            draft.changeInputUnit(to: .inches)
            #expect(draft.canSave)
        }
        let after = try draft.validatedSubmission().dimensions
        #expect(abs(after.lengthInches - before.lengthInches) < 1e-10)
        #expect(abs(after.widthInches - before.widthInches) < 1e-10)
        #expect(abs(after.heightInches - before.heightInches) < 1e-10)
        #expect(MeasurementUnits.both.inputUnit == .inches)
    }

    @Test func switchingPartialInputLeavesInvalidAndBlankFieldsEditable() throws {
        var draft = ManualEntryDraft()
        draft.lengthText = "12"
        draft.widthText = "twenty"
        draft.heightText = ""
        draft.changeInputUnit(to: .centimeters)
        #expect(abs(try #require(Double(draft.lengthText)) - 30.48) < 1e-10)
        #expect(draft.widthText == "twenty" && draft.heightText.isEmpty)
        #expect(validationError(for: draft) == .missingDimensions)
        #expect(draft.validationMessage?.contains("centimeters") == true)
    }

    @Test func centimetersUseTheExistingPhysicalDimensionLimit() throws {
        var draft = ManualEntryDraft(inputUnit: .centimeters)
        draft.lengthText = "1219.2"
        draft.widthText = "40"
        draft.heightText = "35"
        #expect(draft.canSave)
        draft.lengthText = "1219.21"
        #expect(validationError(for: draft) == .dimensionsTooLarge)
        #expect(draft.validationMessage?.contains("1219.2 cm") == true)
    }

    @Test func legacyInchPropertiesKeepTheirMeaningInAMetricDraft() throws {
        var draft = ManualEntryDraft(inputUnit: .centimeters)
        draft.lengthInches = "12"
        draft.widthInches = "24"
        draft.heightInches = "6"
        #expect(abs(try #require(Double(draft.lengthText)) - 30.48) < 1e-10)
        let dimensions = try draft.validatedSubmission().dimensions
        #expect(abs(dimensions.lengthInches - 12) < 1e-10)
        #expect(abs(dimensions.widthInches - 24) < 1e-10)
        #expect(abs(dimensions.heightInches - 6) < 1e-10)
    }

    private var validDraft: ManualEntryDraft {
        var draft = ManualEntryDraft()
        draft.name = "Box"
        draft.lengthInches = "24"
        draft.widthInches = "20"
        draft.heightInches = "20"
        return draft
    }

    private func validationError(for draft: ManualEntryDraft) -> ManualEntryValidationError? {
        do {
            _ = try draft.validatedSubmission()
            return nil
        } catch let error as ManualEntryValidationError {
            return error
        } catch {
            return nil
        }
    }
}

private struct ManualEntryInventoryHarness {
    let directory: URL
    let store: InventoryStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        store = InventoryStore(
            storageURL: directory.appendingPathComponent("inventory.json")
        )
    }
}
