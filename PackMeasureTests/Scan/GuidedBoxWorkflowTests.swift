import XCTest
@testable import PackMeasure

final class GuidedBoxWorkflowTests: XCTestCase {
    private let gravity = SIMD3<Float>(0, -1, 0)

    func testStartsWithConciseReferencePromptAndAdvancesThroughFourPoints() {
        var workflow = GuidedBoxWorkflow()

        XCTAssertEqual(workflow.step, .referenceCorner)
        XCTAssertEqual(workflow.prompt, "Tap one visible box corner.")
        XCTAssertNil(workflow.pointToReplace)

        XCTAssertEqual(
            workflow.record(point: .zero, gravity: gravity),
            .advanced(to: .lengthEndpoint)
        )
        XCTAssertEqual(workflow.prompt, "Tap the end of the length edge from that corner.")
        XCTAssertEqual(
            workflow.record(point: SIMD3<Float>(0.6096, 0, 0), gravity: gravity),
            .advanced(to: .widthEndpoint)
        )
        XCTAssertEqual(workflow.prompt, "Tap the end of the width edge from that corner.")
        XCTAssertEqual(
            workflow.record(point: SIMD3<Float>(0, 0, 0.508), gravity: gravity),
            .advanced(to: .heightEndpoint)
        )
        XCTAssertEqual(workflow.prompt, "Tap the end of the height edge from that corner.")

        let update = workflow.record(
            point: SIMD3<Float>(0, 0.508, 0),
            gravity: gravity
        )

        guard case let .ready(measurement) = update else {
            return XCTFail("Expected a reviewable measurement, got \(update)")
        }
        XCTAssertEqual(workflow.step, .review)
        XCTAssertEqual(workflow.prompt, "Review the dimensions, then confirm.")
        XCTAssertEqual(workflow.measurement, measurement)
        XCTAssertNil(workflow.pointToReplace)
    }

    func testConfirmConvertsReviewIntoExistingSaveFlowEstimate() throws {
        var workflow = GuidedBoxWorkflow()
        recordValidBox(into: &workflow)

        let estimate = try XCTUnwrap(workflow.confirm())

        XCTAssertEqual(workflow.step, .complete)
        XCTAssertEqual(workflow.prompt, "Box measurement complete.")
        XCTAssertEqual(estimate.lengthMeters, 0.6096, accuracy: 0.000_01)
        XCTAssertEqual(estimate.widthMeters, 0.508, accuracy: 0.000_01)
        XCTAssertEqual(estimate.heightMeters, 0.508, accuracy: 0.000_01)
        XCTAssertEqual(estimate.confidence, .medium)
        XCTAssertEqual(estimate.sampleCount, 4)
        XCTAssertEqual(estimate.frameCount, 4)
        XCTAssertEqual(workflow.estimate, estimate)
        XCTAssertEqual(workflow.confirm(), estimate, "Confirming complete work is idempotent")
    }

    func testValidationIdentifiesLengthPointAndRevalidatesOnlyItsReplacement() {
        var workflow = GuidedBoxWorkflow()
        _ = workflow.record(point: .zero, gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0.02, 0, 0), gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0, 0, 0.5), gravity: gravity)

        let invalid = workflow.record(point: SIMD3<Float>(0, 0.5, 0), gravity: gravity)

        guard case let .needsReplacement(point, error) = invalid else {
            return XCTFail("Expected replacement guidance, got \(invalid)")
        }
        XCTAssertEqual(point, .lengthEndpoint)
        XCTAssertEqual(workflow.pointToReplace, .lengthEndpoint)
        XCTAssertEqual(workflow.step, .lengthEndpoint)
        XCTAssertEqual(workflow.prompt, error.localizedDescription)

        let repaired = workflow.record(point: SIMD3<Float>(0.6, 0, 0), gravity: gravity)

        guard case .ready = repaired else {
            return XCTFail("Expected retained points to revalidate, got \(repaired)")
        }
        XCTAssertEqual(workflow.step, .review)
    }

    func testValidationMapsEachErrorToTheActionablePoint() {
        assertReplacement(
            length: SIMD3<Float>(0.6, 0.25, 0),
            width: SIMD3<Float>(0, 0, 0.5),
            height: SIMD3<Float>(0, 0.5, 0),
            expected: .lengthEndpoint
        )
        assertReplacement(
            length: SIMD3<Float>(0.6, 0, 0),
            width: SIMD3<Float>(0, 0.25, 0.5),
            height: SIMD3<Float>(0, 0.5, 0),
            expected: .widthEndpoint
        )
        assertReplacement(
            length: SIMD3<Float>(0.6, 0, 0),
            width: SIMD3<Float>(0, 0, 0.5),
            height: SIMD3<Float>(0.25, 0.5, 0),
            expected: .heightEndpoint
        )
        assertReplacement(
            length: SIMD3<Float>(0.6, 0, 0),
            width: SIMD3<Float>(0.3, 0, 0.4),
            height: SIMD3<Float>(0, 0.5, 0),
            expected: .widthEndpoint
        )
    }

    func testInvalidReferenceAndGravitySelectThePointThatMustBeRetapped() {
        assertReplacement(
            reference: SIMD3<Float>(.nan, 0, 0),
            length: SIMD3<Float>(0.6, 0, 0),
            width: SIMD3<Float>(0, 0, 0.5),
            height: SIMD3<Float>(0, 0.5, 0),
            expected: .referenceCorner
        )

        var workflow = GuidedBoxWorkflow()
        _ = workflow.record(point: .zero, gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0.6, 0, 0), gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0, 0, 0.5), gravity: gravity)
        let update = workflow.record(point: SIMD3<Float>(0, 0.5, 0), gravity: .zero)

        guard case let .needsReplacement(point, error) = update else {
            return XCTFail("Expected gravity retry, got \(update)")
        }
        XCTAssertEqual(point, .heightEndpoint)
        XCTAssertEqual(error, .invalidGravity)
        XCTAssertEqual(workflow.step, .heightEndpoint)
    }

    func testBackMovesOneStepAndReviewBackReplacesHeight() {
        var workflow = GuidedBoxWorkflow()
        _ = workflow.record(point: .zero, gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0.6096, 0, 0), gravity: gravity)

        workflow.back()
        XCTAssertEqual(workflow.step, .lengthEndpoint)
        workflow.back()
        XCTAssertEqual(workflow.step, .referenceCorner)
        workflow.back()
        XCTAssertEqual(workflow.step, .referenceCorner)

        workflow.reset()
        recordValidBox(into: &workflow)
        workflow.back()

        XCTAssertEqual(workflow.step, .heightEndpoint)
        XCTAssertNil(workflow.measurement)
        XCTAssertNil(workflow.estimate)
        guard case .ready = workflow.record(
            point: SIMD3<Float>(0, 0.52, 0),
            gravity: gravity
        ) else {
            return XCTFail("Expected a replacement height to restore review")
        }
        XCTAssertEqual(workflow.step, .review)
    }

    func testResetClearsCompletedWorkflowAndRecordingDuringReviewIsIgnored() throws {
        var workflow = GuidedBoxWorkflow()
        recordValidBox(into: &workflow)
        let measurement = try XCTUnwrap(workflow.measurement)

        XCTAssertEqual(
            workflow.record(point: SIMD3<Float>(9, 9, 9), gravity: gravity),
            .ignored
        )
        XCTAssertEqual(workflow.measurement, measurement)
        _ = workflow.confirm()

        workflow.reset()

        XCTAssertEqual(workflow.step, .referenceCorner)
        XCTAssertNil(workflow.measurement)
        XCTAssertNil(workflow.estimate)
        XCTAssertNil(workflow.pointToReplace)
        XCTAssertEqual(workflow.prompt, "Tap one visible box corner.")
    }

    private func recordValidBox(into workflow: inout GuidedBoxWorkflow) {
        _ = workflow.record(point: .zero, gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0.6096, 0, 0), gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0, 0, 0.508), gravity: gravity)
        _ = workflow.record(point: SIMD3<Float>(0, 0.508, 0), gravity: gravity)
    }

    private func assertReplacement(
        reference: SIMD3<Float> = .zero,
        length: SIMD3<Float>,
        width: SIMD3<Float>,
        height: SIMD3<Float>,
        expected: GuidedBoxPoint,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var workflow = GuidedBoxWorkflow()
        _ = workflow.record(point: reference, gravity: gravity)
        _ = workflow.record(point: length, gravity: gravity)
        _ = workflow.record(point: width, gravity: gravity)
        let update = workflow.record(point: height, gravity: gravity)

        guard case let .needsReplacement(point, _) = update else {
            return XCTFail("Expected replacement guidance, got \(update)", file: file, line: line)
        }
        XCTAssertEqual(point, expected, file: file, line: line)
        XCTAssertEqual(workflow.pointToReplace, expected, file: file, line: line)
        XCTAssertEqual(workflow.step.point, expected, file: file, line: line)
    }
}
