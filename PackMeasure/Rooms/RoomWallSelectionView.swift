import SwiftUI

/// The original scan remains intact until Save. IDs keep the review selection
/// stable even when the kept-room preview renumbers its remaining walls.
struct RoomScanReviewView: View {
    let original: MeasuredRoom
    let store: RoomScanStore
    let diagnostics: String
    let onSaved: () -> Void
    let onScanAgain: () -> Void
    @State private var draft: MeasuredRoom
    @State private var editingMeasurements = false
    @State private var keptIDs: Set<UUID>
    @State private var name: String
    @State private var choosingWalls = false
    @State private var saveFailure: String?

    init(room: MeasuredRoom, store: RoomScanStore, diagnostics: String,
         onSaved: @escaping () -> Void, onScanAgain: @escaping () -> Void) {
        original = room
        self.store = store
        self.diagnostics = diagnostics
        self.onSaved = onSaved
        self.onScanAgain = onScanAgain
        _draft = State(initialValue: room)
        _keptIDs = State(initialValue: Set(room.walls.map(\.id)))
        _name = State(initialValue: room.name)
    }

    private var keptRoom: MeasuredRoom? { try? draft.keepingWalls(keptIDs) }

    var body: some View {
        Group {
            if let room = keptRoom {
                RoomResultView(room: room, onEditMeasurements: { editingMeasurements = true }) {
                    reviewHeader
                }
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        reviewHeader
                        ContentUnavailableView("Choose at least one wall", systemImage: "square.dashed",
                                               description: Text("Open Choose walls to save and keep the walls that belong to this room."))
                    }.padding(20)
                }
            }
        }
        .navigationTitle("Review room").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(keptRoom?.hasRoomExtent == false ? "Save partial" : "Save") {
                    guard var room = keptRoom else { return }
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    room.name = trimmed.isEmpty ? "Room" : trimmed
                    do { try store.save(room); onSaved() }
                    catch { saveFailure = error.localizedDescription }
                }.disabled(keptRoom == nil).accessibilityIdentifier("save-reviewed-room")
            }
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button("Scan again", action: onScanAgain)
                    Spacer()
                    ShareLink("Diagnostics", item: diagnostics + "\nreview_kept_wall_ids=" + keptIDs.map(\.uuidString).sorted().joined(separator: ","))
                }
            }
        }
        .sheet(isPresented: $editingMeasurements) {
            if let room = keptRoom {
                RoomMeasurementsEditor(room: room) { updated in
                    draft.ceilingHeight = updated.ceilingHeight
                    // Exclusion is reversible until Save. Keep annotations for
                    // temporarily hidden walls while editing the visible subset.
                    let hidden = (draft.shelves ?? []).filter { shelf in
                        shelf.wallID.map { !keptIDs.contains($0) } ?? false
                    }
                    draft.shelves = (updated.shelves ?? []) + hidden
                }
            }
        }
        .fullScreenCover(isPresented: $choosingWalls) {
            RoomWallSelectionView(room: draft, keptIDs: $keptIDs)
        }
        .alert("Couldn’t save room", isPresented: Binding(get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
            Button("OK") { saveFailure = nil }
        } message: { Text(saveFailure ?? "") }
    }

    private var reviewHeader: some View {
        VStack(spacing: 12) {
            TextField("Room name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("review-room-name")
            Button { choosingWalls = true } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.square").font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose walls to save").font(.headline)
                        Text("Keeping \(keptIDs.count) of \(original.walls.count) walls · exclude walls outside this room")
                            .font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14).background(MeasureStyle.panel, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain).foregroundStyle(MeasureStyle.accent)
            .accessibilityIdentifier("choose-walls-to-save")
        }
    }
}

struct RoomWallSelectionView: View {
    @Environment(AppPreferences.self) private var preferences
    let room: MeasuredRoom
    @Binding var keptIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int? = 0
    @State private var showing3D = false
    @State private var reset = 0
    @State private var zoom = 0
    @State private var reset3D = 0
    @State private var zoom3D = 0
    @State private var showingList = false
    @State private var previewing = false

    private var omittedIDs: Set<UUID> { Set(room.walls.map(\.id)).subtracting(keptIDs) }
    private var preview: MeasuredRoom? { try? room.keepingWalls(keptIDs) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Keeping \(keptIDs.count) of \(room.walls.count) walls").font(.headline)
                    Text("Tap a wall, then keep or exclude it. Gray dashed walls won’t be saved.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !(room.shelves ?? []).isEmpty {
                        Text("Shelves assigned to excluded walls won’t be saved with this room.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Room view", selection: $showing3D) {
                        Text("2D Plan").tag(false)
                        Text("3D Room").tag(true)
                    }.pickerStyle(.segmented)
                }.padding(.horizontal, 20).padding(.vertical, 12)
                ZStack {
                    FloorplanScrollView(walls: room.walls, selected: $selected, reset: reset, zoomRequest: zoom,
                                        labelMode: .wallIDs, units: preferences.units, omittedWallIDs: omittedIDs)
                        .opacity(showing3D ? 0 : 1).allowsHitTesting(!showing3D).accessibilityHidden(showing3D)
                    RoomWireframeView(walls: room.renderedWalls, selected: $selected, reset: reset3D, zoomRequest: zoom3D,
                                      labelMode: .wallIDs, units: preferences.units, omittedWallIDs: omittedIDs)
                        .opacity(showing3D ? 1 : 0).allowsHitTesting(showing3D).accessibilityHidden(!showing3D)
                }.frame(minHeight: 160).clipped()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("Zoom out", systemImage: "minus.magnifyingglass") { changeZoom(-1) }.labelStyle(.iconOnly)
                            Button("Zoom in", systemImage: "plus.magnifyingglass") { changeZoom(1) }.labelStyle(.iconOnly)
                            Spacer()
                            Button("Fit") { if showing3D { reset3D += 1 } else { reset += 1 } }
                            Button("Wall list", systemImage: "list.bullet") { showingList = true }
                        }.buttonStyle(.bordered)
                        if let selected, room.walls.indices.contains(selected) {
                            let wall = room.walls[selected]
                            HStack {
                                Text("Wall \(selected + 1)").font(.headline)
                                Spacer()
                                Button("Previous wall", systemImage: "chevron.left") { step(-1) }.labelStyle(.iconOnly)
                                Button("Next wall", systemImage: "chevron.right") { step(1) }.labelStyle(.iconOnly)
                            }
                            Text("Length \(MeasuredRoom.dimension(wall.length, units: preferences.units)) · Captured height \(MeasuredRoom.dimension(wall.height, units: preferences.units))")
                                .font(.subheadline).monospacedDigit()
                            Text("\(wall.confidence.capitalized) capture confidence").font(.caption).foregroundStyle(.secondary)
                            Toggle("Keep Wall \(selected + 1)", isOn: keepBinding(wall.id))
                                .font(.headline).accessibilityIdentifier("keep-selected-wall")
                        } else {
                            Text("Tap a wall or open Wall list to choose what to keep.").font(.subheadline)
                        }
                        Button("Preview kept walls", systemImage: "viewfinder") { previewing = true }
                            .buttonStyle(.bordered).disabled(preview == nil)
                    }.padding(20)
                }
                .frame(maxHeight: 270)
                .background(MeasureStyle.panel, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24))
            }
            .background(MeasureStyle.background)
            .navigationTitle("Choose walls").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("finish-room-wall-selection")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu("Selection") {
                        Button("Keep all walls") { keptIDs = Set(room.walls.map(\.id)) }
                        Button("Clear selection") { keptIDs = [] }
                    }
                }
            }
            .sheet(isPresented: $showingList) { wallList }
            .fullScreenCover(isPresented: $previewing) {
                if let preview { RoomFloorplanView(room: preview) }
            }
        }
    }

    private var wallList: some View {
        NavigationStack {
            List {
                Section("Keep the walls that belong to your room") {
                    ForEach(Array(room.walls.enumerated()), id: \.element.id) { index, wall in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Keep Wall \(index + 1)", isOn: keepBinding(wall.id))
                                .accessibilityIdentifier("keep-room-wall-\(index + 1)")
                            Text("Length \(MeasuredRoom.dimension(wall.length, units: preferences.units))").font(.caption)
                            Text("Height \(MeasuredRoom.dimension(wall.height, units: preferences.units)) · \(wall.confidence) confidence")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Locate Wall \(index + 1)") { selected = index; showingList = false }
                                .font(.caption).buttonStyle(.borderless)
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Wall list").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingList = false }.accessibilityIdentifier("finish-room-wall-list")
                }
            }
        }.tint(MeasureStyle.accent)
    }

    private func keepBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { keptIDs.contains(id) }, set: { keep in
            if keep { keptIDs.insert(id) } else { keptIDs.remove(id) }
        })
    }

    private func step(_ delta: Int) {
        guard !room.walls.isEmpty else { return }
        selected = selected.map { ($0 + delta + room.walls.count) % room.walls.count } ?? 0
    }

    private func changeZoom(_ delta: Int) {
        if showing3D { zoom3D += delta } else { zoom += delta }
    }
}
