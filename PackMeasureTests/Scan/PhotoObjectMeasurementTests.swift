import XCTest
import simd
@testable import PackMeasure

final class PhotoObjectMeasurementTests: XCTestCase {
    func testExplicitTargetSelectsTappedInstanceInsteadOfCenteredInstance() throws {
        let labels = try labelMask(
            [
                [1, 1, 0, 2, 2],
                [1, 1, 0, 2, 2],
                [0, 0, 3, 3, 3],
                [0, 0, 3, 3, 3],
                [0, 0, 0, 0, 0],
            ]
        )

        let selected = try PhotoForegroundInstanceSelector().select(
            in: labels,
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.9, 0.2))
        )

        XCTAssertEqual(selected.label, 2)
        XCTAssertEqual(selected.selectedPixelCount, 4)
        XCTAssertTrue(selected.contains(x: 4, y: 1))
        XCTAssertFalse(selected.contains(x: 2, y: 2), "the centered object must not replace an explicit target")
    }

    func testExplicitTargetSelectsOnlyTappedConnectedComponentForReusedLabel() throws {
        let labels = try labelMask(
            [
                [5, 5, 0, 0, 0, 0, 0],
                [5, 5, 0, 0, 0, 0, 0],
                [0, 0, 0, 5, 5, 5, 0],
                [0, 0, 0, 5, 5, 5, 0],
                [0, 0, 0, 5, 5, 5, 0],
                [0, 0, 0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0, 0, 0],
            ]
        )

        let selected = try PhotoForegroundInstanceSelector().select(
            in: labels,
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.1, 0.1))
        )

        XCTAssertEqual(selected.label, 5)
        XCTAssertEqual(selected.selectedPixelCount, 4)
        XCTAssertTrue(selected.contains(x: 0, y: 0))
        XCTAssertFalse(selected.contains(x: 3, y: 3), "selection must follow the tapped component, not image center")
    }

    func testExplicitTargetOnBackgroundFailsWithoutSoleOrCenterFallback() throws {
        let labels = try labelMask(
            [
                [0, 0, 0, 0, 0],
                [0, 7, 7, 0, 0],
                [0, 7, 7, 0, 0],
                [0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0],
            ]
        )

        XCTAssertThrowsError(
            try PhotoForegroundInstanceSelector().select(
                in: labels,
                prompt: .target(normalizedImagePoint: SIMD2<Float>(0.9, 0.9))
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoTargetSelectionError,
                .noForegroundAtTargetPoint
            )
        }
    }

    func testInvalidExplicitTargetPointsFailClosed() throws {
        let labels = try boxMask(width: 5, height: 5, x: 1...3, y: 1...3)
        let invalidPoints = [
            SIMD2<Float>(-.infinity, 0.5),
            SIMD2<Float>(0.5, .nan),
            SIMD2<Float>(-0.001, 0.5),
            SIMD2<Float>(0.5, 1.001),
        ]

        for point in invalidPoints {
            XCTAssertThrowsError(
                try PhotoForegroundInstanceSelector().select(
                    in: labels,
                    prompt: .target(normalizedImagePoint: point)
                )
            ) { error in
                XCTAssertEqual(
                    error as? PhotoTargetSelectionError,
                    .invalidTargetSelectionPoint
                )
            }
        }
    }

    func testStaleExplicitTargetPromptFailsClosed() throws {
        let labels = try boxMask(width: 5, height: 5, x: 1...3, y: 1...3)

        XCTAssertThrowsError(
            try PhotoForegroundInstanceSelector().select(in: labels, prompt: .stale)
        ) { error in
            XCTAssertEqual(
                error as? PhotoTargetSelectionError,
                .staleTargetSelectionPrompt
            )
        }
    }

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

    func testSelectsOnlyCenterConnectedComponentWhenVisionReusesOneLabel() throws {
        let labels = try labelMask(
            [
                [5, 5, 0, 0, 0, 0, 0],
                [5, 5, 0, 0, 0, 0, 0],
                [0, 0, 0, 5, 5, 5, 0],
                [0, 0, 0, 5, 5, 5, 0],
                [0, 0, 0, 5, 5, 5, 0],
                [0, 0, 0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0, 0, 0],
            ]
        )

        let selected = try PhotoForegroundInstanceSelector().select(in: labels)

        XCTAssertEqual(selected.label, 5)
        XCTAssertEqual(selected.selectedPixelCount, 9)
        XCTAssertTrue(selected.contains(x: 3, y: 3))
        XCTAssertFalse(selected.contains(x: 0, y: 0), "a disconnected same-label object must be removed")
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

    func testObjectOutlinePreservesConcavityInsteadOfBecomingBoundingBox() throws {
        let outline = try XCTUnwrap(
            MeasurementObjectOutline(
                width: 4,
                height: 4,
                selectedIndices: [0, 4, 5]
            )
        )
        let loop = try XCTUnwrap(outline.loops.first)
        let xs = loop.map(\.x)
        let ys = loop.map(\.y)
        let minX = try XCTUnwrap(xs.min())
        let maxX = try XCTUnwrap(xs.max())
        let minY = try XCTUnwrap(ys.min())
        let maxY = try XCTUnwrap(ys.max())
        let boundingArea = (maxX - minX) * (maxY - minY)

        XCTAssertEqual(outline.loops.count, 1)
        XCTAssertGreaterThan(boundingArea, 0)
        XCTAssertLessThan(polygonArea(loop), boundingArea * 0.9)
        XCTAssertTrue(loop.allSatisfy(isFiniteAndNormalized))
    }

    func testObjectOutlineRetainsDisconnectedSelectionsAndHole() throws {
        let disconnected = try XCTUnwrap(
            MeasurementObjectOutline(
                width: 6,
                height: 4,
                selectedIndices: [0, 1, 6, 7, 16, 17, 22, 23]
            )
        )
        let ringIndices = (0..<25).filter { index in
            let x = index % 5
            let y = index / 5
            return x == 0 || x == 4 || y == 0 || y == 4
        }
        let ring = try XCTUnwrap(
            MeasurementObjectOutline(width: 5, height: 5, selectedIndices: ringIndices)
        )

        XCTAssertEqual(disconnected.loops.count, 2)
        XCTAssertEqual(ring.loops.count, 2, "the inner boundary must remain visible")
        XCTAssertTrue(disconnected.loops.flatMap { $0 }.allSatisfy(isFiniteAndNormalized))
        XCTAssertTrue(ring.loops.flatMap { $0 }.allSatisfy(isFiniteAndNormalized))
    }

    func testObjectOverlaySuppressesRingHoleButMeasurementOutlineRetainsIt() throws {
        let ringIndices = (0..<25).filter { index in
            let x = index % 5
            let y = index / 5
            return x == 0 || x == 4 || y == 0 || y == 4
        }
        let measurementOutline = try XCTUnwrap(
            MeasurementObjectOutline(width: 5, height: 5, selectedIndices: ringIndices)
        )

        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(5, 5),
            outline: measurementOutline
        )
        let exteriorLoop = try XCTUnwrap(
            measurementOutline.loops.max(by: { polygonArea($0) < polygonArea($1) })
        )

        XCTAssertEqual(measurementOutline.loops.count, 2)
        XCTAssertEqual(overlay.outline.loops.count, 1)
        XCTAssertEqual(overlay.outline.loops[0], exteriorLoop)
    }

    func testObjectOverlayPreservesDisconnectedExteriorIslands() throws {
        let measurementOutline = try XCTUnwrap(
            MeasurementObjectOutline(
                width: 8,
                height: 5,
                selectedIndices: [9, 10, 17, 18, 13, 14, 21, 22]
            )
        )

        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(8, 5),
            outline: measurementOutline
        )

        XCTAssertEqual(measurementOutline.loops.count, 2)
        XCTAssertEqual(overlay.outline, measurementOutline)
    }

    func testObjectOverlayPreservesConcaveExteriorPointForPoint() throws {
        let measurementOutline = try XCTUnwrap(
            MeasurementObjectOutline(
                width: 4,
                height: 4,
                selectedIndices: [0, 4, 5]
            )
        )
        let loop = try XCTUnwrap(measurementOutline.loops.first)
        let xs = loop.map(\.x)
        let ys = loop.map(\.y)
        let minX = try XCTUnwrap(xs.min())
        let maxX = try XCTUnwrap(xs.max())
        let minY = try XCTUnwrap(ys.min())
        let maxY = try XCTUnwrap(ys.max())
        let boundingArea = (maxX - minX) * (maxY - minY)

        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(4, 4),
            outline: measurementOutline
        )

        XCTAssertEqual(overlay.outline, measurementOutline)
        XCTAssertLessThan(polygonArea(overlay.outline.loops[0]), boundingArea * 0.9)
    }

    func testDisplaySilhouetteDoesNotChangeMeasurementSupport() throws {
        let width = 9
        let height = 9
        let ringIndices = (0..<(width * height)).filter { index in
            let x = index % width
            let y = index / width
            return ((2...6).contains(x) && (y == 2 || y == 6))
                || ((2...6).contains(y) && (x == 2 || x == 6))
        }
        var labels = Array(repeating: UInt32.zero, count: width * height)
        for index in ringIndices { labels[index] = 5 }
        let result = try permissiveMeasurement.makePointCloud(
            labelMask: try PhotoInstanceLabelMask(
                width: width,
                height: height,
                labels: labels
            ),
            depthGrid: populatedDepthGrid(width: width, height: height),
            calibration: calibration(imageWidth: width, imageHeight: height)
        )
        let measurementOutline = try XCTUnwrap(result.objectOutline)
        let supportBeforeDisplay = result.depthSupport.indices

        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(9, 9),
            outline: measurementOutline
        )

        XCTAssertEqual(Set(supportBeforeDisplay), Set(ringIndices))
        XCTAssertEqual(result.worldPoints.count, ringIndices.count)
        XCTAssertEqual(result.depthSupport.indices, supportBeforeDisplay)
        XCTAssertEqual(measurementOutline.loops.count, 2)
        XCTAssertEqual(overlay.outline.loops.count, 1)
    }

    func testPointCloudCarriesOutlineFromExactDepthSelection() throws {
        let labels = try lShapeMask(width: 12, height: 12)
        let result = try permissiveMeasurement.makePointCloud(
            labelMask: labels,
            depthGrid: populatedDepthGrid(width: 12, height: 12),
            calibration: calibration(imageWidth: 12, imageHeight: 12)
        )
        let outline = try XCTUnwrap(result.objectOutline)

        XCTAssertFalse(outline.isEmpty)
        XCTAssertTrue(outline.loops.flatMap { $0 }.allSatisfy(isFiniteAndNormalized))
    }

    func testObjectOverlayReprojectsAcrossAspectFillViewportChanges() throws {
        let outline = MeasurementObjectOutline(
            loops: [[
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(1, 1),
                SIMD2<Float>(0, 1),
            ]]
        )
        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(3, 4),
            outline: outline
        )

        let portraitPoint = try XCTUnwrap(
            overlay.normalizedPreviewPoint(
                SIMD2<Float>(0.5, 0.5),
                viewportSize: SIMD2<Float>(300, 400)
            )
        )
        let squareLeftEdge = try XCTUnwrap(
            overlay.normalizedPreviewPoint(
                SIMD2<Float>(0, 0.5),
                viewportSize: SIMD2<Float>(300, 300)
            )
        )
        let squareRightEdge = try XCTUnwrap(
            overlay.normalizedPreviewPoint(
                SIMD2<Float>(1, 0.5),
                viewportSize: SIMD2<Float>(300, 300)
            )
        )
        let squareTopEdge = try XCTUnwrap(
            overlay.normalizedPreviewPoint(
                SIMD2<Float>(0.5, 0),
                viewportSize: SIMD2<Float>(300, 300)
            )
        )
        let squareBottomEdge = try XCTUnwrap(
            overlay.normalizedPreviewPoint(
                SIMD2<Float>(0.5, 1),
                viewportSize: SIMD2<Float>(300, 300)
            )
        )

        XCTAssertEqual(portraitPoint.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(portraitPoint.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(squareLeftEdge.x, 0, accuracy: 0.0001)
        XCTAssertEqual(squareRightEdge.x, 1, accuracy: 0.0001)
        XCTAssertLessThan(squareTopEdge.y, 0)
        XCTAssertGreaterThan(squareBottomEdge.y, 1)
    }

    func testObjectOverlayRejectsContourCroppedByVisibleAspectFillPreview() throws {
        let fullImageOutline = MeasurementObjectOutline(
            loops: [[
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(1, 1),
                SIMD2<Float>(0, 1),
            ]]
        )
        let safelyFramedOutline = MeasurementObjectOutline(
            loops: [[
                SIMD2<Float>(0.2, 0.2),
                SIMD2<Float>(0.8, 0.2),
                SIMD2<Float>(0.8, 0.8),
                SIMD2<Float>(0.2, 0.8),
            ]]
        )
        let viewport = SIMD2<Float>(300, 300)

        XCTAssertFalse(
            MeasurementObjectOverlay(
                displayOrientedImageSize: SIMD2<Float>(3, 4),
                outline: fullImageOutline
            ).isFullyVisible(in: viewport, protectedInsetFraction: 0.02),
            "an image-edge-safe contour can still be clipped by the visible aspect-fill crop"
        )
        XCTAssertTrue(
            MeasurementObjectOverlay(
                displayOrientedImageSize: SIMD2<Float>(3, 4),
                outline: safelyFramedOutline
            ).isFullyVisible(in: viewport, protectedInsetFraction: 0.02)
        )
    }

    func testObjectOverlayReportsPreviewStageForVisibleCropFailure() {
        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(3, 4),
            outline: MeasurementObjectOutline(
                loops: [[
                    SIMD2<Float>(0, 0),
                    SIMD2<Float>(1, 0),
                    SIMD2<Float>(1, 1),
                    SIMD2<Float>(0, 1),
                ]]
            )
        )

        XCTAssertEqual(
            overlay.previewFramingFailure(
                in: SIMD2<Float>(300, 300),
                protectedInsetFraction: 0.02
            ),
            .maskTouchesImageEdge(stage: .previewOutline)
        )
    }

    func testObjectOverlayRequiresVisibleSpaceAroundEveryContourEdge() throws {
        let bottomEdgeOutline = MeasurementObjectOutline(
            loops: [[
                SIMD2<Float>(0.3, 0.45),
                SIMD2<Float>(0.7, 0.45),
                SIMD2<Float>(0.7, 0.87),
                SIMD2<Float>(0.3, 0.87),
            ]]
        )
        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(3, 4),
            outline: bottomEdgeOutline
        )

        XCTAssertFalse(
            overlay.isFullyVisible(
                in: SIMD2<Float>(300, 300),
                protectedInsetFraction: 0.02
            )
        )
    }

    func testObjectOverlayPreservesCapturedPreviewAspectRatioForReview() throws {
        let outline = MeasurementObjectOutline(
            loops: [[
                SIMD2<Float>(0.25, 0.2),
                SIMD2<Float>(0.75, 0.2),
                SIMD2<Float>(0.75, 0.81),
                SIMD2<Float>(0.25, 0.81),
            ]]
        )
        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(3, 4),
            outline: outline,
            capturedPreviewAspectRatio: 0.75
        )

        XCTAssertEqual(overlay.capturedPreviewAspectRatio, 0.75, accuracy: 0.0001)
        XCTAssertTrue(
            overlay.isFullyVisible(
                in: SIMD2<Float>(300, 400),
                protectedInsetFraction: 0.02
            ),
            "the outline is visibly inset in the tall live aiming preview"
        )
    }

    func testObjectOverlayDefaultsToDisplayImageAspectRatioForLegacyCallers() throws {
        let outline = MeasurementObjectOutline(
            loops: [[
                SIMD2<Float>(0.25, 0.21),
                SIMD2<Float>(0.75, 0.21),
                SIMD2<Float>(0.75, 0.79),
                SIMD2<Float>(0.25, 0.79),
            ]]
        )
        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(3, 4),
            outline: outline
        )

        XCTAssertEqual(overlay.capturedPreviewAspectRatio, 0.75, accuracy: 0.0001)
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
        let measurement = permissiveMeasurement

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

    func testPointCloudUsesExplicitTargetForAppearanceAndDepthSelection() throws {
        let width = 12
        let height = 12
        var labels = Array(repeating: UInt32(0), count: width * height)
        for y in 3...8 {
            for x in 1...4 {
                labels[y * width + x] = 7
            }
            for x in 6...9 {
                labels[y * width + x] = 5
            }
        }

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: try PhotoInstanceLabelMask(
                width: width,
                height: height,
                labels: labels
            ),
            depthGrid: populatedDepthGrid(width: width, height: height),
            calibration: calibration(imageWidth: width, imageHeight: height),
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.25, 0.5))
        )

        XCTAssertEqual(result.selectedLabel, 7)
        XCTAssertEqual(result.maskQuality.selectedPixelCount, 24)
        XCTAssertEqual(
            Set(result.depthSupport.indices),
            Set((3...8).flatMap { y in (1...4).map { x in y * width + x } })
        )
    }

    func testPointCloudExcludesDisconnectedSameLabelClutter() throws {
        let width = 12
        let height = 12
        var labels = Array(repeating: UInt32(0), count: width * height)
        for y in 2...9 {
            for x in 4...7 {
                labels[y * width + x] = 5
            }
        }
        for y in 8...9 {
            for x in 9...10 {
                labels[y * width + x] = 5
            }
        }
        let result = try permissiveMeasurement.makePointCloud(
            labelMask: try PhotoInstanceLabelMask(width: width, height: height, labels: labels),
            depthGrid: populatedDepthGrid(width: width, height: height),
            calibration: calibration(imageWidth: width, imageHeight: height)
        )

        XCTAssertEqual(result.maskQuality.selectedPixelCount, 32)
        XCTAssertEqual(result.depthSupport.selectedMaskSampleCount, 32)
        XCTAssertEqual(
            Set(result.depthSupport.indices),
            Set((2...9).flatMap { y in (4...7).map { x in y * width + x } })
        )
        XCTAssertEqual(result.objectOutline?.loops.count, 1)
    }

    func testPointCloudExcludesVisuallyConnectedClutterAcrossDepthJump() throws {
        let width = 12
        let height = 12
        var labels = Array(repeating: UInt32(0), count: width * height)
        var depthGrid = populatedDepthGrid(width: width, height: height)
        for y in 2...9 {
            for x in 3...7 {
                labels[y * width + x] = 5
            }
        }
        for y in 6...8 {
            for x in 8...10 {
                let index = y * width + x
                labels[index] = 5
                depthGrid.depths[index] = 1.5
            }
        }

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: try PhotoInstanceLabelMask(width: width, height: height, labels: labels),
            depthGrid: depthGrid,
            calibration: calibration(imageWidth: width, imageHeight: height)
        )

        XCTAssertEqual(result.depthSupport.selectedMaskSampleCount, 40)
        XCTAssertEqual(result.depthSupport.supportedSampleCount, 40)
        XCTAssertEqual(result.depthSupport.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(
            Set(result.depthSupport.indices),
            Set((2...9).flatMap { y in (3...7).map { x in y * width + x } })
        )
        XCTAssertTrue(result.worldPoints.allSatisfy { abs($0.z + 1) < 0.0001 })
        XCTAssertEqual(result.objectOutline?.loops.count, 1)
    }

    func testPointCloudExcludesNarrowlyAttachedClutterAtSimilarDepth() throws {
        let width = 12
        let height = 12
        var labels = Array(repeating: UInt32(0), count: width * height)
        var depthGrid = populatedDepthGrid(width: width, height: height)
        for y in 2...9 {
            for x in 3...7 {
                labels[y * width + x] = 5
            }
        }
        for y in 6...8 {
            for x in 8...10 {
                let index = y * width + x
                labels[index] = 5
                depthGrid.depths[index] = 1.15
            }
        }

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: try PhotoInstanceLabelMask(width: width, height: height, labels: labels),
            depthGrid: depthGrid,
            calibration: calibration(imageWidth: width, imageHeight: height)
        )

        XCTAssertEqual(result.depthSupport.selectedMaskSampleCount, 40)
        XCTAssertEqual(result.depthSupport.supportedSampleCount, 40)
        XCTAssertEqual(result.depthSupport.coverage, 1, accuracy: 0.0001)
        XCTAssertEqual(
            Set(result.depthSupport.indices),
            Set((2...9).flatMap { y in (3...7).map { x in y * width + x } })
        )
        XCTAssertTrue(result.worldPoints.allSatisfy { abs($0.z + 1) < 0.0001 })
        XCTAssertEqual(result.objectOutline?.loops.count, 1)
    }

    func testReticleDepthFilterPreservesGraduallySlopedTargetSurface() throws {
        let width = 13
        let height = 11
        let labels = try boxMask(width: width, height: height, x: 3...9, y: 2...8)
        var depthGrid = populatedDepthGrid(width: width, height: height)
        for y in 2...8 {
            for x in 3...9 {
                depthGrid.depths[y * width + x] = 1 + Float(abs(x - 6)) * 0.04
            }
        }

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: labels,
            depthGrid: depthGrid,
            calibration: calibration(imageWidth: width, imageHeight: height)
        )

        XCTAssertEqual(result.depthSupport.selectedMaskSampleCount, 49)
        XCTAssertEqual(result.depthSupport.supportedSampleCount, 49)
        XCTAssertEqual(
            Set(result.depthSupport.indices),
            Set((2...8).flatMap { y in (3...9).map { x in y * width + x } })
        )
    }

    func testReticleDepthFilterRetainsTwoVisibleFacesOfBox() throws {
        let width = 8
        let height = 8
        let labels = try boxMask(width: width, height: height, x: 1...6, y: 1...6)
        var depthGrid = populatedDepthGrid(width: width, height: height)
        for y in 1...6 {
            for x in 1...3 {
                depthGrid.depths[y * width + x] = 1.25
            }
            for x in 4...6 {
                depthGrid.depths[y * width + x] = 1.45
            }
        }

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: labels,
            depthGrid: depthGrid,
            calibration: calibration(imageWidth: width, imageHeight: height)
        )

        XCTAssertEqual(result.depthSupport.selectedMaskSampleCount, 36)
        XCTAssertEqual(result.depthSupport.supportedSampleCount, 36)
        XCTAssertEqual(
            Set(result.depthSupport.indices),
            Set((1...6).flatMap { y in (1...6).map { x in y * width + x } })
        )
    }

    func testRejectsMaskWithoutReticleConnectedDepthSurface() throws {
        let width = 12
        let height = 12
        let labels = try boxMask(width: width, height: height, x: 1...2, y: 1...2)
        let depthGrid = populatedDepthGrid(width: width, height: height)

        XCTAssertThrowsError(
            try permissiveMeasurement.makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: width, imageHeight: height)
            )
        ) { error in
            XCTAssertEqual(error as? PhotoObjectMeasurementError, .noReticleDepthSurface)
        }
    }

    func testOutlineUsesExactlyTheDepthSupportedMeasurementRegion() throws {
        let width = 9
        let height = 9
        let labels = try boxMask(width: width, height: height, x: 2...6, y: 2...6)
        var depthGrid = populatedDepthGrid(width: width, height: height)
        depthGrid.confidences[2 * width + 2] = 1

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: labels,
            depthGrid: depthGrid,
            calibration: calibration(imageWidth: width, imageHeight: height)
        )
        let expectedOutline = MeasurementObjectOutline(
            width: width,
            height: height,
            selectedIndices: result.depthSupport.indices
        )

        XCTAssertEqual(result.worldPoints.count, result.depthSupport.indices.count)
        XCTAssertEqual(result.objectOutline, expectedOutline)
    }

    func testRejectsMaskClippedByImageEdge() throws {
        let labels = try boxMask(width: 10, height: 10, x: 0...5, y: 2...7)
        let depthGrid = populatedDepthGrid(width: 10, height: 10)

        XCTAssertThrowsError(
            try permissiveMeasurement.makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: 10, imageHeight: 10)
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .maskTouchesImageEdge(stage: .sourceMask)
            )
        }
    }

    func testRejectsClippedMaskWhenImageEdgeDepthIsUnknown() throws {
        let width = 10
        let height = 10
        let labels = try boxMask(width: width, height: height, x: 0...5, y: 2...7)
        var depthGrid = populatedDepthGrid(width: width, height: height)
        for y in 2...7 {
            let index = y * width
            depthGrid.depths[index] = .nan
            depthGrid.confidences[index] = 0
        }

        XCTAssertThrowsError(
            try permissiveMeasurement.makePointCloud(
                labelMask: labels,
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: width, imageHeight: height),
                prompt: .target(normalizedImagePoint: SIMD2<Float>(0.35, 0.5))
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .maskTouchesImageEdge(stage: .sourceMask)
            )
        }
    }

    func testRejectsThinSourceEdgeContinuationMissedByLowerResolutionDepthSampling() throws {
        let imageWidth = 64
        let imageHeight = 48
        let depthWidth = 8
        let depthHeight = 6
        var labels = Array(repeating: UInt32.zero, count: imageWidth * imageHeight)

        for y in 16...39 {
            for x in 16...47 {
                labels[y * imageWidth + x] = 5
            }
        }
        // This one-source-pixel-high continuation reaches the image edge but
        // falls between the lower-resolution depth grid's center samples.
        for x in 0...15 {
            labels[24 * imageWidth + x] = 5
        }

        var depthGrid = populatedDepthGrid(width: depthWidth, height: depthHeight)
        for x in 0...1 {
            let index = 3 * depthWidth + x
            depthGrid.depths[index] = .nan
            depthGrid.confidences[index] = 0
        }

        XCTAssertThrowsError(
            try permissiveMeasurement.makePointCloud(
                labelMask: PhotoInstanceLabelMask(
                    width: imageWidth,
                    height: imageHeight,
                    labels: labels
                ),
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: imageWidth, imageHeight: imageHeight),
                prompt: .target(normalizedImagePoint: SIMD2<Float>(0.5, 0.5))
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .maskTouchesImageEdge(stage: .sourceMask)
            )
        }
    }

    func testRejectsDepthDisconnectedEdgeIslandAcrossUnknownBridge() throws {
        let width = 16
        let height = 12
        var labels = Array(repeating: UInt32.zero, count: width * height)
        var depthGrid = populatedDepthGrid(width: width, height: height)

        for y in 2...9 {
            for x in 3...8 {
                labels[y * width + x] = 5
                depthGrid.depths[y * width + x] = 1
            }
        }
        for y in 4...7 {
            let bridgeIndex = y * width + 9
            labels[bridgeIndex] = 5
            depthGrid.depths[bridgeIndex] = .nan
            depthGrid.confidences[bridgeIndex] = 0
            for x in 10...15 {
                labels[y * width + x] = 5
                depthGrid.depths[y * width + x] = 1.5
            }
        }

        XCTAssertThrowsError(
            try permissiveMeasurement.makePointCloud(
                labelMask: PhotoInstanceLabelMask(
                    width: width,
                    height: height,
                    labels: labels
                ),
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: width, imageHeight: height),
                prompt: .target(normalizedImagePoint: SIMD2<Float>(0.35, 0.5))
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .maskTouchesImageEdge(stage: .sourceMask)
            )
        }
    }

    func testAcceptsInsetTargetWhenDepthSeparatedAppearanceArtifactTouchesImageEdge() throws {
        let width = 16
        let height = 12
        var labels = Array(repeating: UInt32.zero, count: width * height)
        var depthGrid = populatedDepthGrid(width: width, height: height)
        let targetIndices = Set((2...9).flatMap { y in
            (3...9).map { x in y * width + x }
        })
        let edgeArtifactIndices = Set((2...9).flatMap { y in
            (10...15).map { x in y * width + x }
        })

        for index in targetIndices {
            labels[index] = 5
            depthGrid.depths[index] = 1
        }
        for index in edgeArtifactIndices {
            labels[index] = 5
            depthGrid.depths[index] = 1.5
        }

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: PhotoInstanceLabelMask(
                width: width,
                height: height,
                labels: labels
            ),
            depthGrid: depthGrid,
            calibration: calibration(imageWidth: width, imageHeight: height),
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.35, 0.5))
        )

        XCTAssertTrue(result.maskQuality.touchesProtectedEdge)
        XCTAssertEqual(Set(result.depthSupport.indices), targetIndices)
        XCTAssertEqual(
            result.depthSupport.selectedMaskSampleCount,
            targetIndices.count,
            "a rejected reflection or neighboring surface must not dilute D03/D05 support"
        )
        XCTAssertEqual(result.depthSupport.supportedSampleCount, targetIndices.count)
        XCTAssertEqual(result.depthSupport.horizontalSupport, 1, accuracy: 0.0001)
        XCTAssertEqual(
            result.depthSupport.horizontalEndpointCoverage,
            1,
            accuracy: 0.0001
        )
        XCTAssertFalse(result.depthSupport.indices.contains { $0 % width == width - 1 })
    }

    func testRejectsLegitimateMergedBoxFaceThatReachesImageEdge() throws {
        let width = 16
        let height = 12
        var labels = Array(repeating: UInt32.zero, count: width * height)
        var depthGrid = populatedDepthGrid(width: width, height: height)

        for y in 2...9 {
            for x in 3...15 {
                let index = y * width + x
                labels[index] = 5
                depthGrid.depths[index] = x <= 8 ? 1 : 1.2
            }
        }

        XCTAssertThrowsError(
            try permissiveMeasurement.makePointCloud(
                labelMask: PhotoInstanceLabelMask(
                    width: width,
                    height: height,
                    labels: labels
                ),
                depthGrid: depthGrid,
                calibration: calibration(imageWidth: width, imageHeight: height),
                prompt: .target(normalizedImagePoint: SIMD2<Float>(0.35, 0.5))
            )
        ) { error in
            XCTAssertEqual(
                error as? PhotoObjectMeasurementError,
                .maskTouchesImageEdge(stage: .sourceMask)
            )
        }
    }

    func testAcceptsProvenAlternateEdgeArtifactAcrossImageAndDepthResolutions() throws {
        let imageWidth = 64
        let imageHeight = 48
        let depthWidth = 8
        let depthHeight = 6
        var labels = Array(repeating: UInt32.zero, count: imageWidth * imageHeight)
        var depthGrid = populatedDepthGrid(width: depthWidth, height: depthHeight)

        for y in 8...39 {
            for x in 16...39 {
                labels[y * imageWidth + x] = 5
            }
        }
        for y in 16...31 {
            for x in 40...63 {
                labels[y * imageWidth + x] = 5
            }
        }
        for y in 2...3 {
            for x in 5...7 {
                depthGrid.depths[y * depthWidth + x] = 1.5
            }
        }

        let result = try permissiveMeasurement.makePointCloud(
            labelMask: PhotoInstanceLabelMask(
                width: imageWidth,
                height: imageHeight,
                labels: labels
            ),
            depthGrid: depthGrid,
            calibration: calibration(imageWidth: imageWidth, imageHeight: imageHeight),
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.5, 0.5))
        )

        let expectedTargetDepthIndices = Set((1...4).flatMap { y in
            (2...4).map { x in y * depthWidth + x }
        })
        XCTAssertTrue(result.maskQuality.touchesProtectedEdge)
        XCTAssertEqual(Set(result.depthSupport.indices), expectedTargetDepthIndices)
        XCTAssertEqual(
            result.depthSupport.selectedMaskSampleCount,
            expectedTargetDepthIndices.count
        )
        XCTAssertFalse(result.depthSupport.indices.contains { $0 % depthWidth >= 5 })
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
            try permissiveMeasurement.makePointCloud(
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
            try PhotoObjectMeasurement(
                policy: policy,
                rigidItemMultiplicityGuard: nil
            ).makePointCloud(
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

    func testRejectsHorizontalExtentSupportedOnlyByEndpointOutliers() throws {
        let width = 14
        let height = 12
        let mask = try selectionMask(width: width, height: height, x: 2...11, y: 1...10)
        var confidences = Array(repeating: UInt8(0), count: width * height)
        for y in 1...10 {
            for x in 4...9 {
                confidences[y * width + x] = 2
            }
        }
        confidences[1 * width + 2] = 2
        confidences[10 * width + 11] = 2
        let depthGrid = DepthGrid(
            width: width,
            height: height,
            depths: Array(repeating: 1, count: width * height),
            confidences: confidences
        )
        let policy = PhotoObjectMeasurementPolicy()

        XCTAssertThrowsError(
            try PhotoDepthSupportAnalyzer(policy: policy).analyze(
                mask: mask,
                depthGrid: depthGrid
            )
        ) { error in
            guard case let .insufficientHorizontalDepthEndpointCoverage(actual, minimum) =
                    error as? PhotoObjectMeasurementError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actual, 0.05, accuracy: 0.0001)
            XCTAssertEqual(minimum, 0.5, accuracy: 0.0001)
        }
    }

    func testRejectsVerticalExtentSupportedOnlyByEndpointOutliers() throws {
        let width = 14
        let height = 12
        let mask = try selectionMask(width: width, height: height, x: 2...11, y: 1...10)
        var confidences = Array(repeating: UInt8(0), count: width * height)
        for y in 3...8 {
            for x in 2...11 {
                confidences[y * width + x] = 2
            }
        }
        confidences[1 * width + 2] = 2
        confidences[10 * width + 11] = 2
        let depthGrid = DepthGrid(
            width: width,
            height: height,
            depths: Array(repeating: 1, count: width * height),
            confidences: confidences
        )
        let policy = PhotoObjectMeasurementPolicy()

        XCTAssertThrowsError(
            try PhotoDepthSupportAnalyzer(policy: policy).analyze(
                mask: mask,
                depthGrid: depthGrid
            )
        ) { error in
            guard case let .insufficientVerticalDepthEndpointCoverage(actual, minimum) =
                    error as? PhotoObjectMeasurementError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(actual, 0.05, accuracy: 0.0001)
            XCTAssertEqual(minimum, 0.5, accuracy: 0.0001)
        }
    }

    func testAcceptsDepthWithDenseSupportAtAllFourEndpoints() throws {
        let width = 14
        let height = 12
        let mask = try selectionMask(width: width, height: height, x: 2...11, y: 1...10)
        var confidences = Array(repeating: UInt8(2), count: width * height)
        for y in 4...7 {
            for x in 5...8 {
                confidences[y * width + x] = 0
            }
        }
        let depthGrid = DepthGrid(
            width: width,
            height: height,
            depths: Array(repeating: 1, count: width * height),
            confidences: confidences
        )
        let policy = PhotoObjectMeasurementPolicy()

        let support = try PhotoDepthSupportAnalyzer(policy: policy).analyze(
            mask: mask,
            depthGrid: depthGrid
        )

        XCTAssertEqual(support.horizontalSupport, 1, accuracy: 0.0001)
        XCTAssertEqual(support.verticalSupport, 1, accuracy: 0.0001)
        XCTAssertEqual(support.horizontalEndpointCoverage, 1, accuracy: 0.0001)
        XCTAssertEqual(support.verticalEndpointCoverage, 1, accuracy: 0.0001)
    }

    func testRejectsInvalidDepthEndpointBandFractionPolicy() throws {
        var policy = permissivePolicy
        policy.depthEndpointBandFraction = 0

        XCTAssertThrowsError(try policy.validate()) { error in
            XCTAssertEqual(error as? PhotoObjectMeasurementError, .invalidPolicy)
        }

        policy.depthEndpointBandFraction = 0.51
        XCTAssertThrowsError(try policy.validate()) { error in
            XCTAssertEqual(error as? PhotoObjectMeasurementError, .invalidPolicy)
        }
    }

    func testRejectsMaskAndCalibrationWithDifferentAspectRatios() throws {
        let labels = try boxMask(width: 8, height: 4, x: 2...5, y: 1...2)
        let depthGrid = populatedDepthGrid(width: 4, height: 2)

        XCTAssertThrowsError(
            try permissiveMeasurement.makePointCloud(
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

    private var permissiveMeasurement: PhotoObjectMeasurement {
        PhotoObjectMeasurement(
            policy: permissivePolicy,
            rigidItemMultiplicityGuard: nil
        )
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
            minimumVerticalDepthSupport: 0.6,
            minimumDepthEndpointCoverage: 0
        )
    }

    private func polygonArea(_ points: [SIMD2<Float>]) -> Float {
        guard points.count >= 3 else { return 0 }
        let followingPoints = Array(points.dropFirst()) + [points[0]]
        return abs(zip(points, followingPoints).reduce(0) { total, pair in
            total + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        }) / 2
    }

    private func isFiniteAndNormalized(_ point: SIMD2<Float>) -> Bool {
        point.x.isFinite
            && point.y.isFinite
            && (0...1).contains(point.x)
            && (0...1).contains(point.y)
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

    private func selectionMask(
        width: Int,
        height: Int,
        x: ClosedRange<Int>,
        y: ClosedRange<Int>
    ) throws -> PhotoDepthSelectionMask {
        var selected = Array(repeating: false, count: width * height)
        for row in y {
            for column in x {
                selected[row * width + column] = true
            }
        }
        return try PhotoDepthSelectionMask(width: width, height: height, selected: selected)
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
        for y in 3...9 {
            for x in 3...5 {
                labels[y * width + x] = 5
            }
        }
        for y in 7...9 {
            for x in 3...9 {
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
