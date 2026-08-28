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

    func testMultipleItemFailureHasStableIsolationDiagnosticAndNoFallback() {
        let evidence = PhotoRigidItemMultiplicityEvidence(
            splitHeightFraction: 0.5,
            maximumBoundaryShiftMeters: 0.1,
            normalizedBoundaryShift: 0.2,
            significantBoundaryCount: 3
        )
        let error = PhotoObjectMeasurementError.multipleRigidItemsDetected(evidence)
        let failure = SingleShotCaptureFailure.photo(error)

        XCTAssertEqual(failure.retryCategory, .isolation)
        XCTAssertEqual(failure.disposition, .targetRejected)
        XCTAssertEqual(failure.diagnosticCode, "F07")
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
            for: .photo(.multipleRigidItemsDetected(evidence))
        )

        XCTAssertTrue(message.contains("more than one box"))
        XCTAssertTrue(message.contains("Retap a solid face"))
        XCTAssertTrue(message.contains("4 points"))
        XCTAssertTrue(message.contains("Diagnostic F07"))
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

    private func tapeStripePoints(width: Float, frontZ: Float, y: Float) -> [SIMD3<Float>] {
        (0..<24).map { sample in
            let fraction = (Float(sample) + 0.5) / 24
            return SIMD3<Float>(-width / 2 + width * fraction, y, frontZ - 0.002)
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
}
