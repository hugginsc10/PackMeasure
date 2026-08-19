import CoreGraphics
import Testing
import simd
@testable import PackMeasure

@Suite("Single-shot object measurement")
struct SingleShotObjectMeasurementTests {
    @Test
    func projectsOnlyMaskedConfidentDepthSamples() throws {
        let mask = ImageMask(
            width: 4,
            height: 4,
            values: [
                0, 0, 0, 0,
                0, 1, 1, 0,
                0, 1, 1, 0,
                0, 0, 0, 0,
            ]
        )
        let grid = DepthGrid(
            width: 2,
            height: 2,
            depths: [1, 1, 1, 1],
            confidences: [2, 1, 2, 2]
        )
        let projection = try #require(
            MaskedDepthPointProjector(
                minimumConfidence: 2,
                minimumMaskValue: 0.5
            ).project(
                mask: mask,
                depthGrid: grid,
                imageResolution: CGSize(width: 4, height: 4),
                intrinsics: intrinsics(),
                cameraTransform: matrix_identity_float4x4,
                maximumCount: 8
            )
        )

        #expect(projection.points.count == 3)
        #expect(projection.selectedDepthSampleCount == 3)
        #expect(!projection.touchesImageEdge)
        #expect(abs(projection.coverage - 0.75) < 0.001)
    }

    @Test
    func singleShotOutcomeRejectsWeakMaskBeforeGeometry() {
        let outcome = SingleShotObjectMeasurement.outcome(
            mask: ImageMask(width: 6, height: 6, values: Array(repeating: 0, count: 36)),
            depthGrid: DepthGrid(
                width: 3,
                height: 3,
                depths: Array(repeating: 1, count: 9),
                confidences: Array(repeating: 2, count: 9)
            ),
            imageResolution: CGSize(width: 6, height: 6),
            intrinsics: intrinsics(),
            cameraTransform: matrix_identity_float4x4
        )

        #expect(outcome == .failure(.targetRejected(.insufficientSurfaceEvidence)))
    }

    @Test
    func oneFrameIsEnoughForASingleShotMeasurement() {
        let points = syntheticBoxPoints(
            length: 1.2,
            width: 0.6,
            height: 0.75,
            yaw: .pi / 7,
            center: SIMD3<Double>(0, 0.375, 0)
        ).map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }

        let outcome = MeasurementEstimator.outcome(
            from: points,
            frameCount: 1,
            targetValidation: .valid
        )

        guard case .success(let estimate) = outcome else {
            Issue.record("expected one-frame single-shot estimate to succeed")
            return
        }
        #expect(abs(estimate.lengthMeters - 1.2) < 0.08)
        #expect(abs(estimate.widthMeters - 0.6) < 0.08)
        #expect(abs(estimate.heightMeters - 0.75) < 0.08)
    }

    private func intrinsics() -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(2, 0, 0),
            SIMD3<Float>(0, 2, 0),
            SIMD3<Float>(0.5, 0.5, 1)
        )
    }

    private func syntheticBoxPoints(
        length: Double,
        width: Double,
        height: Double,
        yaw: Double,
        center: SIMD3<Double>
    ) -> [SIMD3<Double>] {
        let rotation = simd_double3x3(
            SIMD3<Double>(cos(yaw), 0, sin(yaw)),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(-sin(yaw), 0, cos(yaw))
        )

        var points: [SIMD3<Double>] = []
        for xi in stride(from: -length / 2, through: length / 2, by: 0.06) {
            for zi in stride(from: -width / 2, through: width / 2, by: 0.06) {
                for yi in stride(from: 0.0, through: height, by: height / 4) {
                    let local = SIMD3<Double>(xi, yi - height / 2, zi)
                    let rotated = rotation * local
                    points.append(rotated + center)
                }
            }
        }

        for xi in stride(from: -length / 2, through: length / 2, by: 0.09) {
            for zi in stride(from: -width / 2, through: width / 2, by: 0.09) {
                let local = SIMD3<Double>(xi, -height / 2, zi)
                let rotated = rotation * local
                points.append(rotated + center)
            }
        }

        return points
    }
}
