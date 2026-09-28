import CoreGraphics
import Testing
import simd
@testable import PackMeasure

@Suite("Explicit target scanner integration")
struct TargetSelectionIntegrationTests {
    @Test
    func missingTappedForegroundFailsClosedWithoutCenterFallback() {
        let failure = SingleShotCaptureFailure.targetSelection(
            .noForegroundAtTargetPoint
        )

        #expect(failure.retryCategory == .isolation)
        #expect(failure.disposition == .targetRejected)
        #expect(failure.diagnosticCode == "F07")
        #expect(!failure.shouldAttemptReticleDepthFallback)

        let copy = ScannerPhotoFailureCopy.message(for: failure)
        #expect(copy.localizedCaseInsensitiveContains("same item"))
        #expect(copy.localizedCaseInsensitiveContains("retake the photo"))
        #expect(!copy.localizedCaseInsensitiveContains("diagnostic"))
        #expect(!copy.localizedCaseInsensitiveContains("center of the frame"))
    }

    @Test
    func invalidAndSupersededTargetPromptsNeverRegainLegacyCenterAuthority() {
        let invalid = SingleShotCaptureFailure.targetSelection(
            .invalidTargetSelectionPoint
        )
        let stale = SingleShotCaptureFailure.targetSelection(
            .staleTargetSelectionPrompt
        )

        #expect(invalid.retryCategory == .processing)
        #expect(invalid.disposition == .unavailable)
        #expect(invalid.diagnosticCode == "P10")
        #expect(!invalid.shouldAttemptReticleDepthFallback)

        #expect(stale.retryCategory == .isolation)
        #expect(stale.disposition == .targetRejected)
        #expect(stale.diagnosticCode == "T02")
        #expect(!stale.shouldAttemptReticleDepthFallback)
    }

    @Test
    func previewTapUsesInverseDisplayTransformExactlyOnce() throws {
        let viewport = SIMD2<Float>(320, 640)
        let rawImagePoint = SIMD2<Float>(0.72, 0.34)
        let displayTransform = CGAffineTransform(
            a: 0,
            b: 1,
            c: -1,
            d: 0,
            tx: 1,
            ty: 0
        )
        let normalizedPreviewPoint = CGPoint(
            x: CGFloat(rawImagePoint.x),
            y: CGFloat(rawImagePoint.y)
        ).applying(displayTransform)
        let previewPoint = SIMD2<Float>(
            Float(normalizedPreviewPoint.x) * viewport.x,
            Float(normalizedPreviewPoint.y) * viewport.y
        )

        let mapped = try #require(
            ScannerTargetProjection.normalizedImagePoint(
                previewPoint: previewPoint,
                viewportSize: viewport,
                displayTransform: displayTransform
            )
        )

        #expect(abs(mapped.x - rawImagePoint.x) < 0.000_01)
        #expect(abs(mapped.y - rawImagePoint.y) < 0.000_01)
    }

    @Test
    func invalidPreviewGeometryCannotCreateTargetAuthority() {
        let identity = CGAffineTransform.identity

        #expect(
            ScannerTargetProjection.normalizedImagePoint(
                previewPoint: SIMD2<Float>(20, 20),
                viewportSize: SIMD2<Float>(0, 100),
                displayTransform: identity
            ) == nil
        )
        #expect(
            ScannerTargetProjection.normalizedImagePoint(
                previewPoint: SIMD2<Float>(-1, 20),
                viewportSize: SIMD2<Float>(100, 100),
                displayTransform: identity
            ) == nil
        )
        #expect(
            ScannerTargetProjection.normalizedImagePoint(
                previewPoint: SIMD2<Float>(20, 20),
                viewportSize: SIMD2<Float>(100, 100),
                displayTransform: CGAffineTransform(
                    a: 1,
                    b: 2,
                    c: 2,
                    d: 4,
                    tx: 0,
                    ty: 0
                )
            ) == nil
        )
    }
}
