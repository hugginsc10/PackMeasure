import CoreGraphics
import simd

/// Converts a point in the laid-out camera preview back into the raw camera
/// image's normalized coordinate space. ARKit's display transform owns both
/// rotation and aspect-fill cropping, so target selection must invert that
/// exact transform rather than approximating it from device orientation.
enum ScannerTargetProjection {
    static func normalizedImagePoint(
        previewPoint: SIMD2<Float>,
        viewportSize: SIMD2<Float>,
        displayTransform: CGAffineTransform
    ) -> SIMD2<Float>? {
        guard previewPoint.x.isFinite,
              previewPoint.y.isFinite,
              viewportSize.x.isFinite,
              viewportSize.y.isFinite,
              viewportSize.x > 0,
              viewportSize.y > 0,
              previewPoint.x >= 0,
              previewPoint.x <= viewportSize.x,
              previewPoint.y >= 0,
              previewPoint.y <= viewportSize.y,
              displayTransform.a.isFinite,
              displayTransform.b.isFinite,
              displayTransform.c.isFinite,
              displayTransform.d.isFinite,
              displayTransform.tx.isFinite,
              displayTransform.ty.isFinite else {
            return nil
        }

        let determinant = displayTransform.a * displayTransform.d
            - displayTransform.b * displayTransform.c
        guard determinant.isFinite, abs(determinant) > 0.000_000_1 else {
            return nil
        }

        let normalizedPreviewPoint = CGPoint(
            x: CGFloat(previewPoint.x / viewportSize.x),
            y: CGFloat(previewPoint.y / viewportSize.y)
        )
        let rawImagePoint = normalizedPreviewPoint.applying(
            displayTransform.inverted()
        )
        guard rawImagePoint.x.isFinite,
              rawImagePoint.y.isFinite,
              (0...1).contains(rawImagePoint.x),
              (0...1).contains(rawImagePoint.y) else {
            return nil
        }

        return SIMD2<Float>(
            Float(rawImagePoint.x),
            Float(rawImagePoint.y)
        )
    }
}
