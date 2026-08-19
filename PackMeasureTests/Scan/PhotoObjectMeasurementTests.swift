import XCTest
import simd
@testable import PackMeasure

final class PhotoObjectMeasurementTests: XCTestCase {
    func testSelectsForegroundInstanceUnderImageCenter() throws {
        let labels = try labelMask(
            [
                [1, 1, 0, 0, 0],
                [1, 1, 0, 2, 2],
                [0, 0, 2, 2, 2],
                [3, 3, 2, 2, 2],
                [3, 3, 0, 0, 0],
            ]
        )

        let selected = try PhotoForegroundInstanceSelector().select(in: labels)

        XCTAssertEqual(selected.label, 2)
        XCTAssertEqual(selected.selectedPixelCount, 8)
        XCTAssertTrue(selected.contains(x: 2, y: 2))
        XCTAssertFalse(selected.contains(x: 0, y: 0))
    }

    func testFallsBackToSoleForegroundInstanceWhenCenterIsBackground() throws {
        let labels = try labelMask(
            [
                [0, 0, 0, 0, 0],
                [0, 7, 7, 0, 0],
                [0, 7, 0, 0, 0],
                [0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0],
            ]
        )

        let selected = try PhotoForegroundInstanceSelector().select(in: labels)

        XCTAssertEqual(selected.label, 7)
        XCTAssertEqual(selected.selectedPixelCount, 3)
    }

    func testRejectsAmbiguousInstancesWhenCenterIsBackground() throws {
        let labels = try labelMask(
            [
                [1, 1, 0, 2, 2],
                [1, 1, 0, 2, 2],
                [0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0],
            ]
        )

        XCTAssertThrowsError(try PhotoForegroundInstanceSelector().select(in: labels)) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .ambiguousForegroundInstances(labels: [1, 2])
            )
        }
    }

    func testReportsAreaAndEdgeQualityForBoxMask() throws {
        let selected = try PhotoForegroundInstanceSelector().select(
            in: try boxMask(width: 7, height: 7, x: 2...4, y: 2...4)
        )

        let quality = selected.quality(edgeMarginPixels: 0)

        XCTAssertEqual(quality.selectedPixelCount, 9)
        XCTAssertEqual(quality.areaFraction, 9.0 / 49.0, accuracy: 0.0001)
        XCTAssertFalse(quality.touchesProtectedEdge)
    }

    func testResamplingPreservesEllipseAndConcaveLShape() throws {
        let ellipse = try PhotoForegroundInstanceSelector().select(
            in: try ellipseMask(width: 12, height: 12, centerX: 6, centerY: 6, radiusX: 4, radiusY: 3)
        ).resampled(toWidth: 6, height: 6)
        let lShape = try PhotoForegroundInstanceSelector().select(
            in: try lShapeMask(width: 12, height: 12)
        ).resampled(toWidth: 6, height: 6)

        XCTAssertTrue(ellipse.contains(x: 3, y: 3))
        XCTAssertFalse(ellipse.contains(x: 1, y: 1))
        XCTAssertTrue(lShape.contains(x: 2, y: 2))
        XCTAssertTrue(lShape.contains(x: 4, y: 4))
        XCTAssertFalse(lShape.contains(x: 4, y: 2), "the L-shape must not become its bounding box")
    }

    func testBuildsWorldPointCloudForBoxEllipseAndLShapeMasks() throws {
        let masks = [
            try boxMask(width: 12, height: 12, x: 3...8, y: 3...8),
            try ellipseMask(width: 12, height: 12, centerX: 6, centerY: 6, radiusX: 4, radiusY: 3),
            try lShapeMask(width: 12, height: 12),
        ]
        let depthGrid = DepthGrid(
            width: 12,
            height: 12,
            depths: Array(repeating: 1.25, count: 144),
            confidences: Array(repeating: 2, count: 144)
        )
        let measurement = PhotoObjectMeasurement(policy: permissivePolicy)

        for labels in masks {
            let result = try measurement.makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: 12, imageHeight: 12)
            )

            XCTAssertEqual(result.selectedLabel, 5)
            XCTAssertEqual(result.worldPoints.count, result.depthSupport.supportedSampleCount)
            XCTAssertGreaterThan(result.worldPoints.count, 10)
            XCTAssertTrue(result.worldPoints.allSatisfy(isFinite))
        }
    }

    func testRejectsMaskClippedByImageEdge() throws {
        let labels = try boxMask(width: 10, height: 10, x: 0...5, y: 2...7)
        let depthGrid = populatedDepthGrid(width: 10, height: 10)

        XCTAssertThrowsError(
            try PhotoObjectMeasurement(policy: permissivePolicy).makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: 10, imageHeight: 10)
            )
        ) { error in
            XCTAssertEqual(error as? PhotoObjectMeasurementError, .maskTouchesImageEdge)
        }
    }

    func testRejectsSparseDepthEvidence() throws {
        let labels = try boxMask(width: 8, height: 8, x: 2...5, y: 2...5)
        var confidences = Array(repeating: UInt8(0), count: 64)
        confidences[2 * 8 + 2] = 2
        confidences[2 * 8 + 3] = 2
        let depthGrid = DepthGrid(
            width: 8,
            height: 8,
            depths: Array(repeating: 1.0, count: 64),
            confidences: confidences
        )

        XCTAssertThrowsError(
            try PhotoObjectMeasurement(policy: permissivePolicy).makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: 8, imageHeight: 8)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .insufficientDepthSamples(actual: 2, minimum: 4)
            )
        }
    }

    func testRejectsDepthThatCoversOnlyOneSpatialBandOfMask() throws {
        let labels = try boxMask(width: 8, height: 8, x: 1...6, y: 1...6)
        var confidences = Array(repeating: UInt8(0), count: 64)
        for y in 1...3 {
            for x in 1...6 {
                confidences[y * 8 + x] = 2
            }
        }
        let depthGrid = DepthGrid(
            width: 8,
            height: 8,
            depths: Array(repeating: 1.0, count: 64),
            confidences: confidences
        )
        var policy = permissivePolicy
        policy.minimumDepthCoverage = 0.4
        policy.minimumVerticalDepthSupport = 0.7

        XCTAssertThrowsError(
            try PhotoObjectMeasurement(policy: policy).makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: 8, imageHeight: 8)
            )
        ) { error in
            guard case let .insufficientVerticalDepthSupport(actual, minimum) =
                    error as? PhotoObjectMeasurementError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actual, 0.5, accuracy: 0.0001)
            XCTAssertEqual(minimum, 0.7, accuracy: 0.0001)
        }
    }

    func testRejectsMaskAndCalibrationWithDifferentAspectRatios() throws {
        let labels = try boxMask(width: 8, height: 4, x: 2...5, y: 1...2)
        let depthGrid = populatedDepthGrid(width: 4, height: 2)

        XCTAssertThrowsError(
            try PhotoObjectMeasurement(policy: permissivePolicy).makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: 4, imageHeight: 8)
            )
        ) { error in
            XCTAssertEqual(error as? PhotoObjectMeasurementError, .maskCalibrationAspectRatioMismatch)
        }
    }

    func testUnprojectionScalesIntrinsicsAndAppliesCameraTransform() throws {
        let mask = try PhotoDepthSelectionMask(
            width: 2,
            height: 2,
            selected: [true, true, true, true]
        )
        let grid = DepthGrid(
            width: 2,
            height: 2,
            depths: Array(repeating: 2, count: 4),
            confidences: Array(repeating: 2, count: 4)
        )
        let support = try PhotoDepthSupportAnalyzer(policy: permissivePolicy).analyze(
            mask: mask,
            depthGrid: grid
        )
        let intrinsics = simd_float3x3(
            SIMD3<Float>(4, 0, 0),
            SIMD3<Float>(0, 4, 0),
            SIMD3<Float>(2, 2, 1)
        )
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(10, 20, 30, 1)
        let calibration = PhotoCameraCalibration(
            imageWidth: 4,
            imageHeight: 4,
            intrinsics: intrinsics,
            cameraTransform: transform
        )

        let points = try PhotoWorldPointProjector().project(
            support: support,
            depthGrid: grid,
            calibration: calibration
        )

        XCTAssertEqual(points[0].x, 9.5, accuracy: 0.0001)
        XCTAssertEqual(points[0].y, 20.5, accuracy: 0.0001)
        XCTAssertEqual(points[0].z, 28, accuracy: 0.0001)
        XCTAssertEqual(points[3].x, 10.5, accuracy: 0.0001)
        XCTAssertEqual(points[3].y, 19.5, accuracy: 0.0001)
        XCTAssertEqual(points[3].z, 28, accuracy: 0.0001)
    }

    private var permissivePolicy: PhotoObjectMeasurementPolicy {
        PhotoObjectMeasurementPolicy(
            minimumMaskAreaFraction: 0.01,
            maximumMaskAreaFraction: 0.95,
            protectedEdgeMarginPixels: 0,
            minimumDepthConfidence: 2,
            minimumDepthSamples: 4,
            minimumDepthCoverage: 0.5,
            minimumHorizontalDepthSupport: 0.6,
            minimumVerticalDepthSupport: 0.6
        )
    }

    private func labelMask(_ rows: [[UInt32]]) throws -> PhotoInstanceLabelMask {
        try PhotoInstanceLabelMask(
            width: rows[0].count,
            height: rows.count,
            labels: rows.flatMap { $0 }
        )
    }

    private func boxMask(
        width: Int,
        height: Int,
        x: ClosedRange<Int>,
        y: ClosedRange<Int>
    ) throws -> PhotoInstanceLabelMask {
        var labels = Array(repeating: UInt32(0), count: width * height)
        for row in y {
            for column in x {
                labels[row * width + column] = 5
            }
        }
        return try PhotoInstanceLabelMask(width: width, height: height, labels: labels)
    }

    private func ellipseMask(
        width: Int,
        height: Int,
        centerX: Int,
        centerY: Int,
        radiusX: Int,
        radiusY: Int
    ) throws -> PhotoInstanceLabelMask {
        var labels = Array(repeating: UInt32(0), count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let dx = Float(x - centerX) / Float(radiusX)
                let dy = Float(y - centerY) / Float(radiusY)
                if dx * dx + dy * dy <= 1 {
                    labels[y * width + x] = 5
                }
            }
        }
        return try PhotoInstanceLabelMask(width: width, height: height, labels: labels)
    }

    private func lShapeMask(width: Int, height: Int) throws -> PhotoInstanceLabelMask {
        var labels = Array(repeating: UInt32(0), count: width * height)
        for y in 3...8 {
            for x in 3...4 {
                labels[y * width + x] = 5
            }
        }
        for y in 7...8 {
            for x in 3...8 {
                labels[y * width + x] = 5
            }
        }
        return try PhotoInstanceLabelMask(width: width, height: height, labels: labels)
    }

    private func populatedDepthGrid(width: Int, height: Int) -> DepthGrid {
        DepthGrid(
            width: width,
            height: height,
            depths: Array(repeating: 1.0, count: width * height),
            confidences: Array(repeating: 2, count: width * height)
        )
    }

    private func calibration(imageWidth: Int, imageHeight: Int) -> PhotoCameraCalibration {
        PhotoCameraCalibration(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            intrinsics: simd_float3x3(
                SIMD3<Float>(Float(imageWidth), 0, 0),
                SIMD3<Float>(0, Float(imageHeight), 0),
                SIMD3<Float>(Float(imageWidth) / 2, Float(imageHeight) / 2, 1)
            ),
            cameraTransform: matrix_identity_float4x4
        )
    }

    private func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}
