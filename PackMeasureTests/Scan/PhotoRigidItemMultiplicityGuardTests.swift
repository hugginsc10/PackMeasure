import XCTest
import simd
@testable import PackMeasure

final class PhotoRigidItemMultiplicityGuardTests: XCTestCase {
    func testRejectsTwoStackedRigidBodiesWithDifferentFootprints() {
        let points = rectangularBody(
            center: SIMD2<Float>(-0.02, 0.01),
            size: SIMD2<Float>(0.42, 0.34),
            minY: 0,
            maxY: 0.44
        ) + rectangularBody(
            center: SIMD2<Float>(0.04, -0.03),
            size: SIMD2<Float>(0.60, 0.48),
            minY: 0.44,
            maxY: 0.91
        )

        guard case .multipleRigidItems(let evidence) =
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points) else {
            return XCTFail("A strong footprint step between two stacked boxes must fail closed")
        }

        XCTAssertEqual(evidence.splitHeightFraction, 0.48, accuracy: 0.08)
        XCTAssertGreaterThanOrEqual(evidence.significantBoundaryCount, 2)
        XCTAssertGreaterThan(evidence.maximumBoundaryShiftMeters, 0.07)
    }

    func testRejectsOffsetStackedRigidBodiesWithMatchingDimensions() {
        let points = rectangularBody(
            center: SIMD2<Float>(-0.045, 0.035),
            size: SIMD2<Float>(0.52, 0.40),
            minY: 0,
            maxY: 0.46
        ) + rectangularBody(
            center: SIMD2<Float>(0.045, -0.035),
            size: SIMD2<Float>(0.52, 0.40),
            minY: 0.46,
            maxY: 0.92
        )

        guard case .multipleRigidItems(let evidence) =
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points) else {
            return XCTFail("A persistent offset at an interior stacking plane must be rejected")
        }

        XCTAssertGreaterThanOrEqual(evidence.significantBoundaryCount, 2)
        XCTAssertGreaterThan(evidence.maximumBoundaryShiftMeters, 0.06)
    }

    func testReturnsInsufficientForPhoto5LikeStackWithOneStrongPersistentBoundaryShift() {
        // The lower carton shares three footprint boundaries with the tall
        // upper carton and extends only to the right. This mirrors a partially
        // occluded supporting box: the change is substantial and persistent,
        // but the Build 36 two-boundary rule labels the union as one item.
        let lower = rectangularBody(
            center: SIMD2<Float>(0.08, 0),
            size: SIMD2<Float>(0.64, 0.38),
            minY: 0,
            maxY: 0.28,
            layerCount: 14
        )
        let upper = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.48, 0.38),
            minY: 0.28,
            maxY: 0.96,
            layerCount: 36
        )

        let evaluation = PhotoRigidItemMultiplicityGuard().evaluate(
            worldPoints: lower + upper
        )

        XCTAssertEqual(evaluation.assessment, .insufficientEvidence)
        XCTAssertEqual(evaluation.indeterminateReason, .oneStrongBoundary)
        XCTAssertEqual(evaluation.candidateEvidence?.significantBoundaryCount, 1)
        XCTAssertGreaterThan(
            evaluation.candidateEvidence?.maximumBoundaryShiftMeters ?? 0,
            0.12
        )
    }

    func testReturnsInsufficientWhenPhoto5SeamIsUnassessableDespiteComparableUpperBands() {
        // The lower support and tall upper carton have a real one-sided
        // footprint step, but LiDAR has no usable bands around their seam.
        // The upper carton still has plenty of internally comparable bands;
        // those bands cannot prove that the entire merged selection is one
        // rigid item.
        let lower = rectangularSlices(
            yValues: [0.025, 0.075, 0.125],
            center: SIMD2<Float>(0.08, 0),
            size: SIMD2<Float>(0.64, 0.38),
            edgeSampleCount: 4
        )
        let upper = rectangularSlices(
            yValues: (6...19).map { 0.025 + Float($0) * 0.05 },
            center: .zero,
            size: SIMD2<Float>(0.48, 0.38),
            edgeSampleCount: 4
        )

        let evaluation = PhotoRigidItemMultiplicityGuard().evaluate(
            worldPoints: lower + upper
        )

        XCTAssertGreaterThan(
            evaluation.usableBinCount,
            6,
            "The fixture must retain valid comparable coverage away from the true seam"
        )
        XCTAssertEqual(
            evaluation.assessment,
            .insufficientEvidence,
            "Comparable bands inside the upper carton must not turn an unassessable merged seam into a single-item verdict"
        )
    }

    func testReturnsInsufficientForSingleCuboidWithAsymmetricVisibilityBoundary() {
        // This is one 0.64 m-wide cuboid. Its lower body exposes the full
        // perimeter, while occlusion hides the upper body's right face and the
        // adjacent portions of its front/back faces. The resulting point cloud
        // has one persistent apparent boundary shift, but no independent proof
        // that the shift belongs to a second rigid item.
        let lower = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.64, 0.38),
            minY: 0,
            maxY: 0.28,
            layerCount: 14
        )
        let upperWithRightSideOccluded = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.64, 0.38),
            minY: 0.28,
            maxY: 0.96,
            layerCount: 36
        ).filter { point in
            point.x <= 0.16
        }

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(
                worldPoints: lower + upperWithRightSideOccluded
            ),
            .insufficientEvidence,
            "One visibility-driven boundary shift is ambiguous and must not be called multiple rigid items"
        )
    }

    func testPhoto5LikeStackAtExact15PercentPointFractionWithMatchingCuboidControl() {
        let lowerY: [Float] = [0.025, 0.075, 0.125]
        // The first upper slice sits in the excluded transition bin but above
        // the split plane. That leaves exactly 48 of 320 points below the
        // candidate split: the configured 15% strong-body floor.
        let upperY: [Float] = [0.195]
            + (4...19).map { 0.025 + Float($0) * 0.05 }
        let expandedLower = rectangularSlices(
            yValues: lowerY,
            center: SIMD2<Float>(0.08, 0),
            size: SIMD2<Float>(0.64, 0.38),
            edgeSampleCount: 4
        )
        let upper = rectangularSlices(
            yValues: upperY,
            center: .zero,
            size: SIMD2<Float>(0.48, 0.38),
            edgeSampleCount: 4
        )
        let expandedPoints = expandedLower + upper

        XCTAssertEqual(expandedLower.count, 48)
        XCTAssertEqual(expandedPoints.count, 320)
        XCTAssertEqual(
            Float(expandedLower.count) / Float(expandedPoints.count),
            0.15,
            accuracy: 0.000_001
        )
        let expandedEvaluation = PhotoRigidItemMultiplicityGuard().evaluate(
            worldPoints: expandedPoints
        )
        XCTAssertEqual(expandedEvaluation.assessment, .insufficientEvidence)
        XCTAssertEqual(expandedEvaluation.indeterminateReason, .oneStrongBoundary)
        XCTAssertEqual(
            expandedEvaluation.candidateEvidence?.lowerBodyPointFraction ?? 0,
            0.15,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            expandedEvaluation.candidateEvidence?.significantBoundaryCount,
            1
        )
        XCTAssertGreaterThan(
            expandedEvaluation.candidateEvidence?.maximumBoundaryShiftMeters ?? 0,
            0.12
        )

        let matchingLower = rectangularSlices(
            yValues: lowerY,
            center: .zero,
            size: SIMD2<Float>(0.48, 0.38),
            edgeSampleCount: 4
        )
        let matchingPoints = matchingLower + upper
        XCTAssertEqual(matchingPoints.count, 320)
        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: matchingPoints),
            .singleRigidItem,
            "The same exact-threshold sampling with one consistent footprint must remain a single cuboid"
        )
    }

    func testReturnsInsufficientForPhoto5LikeStackAtExact160PointBoundary() {
        let lower = rectangularSlices(
            yValues: [0.02, 0.07, 0.12],
            center: SIMD2<Float>(0.08, 0),
            size: SIMD2<Float>(0.64, 0.38),
            edgeSampleCount: 4
        )
        let upper = rectangularSlices(
            yValues: [0.22, 0.27, 0.32, 0.37, 0.42, 0.47, 0.95],
            center: .zero,
            size: SIMD2<Float>(0.48, 0.38),
            edgeSampleCount: 4
        )
        let points = lower + upper
        XCTAssertEqual(points.count, 160)

        let evaluation = PhotoRigidItemMultiplicityGuard().evaluate(
            worldPoints: points
        )
        XCTAssertEqual(evaluation.assessment, .insufficientEvidence)
        XCTAssertEqual(evaluation.indeterminateReason, .oneStrongBoundary)
        XCTAssertEqual(evaluation.candidateEvidence?.significantBoundaryCount, 1)
        XCTAssertGreaterThan(
            evaluation.candidateEvidence?.maximumBoundaryShiftMeters ?? 0,
            0.12
        )
    }

    func testReturnsInsufficientForExact160PointCuboidWithIncompleteVerticalCoverage() {
        let lower = rectangularSlices(
            yValues: [0.02, 0.07, 0.12],
            center: .zero,
            size: SIMD2<Float>(0.48, 0.38),
            edgeSampleCount: 4
        )
        let upper = rectangularSlices(
            yValues: [0.22, 0.27, 0.32, 0.37, 0.42, 0.47, 0.95],
            center: .zero,
            size: SIMD2<Float>(0.48, 0.38),
            edgeSampleCount: 4
        )
        let points = lower + upper
        XCTAssertEqual(points.count, 160)

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points),
            .insufficientEvidence,
            "A few comparable bands cannot prove one cuboid when most of its vertical span has no usable depth"
        )
    }

    func testAcceptsOneTallCuboid() {
        let points = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.48, 0.36),
            minY: 0,
            maxY: 0.96
        )

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points),
            .singleRigidItem
        )
    }

    func testCannotDistinguishPerfectlyFlushMatchingStackFromOneTallCuboid() {
        let points = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.48, 0.36),
            minY: 0,
            maxY: 0.48
        ) + rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.48, 0.36),
            minY: 0.48,
            maxY: 0.96
        )

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points),
            .singleRigidItem,
            "No geometric guard can separate a perfectly flush identical stack from one tall cuboid"
        )
    }

    func testAcceptsCuboidWithOrdinaryTapeSeamAndMissingDepthStripe() {
        let points = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.48, 0.36),
            minY: 0,
            maxY: 0.96
        ).filter { point in
            abs(point.y - 0.48) > 0.018
        } + tapeStripePoints(
            width: 0.48,
            frontZ: -0.18,
            y: 0.48
        )

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points),
            .singleRigidItem,
            "A texture seam or narrow depth dropout is not evidence of two objects"
        )
    }

    func testAcceptsLocalizedFurnitureProtrusion() {
        let body = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.50, 0.38),
            minY: 0,
            maxY: 0.94
        )
        var handle: [SIMD3<Float>] = []
        for layer in 0..<5 {
            let y = 0.42 + Float(layer) * 0.012
            for sample in 0..<10 {
                let x = 0.25 + Float(sample) * 0.008
                handle.append(SIMD3<Float>(x, y, -0.10))
            }
        }

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: body + handle),
            .singleRigidItem,
            "A local handle or furniture protrusion must not look like two substantial bodies"
        )
    }

    func testAcceptsSmoothlySlopedAndRoundedSingleItems() {
        let sloped = varyingBody { fraction in
            (
                center: SIMD2<Float>(0.03 * fraction, 0),
                size: SIMD2<Float>(0.38 + 0.12 * fraction, 0.34)
            )
        }
        let rounded = varyingBody { fraction in
            let bulge = sin(.pi * fraction)
            return (
                center: .zero,
                size: SIMD2<Float>(0.34 + 0.16 * bulge, 0.28 + 0.10 * bulge)
            )
        }

        let guardUnderTest = PhotoRigidItemMultiplicityGuard()
        XCTAssertEqual(guardUnderTest.assess(worldPoints: sloped), .singleRigidItem)
        XCTAssertEqual(guardUnderTest.assess(worldPoints: rounded), .singleRigidItem)
    }

    func testAcceptsNoisyLiDAROnOneCuboid() {
        let points = rectangularBody(
            center: .zero,
            size: SIMD2<Float>(0.50, 0.38),
            minY: 0,
            maxY: 0.94
        ).enumerated().map { index, point in
            let xNoise = Float(index % 7 - 3) * 0.0022
            let yNoise = Float(index % 5 - 2) * 0.0016
            let zNoise = Float(index % 11 - 5) * 0.0018
            return point + SIMD3<Float>(xNoise, yNoise, zNoise)
        }

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points),
            .singleRigidItem
        )
    }

    func testReportsInsufficientEvidenceForSparseSupport() {
        let points = [
            SIMD3<Float>(-0.2, 0, -0.1),
            SIMD3<Float>(0.2, 0.4, -0.1),
            SIMD3<Float>(0.2, 0.8, 0.1),
        ]

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points),
            .insufficientEvidence
        )
    }

    func testEvaluationReports159FinitePointsAgainst160Minimum() {
        let points = Array(
            rectangularBody(
                center: .zero,
                size: SIMD2<Float>(0.48, 0.36),
                minY: 0,
                maxY: 0.96
            ).prefix(159)
        )

        let evaluation = PhotoRigidItemMultiplicityGuard().evaluate(
            worldPoints: points
        )

        XCTAssertEqual(evaluation.assessment, .insufficientEvidence)
        XCTAssertEqual(evaluation.finitePointCount, 159)
        XCTAssertEqual(evaluation.minimumPointCount, 160)
        XCTAssertEqual(evaluation.indeterminateReason, .tooFewPoints)
    }

    func testEvaluationReportsComparableCoverageForSingleCuboid() {
        let evaluation = PhotoRigidItemMultiplicityGuard().evaluate(
            worldPoints: rectangularBody(
                center: .zero,
                size: SIMD2<Float>(0.48, 0.36),
                minY: 0,
                maxY: 0.96
            )
        )

        XCTAssertEqual(evaluation.assessment, .singleRigidItem)
        XCTAssertGreaterThanOrEqual(evaluation.usableBinCount, 6)
        XCTAssertGreaterThan(evaluation.comparableSplitCount, 0)
        XCTAssertEqual(evaluation.comparableSplitCount, evaluation.eligibleSplitCount)
        XCTAssertNil(evaluation.indeterminateReason)
    }

    func testNoncontiguousUsableBinsDoNotProveOneRigidItem() {
        let points = rectangularSlices(
            yValues: [0.02, 0.07, 0.12, 0.87, 0.92, 0.97],
            center: .zero,
            size: SIMD2<Float>(0.48, 0.36)
        )

        XCTAssertEqual(
            PhotoRigidItemMultiplicityGuard().assess(worldPoints: points),
            .insufficientEvidence,
            "Six isolated usable bins are not the contiguous evidence required for a single body"
        )
    }

    func testSmallBoxRoutesToFourPointsWithoutClaimingCloserWillHelp() {
        let evaluation = PhotoRigidItemMultiplicityGuard().evaluate(
            worldPoints: rectangularBody(
                center: .zero,
                size: SIMD2<Float>(0.08, 0.09),
                minY: 0,
                maxY: 0.10
            )
        )

        XCTAssertEqual(evaluation.assessment, .insufficientEvidence)
        XCTAssertEqual(evaluation.indeterminateReason, .footprintBelowMinimum)
        let message = ScannerPhotoFailureCopy.message(
            for: .photo(.rigidItemMultiplicityUncertain(evaluation))
        )
        XCTAssertTrue(message.localizedCaseInsensitiveContains("too small"))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("4 points"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("closer"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("diagnostic"))
    }

    func testPhotoMeasurementRejectsConnectedStackBeforeReturningPointCloud() throws {
        let fixture = try stackedPhotoFixture()

        XCTAssertThrowsError(
            try PhotoObjectMeasurement().makePointCloud(
                labelMask: fixture.mask,
                depthGrid: fixture.depth,
                calibration: fixture.calibration
            )
        ) { error in
            guard case .multipleRigidItemsDetected = error as? PhotoObjectMeasurementError else {
                return XCTFail("Expected the dedicated multiple-item rejection, got \(error)")
            }
        }
    }

    func testBoxMeasurementRaisesEffectiveDepthMinimumTo160() throws {
        let measurement = PhotoObjectMeasurement()
        let fixture = try singlePhotoFixture()
        var depths = Array(repeating: Float.nan, count: fixture.depth.depths.count)
        var confidences = Array(repeating: UInt8.zero, count: fixture.depth.confidences.count)
        let supportedIndices = (10..<22).flatMap { y in
            (14..<27).map { x in y * 40 + x }
        } + (19..<22).map { x in 22 * 40 + x }
        XCTAssertEqual(supportedIndices.count, 159)
        for index in supportedIndices {
            depths[index] = fixture.depth.depths[index]
            confidences[index] = 2
        }

        XCTAssertEqual(measurement.requiredDepthSampleCount, 160)
        XCTAssertThrowsError(
            try measurement.makePointCloud(
                labelMask: fixture.mask,
                depthGrid: DepthGrid(
                    width: 40,
                    height: 40,
                    depths: depths,
                    confidences: confidences
                ),
                calibration: fixture.calibration
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .insufficientDepthSamples(actual: 159, minimum: 160)
            )
        }
    }

    func testPointCloudCarriesSingleRigidItemEvaluation() throws {
        let fixture = try singlePhotoFixture()

        let pointCloud = try PhotoObjectMeasurement().makePointCloud(
            labelMask: fixture.mask,
            depthGrid: fixture.depth,
            calibration: fixture.calibration
        )

        XCTAssertEqual(
            pointCloud.rigidItemMultiplicityEvaluation?.assessment,
            .singleRigidItem
        )
        XCTAssertGreaterThan(
            pointCloud.rigidItemMultiplicityEvaluation?.comparableSplitCount ?? 0,
            0
        )
    }

    func testPhotoMeasurementCanDisableRigidGuardForGeneralItemMode() throws {
        let fixture = try stackedPhotoFixture()
        let measurement = PhotoObjectMeasurement(rigidItemMultiplicityGuard: nil)

        let pointCloud = try measurement.makePointCloud(
            labelMask: fixture.mask,
            depthGrid: fixture.depth,
            calibration: fixture.calibration
        )

        XCTAssertFalse(pointCloud.worldPoints.isEmpty)
        XCTAssertEqual(measurement.requiredDepthSampleCount, 48)
        XCTAssertNil(pointCloud.rigidItemMultiplicityEvaluation)
    }

    func testGeneralItemAcceptsExactly48SupportedPointsWithoutMultiplicityEvaluation() throws {
        let width = 12
        let height = 10
        var labels = Array(repeating: UInt32.zero, count: width * height)
        var depths = Array(repeating: Float.nan, count: width * height)
        var confidences = Array(repeating: UInt8.zero, count: width * height)
        for y in 2...7 {
            for x in 2...9 {
                let index = y * width + x
                labels[index] = 5
                depths[index] = 1
                confidences[index] = 2
            }
        }
        let measurement = PhotoObjectMeasurement(rigidItemMultiplicityGuard: nil)

        let pointCloud = try measurement.makePointCloud(
            labelMask: PhotoInstanceLabelMask(
                width: width,
                height: height,
                labels: labels
            ),
            depthGrid: DepthGrid(
                width: width,
                height: height,
                depths: depths,
                confidences: confidences
            ),
            calibration: PhotoCameraCalibration(
                imageWidth: width,
                imageHeight: height,
                intrinsics: simd_float3x3(
                    SIMD3<Float>(Float(width), 0, 0),
                    SIMD3<Float>(0, Float(height), 0),
                    SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
                ),
                cameraTransform: matrix_identity_float4x4
            )
        )

        XCTAssertEqual(pointCloud.worldPoints.count, 48)
        XCTAssertNil(pointCloud.rigidItemMultiplicityEvaluation)
    }

    func testUncertainMultiplicityFailureHasF09GuidanceAndNoFallback() {
        let evaluation = PhotoRigidItemMultiplicityEvaluation(
            assessment: .insufficientEvidence,
            finitePointCount: 160,
            minimumPointCount: 160,
            usableBinCount: 6,
            comparableSplitCount: 0,
            indeterminateReason: .noComparableSplit
        )
        let error = PhotoObjectMeasurementError.rigidItemMultiplicityUncertain(
            evaluation
        )
        let failure = SingleShotCaptureFailure.photo(error)
        let message = ScannerPhotoFailureCopy.message(for: failure)

        XCTAssertEqual(failure.retryCategory, .isolation)
        XCTAssertEqual(failure.diagnosticCode, "F09")
        XCTAssertFalse(failure.shouldAttemptReticleDepthFallback)
        XCTAssertTrue(failure.diagnosticDescription.contains("finite_points=160"))
        XCTAssertTrue(failure.diagnosticDescription.contains("no_comparable_split"))
        XCTAssertTrue(message.contains("couldn't confirm enough of the box profile"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("diagnostic"))
    }

    func testMultipleItemFailureHasStableIsolationDiagnosticAndNoFallback() {
        let evidence = PhotoRigidItemMultiplicityEvidence(
            splitHeightFraction: 0.5,
            maximumBoundaryShiftMeters: 0.1,
            normalizedBoundaryShift: 0.2,
            significantBoundaryCount: 3
        )
        let error = PhotoObjectMeasurementError.multipleRigidItemsDetected(
            multipleEvaluation(evidence)
        )
        let failure = SingleShotCaptureFailure.photo(error)

        XCTAssertEqual(failure.retryCategory, .isolation)
        XCTAssertEqual(failure.disposition, .targetRejected)
        XCTAssertEqual(failure.diagnosticCode, "F08")
        XCTAssertFalse(failure.shouldAttemptReticleDepthFallback)
        XCTAssertEqual(
            SingleShotObjectMeasurement.failure(for: error),
            .targetRejected(.insufficientSurfaceEvidence)
        )
        XCTAssertTrue(failure.diagnosticDescription.contains("multiple_rigid_items_detected"))
    }

    func testMultipleItemFailureGivesSpecificRetapAndFourPointGuidance() {
        let evidence = PhotoRigidItemMultiplicityEvidence(
            splitHeightFraction: 0.5,
            maximumBoundaryShiftMeters: 0.1,
            normalizedBoundaryShift: 0.2,
            significantBoundaryCount: 3
        )
        let message = ScannerPhotoFailureCopy.message(
            for: .photo(.multipleRigidItemsDetected(multipleEvaluation(evidence)))
        )

        XCTAssertTrue(message.contains("more than one box"))
        XCTAssertTrue(message.contains("Retap a solid face"))
        XCTAssertTrue(message.contains("4 points"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("diagnostic"))
    }

    private func rectangularBody(
        center: SIMD2<Float>,
        size: SIMD2<Float>,
        minY: Float,
        maxY: Float,
        layerCount: Int = 36,
        edgeSampleCount: Int = 18
    ) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(layerCount * edgeSampleCount * 4)
        let minX = center.x - size.x / 2
        let maxX = center.x + size.x / 2
        let minZ = center.y - size.y / 2
        let maxZ = center.y + size.y / 2

        for layer in 0..<layerCount {
            let yFraction = (Float(layer) + 0.5) / Float(layerCount)
            let y = minY + (maxY - minY) * yFraction
            for sample in 0..<edgeSampleCount {
                let fraction = (Float(sample) + 0.5) / Float(edgeSampleCount)
                let x = minX + size.x * fraction
                let z = minZ + size.y * fraction
                points.append(SIMD3<Float>(x, y, minZ))
                points.append(SIMD3<Float>(x, y, maxZ))
                points.append(SIMD3<Float>(minX, y, z))
                points.append(SIMD3<Float>(maxX, y, z))
            }
        }
        return points
    }

    private func multipleEvaluation(
        _ evidence: PhotoRigidItemMultiplicityEvidence
    ) -> PhotoRigidItemMultiplicityEvaluation {
        PhotoRigidItemMultiplicityEvaluation(
            assessment: .multipleRigidItems(evidence),
            finitePointCount: 256,
            minimumPointCount: 160,
            usableBinCount: 20,
            comparableSplitCount: 4,
            indeterminateReason: nil
        )
    }

    private func tapeStripePoints(width: Float, frontZ: Float, y: Float) -> [SIMD3<Float>] {
        (0..<24).map { sample in
            let fraction = (Float(sample) + 0.5) / 24
            return SIMD3<Float>(-width / 2 + width * fraction, y, frontZ - 0.002)
        }
    }

    private func rectangularSlices(
        yValues: [Float],
        center: SIMD2<Float>,
        size: SIMD2<Float>,
        edgeSampleCount: Int = 18
    ) -> [SIMD3<Float>] {
        let minX = center.x - size.x / 2
        let maxX = center.x + size.x / 2
        let minZ = center.y - size.y / 2
        let maxZ = center.y + size.y / 2
        return yValues.flatMap { y in
            (0..<edgeSampleCount).flatMap { sample -> [SIMD3<Float>] in
                let fraction = (Float(sample) + 0.5) / Float(edgeSampleCount)
                let x = minX + size.x * fraction
                let z = minZ + size.y * fraction
                return [
                    SIMD3<Float>(x, y, minZ),
                    SIMD3<Float>(x, y, maxZ),
                    SIMD3<Float>(minX, y, z),
                    SIMD3<Float>(maxX, y, z),
                ]
            }
        }
    }

    private func varyingBody(
        layerCount: Int = 72,
        edgeSampleCount: Int = 18,
        shape: (Float) -> (center: SIMD2<Float>, size: SIMD2<Float>)
    ) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(layerCount * edgeSampleCount * 4)
        for layer in 0..<layerCount {
            let fraction = (Float(layer) + 0.5) / Float(layerCount)
            let profile = shape(fraction)
            let minX = profile.center.x - profile.size.x / 2
            let maxX = profile.center.x + profile.size.x / 2
            let minZ = profile.center.y - profile.size.y / 2
            let maxZ = profile.center.y + profile.size.y / 2
            for sample in 0..<edgeSampleCount {
                let edgeFraction = (Float(sample) + 0.5) / Float(edgeSampleCount)
                let x = minX + profile.size.x * edgeFraction
                let z = minZ + profile.size.y * edgeFraction
                points.append(SIMD3<Float>(x, fraction, minZ))
                points.append(SIMD3<Float>(x, fraction, maxZ))
                points.append(SIMD3<Float>(minX, fraction, z))
                points.append(SIMD3<Float>(maxX, fraction, z))
            }
        }
        return points
    }

    private func stackedPhotoFixture() throws -> (
        mask: PhotoInstanceLabelMask,
        depth: DepthGrid,
        calibration: PhotoCameraCalibration
    ) {
        let width = 40
        let height = 40
        var labels = Array(repeating: UInt32(0), count: width * height)
        var depths = Array(repeating: Float.nan, count: width * height)
        var confidences = Array(repeating: UInt8(0), count: width * height)

        for y in 4...19 {
            for x in 6...33 {
                let index = y * width + x
                labels[index] = 5
                depths[index] = 1.0
                confidences[index] = 2
            }
        }
        for y in 20...35 {
            for x in 10...29 {
                let index = y * width + x
                labels[index] = 5
                depths[index] = 1.1
                confidences[index] = 2
            }
        }

        return (
            try PhotoInstanceLabelMask(width: width, height: height, labels: labels),
            DepthGrid(
                width: width,
                height: height,
                depths: depths,
                confidences: confidences
            ),
            PhotoCameraCalibration(
                imageWidth: width,
                imageHeight: height,
                intrinsics: simd_float3x3(
                    SIMD3<Float>(Float(width), 0, 0),
                    SIMD3<Float>(0, Float(height), 0),
                    SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
                ),
                cameraTransform: matrix_identity_float4x4
            )
        )
    }

    private func singlePhotoFixture() throws -> (
        mask: PhotoInstanceLabelMask,
        depth: DepthGrid,
        calibration: PhotoCameraCalibration
    ) {
        let width = 40
        let height = 40
        var labels = Array(repeating: UInt32.zero, count: width * height)
        var depths = Array(repeating: Float.nan, count: width * height)
        var confidences = Array(repeating: UInt8.zero, count: width * height)
        for y in 4...35 {
            for x in 8...31 {
                let index = y * width + x
                labels[index] = 5
                depths[index] = 1 + Float(x - 8) * 0.002
                confidences[index] = 2
            }
        }
        return (
            try PhotoInstanceLabelMask(width: width, height: height, labels: labels),
            DepthGrid(
                width: width,
                height: height,
                depths: depths,
                confidences: confidences
            ),
            PhotoCameraCalibration(
                imageWidth: width,
                imageHeight: height,
                intrinsics: simd_float3x3(
                    SIMD3<Float>(Float(width), 0, 0),
                    SIMD3<Float>(0, Float(height), 0),
                    SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
                ),
                cameraTransform: matrix_identity_float4x4
            )
        )
    }
}
