import SwiftUI

struct HomeView: View {
    private enum Tab: Hashable {
        case measure
        case rooms
        case load
        case settings
    }

    @Environment(AppModel.self) private var appModel
    @Environment(AppPreferences.self) private var preferences
    @State private var selectedTab: Tab = .measure
    @State private var manualEntryPresented = false

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What are you measuring?")
                                .font(.title2.bold())
                            Text("Choose a room, a small space, or an item.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                        if appModel.inventoryLoadFailed {
                            InventoryRecoveryNotice()
                        }
                        NavigationLink {
                            RoomMeasurementView()
                        } label: {
                            MeasureActionLabel(title: "Measure a room", subtitle: "Scan walls and explore the floorplan.", symbol: "viewfinder")
                        }.buttonStyle(.plain).accessibilityIdentifier("home-measure-room")
                        NavigationLink {
                            InteriorLibraryView()
                        } label: {
                            MeasureActionLabel(title: "Drawer or cabinet", subtitle: "Measure the inside and plan an insert.", symbol: "square.dashed.inset.filled")
                        }.buttonStyle(.plain).accessibilityIdentifier("home-measure-interior")
                        Button { appModel.showingScanner = true } label: {
                            MeasureActionLabel(title: "Scan an item", subtitle: "Boxes, furniture, and moving inventory.", symbol: "shippingbox")
                        }.buttonStyle(.plain).accessibilityIdentifier("home-measure-item")
                            .disabled(appModel.inventoryLoadFailed)
                        Button { manualEntryPresented = true } label: {
                            Label("Enter dimensions manually", systemImage: "ruler")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.bordered)
                            .disabled(appModel.inventoryLoadFailed)
                            .accessibilityIdentifier("home-manual-entry")
                        Divider().padding(.vertical, 6)
                        Button {
                            selectedTab = .load
                        } label: {
                            HStack {
                                Label("Your moving load", systemImage: "truck.box")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(appModel.inventoryLoadFailed ? "Unavailable" : "\(appModel.planningSummary.pieceCount) pieces")
                                    .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                            }.frame(minHeight: 48).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }.padding(20)
                }
                .measureScreen()
                .navigationTitle("PackMeasure").navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("Measure", systemImage: "viewfinder") }
            .tag(Tab.measure)
            NavigationStack { RoomMeasurementView() }
                .tabItem { Label("Rooms", systemImage: "square.split.2x2") }
                .tag(Tab.rooms)
            NavigationStack { PackingDashboardView(manualEntryPresented: $manualEntryPresented) }
                .tabItem { Label("Load", systemImage: "shippingbox") }
                .tag(Tab.load)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(MeasureStyle.accent)
        .toolbarBackground(MeasureStyle.background, for: .tabBar)
        .sheet(isPresented: Binding(get: { appModel.showingScanner }, set: { appModel.showingScanner = $0 })) {
            ScannerSheetView().environment(appModel).environment(preferences)
        }
        .sheet(isPresented: $manualEntryPresented) { ManualEntryView().environment(appModel).environment(preferences) }
        .alert("PackMeasure", isPresented: Binding(get: { appModel.bannerMessage != nil }, set: { if !$0 { appModel.bannerMessage = nil } })) {
            Button("OK", role: .cancel) { appModel.bannerMessage = nil }
        } message: { Text(appModel.bannerMessage ?? "") }
    }
}

private struct InventoryRecoveryNotice: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Saved inventory unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text("Your saved file has been kept. Adding, editing and deleting items is paused until it can be read.")
                .font(.subheadline)
            Button("Try reading inventory again") { appModel.loadIfNeeded() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inventory-retry")
        }
    }
}


private struct PackingDashboardView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppPreferences.self) private var preferences
    @Binding var manualEntryPresented: Bool
    @State private var assignedVehicleEditorPresented = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    MeasureEyebrow(text: "Move planning")
                    Text("Everything adds up.").font(.system(.title2, design: .rounded).bold())
                    Text("Build your inventory. Find the space you need.").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }.listRowBackground(MeasureStyle.panel)
            if appModel.inventoryLoadFailed {
                Section { InventoryRecoveryNotice() }.listRowBackground(MeasureStyle.panel)
            } else {
                spaceNeededSection.listRowBackground(MeasureStyle.panel)
                loadMixSection.listRowBackground(MeasureStyle.panel)
                vehicleSection.listRowBackground(MeasureStyle.panel)
                assignedVehicleSection.listRowBackground(MeasureStyle.panel)
                inventorySection.listRowBackground(MeasureStyle.panel)
            }
            planningDisclaimerSection.listRowBackground(Color.clear)
        }
        .navigationTitle("Your load")
        .measureScreen()
        .sheet(isPresented: $assignedVehicleEditorPresented) {
            AssignedVehicleEditorView(existing: appModel.assignedVehicle)
                .environment(appModel)
                .environment(preferences)
        }
        .toolbar {
            if !appModel.items.isEmpty && !appModel.inventoryLoadFailed {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(
                        item: appModel.shareText(units: preferences.units),
                        preview: SharePreview("PackMeasure Moving Load")
                    ) {
                        Label("Share load plan", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("share-load-plan")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            entryActions
        }
    }

    private var loadMixSelection: Binding<PackingLoadMix> {
        Binding(
            get: { appModel.loadMix },
            set: { appModel.setLoadMix($0) }
        )
    }

    private var summary: PackingSummary {
        appModel.planningSummary
    }

    private var recommendation: PackingVehicleRecommendation {
        appModel.vehicleRecommendation
    }

    private var spaceNeededSection: some View {
        Section {
            HStack(spacing: 12) {
                SummaryTile(
                    title: "Cargo floor",
                    value: preferences.units.areaFromSquareFeet(summary.requiredFloorSquareFeet),
                    systemImage: "square.dashed"
                )
                SummaryTile(
                    title: "Cargo volume",
                    value: preferences.units.volumeFromCubicFeet(summary.requiredCubicFeet),
                    systemImage: "shippingbox"
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            LabeledContent("Saved pieces", value: "\(summary.pieceCount)")
            LabeledContent(
                "Unstacked footprint",
                value: preferences.units.areaFromSquareFeet(summary.rawFootprintSquareFeet)
            )
        } header: {
            Text("Space needed")
        } footer: {
            Text("Cargo floor accounts for your stack settings and includes a \(allowancePercent)% packing allowance.")
        }
    }

    private var loadMixSection: some View {
        Section {
            Picker("Load mix", selection: loadMixSelection) {
                ForEach(PackingLoadMix.allCases, id: \.self) { mix in
                    Text(mix.displayName).tag(mix)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("What are you moving?")
        } footer: {
            Text("This adjusts how much of a vehicle's advertised cargo volume is realistically usable.")
        }
    }

    @ViewBuilder
    private var vehicleSection: some View {
        Section("Recommended vehicle") {
            if appModel.items.isEmpty {
                ContentUnavailableView(
                    "Add your first item",
                    systemImage: "shippingbox",
                    description: Text("Scan it or enter its dimensions to build your truck or van estimate.")
                )
            } else if let vehicle = recommendation.vehicle {
                VehicleRecommendationView(
                    vehicle: vehicle,
                    recommendation: recommendation
                )
            } else {
                Label(PackingMeasurementCopy.recommendation(recommendation, units: preferences.units), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                ForEach(Array(recommendation.rejections.suffix(3).enumerated()), id: \.offset) { _, rejection in
                    Text(PackingMeasurementCopy.rejection(rejection, units: preferences.units))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if appModel.ignoredPackingItemCount > 0 {
                let count = appModel.ignoredPackingItemCount
                Label(
                    count == 1
                        ? "1 saved item could not be included because its dimensions are invalid."
                        : "\(count) saved items could not be included because their dimensions are invalid.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var assignedVehicleSection: some View {
        Section("Assigned vehicle check") {
            if let evaluation = appModel.assignedVehicleEvaluation {
                AssignedVehicleEvaluationView(evaluation: evaluation)
                Button("Edit assigned vehicle") {
                    assignedVehicleEditorPresented = true
                }
                .accessibilityIdentifier("assigned-vehicle-edit")
                Button("Clear assigned vehicle", role: .destructive) {
                    appModel.setAssignedVehicle(nil)
                }
                .accessibilityIdentifier("assigned-vehicle-clear")
            } else {
                Text("Have a specific rental truck or van lined up? Enter its inside cargo bay and rear-door opening to check it against your saved load.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    assignedVehicleEditorPresented = true
                } label: {
                    Label("Check a specific vehicle", systemImage: "checkmark.shield")
                }
                .accessibilityIdentifier("assigned-vehicle-configure")
            }
        }
    }

    @ViewBuilder
    private var inventorySection: some View {
        Section("Saved items") {
            if appModel.items.isEmpty {
                Text("Nothing saved yet. Scan or enter each box, piece of furniture, or loose object you plan to move.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.items) { item in
                    NavigationLink {
                        ItemPackingEditorView(item: item)
                            .environment(appModel)
                    } label: {
                        ItemRow(item: item)
                    }
                }
                .onDelete { offsets in appModel.deleteItems(at: offsets) }
            }
        }
    }

    private var planningDisclaimerSection: some View {
        Section {
            Label {
                Text("Planning estimate only. Scans, usable volume, cargo bays, and door openings vary. Verify the actual vehicle and its rear-door clearance before booking or loading.")
            } icon: {
                Image(systemName: "ruler")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var entryActions: some View {
        HStack(spacing: 12) {
            Button { appModel.showingScanner = true } label: {
                Label("Scan item", systemImage: "viewfinder")
            }.buttonStyle(MeasurePrimaryButton())
            Button { manualEntryPresented = true } label: {
                Image(systemName: "ruler").font(.title3).frame(width: 52, height: 52)
                    .background(MeasureStyle.panel, in: RoundedRectangle(cornerRadius: 18))
            }.accessibilityLabel("Enter dimensions manually")
        }.padding(.horizontal, 20).padding(.vertical, 8).background(MeasureStyle.background)
            .disabled(appModel.inventoryLoadFailed)
    }

    private var allowancePercent: Int {
        Int((summary.packingAllowanceFraction * 100).rounded())
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).bold()).monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(MeasureStyle.panel, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(MeasureStyle.line, lineWidth: 1))
    }
}

private struct VehicleRecommendationView: View {
    @Environment(AppPreferences.self) private var preferences
    let vehicle: PackingVehicleProfile
    let recommendation: PackingVehicleRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(vehicle.name, systemImage: "truck.box.fill")
                .font(.headline)
                .foregroundStyle(.tint)

            if let interior = vehicle.interiorDimensions {
                DetailLine(
                    title: "Interior",
                    value: dimensionString(interior)
                )
            }
            if let door = vehicle.rearDoorOpening {
                DetailLine(
                    title: "Rear door",
                    value: [door.widthInches, door.heightInches].map { preferences.units.length(meters: $0 * 0.0254) }.joined(separator: " × ")
                )
            }
            DetailLine(
                title: "Usable volume",
                value: preferences.units.volumeFromCubicFeet(vehicle.usableCargoVolumeCubicFeet)
            )

            Text(PackingMeasurementCopy.recommendation(recommendation, units: preferences.units))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !recommendation.rejections.isEmpty {
                DisclosureGroup("Why smaller options were ruled out") {
                    ForEach(Array(recommendation.rejections.enumerated()), id: \.offset) { _, rejection in
                        Text(PackingMeasurementCopy.rejection(rejection, units: preferences.units))
                            .font(.footnote)
                            .padding(.vertical, 3)
                    }
                }
                .font(.footnote.weight(.semibold))
            }

            if !vehicle.notes.isEmpty {
                Label(vehicle.notes, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func dimensionString(_ dimensions: ItemDimensions) -> String {
        [dimensions.lengthInches, dimensions.widthInches, dimensions.heightInches]
            .map { preferences.units.length(meters: $0 * 0.0254) }.joined(separator: " × ")
    }
}

private struct DetailLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct ItemRow: View {
    @Environment(AppPreferences.self) private var preferences
    let item: MeasuredItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(item.name)
                    .font(.headline)
                Spacer()
                Text("×\(item.quantity)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(
                "\(preferences.units.length(meters: item.lengthMeters)) × " +
                "\(preferences.units.length(meters: item.widthMeters)) × " +
                "\(preferences.units.length(meters: item.heightMeters))"
            )
            .font(.subheadline)

            HStack(spacing: 8) {
                Label(stackDescription, systemImage: "square.3.layers.3d")
                Label(orientationDescription, systemImage: "rotate.3d")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(SavedMeasurementCopy.qualitySummary(for: item))
                .font(.caption2)
                .foregroundStyle(item.confidence == .low ? .orange : .secondary)
        }
        .padding(.vertical, 3)
    }

    private var stackDescription: String {
        switch item.stackability {
        case .notStackable:
            "No stacking"
        case let .stackable(maxLayers):
            "Stack \(maxLayers) high"
        }
    }

    private var orientationDescription: String {
        item.orientationPolicy == .keepUpright ? "Upright" : "Can rotate"
    }
}

/// Render the planner's structured constraints in the selected display units.
/// The planner and its stored imperial policy remain unchanged.
enum PackingMeasurementCopy {
    static func rejection(_ rejection: PackingVehicleRejection, units: MeasurementUnits) -> String {
        switch rejection.constraint {
        case let .insufficientFloor(required, available):
            "\(rejection.vehicle.name) has \(units.areaFromSquareFeet(available)) of cargo floor, below the \(units.areaFromSquareFeet(required)) estimate."
        case let .insufficientVolume(required, available):
            "\(rejection.vehicle.name) has \(units.volumeFromCubicFeet(available)) of usable cargo volume, below the \(units.volumeFromCubicFeet(required)) estimate."
        default:
            rejection.reason
        }
    }

    static func recommendation(_ recommendation: PackingVehicleRecommendation, units: MeasurementUnits,
                               policy: PackingPolicy = .conservative) -> String {
        guard units != .inches else { return recommendation.reason }
        guard let vehicle = recommendation.vehicle else {
            guard let final = recommendation.rejections.last else { return recommendation.reason }
            return "No listed vehicle is suitable. \(rejection(final, units: units))"
        }
        let summary = recommendation.summary
        let allowance = Int((policy.packingAllowanceFraction * 100).rounded())
        let utilization = Int((vehicle.usableVolumeFraction * 100).rounded())
        return "\(vehicle.name) is the smallest listed profile that clears every item and its rear door with a \(units.preciseLength(millimeters: policy.clearanceMarginInches * 25.4)) fit buffer: \(units.areaFromSquareFeet(summary.requiredFloorSquareFeet)) of \(units.areaFromSquareFeet(vehicle.cargoFloorAreaSquareFeet ?? 0)) floor, and \(units.volumeFromCubicFeet(summary.requiredCubicFeet)) of \(units.volumeFromCubicFeet(vehicle.usableCargoVolumeCubicFeet)) usable cargo volume. Includes a \(allowance)% packing allowance and assumes \(utilization)% of advertised cargo volume is usable."
    }
}

enum SavedMeasurementCopy {
    static func qualitySummary(for item: MeasuredItem) -> String {
        if item.originalDimensions != nil {
            return "Dimensions edited manually · original dimensions preserved"
        }
        guard let angleCount = item.comparisonAngleCount,
              let agreementCount = item.comparisonAgreementCount,
              angleCount >= 2,
              agreementCount >= 2,
              agreementCount <= angleCount else {
            return "\(item.confidence.title) confidence"
        }

        let agreement = agreementCount == angleCount
            ? "\(angleCount)-angle agreement"
            : "\(agreementCount) of \(angleCount) angles agree"
        return "\(agreement) — approximate; verify tight clearances"
    }
}

private struct ItemPackingEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    let item: MeasuredItem

    @State private var name: String
    @State private var quantity: Int
    @State private var isStackable: Bool
    @State private var maxLayers: Int
    @State private var mayRotate: Bool
    @State private var editingDimensions = false
    @State private var restoringOriginalDimensions = false
    @State private var editingInputUnit: MeasurementInputUnit = .inches
    @State private var lengthText = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var initialLengthText = ""
    @State private var initialWidthText = ""
    @State private var initialHeightText = ""
    @State private var saveError: String?

    init(item: MeasuredItem) {
        self.item = item
        _name = State(initialValue: item.name)
        _quantity = State(initialValue: item.quantity)
        switch item.stackability {
        case .notStackable:
            _isStackable = State(initialValue: false)
            _maxLayers = State(initialValue: 2)
        case let .stackable(maxLayers):
            _isStackable = State(initialValue: true)
            _maxLayers = State(initialValue: max(2, maxLayers))
        }
        _mayRotate = State(initialValue: item.orientationPolicy == .mayRotate)
    }

    private var activeInputUnit: MeasurementInputUnit {
        editingDimensions ? editingInputUnit : preferences.units.inputUnit
    }

    private func formattedValue(_ meters: Double, unit: MeasurementInputUnit) -> String {
        String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), unit.value(fromMeters: meters))
    }

    var body: some View {
        Form {
            Group {
                Section("Item") {
                    TextField("Item name", text: $name)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1 ... 999)
                    LabeledContent(
                        "Measured size",
                        value: "\(preferences.units.length(meters: item.lengthMeters)) × \(preferences.units.length(meters: item.widthMeters)) × \(preferences.units.length(meters: item.heightMeters))"
                    )
                    .monospacedDigit()
                    if let original = item.originalDimensions {
                        LabeledContent(
                            "Original dimensions",
                            value: "\(preferences.units.length(meters: original.lengthMeters)) × \(preferences.units.length(meters: original.widthMeters)) × \(preferences.units.length(meters: original.heightMeters))"
                        )
                        .monospacedDigit()
                        Button("Restore original dimensions") {
                            let unit = activeInputUnit
                            editingInputUnit = unit
                            lengthText = formattedValue(original.lengthMeters, unit: unit)
                            widthText = formattedValue(original.widthMeters, unit: unit)
                            heightText = formattedValue(original.heightMeters, unit: unit)
                            restoringOriginalDimensions = true
                        }
                        .accessibilityIdentifier("item-restore-original-dimensions")
                    }
                    Toggle("Edit dimensions", isOn: $editingDimensions)
                        .accessibilityIdentifier("item-edit-dimensions")
                    if editingDimensions {
                        dimensionField("Length", text: $lengthText, identifier: "item-length")
                        dimensionField("Width", text: $widthText, identifier: "item-width")
                        dimensionField("Height", text: $heightText, identifier: "item-height")
                    }
                }

                Section {
                    Toggle("Safe to stack", isOn: $isStackable)
                    if isStackable {
                        Stepper("Maximum layers: \(maxLayers)", value: $maxLayers, in: 2 ... 20)
                    }
                } footer: {
                    Text("Only enable stacking when the item can safely carry the weight above it.")
                }

                Section {
                    Toggle("Safe to turn on its side", isOn: $mayRotate)
                } footer: {
                    Text("Leave this off for liquids, plants, appliances, and fragile or upright-only furniture.")
                }
            }
            .listRowBackground(MeasureStyle.panel)
        }
        .measureScreen()
        .navigationTitle("Packing details")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: editingDimensions) { _, isEditing in
            if isEditing && lengthText.isEmpty && widthText.isEmpty && heightText.isEmpty {
                let unit = preferences.units.inputUnit
                editingInputUnit = unit
                let l = formattedValue(item.lengthMeters, unit: unit)
                let w = formattedValue(item.widthMeters, unit: unit)
                let h = formattedValue(item.heightMeters, unit: unit)
                lengthText = l
                widthText = w
                heightText = h
                initialLengthText = l
                initialWidthText = w
                initialHeightText = h
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }
                .fontWeight(.semibold)
            }
        }
        .alert("Inventory not saved", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private func dimensionField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(
                    "0",
                    text: Binding(
                        get: { text.wrappedValue },
                        set: {
                            text.wrappedValue = $0
                            restoringOriginalDimensions = false
                        }
                    )
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 80)
                .accessibilityLabel("\(title) in \(activeInputUnit.title.lowercased())")
                .accessibilityIdentifier(identifier)
                Text(activeInputUnit.symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        var editedLength: Double?
        var editedWidth: Double?
        var editedHeight: Double?
        if editingDimensions && !restoringOriginalDimensions {
            let trimmedL = lengthText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedW = widthText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedH = heightText.trimmingCharacters(in: .whitespacesAndNewlines)
            func parse(_ text: String) -> Double? {
                Double(text.replacingOccurrences(of: ",", with: "."))
            }
            guard let l = parse(trimmedL),
                  let w = parse(trimmedW),
                  let h = parse(trimmedH),
                  l.isFinite, w.isFinite, h.isFinite, l > 0, w > 0, h > 0 else {
                saveError = "Enter positive length, width, and height in \(activeInputUnit.title.lowercased())."
                return
            }
            if trimmedL != initialLengthText || trimmedW != initialWidthText || trimmedH != initialHeightText {
                editedLength = trimmedL == initialLengthText ? item.lengthMeters : activeInputUnit.meters(from: l)
                editedWidth = trimmedW == initialWidthText ? item.widthMeters : activeInputUnit.meters(from: w)
                editedHeight = trimmedH == initialHeightText ? item.heightMeters : activeInputUnit.meters(from: h)
            }
        }
        if appModel.updateItem(
            id: item.id,
            name: name,
            quantity: quantity,
            stackability: isStackable
                ? .stackable(maxLayers: maxLayers)
                : .notStackable,
            orientationPolicy: mayRotate ? .mayRotate : .keepUpright,
            lengthMeters: editedLength,
            widthMeters: editedWidth,
            heightMeters: editedHeight,
            restoreOriginalDimensions: restoringOriginalDimensions
        ) {
            dismiss()
        } else {
            saveError = appModel.bannerMessage ?? "Enter valid dimensions within 40 ft (480 in) and try saving again."
            appModel.bannerMessage = nil
        }
    }
}

private struct AssignedVehicleEvaluationView: View {
    @Environment(AppPreferences.self) private var preferences
    let evaluation: AssignedVehicleEvaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(evaluation.spec.name, systemImage: "truck.box")
                    .font(.headline)
                    .accessibilityIdentifier("assigned-vehicle-name")
                Spacer()
                Label(
                    evaluation.headline,
                    systemImage: evaluation.passesListedChecks ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(evaluation.passesListedChecks ? .green : .orange)
                .accessibilityIdentifier("assigned-vehicle-status")
            }

            if let interior = evaluation.spec.interiorDimensions {
                DetailLine(
                    title: "Interior (\(evaluation.spec.interiorProvenance.title))",
                    value: dimensionString(interior)
                )
                .accessibilityIdentifier("assigned-vehicle-interior-provenance")
            } else {
                DetailLine(
                    title: "Interior (\(evaluation.spec.interiorProvenance.title))",
                    value: "Unmeasured"
                )
                .accessibilityIdentifier("assigned-vehicle-interior-provenance")
            }

            if let door = evaluation.spec.rearDoorOpening {
                DetailLine(
                    title: "Rear door (\(evaluation.spec.doorProvenance.title))",
                    value: [door.widthInches, door.heightInches]
                        .map { preferences.units.length(meters: $0 * 0.0254) }
                        .joined(separator: " × ")
                )
                .accessibilityIdentifier("assigned-vehicle-door-provenance")
            } else {
                DetailLine(
                    title: "Rear door (\(evaluation.spec.doorProvenance.title))",
                    value: "Unmeasured"
                )
                .accessibilityIdentifier("assigned-vehicle-door-provenance")
            }

            DetailLine(
                title: "Cargo floor",
                value: "\(preferences.units.areaFromSquareFeet(evaluation.summary.requiredFloorSquareFeet)) of \(preferences.units.areaFromSquareFeet(evaluation.vehicle.cargoFloorAreaSquareFeet ?? 0))"
            )
            DetailLine(
                title: "Usable volume",
                value: "\(preferences.units.volumeFromCubicFeet(evaluation.summary.requiredCubicFeet)) of \(preferences.units.volumeFromCubicFeet(evaluation.vehicle.usableCargoVolumeCubicFeet))"
            )

            if !evaluation.rejections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(evaluation.rejections.enumerated()), id: \.offset) { index, rejection in
                        Label(
                            PackingMeasurementCopy.rejection(rejection, units: preferences.units),
                            systemImage: "xmark.octagon.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("assigned-vehicle-rejection-\(index)")
                    }
                }
            }

            Label(evaluation.unverifiedConstraintsNote, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("assigned-vehicle-unverified-note")
        }
        .padding(.vertical, 4)
    }

    private func dimensionString(_ dimensions: ItemDimensions) -> String {
        [dimensions.lengthInches, dimensions.widthInches, dimensions.heightInches]
            .map { preferences.units.length(meters: $0 * 0.0254) }
            .joined(separator: " × ")
    }
}

private struct AssignedVehicleEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var inputUnit: MeasurementInputUnit
    @State private var interiorLengthText: String
    @State private var interiorWidthText: String
    @State private var interiorHeightText: String
    @State private var doorMeasured: Bool
    @State private var doorWidthText: String
    @State private var doorHeightText: String
    @State private var catalogInteriorDimensions: ItemDimensions?
    @State private var catalogInteriorSnapshot: [String]?
    @State private var catalogCargoVolumeCubicFeet: Double?
    @State private var catalogDoorOpening: DoorOpening?
    @State private var catalogDoorSnapshot: [String]?
    @State private var validationMessage: String?

    init(existing: AssignedVehicleSpec?) {
        let defaultUnit: MeasurementInputUnit = .inches
        _inputUnit = State(initialValue: defaultUnit)
        if let existing {
            _name = State(initialValue: existing.name)
            if let interior = existing.interiorDimensions {
                let l = Self.formatInches(interior.lengthInches, unit: defaultUnit)
                let w = Self.formatInches(interior.widthInches, unit: defaultUnit)
                let h = Self.formatInches(interior.heightInches, unit: defaultUnit)
                _interiorLengthText = State(initialValue: l)
                _interiorWidthText = State(initialValue: w)
                _interiorHeightText = State(initialValue: h)
                if existing.interiorProvenance == .catalog {
                    _catalogInteriorDimensions = State(initialValue: interior)
                    _catalogInteriorSnapshot = State(initialValue: [l, w, h])
                    _catalogCargoVolumeCubicFeet = State(initialValue: existing.catalogCargoVolumeCubicFeet)
                } else {
                    _catalogInteriorDimensions = State(initialValue: nil)
                    _catalogInteriorSnapshot = State(initialValue: nil)
                    _catalogCargoVolumeCubicFeet = State(initialValue: nil)
                }
            } else {
                _interiorLengthText = State(initialValue: "")
                _interiorWidthText = State(initialValue: "")
                _interiorHeightText = State(initialValue: "")
                _catalogInteriorDimensions = State(initialValue: nil)
                _catalogInteriorSnapshot = State(initialValue: nil)
                _catalogCargoVolumeCubicFeet = State(initialValue: nil)
            }
            if let door = existing.rearDoorOpening {
                let dw = Self.formatInches(door.widthInches, unit: defaultUnit)
                let dh = Self.formatInches(door.heightInches, unit: defaultUnit)
                _doorMeasured = State(initialValue: true)
                _doorWidthText = State(initialValue: dw)
                _doorHeightText = State(initialValue: dh)
                if existing.doorProvenance == .catalog {
                    _catalogDoorOpening = State(initialValue: door)
                    _catalogDoorSnapshot = State(initialValue: [dw, dh])
                } else {
                    _catalogDoorOpening = State(initialValue: nil)
                    _catalogDoorSnapshot = State(initialValue: nil)
                }
            } else {
                _doorMeasured = State(initialValue: false)
                _doorWidthText = State(initialValue: "")
                _doorHeightText = State(initialValue: "")
                _catalogDoorOpening = State(initialValue: nil)
                _catalogDoorSnapshot = State(initialValue: nil)
            }
        } else {
            _name = State(initialValue: "")
            _interiorLengthText = State(initialValue: "")
            _interiorWidthText = State(initialValue: "")
            _interiorHeightText = State(initialValue: "")
            _doorMeasured = State(initialValue: true)
            _doorWidthText = State(initialValue: "")
            _doorHeightText = State(initialValue: "")
            _catalogInteriorDimensions = State(initialValue: nil)
            _catalogInteriorSnapshot = State(initialValue: nil)
            _catalogCargoVolumeCubicFeet = State(initialValue: nil)
            _catalogDoorOpening = State(initialValue: nil)
            _catalogDoorSnapshot = State(initialValue: nil)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Menu {
                            ForEach(PackingVehicleCatalog.conservativeMovingFleet(loadMix: appModel.loadMix)) { profile in
                                if profile.interiorDimensions != nil {
                                    Button(profile.name) {
                                        applyCatalogProfile(profile)
                                    }
                                }
                            }
                        } label: {
                            Label("Pre-fill from catalog profile", systemImage: "truck.box")
                        }
                        .accessibilityIdentifier("assigned-vehicle-catalog-menu")

                        TextField("Vehicle name (e.g., Rented 10' box truck)", text: $name)
                            .accessibilityIdentifier("assigned-vehicle-name-field")

                        Picker(
                            "Input unit",
                            selection: Binding(
                                get: { inputUnit },
                                set: { changeInputUnit(to: $0) }
                            )
                        ) {
                            ForEach(MeasurementInputUnit.allCases, id: \.self) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                    } header: {
                        Text("Vehicle")
                    } footer: {
                        Text("Catalog values and entered measurements stay labeled separately so you can tell what was measured on the lot.")
                    }

                    Section("Inside cargo bay") {
                        dimensionField("Length", text: $interiorLengthText, identifier: "assigned-vehicle-interior-length")
                        dimensionField("Width", text: $interiorWidthText, identifier: "assigned-vehicle-interior-width")
                        dimensionField("Height", text: $interiorHeightText, identifier: "assigned-vehicle-interior-height")
                    }

                    Section {
                        Toggle("Rear door opening measured", isOn: $doorMeasured)
                            .accessibilityIdentifier("assigned-vehicle-door-measured")
                        if doorMeasured {
                            dimensionField("Opening width", text: $doorWidthText, identifier: "assigned-vehicle-door-width")
                            dimensionField("Opening height", text: $doorHeightText, identifier: "assigned-vehicle-door-height")
                        }
                    } header: {
                        Text("Rear door opening")
                    } footer: {
                        Text("Roll-up and hinged doors are often narrower or lower than the cargo bay. Unmeasured doors cannot pass the vehicle check.")
                    }
                }
                .listRowBackground(MeasureStyle.panel)
            }
            .measureScreen()
            .navigationTitle("Assigned vehicle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("assigned-vehicle-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("assigned-vehicle-save")
                }
            }
            .alert(
                "Vehicle not saved",
                isPresented: Binding(
                    get: { validationMessage != nil },
                    set: { if !$0 { validationMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { validationMessage = nil }
            } message: {
                Text(validationMessage ?? "")
            }
        }
    }

    private func dimensionField(_ title: String, text: Binding<String>, identifier: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 80)
                    .accessibilityLabel("\(title) in \(inputUnit.title.lowercased())")
                    .accessibilityIdentifier(identifier)
                Text(inputUnit.symbol)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func applyCatalogProfile(_ profile: PackingVehicleProfile) {
        let spec = AssignedVehicleSpec.fromCatalog(profile)
        name = spec.name
        if let interior = spec.interiorDimensions {
            let l = Self.formatInches(interior.lengthInches, unit: inputUnit)
            let w = Self.formatInches(interior.widthInches, unit: inputUnit)
            let h = Self.formatInches(interior.heightInches, unit: inputUnit)
            interiorLengthText = l
            interiorWidthText = w
            interiorHeightText = h
            catalogInteriorDimensions = interior
            catalogInteriorSnapshot = [l, w, h]
            catalogCargoVolumeCubicFeet = spec.catalogCargoVolumeCubicFeet
        }
        if let door = spec.rearDoorOpening {
            let dw = Self.formatInches(door.widthInches, unit: inputUnit)
            let dh = Self.formatInches(door.heightInches, unit: inputUnit)
            doorMeasured = true
            doorWidthText = dw
            doorHeightText = dh
            catalogDoorOpening = door
            catalogDoorSnapshot = [dw, dh]
        } else {
            doorMeasured = false
            doorWidthText = ""
            doorHeightText = ""
            catalogDoorOpening = nil
            catalogDoorSnapshot = nil
        }
    }

    private func changeInputUnit(to newUnit: MeasurementInputUnit) {
        guard newUnit != inputUnit else { return }
        let oldUnit = inputUnit

        let trimmedInterior = [
            interiorLengthText.trimmingCharacters(in: .whitespacesAndNewlines),
            interiorWidthText.trimmingCharacters(in: .whitespacesAndNewlines),
            interiorHeightText.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let catalogInteriorDimensions,
           let snapshot = catalogInteriorSnapshot {
            let newL = Self.formatInches(catalogInteriorDimensions.lengthInches, unit: newUnit)
            let newW = Self.formatInches(catalogInteriorDimensions.widthInches, unit: newUnit)
            let newH = Self.formatInches(catalogInteriorDimensions.heightInches, unit: newUnit)
            interiorLengthText = trimmedInterior[0] == snapshot[0]
                ? newL
                : Self.convertedText(interiorLengthText, from: oldUnit, to: newUnit)
            interiorWidthText = trimmedInterior[1] == snapshot[1]
                ? newW
                : Self.convertedText(interiorWidthText, from: oldUnit, to: newUnit)
            interiorHeightText = trimmedInterior[2] == snapshot[2]
                ? newH
                : Self.convertedText(interiorHeightText, from: oldUnit, to: newUnit)
            catalogInteriorSnapshot = [newL, newW, newH]
        } else {
            interiorLengthText = Self.convertedText(interiorLengthText, from: oldUnit, to: newUnit)
            interiorWidthText = Self.convertedText(interiorWidthText, from: oldUnit, to: newUnit)
            interiorHeightText = Self.convertedText(interiorHeightText, from: oldUnit, to: newUnit)
        }

        let trimmedDoor = [
            doorWidthText.trimmingCharacters(in: .whitespacesAndNewlines),
            doorHeightText.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let catalogDoorOpening,
           let snapshot = catalogDoorSnapshot {
            let newDW = Self.formatInches(catalogDoorOpening.widthInches, unit: newUnit)
            let newDH = Self.formatInches(catalogDoorOpening.heightInches, unit: newUnit)
            doorWidthText = trimmedDoor[0] == snapshot[0]
                ? newDW
                : Self.convertedText(doorWidthText, from: oldUnit, to: newUnit)
            doorHeightText = trimmedDoor[1] == snapshot[1]
                ? newDH
                : Self.convertedText(doorHeightText, from: oldUnit, to: newUnit)
            catalogDoorSnapshot = [newDW, newDH]
        } else {
            doorWidthText = Self.convertedText(doorWidthText, from: oldUnit, to: newUnit)
            doorHeightText = Self.convertedText(doorHeightText, from: oldUnit, to: newUnit)
        }

        inputUnit = newUnit
    }

    private func save() {
        let trimmedL = interiorLengthText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedW = interiorWidthText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedH = interiorHeightText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedL = Self.parsePositive(trimmedL),
              let parsedW = Self.parsePositive(trimmedW),
              let parsedH = Self.parsePositive(trimmedH) else {
            validationMessage = "Enter positive interior length, width, and height in \(inputUnit.title.lowercased())."
            return
        }

        let interiorDimensions: ItemDimensions
        let interiorProvenance: PackingDimensionProvenance
        if let catalogInteriorDimensions,
           let catalogInteriorSnapshot,
           [trimmedL, trimmedW, trimmedH] == catalogInteriorSnapshot {
            interiorDimensions = catalogInteriorDimensions
            interiorProvenance = .catalog
        } else {
            let lengthInches = (catalogInteriorDimensions != nil && trimmedL == catalogInteriorSnapshot?[0])
                ? catalogInteriorDimensions!.lengthInches
                : inputUnit.meters(from: parsedL) / 0.0254
            let widthInches = (catalogInteriorDimensions != nil && trimmedW == catalogInteriorSnapshot?[1])
                ? catalogInteriorDimensions!.widthInches
                : inputUnit.meters(from: parsedW) / 0.0254
            let heightInches = (catalogInteriorDimensions != nil && trimmedH == catalogInteriorSnapshot?[2])
                ? catalogInteriorDimensions!.heightInches
                : inputUnit.meters(from: parsedH) / 0.0254
            guard lengthInches <= ManualEntryDraft.maximumDimensionInches,
                  widthInches <= ManualEntryDraft.maximumDimensionInches,
                  heightInches <= ManualEntryDraft.maximumDimensionInches,
                  let dimensions = try? ItemDimensions(
                      lengthInches: lengthInches,
                      widthInches: widthInches,
                      heightInches: heightInches
                  ) else {
                validationMessage = "Enter interior dimensions within 40 ft (480 in)."
                return
            }
            interiorDimensions = dimensions
            interiorProvenance = .measured
        }

        let rearDoorOpening: DoorOpening?
        let doorProvenance: PackingDimensionProvenance
        if doorMeasured {
            let trimmedDW = doorWidthText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedDH = doorHeightText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedDW = Self.parsePositive(trimmedDW),
                  let parsedDH = Self.parsePositive(trimmedDH) else {
                validationMessage = "Enter positive rear-door width and height, or turn off Rear door opening measured."
                return
            }
            if let catalogDoorOpening,
               let catalogDoorSnapshot,
               [trimmedDW, trimmedDH] == catalogDoorSnapshot {
                rearDoorOpening = catalogDoorOpening
                doorProvenance = .catalog
            } else {
                let doorWidthInches = (catalogDoorOpening != nil && trimmedDW == catalogDoorSnapshot?[0])
                    ? catalogDoorOpening!.widthInches
                    : inputUnit.meters(from: parsedDW) / 0.0254
                let doorHeightInches = (catalogDoorOpening != nil && trimmedDH == catalogDoorSnapshot?[1])
                    ? catalogDoorOpening!.heightInches
                    : inputUnit.meters(from: parsedDH) / 0.0254
                guard doorWidthInches <= ManualEntryDraft.maximumDimensionInches,
                      doorHeightInches <= ManualEntryDraft.maximumDimensionInches,
                      let door = try? DoorOpening(
                          widthInches: doorWidthInches,
                          heightInches: doorHeightInches
                      ) else {
                    validationMessage = "Enter rear-door dimensions within 40 ft (480 in)."
                    return
                }
                rearDoorOpening = door
                doorProvenance = .measured
            }
        } else {
            rearDoorOpening = nil
            doorProvenance = .unmeasured
        }

        let spec = AssignedVehicleSpec(
            name: name,
            interiorDimensions: interiorDimensions,
            rearDoorOpening: rearDoorOpening,
            interiorProvenance: interiorProvenance,
            doorProvenance: doorProvenance,
            catalogCargoVolumeCubicFeet: interiorProvenance == .catalog ? catalogCargoVolumeCubicFeet : nil
        )
        if appModel.setAssignedVehicle(spec) {
            dismiss()
        } else {
            validationMessage = appModel.bannerMessage ?? "Could not save assigned vehicle."
            appModel.bannerMessage = nil
        }
    }

    private static func formatInches(_ inches: Double, unit: MeasurementInputUnit) -> String {
        let meters = inches * 0.0254
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), unit.value(fromMeters: meters))
    }

    private static func parsePositive(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")),
              value.isFinite,
              value > 0 else {
            return nil
        }
        return value
    }

    private static func convertedText(
        _ text: String,
        from unit: MeasurementInputUnit,
        to destination: MeasurementInputUnit
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard unit != destination,
              let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else {
            return text
        }
        let converted = unit.converted(value: value, to: destination)
        guard converted.isFinite else { return text }
        return String(format: "%.15g", locale: Locale(identifier: "en_US_POSIX"), converted)
    }
}
