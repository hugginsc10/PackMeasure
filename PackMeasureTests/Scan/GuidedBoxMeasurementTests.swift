import XCTest
@testable import PackMeasure

final class GuidedBoxMeasurementTests: XCTestCase {
    private let inch: Float = 0.0254

    func testMeasuresKnownBoxFromFourSharedCornerTaps() throws {
        let capture = GuidedBoxCapture(
            referenceCorner: SIMD3<Float>(0.2, 0.3, -1.1),
            lengthEndpoint: SIMD3<Float>(0.2 + 24 * inch, 0.3, -1.1),
            widthEndpoint: SIMD3<Float>(0.2, 0.3, -1.1 - 20 * inch),
            heightEndpoint: SIMD3<Float>(0.2, 0.3 + 20 * inch, -1.1),
            gravity: SIMD3<Float>(0, -1, 0)
        )

        let measurement = try GuidedBoxMeasurementEstimator().estimate(capture)

        assertInches(measurement.dimensions, length: 24, width: 20, height: 20)
        XCTAssertEqual(measurement.rawEdgeLengthsMeters.length, Double(24 * inch), accuracy: 0.000_01)
        XCTAssertEqual(measurement.rawEdgeLengthsMeters.width, Double(20 * inch), accuracy: 0.000_01)
        XCTAssertEqual(measurement.rawEdgeLengthsMeters.height, Double(20 * inch), accuracy: 0.000_01)
    }

    func testMeasuresYawedBoxIndependentlyOfWorldAxes() throws {
        let yaw = Float.pi * 0.31
        let lengthDirection = SIMD3<Float>(cos(yaw), 0, sin(yaw))
        let widthDirection = SIMD3<Float>(-sin(yaw), 0, cos(yaw))
        let origin = SIMD3<Float>(-0.4, 0.15, 0.8)
        let capture = GuidedBoxCapture(
            referenceCorner: origin,
            lengthEndpoint: origin + lengthDirection * (36 * inch),
            widthEndpoint: origin + widthDirection * (18 * inch),
            heightEndpoint: origin + SIMD3<Float>(0, 28 * inch, 0),
            gravity: SIMD3<Float>(0, -9.81, 0)
        )

        let measurement = try GuidedBoxMeasurementEstimator().estimate(capture)

        assertInches(measurement.dimensions, length: 36, width: 18, height: 28)
    }

    func testReturnsPackingConservativeDimensionsByRoundingUpAndSortingFootprint() throws {
        let capture = GuidedBoxCapture(
            referenceCorner: .zero,
            lengthEndpoint: SIMD3<Float>(19.01 * inch, 0, 0),
            widthEndpoint: SIMD3<Float>(0, 23.51 * inch, 0),
            heightEndpoint: SIMD3<Float>(0, 0, 17.01 * inch),
            gravity: SIMD3<Float>(0, 0, -1)
        )

        let measurement = try GuidedBoxMeasurementEstimator().estimate(capture)

        assertInches(measurement.dimensions, length: 24, width: 19.5, height: 17.5)
    }

    func testAcceptsEitherDirectionAlongGravityForHeightEdge() throws {
        let capture = GuidedBoxCapture(
            referenceCorner: SIMD3<Float>(0, 1, 0),
            lengthEndpoint: SIMD3<Float>(0.6, 1, 0),
            widthEndpoint: SIMD3<Float>(0, 1, 0.5),
            heightEndpoint: SIMD3<Float>(0, 0.5, 0),
            gravity: SIMD3<Float>(0, -1, 0)
        )

        let measurement = try GuidedBoxMeasurementEstimator().estimate(capture)

        XCTAssertEqual(measurement.dimensions.heightMeters, 0.5, accuracy: 0.000_01)
    }

    func testRejectsEveryEdgeShorterThanMinimum() {
        for edge in GuidedBoxEdge.allCases {
            var capture = validCapture()
            switch edge {
            case .length:
                capture.lengthEndpoint = capture.referenceCorner + SIMD3<Float>(0.02, 0, 0)
            case .width:
                capture.widthEndpoint = capture.referenceCorner + SIMD3<Float>(0, 0, 0.02)
            case .height:
                capture.heightEndpoint = capture.referenceCorner + SIMD3<Float>(0, 0.02, 0)
            }

            XCTAssertThrowsError(try GuidedBoxMeasurementEstimator().estimate(capture)) { error in
                guard case let GuidedBoxMeasurementError.edgeTooShort(actualEdge, actual, minimum) = error else {
                    return XCTFail("Expected short-edge error for \(edge), got \(error)")
                }
                XCTAssertEqual(actualEdge, edge)
                XCTAssertLessThan(actual, minimum)
                XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains(edge.rawValue))
            }
        }
    }

    func testRejectsLengthOrWidthThatIsNotHorizontal() {
        for edge in [GuidedBoxEdge.length, .width] {
            var capture = validCapture()
            let tilted = SIMD3<Float>(0.45, 0.22, 0)
            if edge == .length {
                capture.lengthEndpoint = capture.referenceCorner + tilted
            } else {
                capture.widthEndpoint = capture.referenceCorner + SIMD3<Float>(0, tilted.y, tilted.x)
            }

            XCTAssertThrowsError(try GuidedBoxMeasurementEstimator().estimate(capture)) { error in
                guard case let GuidedBoxMeasurementError.edgeNotHorizontal(actualEdge, deviation, maximum) = error else {
                    return XCTFail("Expected horizontal-edge error for \(edge), got \(error)")
                }
                XCTAssertEqual(actualEdge, edge)
                XCTAssertGreaterThan(deviation, maximum)
                XCTAssertTrue(error.localizedDescription.contains("level"))
            }
        }
    }

    func testRejectsHeightThatDoesNotFollowGravity() {
        var capture = validCapture()
        capture.heightEndpoint = capture.referenceCorner + SIMD3<Float>(0.25, 0.30, 0)

        XCTAssertThrowsError(try GuidedBoxMeasurementEstimator().estimate(capture)) { error in
            guard case let GuidedBoxMeasurementError.heightNotGravityAligned(deviation, maximum) = error else {
                return XCTFail("Expected gravity-alignment error, got \(error)")
            }
            XCTAssertGreaterThan(deviation, maximum)
            XCTAssertTrue(error.localizedDescription.contains("vertical"))
        }
    }

    func testRejectsHorizontalEdgesThatDoNotMeetAtSquareCorner() {
        var capture = validCapture()
        capture.widthEndpoint = capture.referenceCorner + SIMD3<Float>(0.30, 0, 0.40)

        XCTAssertThrowsError(try GuidedBoxMeasurementEstimator().estimate(capture)) { error in
            guard case let GuidedBoxMeasurementError.edgesNotPerpendicular(first, second, deviation, maximum) = error else {
                return XCTFail("Expected perpendicular-edge error, got \(error)")
            }
            XCTAssertEqual(first, .length)
            XCTAssertEqual(second, .width)
            XCTAssertGreaterThan(deviation, maximum)
            XCTAssertTrue(error.localizedDescription.contains("square corner"))
        }
    }

    func testRejectsHeightEdgeThatIsNotPerpendicularUnderStrictConfiguration() {
        let configuration = GuidedBoxMeasurementEstimator.Configuration(
            maximumHorizontalDeviationDegrees: 30,
            maximumHeightDeviationDegrees: 30,
            maximumPerpendicularDeviationDegrees: 8
        )
        var capture = validCapture()
        capture.heightEndpoint = capture.referenceCorner + SIMD3<Float>(0.12, 0.48, 0)

        XCTAssertThrowsError(
            try GuidedBoxMeasurementEstimator(configuration: configuration).estimate(capture)
        ) { error in
            guard case let GuidedBoxMeasurementError.edgesNotPerpendicular(first, second, _, _) = error else {
                return XCTFail("Expected perpendicular-edge error, got \(error)")
            }
            XCTAssertEqual(first, .length)
            XCTAssertEqual(second, .height)
        }
    }

    func testRejectsUnavailableGravityAndNonFiniteTap() {
        var capture = validCapture()
        capture.gravity = .zero

        XCTAssertThrowsError(try GuidedBoxMeasurementEstimator().estimate(capture)) { error in
            XCTAssertEqual(error as? GuidedBoxMeasurementError, .invalidGravity)
            XCTAssertTrue(error.localizedDescription.contains("tracking"))
        }

        capture = validCapture()
        capture.widthEndpoint.x = .nan

        XCTAssertThrowsError(try GuidedBoxMeasurementEstimator().estimate(capture)) { error in
            XCTAssertEqual(error as? GuidedBoxMeasurementError, .nonFinitePoint(.widthEndpoint))
            XCTAssertTrue(error.localizedDescription.contains("width point"))
        }
    }

    func testRejectsInvalidConfiguration() {
        let invalid = GuidedBoxMeasurementEstimator.Configuration(
            minimumEdgeMeters: 0,
            roundingIncrementMeters: -1
        )

        XCTAssertThrowsError(
            try GuidedBoxMeasurementEstimator(configuration: invalid).estimate(validCapture())
        ) { error in
            XCTAssertEqual(error as? GuidedBoxMeasurementError, .invalidConfiguration)
        }
    }

    private func validCapture() -> GuidedBoxCapture {
        GuidedBoxCapture(
            referenceCorner: .zero,
            lengthEndpoint: SIMD3<Float>(0.6, 0, 0),
            widthEndpoint: SIMD3<Float>(0, 0, 0.5),
            heightEndpoint: SIMD3<Float>(0, 0.5, 0),
            gravity: SIMD3<Float>(0, -1, 0)
        )
    }

    private func assertInches(
        _ dimensions: GeometryDimensions,
        length: Double,
        width: Double,
        height: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let converted = dimensions.converted(to: .inches)
        XCTAssertEqual(converted.length, length, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(converted.width, width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(converted.height, height, accuracy: 0.001, file: file, line: line)
    }
}
