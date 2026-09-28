import SwiftUI

struct RoomLengthInput: View {
    let title: String
    let identifier: String
    @Binding var entry: RoomLengthEntry
    let units: RoomEntryUnits
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            HStack {
                if units == .imperial {
                    TextField("0", text: $entry.feet).keyboardType(.numberPad)
                        .accessibilityLabel("\(title) feet").accessibilityIdentifier("\(identifier)-feet")
                    Text("ft").foregroundStyle(.secondary)
                    TextField("0", text: $entry.inches).keyboardType(.decimalPad)
                        .accessibilityLabel("\(title) inches").accessibilityIdentifier("\(identifier)-inches")
                    Text("in").foregroundStyle(.secondary)
                } else {
                    TextField("Meters", text: $entry.meters).keyboardType(.decimalPad)
                        .accessibilityLabel("\(title) meters").accessibilityIdentifier("\(identifier)-meters")
                    Text("m").foregroundStyle(.secondary)
                }
            }.textFieldStyle(.roundedBorder)
        }.padding(.vertical, 4)
    }
}

struct RoomMeasurementsEditor: View {
    @State private var room: MeasuredRoom
    @State private var usesCeiling: Bool
    @State private var ceiling: RoomLengthEntry
    @State private var units: RoomEntryUnits = .imperial
    @State private var addingShelf = false
    @State private var editingShelf: RoomShelfMeasurement?
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    let onApply: (MeasuredRoom) throws -> Void

    init(room: MeasuredRoom, onApply: @escaping (MeasuredRoom) throws -> Void) {
        _room = State(initialValue: room)
        _usesCeiling = State(initialValue: room.ceilingHeight != nil)
        _ceiling = State(initialValue: RoomLengthEntry(room.ceilingHeight?.meters))
        self.onApply = onApply
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Input units", selection: Binding(get: { units }, set: { next in
                        do { try ceiling.convert(from: units); units = next }
                        catch { self.error = error.localizedDescription }
                    })) { ForEach(RoomEntryUnits.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                }
                Section("Ceiling height") {
                    Toggle("Use measured ceiling height", isOn: $usesCeiling).accessibilityIdentifier("use-measured-ceiling")
                    if usesCeiling {
                        RoomLengthInput(title: "Floor to ceiling", identifier: "ceiling", entry: $ceiling, units: units)
                        Text("Enter a measurement you took, such as 9 ft 0 in. This sets a flat ceiling height for the 3D outline. Original scanned wall heights stay unchanged.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("The 3D outline uses captured wall heights. Enable this after measuring the actual ceiling height.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Shelves") {
                    ForEach(room.shelves ?? []) { shelf in
                        Button { editingShelf = shelf } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(shelf.name).font(.headline)
                                Text("Depth \(RoomShelfMeasurement.dimension(shelf.depth))").font(.caption)
                                Text("Above floor \(RoomShelfMeasurement.dimension(shelf.heightAboveFloor))").font(.caption)
                                Text(shelf.clearanceAbove.map { "Clear above \(RoomShelfMeasurement.dimension($0))" } ?? "Clear above not measured").font(.caption)
                            }.foregroundStyle(.primary)
                        }
                    }.onDelete { offsets in room.shelves?.remove(atOffsets: offsets) }
                    Button("Add shelf", systemImage: "plus") { addingShelf = true }.accessibilityIdentifier("add-shelf")
                    Text("Measure a selected shelf with LiDAR, enter dimensions, or calculate depth from two aligned distances. Each shelf keeps its own measurements.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Ceiling & shelves").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply() }.accessibilityIdentifier("apply-room-measurements") }
            }
            .sheet(isPresented: $addingShelf) { ShelfMeasurementEditor(walls: room.walls, onSave: saveShelf) }
            .sheet(item: $editingShelf) { ShelfMeasurementEditor(walls: room.walls, shelf: $0, onSave: saveShelf) }
            .alert("Check measurements", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }.tint(MeasureStyle.accent).preferredColorScheme(.dark)
    }
    private func saveShelf(_ shelf: RoomShelfMeasurement) {
        var shelves = room.shelves ?? []
        if let index = shelves.firstIndex(where: { $0.id == shelf.id }) { shelves[index] = shelf }
        else { shelves.append(shelf) }
        room.shelves = shelves
    }
    private func apply() {
        do {
            if usesCeiling {
                guard let value = try ceiling.value(in: units) else { throw RoomDimensionError.invalidHeight }
                let candidate = try RoomCeilingHeight(meters: value)
                if let shelf = room.shelves?.first(where: { $0.heightAboveFloor + ($0.clearanceAbove ?? 0) > value + 0.03 }) {
                    error = "\(shelf.name) extends above the entered ceiling height. Check its floor height, clear space, or the ceiling measurement."; return
                }
                room.ceilingHeight = candidate
            } else { room.ceilingHeight = nil }
            try onApply(room); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ShelfMeasurementEditor: View {
    let walls: [MeasuredRoom.Wall]
    let shelf: RoomShelfMeasurement?
    let onSave: (RoomShelfMeasurement) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var wallID: UUID?
    @State private var units: RoomEntryUnits = .imperial
    @State private var subtractDistances: Bool
    @State private var depth: RoomLengthEntry
    @State private var floorHeight: RoomLengthEntry
    @State private var clearance: RoomLengthEntry
    @State private var back: RoomLengthEntry
    @State private var front: RoomLengthEntry
    @State private var scanning = false
    @State private var capturedPoints: [SIMD3<Float>]?
    @State private var selectedTop: SIMD3<Float>?
    @State private var unchangedCapture: Bool
    @State private var capturedSource: RoomShelfMeasurement.Source
    @State private var pointMatches: [ShelfPointMatch]?
    @State private var error: String?

    init(walls: [MeasuredRoom.Wall], shelf: RoomShelfMeasurement? = nil, onSave: @escaping (RoomShelfMeasurement) -> Void) {
        self.walls = walls; self.shelf = shelf; self.onSave = onSave
        _name = State(initialValue: shelf?.name ?? "Shelf")
        _wallID = State(initialValue: shelf?.wallID)
        _subtractDistances = State(initialValue: shelf?.source == .difference)
        _depth = State(initialValue: RoomLengthEntry(shelf?.depth))
        _floorHeight = State(initialValue: RoomLengthEntry(shelf?.heightAboveFloor))
        _clearance = State(initialValue: RoomLengthEntry(shelf?.clearanceAbove))
        _back = State(initialValue: RoomLengthEntry(shelf?.referenceToBack))
        _front = State(initialValue: RoomLengthEntry(shelf?.referenceToFront))
        _capturedPoints = State(initialValue: shelf?.capturedPoints)
        _selectedTop = State(initialValue: shelf?.selectedTop)
        _unchangedCapture = State(initialValue: shelf?.source == .lidar || shelf?.source == .twoView)
        _capturedSource = State(initialValue: shelf?.source ?? .lidar)
        _pointMatches = State(initialValue: shelf?.pointMatches)
    }
    private func edited(_ entry: Binding<RoomLengthEntry>) -> Binding<RoomLengthEntry> {
        Binding(get: { entry.wrappedValue }, set: { entry.wrappedValue = $0; unchangedCapture = false })
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Shelf name", text: $name).accessibilityIdentifier("shelf-name")
                    Picker("Attach to wall", selection: $wallID) {
                        Text("No wall assigned").tag(UUID?.none)
                        ForEach(Array(walls.enumerated()), id: \.element.id) { index, wall in
                            Text("Wall \(index + 1)").tag(Optional(wall.id))
                        }
                    }
                    Button("Scan selected shelf", systemImage: "viewfinder") { scanning = true }.accessibilityIdentifier("scan-shelf")
                    Text("Auto chooses a solid-surface or wire-compatible method from the initial tap. Use Method in the scanner to override it. Hidden edges still need a clearer view.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Measurements") {
                    Picker("Input units", selection: Binding(get: { units }, set: changeUnits)) {
                        ForEach(RoomEntryUnits.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Calculate depth by subtraction", isOn: Binding(get: { subtractDistances }, set: { subtractDistances = $0; unchangedCapture = false }))
                        .accessibilityIdentifier("shelf-subtraction")
                    if subtractDistances {
                        RoomLengthInput(title: "Reference to back edge", identifier: "reference-back", entry: edited($back), units: units)
                        RoomLengthInput(title: "Reference to front edge", identifier: "reference-front", entry: edited($front), units: units)
                        Text("Use the same starting reference and straight direction. Back-edge distance minus front-edge distance gives shelf depth. Use the back wall only if the shelf touches it.").font(.footnote).foregroundStyle(.secondary)
                        if let b = try? back.value(in: units), let f = try? front.value(in: units), let value = try? RoomShelfMeasurement.depthFromDistances(back: b, front: f) {
                            LabeledContent("Calculated depth", value: RoomShelfMeasurement.dimension(value)).accessibilityIdentifier("calculated-shelf-depth")
                        }
                    } else {
                        RoomLengthInput(title: "Shelf depth", identifier: "shelf-depth", entry: edited($depth), units: units)
                    }
                    RoomLengthInput(title: "Shelf top above floor", identifier: "shelf-height", entry: edited($floorHeight), units: units)
                    RoomLengthInput(title: "Clear space above (optional)", identifier: "shelf-clearance", entry: edited($clearance), units: units)
                    Text("Clear space is measured from this shelf’s top to the underside of the shelf or lowest obstruction above. Leave blank if not measured.").font(.footnote).foregroundStyle(.secondary)
                    if unchangedCapture { Text(capturedSource == .twoView ? "Matched-point estimate · verify with a tape or laser measure." : "LiDAR estimate · verify with a tape or laser measure.").font(.footnote).foregroundStyle(.orange) }
                }
            }
            .navigationTitle(shelf == nil ? "Add shelf" : "Edit shelf").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Keep shelf") { save() }.accessibilityIdentifier("keep-shelf") }
            }
            .fullScreenCover(isPresented: $scanning) {
                ShelfCaptureFlow { result, points, selected, source, matches in
                    depth = RoomLengthEntry(result.depth); floorHeight = RoomLengthEntry(result.height)
                    clearance = RoomLengthEntry(result.clearance); capturedPoints = points; selectedTop = selected
                    subtractDistances = false; unchangedCapture = true; capturedSource = source; pointMatches = matches
                }
            }
            .alert("Check shelf measurements", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }.tint(MeasureStyle.accent).preferredColorScheme(.dark)
    }
    private func changeUnits(_ next: RoomEntryUnits) {
        do {
            // Convert all fields atomically; an invalid value leaves the current units intact.
            var entries = [depth, floorHeight, clearance, back, front]
            for index in entries.indices { try entries[index].convert(from: units) }
            depth = entries[0]; floorHeight = entries[1]; clearance = entries[2]; back = entries[3]; front = entries[4]
            units = next
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            let b = subtractDistances ? try back.value(in: units) : nil
            let f = subtractDistances ? try front.value(in: units) : nil
            let shelfDepth: Float
            if subtractDistances {
                guard let b, let f else { throw RoomDimensionError.invalidDifference }
                shelfDepth = try RoomShelfMeasurement.depthFromDistances(back: b, front: f)
            } else {
                guard let value = try depth.value(in: units) else { throw RoomDimensionError.invalidShelf }
                shelfDepth = value
            }
            guard let height = try floorHeight.value(in: units) else { throw RoomDimensionError.invalidShelf }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let record = try RoomShelfMeasurement(id: shelf?.id ?? UUID(), name: trimmed.isEmpty ? "Shelf" : trimmed,
                wallID: wallID, depth: shelfDepth, heightAboveFloor: height, clearanceAbove: clearance.value(in: units),
                source: subtractDistances ? .difference : unchangedCapture ? capturedSource : .manual,
                capturedPoints: capturedPoints, selectedTop: selectedTop, referenceToBack: b, referenceToFront: f, pointMatches: pointMatches)
            onSave(record); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct RoomSavedDetailView: View {
    @State var room: MeasuredRoom
    let store: RoomScanStore
    @State private var editing = false
    var body: some View {
        RoomResultView(room: room, onEditMeasurements: { editing = true })
            .sheet(isPresented: $editing) {
                RoomMeasurementsEditor(room: room) { updated in
                    try store.save(updated); room = updated
                }
            }
    }
}
