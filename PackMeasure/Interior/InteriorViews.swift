import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

struct InteriorLibraryView: View {
    @State private var records: [InteriorMeasurement] = []
    @State private var showingScanner = false
    @State private var error: String?
    @State private var loaded = false
    private let store = InteriorStore()
    var body: some View {
        List {
            Section {
                Button { showingScanner = true } label: { Label("Scan drawer or interior", systemImage: "viewfinder") }
                    .disabled(!loaded)
                Text("Capture an irregular floor outline, exclude obstacles, and export a millimeter SVG for CAD. Saved interiors are separate from cargo inventory.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Saved interiors") {
                ForEach(records) { record in
                    NavigationLink {
                        InteriorReviewView(record: record, onSave: save)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(record.name)
                            Text("\(record.contours.first?.count ?? 0) perimeter points · \(record.capturedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    var next = records
                    next.remove(atOffsets: offsets)
                    do { try store.save(next); records = next } catch { self.error = error.localizedDescription }
                }
                if records.isEmpty { Text("No interior scans saved yet.").foregroundStyle(.secondary) }
            }
            if let error { Section("Could not save or load") { Text(error).foregroundStyle(.orange) } }
        }
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
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .svg) { value in
            Data(value.svg.utf8)
        }
        .suggestedFileName("interior-insert.svg")
    }
}

struct InteriorReviewView: View {
    @State var record: InteriorMeasurement
    var onSave: (InteriorMeasurement) throws -> Void
    @State private var exporting = false
    @State private var document = InteriorSVGDocument(text: "")
    @State private var message: String?
    private var output: Result<[[InteriorPoint]], Error> { Result { try record.insertContours() } }
    var body: some View {
        Form {
            Section("Inside footprint · millimeters") {
                InteriorOutlineView(contours: record.contours, inset: try? output.get())
                    .frame(height: 220)
                Text("Gray: captured boundary · Teal: insert footprint · Blank cutouts: obstacles")
                    .font(.caption).foregroundStyle(.secondary)
                if let outer = record.contours.first,
                   let minX = outer.map(\.x).min(), let maxX = outer.map(\.x).max(),
                   let minY = outer.map(\.y).min(), let maxY = outer.map(\.y).max() {
                    LabeledContent("Overall span along first edge", value: "\((maxX - minX).formatted(.number.precision(.fractionLength(1)))) mm")
                    LabeledContent("Overall span across first edge", value: "\((maxY - minY).formatted(.number.precision(.fractionLength(1)))) mm")
                }
                Text("Overall spans are bounding dimensions; an irregular insert must follow the outline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Insert settings") {
                TextField("Interior name", text: $record.name)
                HStack {
                    Text("Usable height (mm)")
                    TextField("Height", value: $record.heightMM, format: .number.precision(.fractionLength(1)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                Stepper("Side clearance: \(record.sideClearanceMM.formatted()) mm", value: $record.sideClearanceMM, in: 0...30, step: 0.5)
                Stepper("Top clearance: \(record.topClearanceMM.formatted()) mm", value: $record.topClearanceMM, in: 0...30, step: 0.5)
                Text("Side clearance is applied at every wall and around obstacles. A rectangular insert loses twice this amount per horizontal dimension. Top clearance is subtracted once from usable height.")
                    .font(.caption).foregroundStyle(.secondary)
                if case .success = output {
                    LabeledContent("Draft extrusion height", value: "\((record.heightMM - record.topClearanceMM).formatted(.number.precision(.fractionLength(1)))) mm")
                } else if case .failure(let error) = output {
                    Text(error.localizedDescription).foregroundStyle(.orange)
                }
            }
            Section("Verify or correct the outline") {
                Text("Coordinates are in mm, relative to point 1. The first edge defines the horizontal axis. Use physical measurements to correct points before exporting.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(record.contours.indices, id: \.self) { loopIndex in
                    DisclosureGroup(loopIndex == 0 ? "Inside perimeter" : "Obstacle \(loopIndex)") {
                        ForEach(record.contours[loopIndex].indices, id: \.self) { pointIndex in
                            HStack {
                                Text("\(pointIndex + 1)")
                                TextField("X (mm)", value: $record.contours[loopIndex][pointIndex].x, format: .number)
                                    .accessibilityLabel("Point \(pointIndex + 1) X in millimeters")
                                TextField("Y (mm)", value: $record.contours[loopIndex][pointIndex].y, format: .number)
                                    .accessibilityLabel("Point \(pointIndex + 1) Y in millimeters")
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
                    ShareLink(item: InteriorSVGTransfer(svg: svg), preview: SharePreview("Interior insert SVG")) {
                        Label("Share SVG", systemImage: "square.and.arrow.up")
                    }
                }
                if let message { Text(message).font(.footnote) }
            }
        }
        .navigationTitle("Interior draft")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentType: .svg, defaultFilename: "interior-insert") { result in
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
    var body: some View {
        Canvas { context, size in
            let all = contours.flatMap { $0 }
            guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
                  let minY = all.map(\.y).min(), let maxY = all.map(\.y).max(),
                  maxX > minX, maxY > minY else { return }
            let scale = min((size.width - 24) / (maxX - minX), (size.height - 24) / (maxY - minY))
            func path(_ loops: [[InteriorPoint]]) -> Path {
                Path { path in
                    for loop in loops {
                        for (i, p) in loop.enumerated() {
                            let point = CGPoint(x: 12 + (p.x - minX) * scale, y: 12 + (p.y - minY) * scale)
                            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        path.closeSubpath()
                    }
                }
            }
            context.stroke(path(contours), with: .color(.gray), lineWidth: 2)
            if let inset { context.fill(path(inset), with: .color(.teal.opacity(0.35)), style: FillStyle(eoFill: true)) }
        }
        .accessibilityLabel("Interior outline with \(max(0, contours.count - 1)) obstacle cutouts")
    }
}
