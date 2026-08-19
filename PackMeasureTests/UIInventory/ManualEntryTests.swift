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
        #expect(reloaded.items == model.items)
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
