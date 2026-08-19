import Foundation

struct DepthGrid: Sendable {
    let width: Int
    let height: Int
    var depths: [Float]
    var confidences: [UInt8]

    init(width: Int, height: Int, depths: [Float], confidences: [UInt8]) {
        precondition(width > 0 && height > 0)
        precondition(depths.count == width * height)
        precondition(confidences.count == depths.count)
        self.width = width
        self.height = height
        self.depths = depths
        self.confidences = confidences
    }
}

struct PixelBounds: Equatable, Sendable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int
}

struct DepthRegion: Sendable {
    let indices: [Int]
    let seedDepthMeters: Float
    let bounds: PixelBounds

    var pixelCount: Int { indices.count }

    func contains(x: Int, y: Int, gridWidth: Int) -> Bool {
        indices.contains(y * gridWidth + x)
    }
}

/// Finds the connected depth surface under the center reticle.
///
/// The global seed-distance guard prevents the walk from leaking far behind
/// the target, while the local gradient guard allows it to follow a visible
/// side or top face that gradually recedes from the camera.
struct DepthRegionSegmenter: Sendable {
    var minimumConfidence: UInt8 = 1
    var minimumDepthMeters: Float = 0.15
    var maximumDepthMeters: Float = 6.0
    var localJumpMeters: Float = 0.075
    var localJumpFraction: Float = 0.035
    var maximumSeedDeltaMeters: Float = 0.75
    var maximumSeedDeltaFraction: Float = 0.45
    var seedSearchRadius: Int = 3

    func segment(_ grid: DepthGrid) -> DepthRegion? {
        guard let seed = findSeed(in: grid) else { return nil }
        let seedDepth = grid.depths[seed]
        let maxSeedDelta = max(maximumSeedDeltaMeters, seedDepth * maximumSeedDeltaFraction)

        var visited = Array(repeating: false, count: grid.depths.count)
        var accepted: [Int] = []
        var queue: [Int] = [seed]
        var readIndex = 0
        visited[seed] = true

        while readIndex < queue.count {
            let index = queue[readIndex]
            readIndex += 1
            accepted.append(index)

            let x = index % grid.width
            let y = index / grid.width
            let currentDepth = grid.depths[index]

            for neighbor in neighbors(x: x, y: y, width: grid.width, height: grid.height) {
                guard !visited[neighbor] else { continue }
                visited[neighbor] = true

                let candidateDepth = grid.depths[neighbor]
                guard isUsable(index: neighbor, in: grid) else { continue }
                guard abs(candidateDepth - seedDepth) <= maxSeedDelta else { continue }

                let localLimit = max(localJumpMeters, currentDepth * localJumpFraction)
                guard abs(candidateDepth - currentDepth) <= localLimit else { continue }
                queue.append(neighbor)
            }
        }

        guard !accepted.isEmpty else { return nil }
        let xs = accepted.map { $0 % grid.width }
        let ys = accepted.map { $0 / grid.width }
        let bounds = PixelBounds(
            minX: xs.min() ?? 0,
            minY: ys.min() ?? 0,
            maxX: xs.max() ?? 0,
            maxY: ys.max() ?? 0
        )
        return DepthRegion(indices: accepted, seedDepthMeters: seedDepth, bounds: bounds)
    }

    private func findSeed(in grid: DepthGrid) -> Int? {
        let centerX = grid.width / 2
        let centerY = grid.height / 2

        for radius in 0...seedSearchRadius {
            var candidates: [(index: Int, distanceSquared: Int, depth: Float)] = []
            let minX = max(0, centerX - radius)
            let maxX = min(grid.width - 1, centerX + radius)
            let minY = max(0, centerY - radius)
            let maxY = min(grid.height - 1, centerY + radius)

            for y in minY...maxY {
                for x in minX...maxX {
                    guard radius == 0 || x == minX || x == maxX || y == minY || y == maxY else {
                        continue
                    }
                    let index = y * grid.width + x
                    guard isUsable(index: index, in: grid) else { continue }
                    let dx = x - centerX
                    let dy = y - centerY
                    candidates.append((index, dx * dx + dy * dy, grid.depths[index]))
                }
            }

            if let best = candidates.min(by: {
                if $0.distanceSquared == $1.distanceSquared { return $0.depth < $1.depth }
                return $0.distanceSquared < $1.distanceSquared
            }) {
                return best.index
            }
        }
        return nil
    }

    private func isUsable(index: Int, in grid: DepthGrid) -> Bool {
        let depth = grid.depths[index]
        return depth.isFinite
            && depth >= minimumDepthMeters
            && depth <= maximumDepthMeters
            && grid.confidences[index] >= minimumConfidence
    }

    private func neighbors(x: Int, y: Int, width: Int, height: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(4)
        if x > 0 { result.append(y * width + x - 1) }
        if x + 1 < width { result.append(y * width + x + 1) }
        if y > 0 { result.append((y - 1) * width + x) }
        if y + 1 < height { result.append((y + 1) * width + x) }
        return result
    }
}
