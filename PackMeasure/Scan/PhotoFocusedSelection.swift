import Foundation
import simd

/// Integer crops and mask registration share top-left raw-image coordinates.
struct PhotoFocusWindow: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    static func candidates(width: Int, height: Int, target: SIMD2<Float>) -> [Self] {
        guard width > 0, height > 0, target.x.isFinite, target.y.isFinite,
              target.x >= 0, target.x <= 1, target.y >= 0, target.y <= 1 else { return [] }
        return [0.8, 0.65, 0.5].map { fraction in
            let w = max(1, Int(Double(width) * fraction))
            let h = max(1, Int(Double(height) * fraction))
            return Self(x: max(0, min(width - w, Int(target.x * Float(width)) - w / 2)),
                        y: max(0, min(height - h, Int(target.y * Float(height)) - h / 2)),
                        width: w, height: h)
        }
    }

    func prompt(_ target: SIMD2<Float>, imageWidth: Int, imageHeight: Int) -> SIMD2<Float> {
        SIMD2((target.x * Float(imageWidth) - Float(x)) / Float(width),
              (target.y * Float(imageHeight) - Float(y)) / Float(height))
    }

    /// Never promote a mask cut by a crop boundary into a full-image object.
    func registered(_ selection: PhotoSelectedInstanceMask, imageWidth: Int,
                    imageHeight: Int) throws -> PhotoInstanceLabelMask? {
        guard selection.width == width, selection.height == height,
              x >= 0, y >= 0, x + width <= imageWidth, y + height <= imageHeight,
              !selection.quality(edgeMarginPixels: max(2, min(width, height) / 50)).touchesProtectedEdge else { return nil }
        var labels = Array(repeating: UInt32(0), count: imageWidth * imageHeight)
        for cy in 0..<height {
            for cx in 0..<width where selection.contains(x: cx, y: cy) {
                labels[(y + cy) * imageWidth + x + cx] = 1
            }
        }
        return try PhotoInstanceLabelMask(width: imageWidth, height: imageHeight, labels: labels)
    }
}

struct PhotoFocusedSelectionConsensus {
    /// Require two context sizes to select essentially the same complete shape.
    /// Preserve their union, rather than shrinking to their intersection.
    static func merge(_ first: PhotoInstanceLabelMask, _ second: PhotoInstanceLabelMask,
                      within original: PhotoSelectedInstanceMask) throws -> PhotoInstanceLabelMask? {
        guard first.width == second.width, first.height == second.height,
              first.width == original.width, first.height == original.height else { return nil }
        var intersection = 0, union = 0
        var labels = Array(repeating: UInt32(0), count: first.labels.count)
        for index in labels.indices {
            let a = first.labels[index] != 0, b = second.labels[index] != 0
            guard a || b else { continue }
            // A focused pass cannot acquire a different original foreground object.
            guard original.contains(x: index % first.width, y: index / first.width) else { return nil }
            union += 1
            if a && b { intersection += 1 }
            labels[index] = 1
        }
        guard union > 0, Double(intersection) / Double(union) >= 0.9 else { return nil }
        return try PhotoInstanceLabelMask(width: first.width, height: first.height, labels: labels)
    }
}
