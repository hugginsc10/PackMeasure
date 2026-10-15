import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Interior physical verification and fit history")
struct InteriorVerificationTests {
    let date = Date(timeIntervalSinceReferenceDate: 123456)
    var record: InteriorMeasurement {
        InteriorMeasurement(name: "Notched cabinet", contours: [
            [.init(x: 0, y: 0), .init(x: 400, y: 0), .init(x: 400, y: 200),
             .init(x: 200, y: 200), .init(x: 200, y: 300), .init(x: 0, y: 300)],
            [.init(x: 100, y: 100), .init(x: 150, y: 100), .init(x: 150, y: 150), .init(x: 100, y: 150)]
        ], heightMM: 100, heightSource: .lidar, sideClearanceMM: 2.5, topClearanceMM: 3)
    }

    func json(_ value: InteriorMeasurement) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func decode(_ object: [String: Any]) throws -> InteriorMeasurement {
        try JSONDecoder().decode(InteriorMeasurement.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func legacyRecordDecodesWithoutInventingOriginalCaptureOrChecks() throws {
        let original = record
        var object = try json(original)
        object.removeValue(forKey: "originalGeometry")
        object.removeValue(forKey: "verification")
        var restored = try decode(object)
        #expect(restored == original)
        #expect(restored.originalGeometry == nil && restored.verification == nil)
        #expect(restored.currentFitStatus == .notTested && !restored.fitIsStale)
        #expect(try restored.svg() == original.svg())
        restored.preserveOriginalGeometry(at: date)
        #expect(restored.originalGeometry?.source == .savedGeometry)
        #expect(restored.originalGeometry?.geometry == original.geometrySnapshot)
    }

    @Test func preservesFirstGeometryThroughRepeatedCorrectionsAndReopening() throws {
        var value = record
        value.preserveOriginalGeometry(source: .scanCapture, at: date)
        let original = value.originalGeometry
        value.contours[0][1].x = 398
        value.heightMM = 98
        value.heightSource = .entered
        value.sideClearanceMM = 4
        value.preserveOriginalGeometry(source: .savedGeometry)
        value.contours[1][0].x = 99
        value.topClearanceMM = 5
        value.preserveOriginalGeometry(source: .scanCapture)
        let restored = try JSONDecoder().decode(InteriorMeasurement.self, from: JSONEncoder().encode(value))
        #expect(restored.originalGeometry == original)
        #expect(restored.originalGeometry?.geometry.contours == record.contours)
        #expect(restored.originalGeometry?.geometry.heightMM == 100)
        #expect(restored.originalGeometry?.geometry.sideClearanceMM == 2.5)
        #expect(restored.geometrySnapshot != original?.geometry)
    }

    @Test @MainActor func scannerFreezesReviewGeometryBeforeFormCorrections() throws {
        let state = InteriorScanState()
        state.useManual()
        state.loops = [[SIMD3(0, 0, 0), SIMD3(0.4, 0, 0), SIMD3(0.4, 0, 0.3), SIMD3(0, 0, 0.3)]]
        state.finishLoop(addObstacle: false)
        state.enterHeight(100)
        var value = try #require(state.result)
        let captured = try #require(value.originalGeometry)
        #expect(captured.source == .scanCapture)
        #expect(captured.preservedAt == value.capturedAt)
        #expect(captured.geometry == value.geometrySnapshot)
        value.heightMM = 90
        value.contours[0][1].x = 390
        #expect(value.originalGeometry == captured)
    }

    @Test func independentValuesAndFitLeaveGeometryAndSVGUnchanged() throws {
        var value = record
        let geometry = value.geometrySnapshot
        let svg = try value.svg()
        value.applyVerification(try InteriorVerification(alongFirstEdgeMM: 399.25, acrossFirstEdgeMM: 298.5,
                                                        usableHeightMM: 98.75, intendedInsertHeightMM: 80,
                                                        source: "  Caliper and tape  ", measuredAt: date))
        value.recordFit(status: .interference, note: "  Hinge catches on entry  ", at: date)
        #expect(value.geometrySnapshot == geometry)
        #expect(try value.svg() == svg)
        #expect(value.verification?.source == "Caliper and tape")
        #expect(value.verification?.fit?.note == "Hinge catches on entry")
        #expect(value.currentFitStatus == .interference && !value.fitIsStale)
        #expect(value.verification?.usableHeightMM == 98.75)
        #expect(value.heightMM == 100 && value.topClearanceMM == 3)
        #expect(value.geometrySnapshot.alongFirstEdgeMM == 400)
        #expect(value.geometrySnapshot.acrossFirstEdgeMM == 300)
    }

    @Test func firstPhysicalMeasurementDoesNotInheritAnEarlierPlanningOrFitDate() throws {
        let today = date.addingTimeInterval(86_400 * 30)
        let planning = try InteriorVerification(intendedInsertHeightMM: 80, measuredAt: date)
        #expect(planning.measurementEntryDate(now: today) == today)
        var fitOnly = record
        fitOnly.recordFit(status: .fits, at: date)
        #expect(try #require(fitOnly.verification).measurementEntryDate(now: today) == today)
        for measurements in [
            try InteriorVerification(alongFirstEdgeMM: 400, measuredAt: date),
            try InteriorVerification(acrossFirstEdgeMM: 300, measuredAt: date),
            try InteriorVerification(usableHeightMM: 100, measuredAt: date)
        ] {
            #expect(measurements.measurementEntryDate(now: today) == date)
        }
    }

    @Test func optionalLengthsRejectZeroNegativeAndNonfiniteValuesInEveryField() {
        for invalid in [0.0, -1, .nan, .infinity, -.infinity] {
            #expect(throws: InteriorVerificationError.self) { try InteriorVerification(alongFirstEdgeMM: invalid) }
            #expect(throws: InteriorVerificationError.self) { try InteriorVerification(acrossFirstEdgeMM: invalid) }
            #expect(throws: InteriorVerificationError.self) { try InteriorVerification(usableHeightMM: invalid) }
            #expect(throws: InteriorVerificationError.self) { try InteriorVerification(intendedInsertHeightMM: invalid) }
        }
        #expect(throws: InteriorVerificationError.self) { try InteriorVerification(usableHeightMM: 100, source: " \n ") }
        #expect(throws: InteriorVerificationError.self) {
            try InteriorVerification(measuredAt: Date(timeIntervalSinceReferenceDate: .infinity))
        }
    }

    @Test func inchCentimeterAndMillimeterInputsStoreEquivalentCanonicalMeasurements() throws {
        for unit in InteriorUnit.allCases {
            let value = 88.9123
            let input = unit.value(fromMillimeters: value)
            let verification = try InteriorVerification(usableHeightMM: unit.millimeters(from: input),
                                                       intendedInsertHeightMM: unit.millimeters(from: input), measuredAt: date)
            #expect(abs(try #require(verification.usableHeightMM) - value) < 0.000001)
            #expect(abs(try #require(verification.intendedInsertHeightMM) - value) < 0.000001)
        }
    }

    @Test func eachManufacturingChangeMakesHistoricalFitStale() throws {
        var tested = record
        tested.applyVerification(try InteriorVerification(intendedInsertHeightMM: 80, measuredAt: date))
        tested.recordFit(status: .fits, note: "Seats without force", at: date)
        let result = tested.verification?.fit
        let edits: [(inout InteriorMeasurement) throws -> Void] = [
            { $0.contours[0][1].x -= 1 },
            { $0.contours[1][0].x -= 1 },
            { $0.heightMM -= 1 },
            { $0.sideClearanceMM += 0.5 },
            { $0.topClearanceMM += 0.5 },
            { $0.applyVerification(try InteriorVerification(intendedInsertHeightMM: 81, measuredAt: date)) }
        ]
        for edit in edits {
            var changed = tested
            try edit(&changed)
            #expect(changed.fitIsStale)
            #expect(changed.currentFitStatus == .notTested)
            #expect(changed.verification?.fit == result)
        }
        // Physical observations are annotations, so changing them does not revise
        // an unchanged artifact or renew an earlier result.
        tested.applyVerification(try InteriorVerification(alongFirstEdgeMM: 401, intendedInsertHeightMM: 80,
                                                         source: "Different tape", measuredAt: date))
        #expect(!tested.fitIsStale && tested.currentFitStatus == .fits)
        #expect(tested.verification?.fit == result)
        tested.name = "Renamed cabinet"
        tested.heightSource = .entered
        #expect(!tested.fitIsStale)
    }

    @Test func explicitRetestBindsNewSettingsAndNotTestedClearsTheClaim() {
        var value = record
        value.recordFit(status: .tooTight, at: date)
        value.sideClearanceMM = 4
        #expect(value.fitIsStale)
        value.recordFit(status: .fits, at: date.addingTimeInterval(60))
        #expect(!value.fitIsStale && value.currentFitStatus == .fits)
        #expect(value.verification?.fit?.testedAt == date.addingTimeInterval(60))
        value.recordFit(status: .notTested)
        #expect(!value.fitIsStale && value.currentFitStatus == .notTested)
        #expect(value.verification?.fit?.snapshot == nil)
        #expect(value.verification?.fit?.testedAt == nil)
    }

    @Test func realInteriorStoreRoundtripPreservesOriginalAnnotationsAndStaleFit() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InteriorStore(url: directory.appending(path: "interiors.json"))
        var value = record
        value.preserveOriginalGeometry(source: .scanCapture, at: date)
        value.applyVerification(try InteriorVerification(alongFirstEdgeMM: 399.75, usableHeightMM: 97.5,
                                                        intendedInsertHeightMM: 85, source: "Ruler", measuredAt: date))
        value.recordFit(status: .tooLoose, note: "Front edge", at: date)
        value.contours[0][1].x = 399
        try store.save([value])
        let restored = try #require(store.load().first)
        #expect(restored == value)
        #expect(restored.fitIsStale && restored.currentFitStatus == .notTested)
        #expect(restored.verification?.fit?.status == .tooLoose)
        #expect(restored.originalGeometry?.source == .scanCapture)
        #expect(try restored.svg() == value.svg())
    }

    @Test func malformedOptionalMetadataDoesNotHideReadableSavedGeometry() throws {
        var value = record
        value.preserveOriginalGeometry(source: .scanCapture, at: date)
        value.applyVerification(try InteriorVerification(alongFirstEdgeMM: 400, measuredAt: date))
        var object = try json(value)
        var verification = try #require(object["verification"] as? [String: Any])
        verification["alongFirstEdgeMM"] = -1
        object["verification"] = verification
        var original = try #require(object["originalGeometry"] as? [String: Any])
        var geometry = try #require(original["geometry"] as? [String: Any])
        geometry["contours"] = []
        original["geometry"] = geometry
        object["originalGeometry"] = original
        let restored = try decode(object)
        #expect(restored.verification == nil && restored.originalGeometry == nil)
        #expect(restored.geometrySnapshot == value.geometrySnapshot)
        #expect(try restored.svg() == value.svg())
    }

    @Test func malformedFitBindingRetainsHistoryButCannotClaimCurrentFit() throws {
        var value = record
        value.recordFit(status: .fits, note: "Historical test", at: date)
        var object = try json(value)
        var verification = try #require(object["verification"] as? [String: Any])
        var fit = try #require(verification["fit"] as? [String: Any])
        var binding = try #require(fit["snapshot"] as? [String: Any])
        binding["heightMM"] = -1
        fit["snapshot"] = binding
        verification["fit"] = fit
        object["verification"] = verification
        let restored = try decode(object)
        #expect(restored.verification?.fit?.status == .fits)
        #expect(restored.verification?.fit?.note == "Historical test")
        #expect(restored.verification?.fit?.snapshot == nil)
        #expect(restored.fitIsStale && restored.currentFitStatus == .notTested)
    }

    @Test func datelessHistoricalFitCannotClaimCurrentFitEvenWithMatchingGeometry() throws {
        var value = record
        value.recordFit(status: .fits, note: "Historical fit", at: date)
        var object = try json(value)
        var verification = try #require(object["verification"] as? [String: Any])
        var fit = try #require(verification["fit"] as? [String: Any])
        fit.removeValue(forKey: "testedAt")
        verification["fit"] = fit
        object["verification"] = verification
        let restored = try decode(object)
        #expect(restored.verification?.fit?.status == .fits)
        #expect(restored.verification?.fit?.snapshot != nil)
        #expect(restored.fitIsStale && restored.currentFitStatus == .notTested)
    }

    @Test func multiAttemptFitHistoryPreservesSupersededTestsAndUpdatesSameTestNoteInPlace() throws {
        var value = record
        value.recordFit(status: .tooTight, note: "Coupon 1 at 2.5 mm side clearance", at: date)
        #expect(value.verification?.fitHistory.isEmpty == true)
        // Updating the note on the same geometry and status updates in place without duplicating history.
        value.recordFit(status: .tooTight, note: "Coupon 1 at 2.5 mm clearance (front binds)", at: date.addingTimeInterval(30))
        #expect(value.verification?.fitHistory.isEmpty == true)
        #expect(value.verification?.fit?.note == "Coupon 1 at 2.5 mm clearance (front binds)")

        // Adjusting side clearance and recording a second coupon archives Coupon 1 in fitHistory.
        value.sideClearanceMM = 3.0
        value.recordFit(status: .fits, note: "Coupon 2 at 3.0 mm clearance", at: date.addingTimeInterval(120))
        let history = try #require(value.verification?.fitHistory)
        #expect(history.count == 1)
        #expect(history[0].status == .tooTight)
        #expect(history[0].snapshot?.sideClearanceMM == 2.5)
        #expect(value.verification?.fit?.status == .fits)
        #expect(value.verification?.fit?.snapshot?.sideClearanceMM == 3.0)

        // Applying measured dimensions preserves both current fit and fitHistory.
        value.applyVerification(try InteriorVerification(alongFirstEdgeMM: 399.5, source: "Caliper", measuredAt: date))
        #expect(value.verification?.fitHistory.count == 1)
        #expect(value.verification?.fit?.status == .fits)

        let restored = try JSONDecoder().decode(InteriorMeasurement.self, from: JSONEncoder().encode(value))
        #expect(restored.verification?.fitHistory == history)
    }
}
