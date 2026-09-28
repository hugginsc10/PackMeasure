import ARKit
import UIKit

/// Image, depth, calibration and pose from a single frame in the current session.
struct InteriorPhoto: Identifiable {
    let id = UUID()
    let generation: UUID
    let image: UIImage
    let grid: DepthGrid
    let imageSize: SIMD2<Int>
    let intrinsics: simd_float3x3
    let transform: simd_float4x4

    func worldPoint(at portraitPoint: CGPoint) -> SIMD3<Float>? {
        guard portraitPoint.x.isFinite, portraitPoint.y.isFinite,
              (0..<1).contains(portraitPoint.x), (0..<1).contains(portraitPoint.y) else { return nil }
        let sensor = SIMD2<Float>(Float(portraitPoint.y), 1 - Float(portraitPoint.x))
        let reading = ScannerFrameDepthSampler(minimumDepthMeters: 0.15, maximumDepthMeters: 2.5)
            .sample(normalizedImagePoint: sensor, grid: grid, cameraImageResolutionPixels: imageSize,
                    cameraIntrinsics: intrinsics, cameraTransform: transform)
        guard let reading, reading.confidence == .high else { return nil }
        return reading.worldPosition
    }

    func portraitPoint(_ world: SIMD3<Float>) -> CGPoint? {
        let local = transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        guard local.z < -0.001 else { return nil }
        let x = (intrinsics[0][0] * local.x / -local.z + intrinsics[2][0]) / Float(imageSize.x)
        let y = (intrinsics[2][1] - intrinsics[1][1] * local.y / -local.z) / Float(imageSize.y)
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(1 - y), y: CGFloat(x))
    }
}
