import XCTest
@testable import PackMeasure

final class GuidedBoxCaptureSessionTests: XCTestCase {
    private let context = GuidedBoxCaptureContext(
        measurementSeriesID: 42,
        targetID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )
    private let gravity = SIMD3<Float>(0, -1, 0)
    private let stablePose = GuidedBoxCapturePose(
        position: SIMD3<Float>(0.1, 1.2, -0.4),
        orientation: SIMD4<Float>(0, 0, 0, 1)
    )

    func testEvidencePolicyKeepsAutomaticAndGuidedPathsSeparate() {
        let policy = MeasurementEvidenceSeparationPolicy()

        XCTAssertTrue(policy.accepts(.automaticPhoto, for: .automaticPhotos))
        XCTAssertFalse(policy.accepts(.guidedLidarCorners, for: .automaticPhotos))
        XCTAssertTrue(policy.accepts(.guidedLidarCorners, for: .guidedCorners))
        XCTAssertFalse(policy.accepts(.automaticPhoto, for: .guidedCorners))
    }

    func testRequestCarriesSeriesTargetStepAndPose() throws {
        var session = GuidedBoxCaptureSession(context: context)

        let request = try XCTUnwrap(
            session.beginRequest(requestID: 7, requestedPose: stablePose)
        )

        XCTAssertEqual(request.requestID, 7)
        XCTAssertEqual(request.context, context)
        XCTAssertEqual(request.point, .referenceCorner)
        XCTAssertEqual(request.requestedPose, stablePose)
        XCTAssertEqual(session.pendingRequest, request)
        XCTAssertNil(
            session.beginRequest(requestID: 8, requestedPose: stablePose),
            "Only one guided point request may be in flight"
        )
    }

    func testFourLidarSamplesBuildNumberedMarkersLinesAndGuidedResult() throws {
        var session = GuidedBoxCaptureSession(context: context)

        XCTAssertEqual(
            record(.referenceCorner, at: .zero, requestID: 1, in: &session),
            .workflow(.advanced(to: .lengthEndpoint))
        )
        assertOverlay(session.overlay, markerNumbers: [1], lineEndpoints: [])

        XCTAssertEqual(
            record(
                .lengthEndpoint,
                at: SIMD3<Float>(0.6096, 0, 0),
                requestID: 2,
                in: &session
            ),
            .workflow(.advanced(to: .widthEndpoint))
        )
        assertOverlay(session.overlay, markerNumbers: [1, 2], lineEndpoints: [.lengthEndpoint])

        XCTAssertEqual(
            record(
                .widthEndpoint,
                at: SIMD3<Float>(0, 0, 0.508),
                requestID: 3,
                in: &session
            ),
            .workflow(.advanced(to: .heightEndpoint))
        )
        assertOverlay(
            session.overlay,
            markerNumbers: [1, 2, 3],
            lineEndpoints: [.lengthEndpoint, .widthEndpoint]
        )

        let fourthUpdate = record(
            .heightEndpoint,
            at: SIMD3<Float>(0, 0.508, 0),
            requestID: 4,
            in: &session
        )
        guard case .workflow(.ready) = fourthUpdate else {
            return XCTFail("Expected a reviewable guided measurement, got \(fourthUpdate)")
        }
        assertOverlay(
            session.overlay,
            markerNumbers: [1, 2, 3, 4],
            lineEndpoints: [.lengthEndpoint, .widthEndpoint, .heightEndpoint]
        )

        let result = try XCTUnwrap(session.confirm())

        XCTAssertEqual(result.source, .guidedLidarCorners)
        XCTAssertEqual(result.context, context)
        XCTAssertEqual(result.estimate.confidence, .medium)
        XCTAssertEqual(result.provenance.map(\.point), GuidedBoxPoint.captureOrder)
        XCTAssertTrue(result.provenance.allSatisfy { $0.source == .guidedLidarCorners })
        XCTAssertEqual(session.confirm(), result, "Guided confirmation should be idempotent")
    }

    func testMatchingWrongSourceConsumesRequestWithoutAddingMarker() throws {
        var session = GuidedBoxCaptureSession(context: context)
        let request = try XCTUnwrap(
            session.beginRequest(requestID: 1, requestedPose: stablePose)
        )
        let sample = sample(
            for: request,
            worldPosition: .zero,
            source: .automaticPhoto
        )

        XCTAssertEqual(
            session.consume(sample),
            .rejected(.wrongEvidenceSource(expected: .guidedLidarCorners, actual: .automaticPhoto))
        )
        XCTAssertNil(session.pendingRequest, "A matching consumed request must always terminate")
        XCTAssertEqual(session.step, .referenceCorner)
        XCTAssertTrue(session.overlay.isEmpty)
    }

    func testStaleCallbackCannotConsumeCurrentRequest() throws {
        var session = GuidedBoxCaptureSession(context: context)
        let current = try XCTUnwrap(
            session.beginRequest(requestID: 12, requestedPose: stablePose)
        )
        var staleProvenance = provenance(for: current)
        staleProvenance.requestID = 11

        let update = session.consume(
            GuidedBoxPointSample(
                provenance: staleProvenance,
                worldPosition: .zero,
                gravity: gravity,
                capturedPose: stablePose
            )
        )

        XCTAssertEqual(update, .ignored(.requestMismatch(expected: 12, actual: 11)))
        XCTAssertEqual(session.pendingRequest, current)
        XCTAssertTrue(session.overlay.isEmpty)
    }

    func testSeriesOrTargetMismatchConsumesMatchingRequestAndFailsClosed() throws {
        var session = GuidedBoxCaptureSession(context: context)
        let request = try XCTUnwrap(
            session.beginRequest(requestID: 1, requestedPose: stablePose)
        )
        let wrongContext = GuidedBoxCaptureContext(
            measurementSeriesID: context.measurementSeriesID + 1,
            targetID: UUID()
        )
        var wrongProvenance = provenance(for: request)
        wrongProvenance.context = wrongContext

        XCTAssertEqual(
            session.consume(
                GuidedBoxPointSample(
                    provenance: wrongProvenance,
                    worldPosition: .zero,
                    gravity: gravity,
                    capturedPose: stablePose
                )
            ),
            .rejected(.contextMismatch(expected: context, actual: wrongContext))
        )
        XCTAssertNil(session.pendingRequest)
        XCTAssertTrue(session.overlay.isEmpty)
    }

    func testTranslationOrRotationBeyondSettledFrameLimitConsumesRequest() throws {
        var translatedSession = GuidedBoxCaptureSession(context: context)
        let translatedRequest = try XCTUnwrap(
            translatedSession.beginRequest(requestID: 1, requestedPose: stablePose)
        )
        let translatedPose = GuidedBoxCapturePose(
            position: stablePose.position + SIMD3<Float>(0.031, 0, 0),
            orientation: stablePose.orientation
        )

        let translationUpdate = translatedSession.consume(
            sample(
                for: translatedRequest,
                worldPosition: .zero,
                capturedPose: translatedPose
            )
        )

        guard case let .rejected(.cameraMoved(translation, maximumTranslation, _, _)) =
            translationUpdate else {
            return XCTFail("Expected translation rejection, got \(translationUpdate)")
        }
        XCTAssertEqual(translation, 0.031, accuracy: 0.000_01)
        XCTAssertEqual(maximumTranslation, 0.03, accuracy: 0.000_01)
        XCTAssertNil(translatedSession.pendingRequest)
        XCTAssertTrue(translatedSession.overlay.isEmpty)

        var rotatedSession = GuidedBoxCaptureSession(context: context)
        let rotatedRequest = try XCTUnwrap(
            rotatedSession.beginRequest(requestID: 1, requestedPose: stablePose)
        )
        let rotatedPose = GuidedBoxCapturePose(
            position: stablePose.position,
            orientation: yawQuaternion(degrees: 4.1)
        )

        let rotationUpdate = rotatedSession.consume(
            sample(
                for: rotatedRequest,
                worldPosition: .zero,
                capturedPose: rotatedPose
            )
        )

        guard case let .rejected(.cameraMoved(_, _, rotation, maximumRotation)) =
            rotationUpdate else {
            return XCTFail("Expected rotation rejection, got \(rotationUpdate)")
        }
        XCTAssertEqual(rotation, 4.1, accuracy: 0.001)
        XCTAssertEqual(maximumRotation, 4, accuracy: 0.000_01)
        XCTAssertNil(rotatedSession.pendingRequest)
        XCTAssertTrue(rotatedSession.overlay.isEmpty)
    }

    func testBackDropsSelectedAndDependentMarkersWithoutReusingStalePoints() {
        var session = GuidedBoxCaptureSession(context: context)
        _ = record(.referenceCorner, at: .zero, requestID: 1, in: &session)
        _ = record(
            .lengthEndpoint,
            at: SIMD3<Float>(0.6096, 0, 0),
            requestID: 2,
            in: &session
        )
        _ = record(
            .widthEndpoint,
            at: SIMD3<Float>(0, 0, 0.508),
            requestID: 3,
            in: &session
        )
        _ = record(
            .heightEndpoint,
            at: SIMD3<Float>(0, 0.508, 0),
            requestID: 4,
            in: &session
        )

        session.back()
        XCTAssertEqual(session.step, .heightEndpoint)
        assertOverlay(
            session.overlay,
            markerNumbers: [1, 2, 3],
            lineEndpoints: [.lengthEndpoint, .widthEndpoint]
        )

        session.back()
        XCTAssertEqual(session.step, .widthEndpoint)
        assertOverlay(session.overlay, markerNumbers: [1, 2], lineEndpoints: [.lengthEndpoint])

        let replacement = record(
            .widthEndpoint,
            at: SIMD3<Float>(0, 0, 0.55),
            requestID: 5,
            in: &session
        )

        XCTAssertEqual(replacement, .workflow(.advanced(to: .heightEndpoint)))
        XCTAssertEqual(session.step, .heightEndpoint)
        assertOverlay(
            session.overlay,
            markerNumbers: [1, 2, 3],
            lineEndpoints: [.lengthEndpoint, .widthEndpoint]
        )
    }

    func testGeometryReplacementDropsOnlyRejectedMarkerAndKeepsOtherThree() {
        var session = GuidedBoxCaptureSession(context: context)
        _ = record(.referenceCorner, at: .zero, requestID: 1, in: &session)
        _ = record(
            .lengthEndpoint,
            at: SIMD3<Float>(0.6, 0, 0),
            requestID: 2,
            in: &session
        )
        _ = record(
            .widthEndpoint,
            at: SIMD3<Float>(0.3, 0, 0.4),
            requestID: 3,
            in: &session
        )

        let update = record(
            .heightEndpoint,
            at: SIMD3<Float>(0, 0.5, 0),
            requestID: 4,
            in: &session
        )

        guard case .workflow(.needsReplacement(point: .widthEndpoint, error: _)) = update else {
            return XCTFail("Expected width replacement, got \(update)")
        }
        XCTAssertEqual(session.step, .widthEndpoint)
        assertOverlay(
            session.overlay,
            markerNumbers: [1, 2, 4],
            lineEndpoints: [.lengthEndpoint, .heightEndpoint]
        )

        let repaired = record(
            .widthEndpoint,
            at: SIMD3<Float>(0, 0, 0.5),
            requestID: 5,
            in: &session
        )
        guard case .workflow(.ready) = repaired else {
            return XCTFail("Expected replacement to restore review, got \(repaired)")
        }
        assertOverlay(
            session.overlay,
            markerNumbers: [1, 2, 3, 4],
            lineEndpoints: [.lengthEndpoint, .widthEndpoint, .heightEndpoint]
        )
    }

    func testEveryLifecycleBoundaryClearsRequestsMarkersLinesTargetAndResult() throws {
        for boundary in GuidedBoxLifecycleBoundary.allCases {
            var session = GuidedBoxCaptureSession(context: context)
            _ = record(.referenceCorner, at: .zero, requestID: 1, in: &session)
            _ = record(
                .lengthEndpoint,
                at: SIMD3<Float>(0.6, 0, 0),
                requestID: 2,
                in: &session
            )
            let delayedRequest = try XCTUnwrap(
                session.beginRequest(requestID: 3, requestedPose: stablePose)
            )

            session.clear(for: boundary)

            XCTAssertFalse(session.isActive, "Boundary \(boundary) must deactivate the session")
            XCTAssertNil(session.context)
            XCTAssertNil(session.pendingRequest)
            XCTAssertEqual(session.step, .referenceCorner)
            XCTAssertTrue(session.overlay.isEmpty)
            XCTAssertTrue(session.samples.isEmpty)
            XCTAssertNil(session.measurementResult)
            XCTAssertEqual(
                session.consume(sample(for: delayedRequest, worldPosition: SIMD3<Float>(0, 0, 0.5))),
                .ignored(.inactive)
            )
        }
    }

    func testNewSeriesRejectsOldContextEvenWhenRequestIDIsReused() throws {
        var session = GuidedBoxCaptureSession(context: context)
        let oldRequest = try XCTUnwrap(
            session.beginRequest(requestID: 1, requestedPose: stablePose)
        )
        session.clear(for: .restart)

        let newContext = GuidedBoxCaptureContext(
            measurementSeriesID: context.measurementSeriesID + 1,
            targetID: UUID()
        )
        session.start(context: newContext)
        let newRequest = try XCTUnwrap(
            session.beginRequest(requestID: 1, requestedPose: stablePose)
        )

        XCTAssertEqual(
            session.consume(sample(for: oldRequest, worldPosition: .zero)),
            .rejected(.contextMismatch(expected: newContext, actual: context))
        )
        XCTAssertNil(session.pendingRequest)
        XCTAssertEqual(session.step, .referenceCorner)
        XCTAssertTrue(session.overlay.isEmpty)

        let retry = try XCTUnwrap(
            session.beginRequest(requestID: 2, requestedPose: stablePose)
        )
        XCTAssertEqual(retry.context, newRequest.context)
    }

    private func record(
        _ expectedPoint: GuidedBoxPoint,
        at worldPosition: SIMD3<Float>,
        requestID: Int,
        in session: inout GuidedBoxCaptureSession
    ) -> GuidedBoxCaptureSessionUpdate {
        guard let request = session.beginRequest(
            requestID: requestID,
            requestedPose: stablePose
        ) else {
            XCTFail("Expected request \(requestID) for \(expectedPoint)")
            return .ignored(.noPendingRequest)
        }
        XCTAssertEqual(request.point, expectedPoint)
        return session.consume(sample(for: request, worldPosition: worldPosition))
    }

    private func sample(
        for request: GuidedBoxCaptureRequest,
        worldPosition: SIMD3<Float>,
        source: MeasurementEvidenceSource = .guidedLidarCorners,
        capturedPose: GuidedBoxCapturePose? = nil
    ) -> GuidedBoxPointSample {
        var provenance = provenance(for: request)
        provenance.source = source
        return GuidedBoxPointSample(
            provenance: provenance,
            worldPosition: worldPosition,
            gravity: gravity,
            capturedPose: capturedPose ?? stablePose
        )
    }

    private func provenance(
        for request: GuidedBoxCaptureRequest
    ) -> GuidedBoxPointProvenance {
        GuidedBoxPointProvenance(
            requestID: request.requestID,
            context: request.context,
            point: request.point,
            source: .guidedLidarCorners
        )
    }

    private func yawQuaternion(degrees: Float) -> SIMD4<Float> {
        let halfRadians = degrees * .pi / 360
        return SIMD4<Float>(0, sin(halfRadians), 0, cos(halfRadians))
    }

    private func assertOverlay(
        _ overlay: GuidedBoxOverlay,
        markerNumbers: [Int],
        lineEndpoints: [GuidedBoxPoint],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(overlay.markers.map(\.number), markerNumbers, file: file, line: line)
        XCTAssertEqual(overlay.lines.map(\.endpoint), lineEndpoints, file: file, line: line)
        XCTAssertTrue(
            overlay.lines.allSatisfy { $0.reference == .referenceCorner },
            file: file,
            line: line
        )
    }
}
