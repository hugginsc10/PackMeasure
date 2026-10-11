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

    private(set) var inputUnit: MeasurementInputUnit
    var name = ""
    var quantity = 1
    var lengthText = ""
    var widthText = ""
    var heightText = ""
    var isStackable = false
    var maxStackLayers = 2
    var mayRotate = false

    init(inputUnit: MeasurementInputUnit = .inches) {
        self.inputUnit = inputUnit
    }

    // Preserve the existing inches-based draft API. The form binds to the
    // selected-unit text instead, so these aliases always retain their meaning.
    var lengthInches: String {
        get { convertedText(lengthText, from: inputUnit, to: .inches) }
        set { lengthText = convertedText(newValue, from: .inches, to: inputUnit) }
    }
    var widthInches: String {
        get { convertedText(widthText, from: inputUnit, to: .inches) }
        set { widthText = convertedText(newValue, from: .inches, to: inputUnit) }
    }
    var heightInches: String {
        get { convertedText(heightText, from: inputUnit, to: .inches) }
        set { heightText = convertedText(newValue, from: .inches, to: inputUnit) }
    }

    mutating func changeInputUnit(to unit: MeasurementInputUnit) {
        guard unit != inputUnit else { return }
        lengthText = convertedText(lengthText, from: inputUnit, to: unit)
        widthText = convertedText(widthText, from: inputUnit, to: unit)
        heightText = convertedText(heightText, from: inputUnit, to: unit)
        inputUnit = unit
    }

    private var maximumDimensionInInputUnit: Double {
        inputUnit == .inches ? Self.maximumDimensionInches
            : MeasurementInputUnit.inches.converted(value: Self.maximumDimensionInches, to: inputUnit)
    }

    var hasDimensionInput: Bool {
        !lengthText.isEmpty || !widthText.isEmpty || !heightText.isEmpty
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
        } catch ManualEntryValidationError.missingDimensions {
            return "Enter length, width, and height as numbers in \(inputUnit.title.lowercased())."
        } catch ManualEntryValidationError.dimensionsTooLarge {
            let maximum = String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), maximumDimensionInInputUnit)
            return "Every dimension must be \(maximum) \(inputUnit.symbol) or less."
        } catch {
            return error.localizedDescription
        }
    }

    func validatedSubmission() throws -> ManualEntrySubmission {
        guard let length = parseDimension(lengthText),
              let width = parseDimension(widthText),
              let height = parseDimension(heightText)
        else {
            throw ManualEntryValidationError.missingDimensions
        }

        guard length.isFinite, width.isFinite, height.isFinite,
              length > 0, width > 0, height > 0
        else {
            throw ManualEntryValidationError.nonPositiveDimensions
        }

        guard length <= maximumDimensionInInputUnit,
              width <= maximumDimensionInInputUnit,
              height <= maximumDimensionInInputUnit
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
                lengthInches: inputUnit == .inches ? length : inputUnit.converted(value: length, to: .inches),
                widthInches: inputUnit == .inches ? width : inputUnit.converted(value: width, to: .inches),
                heightInches: inputUnit == .inches ? height : inputUnit.converted(value: height, to: .inches)
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

    private func convertedText(_ text: String, from unit: MeasurementInputUnit, to destination: MeasurementInputUnit) -> String {
        guard unit != destination, let value = parseDimension(text), value.isFinite else { return text }
        let converted = unit.converted(value: value, to: destination)
        guard converted.isFinite else { return text }
        // Avoid exposing floating-point tails while retaining far more precision
        // than measurement input needs. Blank/invalid fields remain editable.
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), converted)
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
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ManualEntryDraft()
    @State private var appliedPreferredInputUnit = false
    @State private var saveError: String?
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        MeasureEyebrow(text: "Manual measurement")
                        Text("Add an item.").font(.title2.bold())
                    }.padding(.vertical, 8)
                }.listRowBackground(MeasureStyle.panel)
                Section("Item") {
                    TextField("Item name", text: $draft.name)
                        .focused($focusedField, equals: .name)
                        .textInputAutocapitalization(.words)
                    Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1 ... 999)
                }

                Section {
                    Picker("Input units", selection: Binding(
                        get: { draft.inputUnit }, set: { draft.changeInputUnit(to: $0) }
                    )) {
                        ForEach(MeasurementInputUnit.allCases, id: \.self) { unit in
                            Text(unit.title).tag(unit)
                        }
                    }.pickerStyle(.segmented)
                    dimensionField("Length", text: $draft.lengthText, field: .length)
                    dimensionField("Width", text: $draft.widthText, field: .width)
                    dimensionField("Height", text: $draft.heightText, field: .height)

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
                    Text(draft.inputUnit == .inches
                         ? "Enter the outside measurements in inches. Decimals are okay; for example, use 24.5 for 24½ inches."
                         : "Enter the outside measurements in centimeters. Decimals are okay; for example, use 62.2 cm.")
                }

                if let preview = draft.preview {
                    Section("Space preview") {
                        LabeledContent(
                            "Each item footprint",
                            value: preferences.units.areaFromSquareFeet(preview.perItemFootprintSquareFeet)
                        )
                        if draft.quantity > 1 {
                            LabeledContent(
                                "Total footprint",
                                value: preferences.units.areaFromSquareFeet(preview.totalFootprintSquareFeet)
                            )
                        }
                        LabeledContent(
                            "Total volume",
                            value: preferences.units.volumeFromCubicFeet(preview.totalCubicFeet, imperialDecimalPlaces: 1, metricDecimalPlaces: 3)
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
                }.listRowBackground(MeasureStyle.panel)
            }
            .measureScreen()
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
        .onAppear {
            guard !appliedPreferredInputUnit else { return }
            draft.changeInputUnit(to: preferences.units.inputUnit)
            appliedPreferredInputUnit = true
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
                    .accessibilityLabel("\(title) in \(draft.inputUnit.title.lowercased())")
                Text(draft.inputUnit.symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        do {
            try draft.save(to: appModel)
            dismiss()
        } catch {
            saveError = draft.validationMessage ?? error.localizedDescription
        }
    }
}
