import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

struct InteriorLibraryView: View {
    @Environment(AppPreferences.self) private var preferences
    @State private var records: [InteriorMeasurement] = []
    @State private var showingScanner = false
    @State private var error: String?
    @State private var loaded = false
    private let store = InteriorStore()
    var body: some View {
        List {
            Group {
                Section {
                    Button { showingScanner = true } label: {
                        Label("Scan drawer or cabinet", systemImage: "viewfinder")
                            .font(.headline)
                    }
                    .disabled(!loaded)
                    Text("Capture an irregular floor outline, exclude obstacles, and export a millimeter SVG for CAD. Saved interiors are separate from cargo inventory.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Saved interiors") {
                    ForEach(records) { record in
                        NavigationLink {
                            InteriorReviewView(record: record, onSave: save)
                        } label: {
                            InteriorLibraryRow(record: record, units: preferences.units)
                        }
                    }
                    .onDelete { offsets in
                        var next = records
                        next.remove(atOffsets: offsets)
                        do { try store.save(next); records = next } catch { self.error = error.localizedDescription }
                    }
                    if records.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "square.dashed.inset.filled")
                                .font(.title3)
                                .foregroundStyle(MeasureStyle.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("No interior scans saved yet.").font(.subheadline.weight(.semibold))
                                Text("Scan a drawer, shelf, or cabinet compartment to save its outline and CAD insert settings.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let error { Section("Could not save or load") { Text(error).foregroundStyle(.orange) } }
            }
            .listRowBackground(MeasureStyle.panel)
        }
        .measureScreen()
        .navigationTitle("Interiors & inserts")
        .sheet(isPresented: $showingScanner) { InteriorScannerView(onSave: save) }
        .task {
            do { records = try store.load(); loaded = true } catch { self.error = error.localizedDescription }
        }
    }
    private func save(_ record: InteriorMeasurement) throws {
        var next = records.filter { $0.id != record.id }
        next.insert(record, at: 0)
        try store.save(next)
        records = next
    }
}

private struct InteriorLibraryRow: View {
    let record: InteriorMeasurement
    let units: MeasurementUnits

    private var spanSummary: String? {
        let snapshot = record.geometrySnapshot
        guard let along = snapshot.alongFirstEdgeMM, let across = snapshot.acrossFirstEdgeMM else { return nil }
        return "\(units.preciseLength(millimeters: along)) × \(units.preciseLength(millimeters: across)) · \(units.preciseLength(millimeters: record.heightMM))"
    }

    var body: some View {
        HStack(spacing: 14) {
            InteriorOutlineView(
                contours: record.contours,
                inset: try? record.insertContours(),
                showBadges: false
            )
            .frame(width: 72, height: 64)
            .background(MeasureStyle.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MeasureStyle.line, lineWidth: 1))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if record.verification?.fit != nil {
                        InteriorFitStatusPill(record: record)
                    }
                }
                if let spanSummary {
                    Text(spanSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                let obstacleCount = max(0, record.contours.count - 1)
                let obstacleSuffix = obstacleCount > 0
                    ? " · \(obstacleCount) \(obstacleCount == 1 ? "obstacle" : "obstacles")"
                    : ""
                Text("\(record.contours.first?.count ?? 0) perimeter points\(obstacleSuffix) · \(record.capturedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct InteriorFitStatusPill: View {
    let record: InteriorMeasurement

    private var label: String {
        guard let fit = record.verification?.fit else { return "Not tested" }
        return record.fitIsStale ? "Needs recheck" : fit.status.title
    }

    private var symbol: String {
        guard let fit = record.verification?.fit else { return "square.dashed" }
        if record.fitIsStale { return "arrow.clockwise.circle.fill" }
        switch fit.status {
        case .fits: return "checkmark.circle.fill"
        case .tooTight, .tooLoose, .interference: return "exclamationmark.triangle.fill"
        case .notTested: return "square.dashed"
        }
    }

    private var tint: Color {
        guard let fit = record.verification?.fit else { return .secondary }
        if record.fitIsStale { return .orange }
        switch fit.status {
        case .fits: return MeasureStyle.accent
        case .tooTight, .tooLoose, .interference: return .orange
        case .notTested: return .secondary
        }
    }

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

struct InteriorSVGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.svg] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct InteriorSVGTransfer: Transferable {
    let svg: String
    var filename: String = "interior-insert.svg"
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .svg) { value in
            Data(value.svg.utf8)
        }
        .suggestedFileName { value in
            value.filename
        }
    }
}

struct InteriorReviewView: View {
    @State var record: InteriorMeasurement
    var onSave: (InteriorMeasurement) throws -> Void
    @State private var exporting = false
    @State private var document = InteriorSVGDocument(text: "")
    @State private var message: String?
    @Environment(AppPreferences.self) private var preferences
    @State private var editingUnit: InteriorUnit?
    @State private var millimeterCorrections = false

    init(record: InteriorMeasurement, onSave: @escaping (InteriorMeasurement) throws -> Void) {
        var preserved = record
        // Old saves may already contain corrections. Preserve what was saved without
        // claiming it is the original scan, before any controls can change it.
        preserved.preserveOriginalGeometry(source: .savedGeometry)
        _record = State(initialValue: preserved)
        self.onSave = onSave
    }
    /// The numeric field being edited. Its uncommitted text would be read in the new unit,
    /// so units cannot change until editing ends.
    @FocusState private var editing: Field?
    private enum Field: Hashable { case height, point(loop: Int, index: Int, axis: Int) }
    private var unit: InteriorUnit {
        editingUnit ?? (millimeterCorrections ? .millimeters : preferences.units.inputUnit == .inches ? .inches : .centimeters)
    }
    private var output: Result<[[InteriorPoint]], Error> { Result { try record.insertContours() } }
    /// Edits a stored millimeter value in the chosen unit.
    private func length(_ millimeters: Binding<Double>) -> Binding<Double> {
        Binding(get: { unit.value(fromMillimeters: millimeters.wrappedValue) },
                set: { millimeters.wrappedValue = unit.millimeters(from: $0) })
    }
    var body: some View {
        Form {
            Group {
                Section("Inside footprint · \(preferences.units.title.lowercased())") {
                    if record.footprintModel == .rectangular {
                        Label("Rectangular fit · verify all four sides", systemImage: "rectangle.dashed")
                            .font(.caption.weight(.medium)).foregroundStyle(MeasureStyle.accent)
                            .accessibilityIdentifier("interior-rectangular-fit")
                    }
                    Picker("Units", selection: Binding(get: { preferences.units }, set: { preferences.units = $0 })) {
                        ForEach(MeasurementUnits.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("interior-units").disabled(editing != nil)
                    if editing != nil { Text("Finish editing to change units.").font(.caption).foregroundStyle(.secondary) }
                    InteriorOutlineView(contours: record.contours, inset: try? output.get())
                        .frame(height: 220)
                        .background(MeasureStyle.background, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(MeasureStyle.line, lineWidth: 1))
                    Text("Gray: current boundary · Orange: first edge (1 -> 2) · Teal: insert footprint")
                        .font(.caption).foregroundStyle(.secondary)
                    if let outer = record.contours.first,
                       let minX = outer.map(\.x).min(), let maxX = outer.map(\.x).max(),
                       let minY = outer.map(\.y).min(), let maxY = outer.map(\.y).max() {
                        LabeledContent("Overall span along first edge", value: preferences.units.preciseLength(millimeters: maxX - minX))
                            .monospacedDigit()
                        LabeledContent("Overall span across first edge", value: preferences.units.preciseLength(millimeters: maxY - minY))
                            .monospacedDigit()
                    }
                    Text("Overall spans are bounding dimensions; an irregular insert must follow the outline.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let spread = record.capturedBoundaryAgreement?.compactMap(\.spreadMM).max() {
                        LabeledContent("Captured boundary variation", value: preferences.units.preciseLength(millimeters: spread))
                            .monospacedDigit()
                            .accessibilityIdentifier("interior-boundary-variation")
                        Text("This is the variation between views of observed edges. Similar views can share measurement bias; verify dimensions with a tape before sizing an insert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Insert settings") {
                    TextField("Interior name", text: $record.name)
                    HStack {
                        Text("Usable height (\(unit.symbol))")
                        TextField("Height", value: length(Binding(get: { record.heightMM }, set: { record.heightMM = $0; record.heightSource = .entered })),
                                  format: .number.precision(.fractionLength(unit.fractionDigits...10)))
                            .focused($editing, equals: .height)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .accessibilityIdentifier("interior-usable-height")
                    }
                    Text(record.heightSource == .entered ? "Height entered by you" : record.heightSource == .lidar ? "Captured height · verify available space" : "Verify available height")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Side clearance: \(preferences.units.preciseLength(millimeters: record.sideClearanceMM))", value: $record.sideClearanceMM, in: 0...30, step: 0.5)
                        .monospacedDigit()
                        .accessibilityIdentifier("interior-side-clearance")
                    Stepper("Top clearance: \(preferences.units.preciseLength(millimeters: record.topClearanceMM))", value: $record.topClearanceMM, in: 0...30, step: 0.5)
                        .monospacedDigit()
                        .accessibilityIdentifier("interior-top-clearance")
                    Text("Side clearance is applied at every wall and around obstacles. A rectangular insert loses twice this amount per horizontal dimension. Top clearance is subtracted once from usable height.")
                        .font(.caption).foregroundStyle(.secondary)
                    if case .success(let insetLoops) = output {
                        if let outer = insetLoops.first,
                           let minX = outer.map(\.x).min(), let maxX = outer.map(\.x).max(),
                           let minY = outer.map(\.y).min(), let maxY = outer.map(\.y).max() {
                            LabeledContent("Insert span along first edge", value: preferences.units.preciseLength(millimeters: maxX - minX))
                                .monospacedDigit()
                                .accessibilityIdentifier("interior-insert-span-along")
                            LabeledContent("Insert span across first edge", value: preferences.units.preciseLength(millimeters: maxY - minY))
                                .monospacedDigit()
                                .accessibilityIdentifier("interior-insert-span-across")
                        }
                        LabeledContent("Draft extrusion height", value: preferences.units.preciseLength(millimeters: record.heightMM - record.topClearanceMM))
                            .monospacedDigit()
                    } else if case .failure(let error) = output {
                        Text(error.localizedDescription).foregroundStyle(.orange)
                    }
                }
                InteriorVerificationCard(record: $record)
                Section("Verify or correct the outline") {
                    Toggle("Edit in millimeters", isOn: $millimeterCorrections)
                        .disabled(editing != nil)
                        .accessibilityIdentifier("interior-correction-millimeters")
                    Text("Coordinates are in \(unit.title.lowercased()), relative to point 1. The first edge defines the horizontal axis. Use physical measurements to correct points before exporting.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(record.contours.indices, id: \.self) { loopIndex in
                        DisclosureGroup(loopIndex == 0 ? "Inside perimeter" : "Obstacle \(loopIndex)") {
                            ForEach(record.contours[loopIndex].indices, id: \.self) { pointIndex in
                                HStack {
                                    Text("\(pointIndex + 1)")
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(minWidth: 22, alignment: .leading)
                                    TextField("X (\(unit.symbol))", value: length($record.contours[loopIndex][pointIndex].x), format: .number)
                                        .focused($editing, equals: .point(loop: loopIndex, index: pointIndex, axis: 0))
                                        .monospacedDigit()
                                        .accessibilityLabel("Point \(pointIndex + 1) X in \(unit.title.lowercased())")
                                        .accessibilityIdentifier("interior-point-\(loopIndex)-\(pointIndex)-x")
                                    TextField("Y (\(unit.symbol))", value: length($record.contours[loopIndex][pointIndex].y), format: .number)
                                        .focused($editing, equals: .point(loop: loopIndex, index: pointIndex, axis: 1))
                                        .monospacedDigit()
                                        .accessibilityLabel("Point \(pointIndex + 1) Y in \(unit.title.lowercased())")
                                        .accessibilityIdentifier("interior-point-\(loopIndex)-\(pointIndex)-y")
                                }
                                .keyboardType(.numbersAndPunctuation)
                            }
                        }
                    }
                }
                Section("Check before printing") {
                    Text("LiDAR is an estimate, not a fit guarantee. Verify the narrowest widths, curve segments, obstacles and closed-drawer height with a ruler or caliper. Adjust usable height here. For tapered walls or overhangs, use the tightest footprint over the full insert height; this scan does not capture a 3D cavity.")
                    Text("Export the SVG at 1:1 millimeter scale, check one known dimension in CAD, then extrude to the draft height. Print a thin test outline before a full insert.")
                }
                Section {
                    Button("Save interior") {
                        do { try onSave(record); message = "Interior saved." } catch { message = error.localizedDescription }
                    }
                    .disabled((try? output.get()) == nil)
                    Button("Export insert SVG") {
                        do { document = InteriorSVGDocument(text: try record.svg()); exporting = true }
                        catch { message = error.localizedDescription }
                    }
                    .disabled((try? output.get()) == nil)
                    if let svg = try? record.svg() {
                        ShareLink(
                            item: InteriorSVGTransfer(svg: svg, filename: "\(record.exportBasename).svg"),
                            preview: SharePreview(record.exportBasename)
                        ) {
                            Label("Share SVG", systemImage: "square.and.arrow.up")
                        }
                    }
                    if let message { Text(message).font(.footnote) }
                }
            }
            .listRowBackground(MeasureStyle.panel)
        }
        .measureScreen()
        .navigationTitle("Review interior")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: editing) { _, next in
            if next != nil, editingUnit == nil { editingUnit = unit }
            else if next == nil { editingUnit = nil }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do { try onSave(record); message = "Interior saved." } catch { message = error.localizedDescription }
                }.disabled((try? output.get()) == nil).accessibilityIdentifier("save-interior-review")
            }
            // Decimal pads have no return key; this commits the value being edited.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editing = nil }
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .svg, defaultFilename: record.exportBasename) { result in
            switch result {
            case .success: message = "SVG exported. Verify its scale in CAD."
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
}

struct InteriorOutlineView: View {
    let contours: [[InteriorPoint]]
    let inset: [[InteriorPoint]]?
    var showBadges: Bool = true

    var body: some View {
        Canvas { context, size in
            let all = contours.flatMap { $0 }
            let pad: Double = showBadges ? 16 : 8
            guard size.width > pad * 2, size.height > pad * 2,
                  let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
                  let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(),
                  maxX > minX, maxY > minY else { return }

            let gridSpacing: CGFloat = showBadges ? 24 : 16
            var grid = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: gridSpacing) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat(0), through: size.height, by: gridSpacing) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(MeasureStyle.accent.opacity(0.08)), lineWidth: 0.5)

            let scale = min((size.width - pad * 2) / (maxX - minX), (size.height - pad * 2) / (maxY - minY))
            func point(_ p: InteriorPoint) -> CGPoint {
                CGPoint(x: pad + (p.x - minX) * scale, y: pad + (p.y - minY) * scale)
            }
            func path(_ loops: [[InteriorPoint]]) -> Path {
                Path { path in
                    for loop in loops {
                        for (i, p) in loop.enumerated() {
                            if i == 0 { path.move(to: point(p)) } else { path.addLine(to: point(p)) }
                        }
                        path.closeSubpath()
                    }
                }
            }
            context.stroke(path(contours), with: .color(.gray), lineWidth: showBadges ? 2 : 1.5)
            if let inset {
                context.fill(path(inset), with: .color(.teal.opacity(0.32)), style: FillStyle(eoFill: true))
                context.stroke(path(inset), with: .color(MeasureStyle.accent.opacity(0.75)), lineWidth: 1)
            }
            if let outer = contours.first {
                if outer.count >= 2 {
                    var firstEdge = Path()
                    firstEdge.move(to: point(outer[0]))
                    firstEdge.addLine(to: point(outer[1]))
                    context.stroke(firstEdge, with: .color(.orange), lineWidth: showBadges ? 3 : 2)
                }
                guard showBadges else { return }
                let stride = outer.count <= 12 ? 1 : max(2, outer.count / 8)
                for (i, p) in outer.enumerated() where i <= 1 || i % stride == 0 {
                    let center = point(p)
                    let badge = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
                    context.fill(Path(ellipseIn: badge), with: .color(i == 0 ? .orange : .secondary))
                    context.draw(
                        Text("\(i + 1)").font(.caption2.weight(.bold)).foregroundStyle(.white),
                        at: center,
                        anchor: .center
                    )
                }
            }
        }
        .accessibilityLabel("Interior outline with \(max(0, contours.count - 1)) obstacle cutouts")
    }
}

