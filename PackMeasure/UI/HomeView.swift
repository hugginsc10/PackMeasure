import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel
    @State private var manualEntryPresented = false

    var body: some View {
        TabView {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            MeasureEyebrow(text: "Measure • Plan • Move")
                            Text("Know your space.")
                                .font(.system(.largeTitle, design: .rounded).bold())
                            Text("From a single item to the room around it.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            BlueprintArtwork().frame(height: 140)
                        }
                        .measurePanel()
                        NavigationLink {
                            RoomMeasurementView()
                        } label: {
                            MeasureActionLabel(title: "Measure a room", subtitle: "Capture walls. Explore your floorplan.", symbol: "viewfinder")
                        }.buttonStyle(.plain)
                        NavigationLink {
                            InteriorLibraryView()
                        } label: {
                            MeasureActionLabel(title: "Measure a drawer interior", subtitle: "Trace irregular outlines. Design a fitted insert.", symbol: "square.dashed.inset.filled")
                        }.buttonStyle(.plain)
                        Button { appModel.showingScanner = true } label: {
                            MeasureActionLabel(title: "Scan an item", subtitle: "Measure boxes, furniture, and more.", symbol: "shippingbox")
                        }.buttonStyle(.plain)
                        Button { manualEntryPresented = true } label: {
                            Label("Enter dimensions manually", systemImage: "ruler")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(.bordered)
                        NavigationLink {
                            PackingDashboardView(manualEntryPresented: $manualEntryPresented)
                        } label: {
                            HStack {
                                MeasureEyebrow(text: "View your load")
                                Spacer()
                                Text("\(appModel.planningSummary.pieceCount) pieces")
                                    .font(.system(.subheadline, design: .monospaced)).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                            }.frame(minHeight: 48)
                        }.buttonStyle(.plain)
                    }.padding(20)
                }
                .measureScreen()
                .navigationTitle("PackMeasure").navigationBarTitleDisplayMode(.inline)
            }.tabItem { Label("Measure", systemImage: "viewfinder") }
            NavigationStack { RoomMeasurementView() }
                .tabItem { Label("Rooms", systemImage: "square.split.2x2") }
            NavigationStack { PackingDashboardView(manualEntryPresented: $manualEntryPresented) }
                .tabItem { Label("Load", systemImage: "shippingbox") }
        }
        .tint(MeasureStyle.accent)
        .sheet(isPresented: Binding(get: { appModel.showingScanner }, set: { appModel.showingScanner = $0 })) {
            ScannerSheetView().environment(appModel)
        }
        .sheet(isPresented: $manualEntryPresented) { ManualEntryView().environment(appModel) }
        .alert("PackMeasure", isPresented: Binding(get: { appModel.bannerMessage != nil }, set: { if !$0 { appModel.bannerMessage = nil } })) {
            Button("OK", role: .cancel) { appModel.bannerMessage = nil }
        } message: { Text(appModel.bannerMessage ?? "") }
    }
}


private struct PackingDashboardView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var manualEntryPresented: Bool

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    MeasureEyebrow(text: "Move planning")
                    Text("Everything adds up.").font(.system(.title2, design: .rounded).bold())
                    Text("Build your inventory. Find the space you need.").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }.listRowBackground(MeasureStyle.panel)
            spaceNeededSection.listRowBackground(MeasureStyle.panel)
            loadMixSection.listRowBackground(MeasureStyle.panel)
            vehicleSection.listRowBackground(MeasureStyle.panel)
            inventorySection.listRowBackground(MeasureStyle.panel)
            planningDisclaimerSection.listRowBackground(Color.clear)
        }
        .navigationTitle("Your load")
        .measureScreen()
        .safeAreaInset(edge: .bottom) {
            entryActions
        }
    }

    private var loadMixSelection: Binding<PackingLoadMix> {
        Binding(
            get: { appModel.loadMix },
            set: appModel.setLoadMix
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
                    value: MeasurementMath.decimalSquareFeetString(summary.requiredFloorSquareFeet),
                    systemImage: "square.dashed"
                )
                SummaryTile(
                    title: "Cargo volume",
                    value: MeasurementMath.decimalCubicFeetString(summary.requiredCubicFeet),
                    systemImage: "shippingbox"
                )
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            LabeledContent("Saved pieces", value: "\(summary.pieceCount)")
            LabeledContent(
                "Unstacked footprint",
                value: MeasurementMath.decimalSquareFeetString(summary.rawFootprintSquareFeet)
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
                Label(recommendation.reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                ForEach(Array(recommendation.rejections.suffix(3).enumerated()), id: \.offset) { _, rejection in
                    Text(rejection.reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if appModel.ignoredPackingItemCount > 0 {
                Label(
                    "\(appModel.ignoredPackingItemCount) saved item could not be included because its dimensions are invalid.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
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
                .onDelete(perform: appModel.deleteItems)
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
                    value: "\(wholeNumber(door.widthInches)) × \(wholeNumber(door.heightInches)) in"
                )
            }
            DetailLine(
                title: "Usable volume",
                value: MeasurementMath.decimalCubicFeetString(vehicle.usableCargoVolumeCubicFeet)
            )

            Text(recommendation.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !recommendation.rejections.isEmpty {
                DisclosureGroup("Why smaller options were ruled out") {
                    ForEach(Array(recommendation.rejections.enumerated()), id: \.offset) { _, rejection in
                        Text(rejection.reason)
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
        "\(wholeNumber(dimensions.lengthInches)) × \(wholeNumber(dimensions.widthInches)) × \(wholeNumber(dimensions.heightInches)) in"
    }

    private func wholeNumber(_ value: Double) -> String {
        String(format: "%.0f", value)
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
                "\(MeasurementMath.inchString(from: item.lengthMeters)) × " +
                "\(MeasurementMath.inchString(from: item.widthMeters)) × " +
                "\(MeasurementMath.inchString(from: item.heightMeters))"
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

enum SavedMeasurementCopy {
    static func qualitySummary(for item: MeasuredItem) -> String {
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
    @Environment(\.dismiss) private var dismiss

    let item: MeasuredItem

    @State private var name: String
    @State private var quantity: Int
    @State private var isStackable: Bool
    @State private var maxLayers: Int
    @State private var mayRotate: Bool

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

    var body: some View {
        Form {
            Section("Item") {
                TextField("Item name", text: $name)
                Stepper("Quantity: \(quantity)", value: $quantity, in: 1 ... 999)
                LabeledContent(
                    "Measured size",
                    value: "\(MeasurementMath.inchString(from: item.lengthMeters)) × \(MeasurementMath.inchString(from: item.widthMeters)) × \(MeasurementMath.inchString(from: item.heightMeters))"
                )
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
        .measureScreen()
        .navigationTitle("Packing details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    appModel.updateItem(
                        id: item.id,
                        name: name,
                        quantity: quantity,
                        stackability: isStackable
                            ? .stackable(maxLayers: maxLayers)
                            : .notStackable,
                        orientationPolicy: mayRotate ? .mayRotate : .keepUpright
                    )
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
    }
}
