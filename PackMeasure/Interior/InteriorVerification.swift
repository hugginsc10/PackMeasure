import Foundation

/// A copy of the geometry being reviewed. Verification values never replace it.
struct InteriorGeometrySnapshot: Codable, Equatable, Sendable {
    let contours: [[InteriorPoint]]
    let heightMM: Double
    let heightSource: InteriorMeasurement.HeightSource?
    let sideClearanceMM: Double
    let topClearanceMM: Double
    let footprintModel: InteriorFootprintModel?

    /// Spans use the same coordinate frame as the existing review and SVG.
    var alongFirstEdgeMM: Double? { span(\.x) }
    var acrossFirstEdgeMM: Double? { span(\.y) }

    private func span(_ axis: KeyPath<InteriorPoint, Double>) -> Double? {
        guard let outer = contours.first, !outer.isEmpty else { return nil }
        let values = outer.map { $0[keyPath: axis] }
        guard values.allSatisfy(\.isFinite), let low = values.min(), let high = values.max() else { return nil }
        let result = high - low
        return result.isFinite ? result : nil
    }

    private enum CodingKeys: String, CodingKey {
        case contours, heightMM, heightSource, sideClearanceMM, topClearanceMM, footprintModel
    }

    init(contours: [[InteriorPoint]], heightMM: Double, heightSource: InteriorMeasurement.HeightSource?,
         sideClearanceMM: Double, topClearanceMM: Double, footprintModel: InteriorFootprintModel?) {
        self.contours = contours
        self.heightMM = heightMM
        self.heightSource = heightSource
        self.sideClearanceMM = sideClearanceMM
        self.topClearanceMM = topClearanceMM
        self.footprintModel = footprintModel
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(contours: try values.decode([[InteriorPoint]].self, forKey: .contours),
                  heightMM: try values.decode(Double.self, forKey: .heightMM),
                  heightSource: try values.decodeIfPresent(InteriorMeasurement.HeightSource.self, forKey: .heightSource),
                  sideClearanceMM: try values.decode(Double.self, forKey: .sideClearanceMM),
                  topClearanceMM: try values.decode(Double.self, forKey: .topClearanceMM),
                  footprintModel: try values.decodeIfPresent(InteriorFootprintModel.self, forKey: .footprintModel))
        try InteriorGeometry.validate(contours)
        guard heightMM.isFinite, heightMM > 0,
              sideClearanceMM.isFinite, sideClearanceMM >= 0,
              topClearanceMM.isFinite, topClearanceMM >= 0 else {
            throw InteriorVerificationError.invalidLength
        }
    }
}

struct InteriorOriginalGeometry: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Created when the scanner first produces its review measurement.
        case scanCapture
        /// A legacy saved record; its unavailable original capture is not inferred.
        case savedGeometry
    }

    let geometry: InteriorGeometrySnapshot
    let source: Source
    let preservedAt: Date

    init(geometry: InteriorGeometrySnapshot, source: Source, preservedAt: Date) {
        self.geometry = geometry; self.source = source; self.preservedAt = preservedAt
    }

    private enum CodingKeys: String, CodingKey { case geometry, source, preservedAt }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(geometry: try values.decode(InteriorGeometrySnapshot.self, forKey: .geometry),
                  source: try values.decode(Source.self, forKey: .source),
                  preservedAt: try values.decode(Date.self, forKey: .preservedAt))
        guard preservedAt.timeIntervalSinceReferenceDate.isFinite else { throw InteriorVerificationError.invalidDate }
    }
}

enum InteriorFitStatus: String, Codable, CaseIterable, Sendable {
    case notTested, fits, tooTight, tooLoose, interference

    var title: String {
        switch self {
        case .notTested: "Not tested"
        case .fits: "Fits"
        case .tooTight: "Too tight"
        case .tooLoose: "Too loose"
        case .interference: "Interference"
        }
    }
}

/// The settings that a physical fit result applies to, not an accuracy certificate.
struct InteriorFitSnapshot: Codable, Equatable, Sendable {
    let contours: [[InteriorPoint]]
    let heightMM: Double
    let sideClearanceMM: Double
    let topClearanceMM: Double
    let intendedInsertHeightMM: Double?

    private enum CodingKeys: String, CodingKey {
        case contours, heightMM, sideClearanceMM, topClearanceMM, intendedInsertHeightMM
    }

    init(contours: [[InteriorPoint]], heightMM: Double, sideClearanceMM: Double,
         topClearanceMM: Double, intendedInsertHeightMM: Double?) {
        self.contours = contours
        self.heightMM = heightMM
        self.sideClearanceMM = sideClearanceMM
        self.topClearanceMM = topClearanceMM
        self.intendedInsertHeightMM = intendedInsertHeightMM
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(contours: try values.decode([[InteriorPoint]].self, forKey: .contours),
                  heightMM: try values.decode(Double.self, forKey: .heightMM),
                  sideClearanceMM: try values.decode(Double.self, forKey: .sideClearanceMM),
                  topClearanceMM: try values.decode(Double.self, forKey: .topClearanceMM),
                  intendedInsertHeightMM: try values.decodeIfPresent(Double.self, forKey: .intendedInsertHeightMM))
        try InteriorGeometry.validate(contours)
        guard heightMM.isFinite, heightMM > 0,
              sideClearanceMM.isFinite, sideClearanceMM >= 0,
              topClearanceMM.isFinite, topClearanceMM >= 0,
              intendedInsertHeightMM.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw InteriorVerificationError.invalidLength
        }
    }
}

struct InteriorFitResult: Codable, Equatable, Sendable {
    let status: InteriorFitStatus
    let note: String?
    let testedAt: Date?
    let snapshot: InteriorFitSnapshot?

    init(status: InteriorFitStatus, note: String?, testedAt: Date?, snapshot: InteriorFitSnapshot?) {
        self.status = status
        self.note = note
        self.testedAt = testedAt
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey { case status, note, testedAt, snapshot }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decode(InteriorFitStatus.self, forKey: .status)
        note = try values.decodeIfPresent(String.self, forKey: .note)
        testedAt = try values.decodeIfPresent(Date.self, forKey: .testedAt)
        guard testedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            throw InteriorVerificationError.invalidDate
        }
        // A damaged/missing binding can retain a historical result, but cannot
        // establish a current fit. fitIsStale deliberately rejects nil snapshots.
        snapshot = try? values.decodeIfPresent(InteriorFitSnapshot.self, forKey: .snapshot)
    }
}

enum InteriorVerificationError: Error, LocalizedError {
    case invalidLength
    case missingSource
    case invalidDate

    var errorDescription: String? {
        switch self {
        case .invalidLength: "Enter a positive, finite measurement, or leave it blank."
        case .missingSource: "Add the source or tool used for your physical measurements."
        case .invalidDate: "Choose a valid measurement or fit-test date."
        }
    }
}

/// Independent physical observations and intended insert height, all stored in mm.
/// These annotations do not correct the outline, captured height or export settings.
struct InteriorVerification: Codable, Equatable, Sendable {
    let alongFirstEdgeMM: Double?
    let acrossFirstEdgeMM: Double?
    let usableHeightMM: Double?
    let intendedInsertHeightMM: Double?
    let source: String
    let measuredAt: Date
    var fit: InteriorFitResult?
    var fitHistory: [InteriorFitResult]

    /// Fit/planning-only notes do not establish when a ruler measurement occurred.
    func measurementEntryDate(now: Date = .now) -> Date {
        [alongFirstEdgeMM, acrossFirstEdgeMM, usableHeightMM].contains(where: { $0 != nil })
            ? measuredAt : now
    }

    init(alongFirstEdgeMM: Double? = nil, acrossFirstEdgeMM: Double? = nil,
         usableHeightMM: Double? = nil, intendedInsertHeightMM: Double? = nil,
         source: String = "Physical measurement", measuredAt: Date = .now,
         fit: InteriorFitResult? = nil, fitHistory: [InteriorFitResult] = []) throws {
        let lengths = [alongFirstEdgeMM, acrossFirstEdgeMM, usableHeightMM, intendedInsertHeightMM]
        guard lengths.compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw InteriorVerificationError.invalidLength
        }
        guard measuredAt.timeIntervalSinceReferenceDate.isFinite else { throw InteriorVerificationError.invalidDate }
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if [alongFirstEdgeMM, acrossFirstEdgeMM, usableHeightMM].contains(where: { $0 != nil }) && source.isEmpty {
            throw InteriorVerificationError.missingSource
        }
        self.alongFirstEdgeMM = alongFirstEdgeMM
        self.acrossFirstEdgeMM = acrossFirstEdgeMM
        self.usableHeightMM = usableHeightMM
        self.intendedInsertHeightMM = intendedInsertHeightMM
        self.source = source
        self.measuredAt = measuredAt
        self.fit = fit
        self.fitHistory = fitHistory.filter { $0.status != .notTested }
    }

    private enum CodingKeys: String, CodingKey {
        case alongFirstEdgeMM, acrossFirstEdgeMM, usableHeightMM, intendedInsertHeightMM
        case source, measuredAt, fit, fitHistory
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(alongFirstEdgeMM: values.decodeIfPresent(Double.self, forKey: .alongFirstEdgeMM),
                      acrossFirstEdgeMM: values.decodeIfPresent(Double.self, forKey: .acrossFirstEdgeMM),
                      usableHeightMM: values.decodeIfPresent(Double.self, forKey: .usableHeightMM),
                      intendedInsertHeightMM: values.decodeIfPresent(Double.self, forKey: .intendedInsertHeightMM),
                      source: values.decodeIfPresent(String.self, forKey: .source) ?? "Physical measurement",
                      measuredAt: values.decode(Date.self, forKey: .measuredAt),
                      fit: try? values.decodeIfPresent(InteriorFitResult.self, forKey: .fit),
                      fitHistory: (try? values.decodeIfPresent([InteriorFitResult].self, forKey: .fitHistory)) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(alongFirstEdgeMM, forKey: .alongFirstEdgeMM)
        try container.encodeIfPresent(acrossFirstEdgeMM, forKey: .acrossFirstEdgeMM)
        try container.encodeIfPresent(usableHeightMM, forKey: .usableHeightMM)
        try container.encodeIfPresent(intendedInsertHeightMM, forKey: .intendedInsertHeightMM)
        try container.encode(source, forKey: .source)
        try container.encode(measuredAt, forKey: .measuredAt)
        try container.encodeIfPresent(fit, forKey: .fit)
        if !fitHistory.isEmpty {
            try container.encode(fitHistory, forKey: .fitHistory)
        }
    }
}

extension InteriorMeasurement {
    var geometrySnapshot: InteriorGeometrySnapshot {
        InteriorGeometrySnapshot(contours: contours, heightMM: heightMM, heightSource: heightSource,
                                 sideClearanceMM: sideClearanceMM, topClearanceMM: topClearanceMM,
                                 footprintModel: footprintModel)
    }

    mutating func preserveOriginalGeometry(source: InteriorOriginalGeometry.Source = .savedGeometry,
                                          at date: Date = .now) {
        guard originalGeometry == nil, date.timeIntervalSinceReferenceDate.isFinite else { return }
        originalGeometry = InteriorOriginalGeometry(geometry: geometrySnapshot, source: source, preservedAt: date)
    }

    /// Annotation edits retain an earlier test; they never silently re-test it.
    mutating func applyVerification(_ new: InteriorVerification) {
        preserveOriginalGeometry()
        var new = new
        if new.fit == nil { new.fit = verification?.fit }
        if new.fitHistory.isEmpty { new.fitHistory = verification?.fitHistory ?? [] }
        verification = new
    }

    private var fitSnapshot: InteriorFitSnapshot {
        InteriorFitSnapshot(contours: contours, heightMM: heightMM,
                            sideClearanceMM: sideClearanceMM, topClearanceMM: topClearanceMM,
                            intendedInsertHeightMM: verification?.intendedInsertHeightMM)
    }

    var fitIsStale: Bool {
        guard let fit = verification?.fit, fit.status != .notTested else { return false }
        return fit.testedAt == nil || fit.snapshot == nil || fit.snapshot != fitSnapshot
    }

    /// The historical result remains available through verification.fit when stale.
    var currentFitStatus: InteriorFitStatus {
        fitIsStale ? .notTested : verification?.fit?.status ?? .notTested
    }

    mutating func recordFit(status: InteriorFitStatus, note: String? = nil, at date: Date = .now) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        preserveOriginalGeometry()
        // No physical dimensions are inferred when recording a fit alone.
        guard var values = verification ?? (try? InteriorVerification()) else { return }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSnapshot = status == .notTested ? nil : fitSnapshot
        if let previous = values.fit,
           previous.status != .notTested,
           fitIsStale || previous.snapshot != currentSnapshot || previous.status != status {
            values.fitHistory.append(previous)
            if values.fitHistory.count > 10 {
                values.fitHistory.removeFirst(values.fitHistory.count - 10)
            }
        }
        values.fit = InteriorFitResult(status: status,
                                       note: trimmedNote?.isEmpty == false ? trimmedNote : nil,
                                       testedAt: status == .notTested ? nil : date,
                                       snapshot: currentSnapshot)
        verification = values
    }
}
