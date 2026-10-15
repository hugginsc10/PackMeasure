import SwiftUI

/// Optional independent measurement input. Unit changes only format the retained
/// millimeters; they never reparse a rounded display or modify captured geometry.
struct InteriorVerificationLengthDraft {
    private(set) var text: String
    private(set) var unit: InteriorUnit
    private(set) var millimeters: Double?

    init(millimeters: Double? = nil, unit: InteriorUnit = .millimeters) {
        self.millimeters = millimeters
        self.unit = unit
        text = millimeters.map { String(unit.value(fromMillimeters: $0)) } ?? ""
    }

    var isValid: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || millimeters != nil
    }

    mutating func setText(_ value: String) {
        text = value
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let number = Double(normalized), number.isFinite, number > 0 else {
            millimeters = nil
            return
        }
        let converted = unit.millimeters(from: number)
        millimeters = converted.isFinite && converted > 0 ? converted : nil
    }

    @discardableResult mutating func changeUnit(to next: InteriorUnit) -> Bool {
        guard isValid else { return false }
        unit = next
        text = millimeters.map { String(next.value(fromMillimeters: $0)) } ?? ""
        return true
    }
}

struct InteriorVerificationCard: View {
    @Binding var record: InteriorMeasurement
    @State private var editingMeasurements = false
    @State private var editingFit = false
    @Environment(AppPreferences.self) private var preferences

    private var original: InteriorGeometrySnapshot {
        record.originalGeometry?.geometry ?? record.geometrySnapshot
    }
    private var baselineTitle: String {
        record.originalGeometry?.source == .scanCapture ? "Original capture" : "Saved geometry baseline"
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text(baselineTitle).font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("verification-original-summary")
                Text(record.originalGeometry?.source == .scanCapture
                     ? "The original geometry is preserved separately from your corrections."
                     : "This older save may contain earlier corrections. Its saved geometry is preserved as the baseline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            dimensionRow("Along first edge", original: original.alongFirstEdgeMM,
                         current: record.geometrySnapshot.alongFirstEdgeMM,
                         measured: record.verification?.alongFirstEdgeMM,
                         identifier: "verification-along-reference")
            dimensionRow("Across first edge", original: original.acrossFirstEdgeMM,
                         current: record.geometrySnapshot.acrossFirstEdgeMM,
                         measured: record.verification?.acrossFirstEdgeMM,
                         identifier: "verification-across-reference")
            dimensionRow("Usable height", original: original.heightMM,
                         current: record.heightMM, measured: record.verification?.usableHeightMM,
                         identifier: "verification-height-reference")
            if let verification = record.verification {
                if verification.alongFirstEdgeMM != nil || verification.acrossFirstEdgeMM != nil || verification.usableHeightMM != nil {
                    LabeledContent("Measured with", value: verification.source)
                    LabeledContent("Measured on", value: verification.measuredAt.formatted(date: .abbreviated, time: .omitted))
                }
                if let height = verification.intendedInsertHeightMM {
                    LabeledContent("Intended insert height", value: preferences.units.preciseLength(millimeters: height))
                        .accessibilityIdentifier("verification-insert-height-reference")
                }
            }
            Text("Spans are bounding dimensions in the first-edge frame, not the narrowest opening or clearance at insert height. Measured values are notes; they do not reshape the outline or change clearance.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Add or edit measured dimensions") { editingMeasurements = true }
                .accessibilityIdentifier("edit-interior-verification")
                .sheet(isPresented: $editingMeasurements) {
                    InteriorVerificationEditor(verification: record.verification) { record.applyVerification($0) }
                }
            fitSummary
            Button("Record physical fit") { editingFit = true }
                .accessibilityIdentifier("record-interior-fit")
                .sheet(isPresented: $editingFit) {
                    InteriorPhysicalFitEditor(record: record) { status, note, date in
                        record.recordFit(status: status, note: note, at: date)
                    }
                }
            Text("Apply updates this review. Save interior to keep your changes.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Verify dimensions").accessibilityIdentifier("interior-verification-card")
        }
    }

    private func dimensionRow(_ title: String, original: Double?, current: Double?, measured: Double?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if let original { Text("Baseline: \(preferences.units.preciseLength(millimeters: original))").font(.caption).foregroundStyle(.secondary) }
            if let current { Text("Current: \(preferences.units.preciseLength(millimeters: current))").font(.caption).foregroundStyle(.secondary) }
            if let measured {
                Text("Measured: \(preferences.units.preciseLength(millimeters: measured))")
                if let original { Text("Measured − baseline: \(signedDifference(measured - original))").font(.caption).foregroundStyle(.secondary) }
                if let current { Text("Measured − current: \(signedDifference(measured - current))").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("No independent measurement").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func signedDifference(_ millimeters: Double) -> String {
        let prefix = millimeters > 0 ? "+" : millimeters < 0 ? "−" : ""
        return prefix + preferences.units.preciseLength(millimeters: abs(millimeters))
    }

    @ViewBuilder private var fitSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let fit = record.verification?.fit {
                Text(record.fitIsStale ? "Previous fit: \(fit.status.title) · needs recheck" : "Physical fit: \(fit.status.title)")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("verification-fit-state")
                if let summary = fitDateOrHistorySummary(fit.testedAt) {
                    Text(summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("verification-fit-history")
                }
                if let note = fit.note, !note.isEmpty { Text(note).font(.caption) }
                if record.fitIsStale {
                    Text("The outline, usable height, clearance or intended insert height changed, or the saved test details are incomplete. Test the current version again.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Physical fit: Not tested").font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("verification-fit-state")
                if let summary = fitDateOrHistorySummary(nil) {
                    Text(summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("verification-fit-history")
                }
            }
            Text("A recorded fit applies only to the version you physically tested; it does not verify LiDAR accuracy.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fitDateOrHistorySummary(_ date: Date?) -> String? {
        let historyCount = record.verification?.fitHistory.count ?? 0
        let historyLabel: String? = historyCount > 0
            ? "\(historyCount) earlier \(historyCount == 1 ? "test" : "tests")"
            : nil
        switch (date.map { $0.formatted(date: .abbreviated, time: .omitted) }, historyLabel) {
        case let (dateText?, historyText?):
            return "\(dateText) · \(historyText)"
        case let (dateText?, nil):
            return dateText
        case let (nil, historyText?):
            return historyText
        case (nil, nil):
            return nil
        }
    }
}

private struct InteriorVerificationEditor: View {
    let onApply: (InteriorVerification) -> Void
    @State private var along: InteriorVerificationLengthDraft
    @State private var across: InteriorVerificationLengthDraft
    @State private var height: InteriorVerificationLengthDraft
    @State private var insertHeight: InteriorVerificationLengthDraft
    @State private var unit: InteriorUnit = .millimeters
    @State private var source: String
    @State private var measuredAt: Date
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: String?

    init(verification: InteriorVerification?, onApply: @escaping (InteriorVerification) -> Void) {
        self.onApply = onApply
        _along = State(initialValue: .init(millimeters: verification?.alongFirstEdgeMM))
        _across = State(initialValue: .init(millimeters: verification?.acrossFirstEdgeMM))
        _height = State(initialValue: .init(millimeters: verification?.usableHeightMM))
        _insertHeight = State(initialValue: .init(millimeters: verification?.intendedInsertHeightMM))
        _source = State(initialValue: verification?.source ?? "Physical measurement")
        _measuredAt = State(initialValue: verification?.measurementEntryDate() ?? .now)
    }

    private var valid: Bool {
        [along, across, height, insertHeight].allSatisfy(\.isValid)
        && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Input units", selection: Binding(get: { unit }, set: { changeUnit($0) })) {
                        ForEach(InteriorUnit.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("verification-unit-picker")
                    Text("Independent measurements stay separate from the outline and clearance. Leave an optional value blank to remove it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Measured interior · optional") {
                    lengthField("Along first edge", draft: $along, identifier: "verification-along-value")
                    lengthField("Across first edge", draft: $across, identifier: "verification-across-value")
                    lengthField("Usable height", draft: $height, identifier: "verification-height-value")
                    TextField("Measurement source", text: $source)
                        .focused($focusedField, equals: "source")
                        .accessibilityIdentifier("verification-source")
                    DatePicker("Measured on", selection: $measuredAt, displayedComponents: .date)
                        .accessibilityIdentifier("verification-measured-date")
                    Text("Measure the overall spans in the scan’s first-edge frame. Also check narrow sections, obstacles and closed-drawer space before printing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Intended insert · optional") {
                    lengthField("Insert height", draft: $insertHeight, identifier: "verification-insert-height-value")
                    Text("Record the height of the insert you plan to test. This does not set usable height, subtract clearance or change the exported extrusion height.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !valid {
                    Section { Text("Use positive, finite dimensions or leave them blank. Enter a measurement source.").font(.footnote).foregroundStyle(.orange) }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange).accessibilityIdentifier("verification-input-error") } }
            }
            .accessibilityIdentifier("interior-verification-editor")
            .navigationTitle("Measured dimensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("cancel-interior-verification")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.disabled(!valid).accessibilityIdentifier("apply-interior-verification")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
        }
    }

    private func lengthField(_ title: String, draft: Binding<InteriorVerificationLengthDraft>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(unit.symbol))").font(.subheadline)
            TextField("Optional", text: Binding(get: { draft.wrappedValue.text }, set: { draft.wrappedValue.setText($0) }))
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: identifier)
                .accessibilityLabel("\(title) in \(unit.title.lowercased())")
                .accessibilityIdentifier(identifier)
        }
    }

    private func changeUnit(_ next: InteriorUnit) {
        guard [along, across, height, insertHeight].allSatisfy(\.isValid) else {
            error = "Correct the dimension or leave it blank before changing units."
            return
        }
        along.changeUnit(to: next)
        across.changeUnit(to: next)
        height.changeUnit(to: next)
        insertHeight.changeUnit(to: next)
        unit = next
        error = nil
    }

    private func apply() {
        do {
            let value = try InteriorVerification(alongFirstEdgeMM: along.millimeters,
                                                 acrossFirstEdgeMM: across.millimeters,
                                                 usableHeightMM: height.millimeters,
                                                 intendedInsertHeightMM: insertHeight.millimeters,
                                                 source: source, measuredAt: measuredAt)
            onApply(value)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct InteriorPhysicalFitEditor: View {
    let onApply: (InteriorFitStatus, String?, Date) -> Void
    @State private var status: InteriorFitStatus
    @State private var note: String
    @State private var testedAt: Date = .now
    let wasStale: Bool
    let fitHistory: [InteriorFitResult]
    @Environment(\.dismiss) private var dismiss
    @Environment(AppPreferences.self) private var preferences

    init(record: InteriorMeasurement, onApply: @escaping (InteriorFitStatus, String?, Date) -> Void) {
        self.onApply = onApply
        // A previous test cannot become current merely by opening this sheet.
        _status = State(initialValue: record.currentFitStatus)
        _note = State(initialValue: record.fitIsStale ? "" : record.verification?.fit?.note ?? "")
        _testedAt = State(initialValue: record.fitIsStale ? .now : record.verification?.fit?.testedAt ?? .now)
        wasStale = record.fitIsStale
        fitHistory = record.verification?.fitHistory ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Physical fit", selection: $status) {
                        ForEach(InteriorFitStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("verification-fit-status")
                    TextField("What did you test?", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .accessibilityIdentifier("verification-fit-note")
                    DatePicker("Tested on", selection: $testedAt, displayedComponents: .date)
                        .accessibilityIdentifier("verification-fit-date")
                    Text("Only record a result after physically checking an insert or test outline made for the current outline, height and clearance settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    if wasStale {
                        Text("The previous result needs a recheck. Apply records a new result for the current version.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if !fitHistory.isEmpty {
                    Section("Earlier fit tests") {
                        ForEach(fitHistory.indices, id: \.self) { index in
                            priorFitRow(fitHistory[fitHistory.count - 1 - index])
                        }
                    }
                }
            }
            .accessibilityIdentifier("verification-fit-editor")
            .navigationTitle("Physical fit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("cancel-interior-fit")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(status, note, testedAt)
                        dismiss()
                    }.accessibilityIdentifier("apply-interior-fit")
                }
            }
        }
    }

    private func priorFitRow(_ prior: InteriorFitResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(prior.status.title)
                .font(.subheadline.weight(.semibold))
            if let snapshot = prior.snapshot {
                let side = preferences.units.preciseLength(millimeters: snapshot.sideClearanceMM)
                let top = preferences.units.preciseLength(millimeters: snapshot.topClearanceMM)
                let height = preferences.units.preciseLength(millimeters: snapshot.heightMM)
                Text("\(side) side · \(top) top · \(height) height")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = prior.note, !note.isEmpty {
                Text(note).font(.caption)
            }
            if let date = prior.testedAt {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
