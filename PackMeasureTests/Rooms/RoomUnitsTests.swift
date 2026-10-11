import XCTest
@testable import PackMeasure

final class RoomUnitsTests: XCTestCase {
    func testCentimeterEntryConvertsWithoutRoundingTheMeasurement() throws {
        var entry = RoomLengthEntry()
        entry.centimeters = "123.4567"
        let expected = try XCTUnwrap(entry.value(in: .centimeters))
        XCTAssertEqual(expected, 1.234567, accuracy: 0.000001)

        try entry.convert(from: .centimeters)
        for units in RoomEntryUnits.allCases {
            XCTAssertEqual(try XCTUnwrap(entry.value(in: units)), expected, accuracy: 0.000001)
            try entry.convert(from: units)
        }
        // Editing the new representation invalidates the preserved metric value.
        entry.totalInches = "80"
        XCTAssertEqual(try XCTUnwrap(entry.value(in: .inches)), 2.032, accuracy: 0.000001)
        try entry.convert(from: .inches)
        XCTAssertEqual(try XCTUnwrap(entry.value(in: .centimeters)), 2.032, accuracy: 0.000001)
    }

    func testInvalidScalarInputsDoNotConvertOrReplaceAnEntry() throws {
        for text in ["invalid", "-1", "nan", "inf", "100001"] {
            var entry = RoomLengthEntry()
            entry.centimeters = text
            XCTAssertThrowsError(try entry.convert(from: .centimeters))
            XCTAssertEqual(entry.centimeters, text)
            XCTAssertEqual(entry.totalInches, "")
        }
        XCTAssertNil(try RoomLengthEntry().value(in: .centimeters))
        XCTAssertNil(try RoomLengthEntry().value(in: .inches))
        XCTAssertEqual(RoomEntryUnits(preferred: .inches), .inches)
        XCTAssertEqual(RoomEntryUnits(preferred: .centimeters), .centimeters)
        XCTAssertEqual(RoomEntryUnits(preferred: .both), .inches)
    }

    func testRoomSharingUsesSelectedUnitsForWallsCeilingAndShelves() throws {
        let shelf = try RoomShelfMeasurement(name: "Shelf", depth: 0.3048, heightAboveFloor: 1.2192,
                                             clearanceAbove: nil, source: .manual)
        let walls = [
            wall([0, 0], [3, 0], height: 2.4), wall([3, 0], [3, 2], height: 2.7),
            wall([3, 2], [0, 2], height: 2.4), wall([0, 2], [0, 0], height: 2.7)
        ]
        let room = try MeasuredRoom(walls: walls, captureSource: .liveSnapshot,
                                    ceilingHeight: RoomCeilingHeight(meters: 2.7432), shelves: [shelf])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(room)
        let metric = room.shareText(units: .centimeters)
        XCTAssertTrue(metric.contains("Ceiling height: 274.3 cm"))
        XCTAssertTrue(metric.contains("Wall 1: 300.0 cm long × 240.0 cm high"))
        XCTAssertTrue(metric.contains("Shelf: depth 30.48 cm; top above floor 121.92 cm"))
        XCTAssertTrue(metric.contains("Live outline · unprocessed"))
        XCTAssertEqual(room.heightReviewMessage(units: .centimeters),
                       "Captured wall heights range from 240.0 cm to 270.0 cm. Check the upper inside corners and exclude outside walls. Wall heights do not verify the ceiling.")
        let imperial = room.shareText(units: .inches)
        XCTAssertTrue(imperial.contains("Wall 1: 9 ft 10 in long"))
        XCTAssertTrue(imperial.contains("Shelf: depth 12.00 in; top above floor 48.00 in"))
        XCTAssertFalse(imperial.contains(" cm"))
        XCTAssertTrue(room.shareText(units: .both).contains("9 ft 10 in · 300.0 cm"))
        XCTAssertEqual(try encoder.encode(room), original)
        XCTAssertTrue(room.shareText.contains("3.00 m · 9.8 ft"), "Legacy format remains available to older callers")
    }

    func testFloorplanLengthLabelsUseExplicitUnitsWhileWallIDsStayStable() {
        let sample = wall([0, 0], [2, 0], height: 2.4)
        XCTAssertEqual(FloorplanLabelMode.lengths.text(for: sample, index: 4, units: .inches), "6 ft 7 in")
        XCTAssertEqual(FloorplanLabelMode.lengths.text(for: sample, index: 4, units: .centimeters), "200.0 cm")
        XCTAssertEqual(FloorplanLabelMode.lengths.text(for: sample, index: 4, units: .both), "6 ft 7 in · 200.0 cm")
        for units in MeasurementUnits.allCases {
            XCTAssertEqual(FloorplanLabelMode.wallIDs.text(for: sample, index: 4, units: units), "5")
        }
    }

    private func wall(_ start: SIMD2<Float>, _ end: SIMD2<Float>, height: Float) -> MeasuredRoom.Wall {
        .init(id: UUID(), start: start, end: end, height: height, confidence: "high")
    }
}
