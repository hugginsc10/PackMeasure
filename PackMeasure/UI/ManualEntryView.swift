import Foundation
import SwiftUI

enum ManualEntryValidationError: Error, Equatable {
    case missingDimensions
    case nonPositiveDimensions
    case dimensionsTooLarge
    case invalidQuantity
    case invalidStackLimit
}

extension ManualEntryValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingDimensions:
            "Enter length, width, and height as numbers in inches."
        case .nonPositiveDimensions:
            "Every dimension must be greater than zero."
        case .dimensionsTooLarge:
            "Every dimension must be 480 inches (40 ft) or less."
        case .invalidQuantity:
            "Quantity must be between 1 and 999."
        case .invalidStackLimit:
            "Maximum stack layers must be between 2 and 20."
        }
    }
}

struct ManualEntryPreview: Equatable {
    let perItemFootprintSquareFeet: Double
    let totalFootprintSquareFeet: Double
    let totalCubicFeet: Double
}

struct ManualEntrySubmission {
    let name: String
    let quantity: Int
    let dimensions: ItemDimensions
    let stackability: ItemStackability
    let orientationPolicy: ItemOrientationPolicy
}

struct ManualEntryDraft {
    static let maximumDimensionInches = 480.0

    var name = ""
    var quantity = 1
    var lengthInches = ""
    var widthInches = ""
    var heightInches = ""
    var isStackable = false
    var maxStackLayers = 2
    var mayRotate = false

    var hasDimensionInput: Bool {
        !lengthInches.isEmpty || !widthInches.isEmpty || !heightInches.isEmpty
    }

    var preview: ManualEntryPreview? {
        guard let submission = try? validatedSubmission() else {
            return nil
        }

        return ManualEntryPreview(
            perItemFootprintSquareFeet: submission.dimensions.footprintSquareFeet,
            totalFootprintSquareFeet: submission.dimensions.footprintSquareFeet * Double(quantity),
            totalCubicFeet: submission.dimensions.cubicFeet * Double(quantity)
        )
    }

    var canSave: Bool {
        (try? validatedSubmission()) != nil
    }

    var validationMessage: String? {
        do {
            _ = try validatedSubmission()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func validatedSubmission() throws -> ManualEntrySubmission {
        guard let length = parseDimension(lengthInches),
              let width = parseDimension(widthInches),
              let height = parseDimension(heightInches)
        else {
            throw ManualEntryValidationError.missingDimensions
        }

        guard length.isFinite, width.isFinite, height.isFinite,
              length > 0, width > 0, height > 0
        else {
            throw ManualEntryValidationError.nonPositiveDimensions
        }

        guard length <= Self.maximumDimensionInches,
              width <= Self.maximumDimensionInches,
              height <= Self.maximumDimensionInches
        else {
            throw ManualEntryValidationError.dimensionsTooLarge
        }

        guard (1 ... 999).contains(quantity) else {
            throw ManualEntryValidationError.invalidQuantity
        }

        if isStackable, !(2 ... 20).contains(maxStackLayers) {
            throw ManualEntryValidationError.invalidStackLimit
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManualEntrySubmission(
            name: trimmedName.isEmpty ? "Manual item" : trimmedName,
            quantity: quantity,
            dimensions: try ItemDimensions(
                lengthInches: length,
                widthInches: width,
                heightInches: height
            ),
            stackability: isStackable
                ? .stackable(maxLayers: maxStackLayers)
                : .notStackable,
            orientationPolicy: mayRotate ? .mayRotate : .keepUpright
        )
    }

    @MainActor
    func save(to appModel: AppModel) throws {
        let submission = try validatedSubmission()
        appModel.addItem(
            name: submission.name,
            estimate: MeasurementEstimate(
                lengthMeters: submission.dimensions.lengthInches / 39.370_078_740_157_48,
                widthMeters: submission.dimensions.widthInches / 39.370_078_740_157_48,
                heightMeters: submission.dimensions.heightInches / 39.370_078_740_157_48,
                confidence: .high,
                sampleCount: 0,
                frameCount: 0
            ),
            quantity: submission.quantity,
            stackability: submission.stackability,
            orientationPolicy: submission.orientationPolicy
        )
    }

    private func parseDimension(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct ManualEntryView: View {
    private enum Field: Hashable {
        case name
        case length
        case width
        case height
    }

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ManualEntryDraft()
    @State private var saveError: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Item name", text: $draft.name)
                        .focused($focusedField, equals: .name)
                        .textInputAutocapitalization(.words)
                    Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1 ... 999)
                }

                Section {
                    dimensionField("Length", text: $draft.lengthInches, field: .length)
                    dimensionField("Width", text: $draft.widthInches, field: .width)
                    dimensionField("Height", text: $draft.heightInches, field: .height)

                    if draft.hasDimensionInput,
                       let message = draft.validationMessage,
                       draft.preview == nil
                    {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Dimensions")
                } footer: {
                    Text("Enter the outside measurements in inches. Decimals are okay; for example, use 24.5 for 24½ inches.")
                }

                if let preview = draft.preview {
                    Section("Space preview") {
                        LabeledContent(
                            "Each item footprint",
                            value: squareFeet(preview.perItemFootprintSquareFeet)
                        )
                        if draft.quantity > 1 {
                            LabeledContent(
                                "Total footprint",
                                value: squareFeet(preview.totalFootprintSquareFeet)
                            )
                        }
                        LabeledContent(
                            "Total volume",
                            value: cubicFeet(preview.totalCubicFeet)
                        )
                    }
                }

                Section {
                    Toggle("Safe to stack", isOn: $draft.isStackable)
                    if draft.isStackable {
                        Stepper(
                            "Maximum layers: \(draft.maxStackLayers)",
                            value: $draft.maxStackLayers,
                            in: 2 ... 20
                        )
                    }
                } footer: {
                    Text("Only enable stacking when the item can safely carry the weight above it.")
                }

                Section {
                    Toggle("Safe to turn on its side", isOn: $draft.mayRotate)
                } footer: {
                    Text("Leave this off for liquids, plants, appliances, and fragile or upright-only furniture.")
                }

                if let saveError {
                    Section {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Enter dimensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
    }

    private func dimensionField(
        _ title: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: field)
                    .frame(minWidth: 80)
                    .accessibilityLabel("\(title) in inches")
                Text("in")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        do {
            try draft.save(to: appModel)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func squareFeet(_ value: Double) -> String {
        String(format: "%.1f sq ft", value)
    }

    private func cubicFeet(_ value: Double) -> String {
        String(format: "%.1f cu ft", value)
    }
}
