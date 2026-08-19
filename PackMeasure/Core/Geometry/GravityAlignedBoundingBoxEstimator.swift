import Foundation

/// Estimates the smallest gravity-aligned 3D packing box from world-space
/// points. Y is treated as vertical. XZ orientation starts with robust PCA,
/// while a small minimum-area refinement resolves PCA's square-box ambiguity.
struct GravityAlignedBoundingBoxEstimator: Sendable {
    struct Configuration: Equatable, Sendable {
        var trimmingFraction: Double = 0.02
        var outlierFenceScale: Double = 0.15
        var voxelSizeMeters: Double = 0.005
        var minimumPointCount: Int = 8
        var minimumDimensionMeters: Double = 0.002
        var orientationSearchStepRadians: Double = .pi / 720

        static let `default` = Configuration()
    }

    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    func estimate(points: [SIMD3<Float>]) throws -> GravityAlignedBoundingBoxEstimate {
        try validateConfiguration()

        let finitePoints = points.filter(\.allComponentsAreFinite)
        guard finitePoints.count >= configuration.minimumPointCount else {
            throw BoundingBoxEstimationError.insufficientFinitePoints(
                actual: finitePoints.count,
                minimum: configuration.minimumPointCount
            )
        }

        let uniquePoints = voxelCentroids(
            finitePoints,
            voxelSizeMeters: configuration.voxelSizeMeters
        )
        guard uniquePoints.count >= configuration.minimumPointCount else {
            throw BoundingBoxEstimationError.insufficientUniquePoints(
                actual: uniquePoints.count,
                minimum: configuration.minimumPointCount
            )
        }

        let initialPCA = try horizontalPCA(of: uniquePoints)
        let initialAxes = HorizontalAxes(yaw: initialPCA.yaw)
        let initialProjections = project(uniquePoints, onto: initialAxes)
        let inlierPoints = robustInliers(
            points: uniquePoints,
            projections: initialProjections
        )

        guard inlierPoints.count >= configuration.minimumPointCount else {
            throw BoundingBoxEstimationError.insufficientUniquePoints(
                actual: inlierPoints.count,
                minimum: configuration.minimumPointCount
            )
        }

        var measurementPCA = initialPCA
        var measurementPoints = inlierPoints
        let refinedYaw = minimumAreaYaw(points: inlierPoints, around: initialPCA.yaw)
        var axes = HorizontalAxes(yaw: refinedYaw)
        var projections = project(inlierPoints, onto: axes)
        var extentAlongLengthAxis = projections.firstSpan
        var extentAlongWidthAxis = projections.secondSpan

        if extentAlongWidthAxis > extentAlongLengthAxis {
            axes = HorizontalAxes(yaw: refinedYaw + .pi / 2)
            projections = project(inlierPoints, onto: axes)
            swap(&extentAlongLengthAxis, &extentAlongWidthAxis)
        }

        var height = projections.verticalSpan
        guard extentAlongLengthAxis >= configuration.minimumDimensionMeters,
              extentAlongWidthAxis >= configuration.minimumDimensionMeters,
              height >= configuration.minimumDimensionMeters else {
            throw BoundingBoxEstimationError.degeneratePointCloud
        }

        var recoveredGroundPlane = false
        if hasGroundPlaneContamination(in: projections) {
            guard let recovery = recoverGroundContaminatedObject(
                from: inlierPoints,
                contaminatedProjections: projections
            ) else {
                throw BoundingBoxEstimationError.groundPlaneContamination
            }
            measurementPCA = recovery.pca
            measurementPoints = recovery.points
            axes = recovery.axes
            projections = recovery.projections
            extentAlongLengthAxis = recovery.length
            extentAlongWidthAxis = recovery.width
            height = recovery.height
            recoveredGroundPlane = true
        }

        let horizontalCenter = axes.point(
            first: projections.firstMidpoint,
            second: projections.secondMidpoint
        )
        let center = SIMD3<Float>(
            Float(horizontalCenter.x),
            Float(projections.verticalMidpoint),
            Float(horizontalCenter.z)
        )

        let dimensions = GeometryDimensions(
            lengthMeters: extentAlongLengthAxis,
            widthMeters: extentAlongWidthAxis,
            heightMeters: height
        )
        let inlierRatio = Double(measurementPoints.count) / Double(uniquePoints.count)
        let confidence = confidence(
            pointCount: measurementPoints.count,
            inlierRatio: inlierRatio,
            horizontalStability: measurementPCA.horizontalStability,
            dimensions: dimensions,
            maximumScore: recoveredGroundPlane ? 0.79 : 1
        )

        return GravityAlignedBoundingBoxEstimate(
            dimensions: dimensions,
            center: center,
            yawRadians: Float(normalizeHalfTurn(axes.yaw)),
            confidence: confidence,
            diagnostics: GeometryDiagnostics(
                inputPointCount: points.count,
                finitePointCount: finitePoints.count,
                uniquePointCount: uniquePoints.count,
                inlierPointCount: measurementPoints.count,
                filteredNonFinitePointCount: points.count - finitePoints.count,
                deduplicatedPointCount: finitePoints.count - uniquePoints.count,
                rejectedOutlierCount: uniquePoints.count - measurementPoints.count
            )
        )
    }

    private func validateConfiguration() throws {
        guard configuration.trimmingFraction >= 0,
              configuration.trimmingFraction < 0.25,
              configuration.outlierFenceScale >= 0,
              configuration.voxelSizeMeters > 0,
              configuration.minimumPointCount >= 4,
              configuration.minimumDimensionMeters > 0,
              configuration.orientationSearchStepRadians > 0,
              configuration.orientationSearchStepRadians <= .pi / 8 else {
            throw BoundingBoxEstimationError.invalidConfiguration
        }
    }

    private func horizontalPCA(of points: [SIMD3<Float>]) throws -> HorizontalPCA {
        let horizontal = points.map {
            HorizontalPoint(x: Double($0.x), z: Double($0.z))
        }
        let low = configuration.trimmingFraction
        let high = 1 - low
        let xLow = quantile(horizontal.map(\.x), at: low)
        let xHigh = quantile(horizontal.map(\.x), at: high)
        let zLow = quantile(horizontal.map(\.z), at: low)
        let zHigh = quantile(horizontal.map(\.z), at: high)

        // Winsorization protects the covariance (and therefore the PCA angle)
        // from isolated depth spikes without discarding real edge samples.
        let robust = horizontal.map {
            HorizontalPoint(
                x: min(max($0.x, xLow), xHigh),
                z: min(max($0.z, zLow), zHigh)
            )
        }
        let count = Double(robust.count)
        let meanX = robust.reduce(0) { $0 + $1.x } / count
        let meanZ = robust.reduce(0) { $0 + $1.z } / count

        var covarianceXX = 0.0
        var covarianceZZ = 0.0
        var covarianceXZ = 0.0
        for point in robust {
            let x = point.x - meanX
            let z = point.z - meanZ
            covarianceXX += x * x
            covarianceZZ += z * z
            covarianceXZ += x * z
        }
        covarianceXX /= count
        covarianceZZ /= count
        covarianceXZ /= count

        let trace = covarianceXX + covarianceZZ
        let discriminant = hypot(covarianceXX - covarianceZZ, 2 * covarianceXZ)
        let largestEigenvalue = (trace + discriminant) / 2
        let smallestEigenvalue = max(0, (trace - discriminant) / 2)
        guard largestEigenvalue > 1e-12 else {
            throw BoundingBoxEstimationError.degeneratePointCloud
        }

        let yaw = 0.5 * atan2(2 * covarianceXZ, covarianceXX - covarianceZZ)
        let stability = max(
            0,
            min(1, (largestEigenvalue - smallestEigenvalue) / largestEigenvalue)
        )
        return HorizontalPCA(yaw: yaw, horizontalStability: stability)
    }

    private func robustInliers(
        points: [SIMD3<Float>],
        projections: Projections
    ) -> [SIMD3<Float>] {
        let firstFence = percentileFence(projections.first)
        let secondFence = percentileFence(projections.second)
        let verticalFence = percentileFence(projections.vertical)

        return zip(points.indices, points).compactMap { index, point in
            guard firstFence.contains(projections.first[index]),
                  secondFence.contains(projections.second[index]),
                  verticalFence.contains(projections.vertical[index]) else {
                return nil
            }
            return point
        }
    }

    private func percentileFence(_ values: [Double]) -> ClosedRange<Double> {
        let lower = quantile(values, at: configuration.trimmingFraction)
        let upper = quantile(values, at: 1 - configuration.trimmingFraction)
        let centralSpan = max(0, upper - lower)
        let minimumMargin = configuration.voxelSizeMeters * 2
        let margin = max(minimumMargin, centralSpan * configuration.outlierFenceScale)
        return (lower - margin)...(upper + margin)
    }

    /// A connected floor skirt is coherent enough to survive ordinary outlier
    /// trimming. Detect it by comparing the lowest horizontal slice with the
    /// raised object body: a real box keeps roughly the same footprint, while
    /// leaked ground points expand only the base.
    private func hasGroundPlaneContamination(in projections: Projections) -> Bool {
        guard let minimumY = projections.vertical.min(),
              let maximumY = projections.vertical.max() else {
            return false
        }

        let height = maximumY - minimumY
        let baseThickness = min(0.04, max(0.015, height * 0.08))
        let bodyStart = minimumY + max(0.025, height * 0.25)

        var baseFirst: [Double] = []
        var baseSecond: [Double] = []
        var bodyFirst: [Double] = []
        var bodySecond: [Double] = []

        for index in projections.vertical.indices {
            let y = projections.vertical[index]
            if y <= minimumY + baseThickness {
                baseFirst.append(projections.first[index])
                baseSecond.append(projections.second[index])
            }
            if y >= bodyStart {
                bodyFirst.append(projections.first[index])
                bodySecond.append(projections.second[index])
            }
        }

        let minimumSliceSupport = max(8, configuration.minimumPointCount)
        guard baseFirst.count >= minimumSliceSupport,
              bodyFirst.count >= minimumSliceSupport else {
            return false
        }

        let baseLength = centralSpan(baseFirst)
        let baseWidth = centralSpan(baseSecond)
        let bodyLength = centralSpan(bodyFirst)
        let bodyWidth = centralSpan(bodySecond)
        guard bodyLength >= configuration.minimumDimensionMeters,
              bodyWidth >= configuration.minimumDimensionMeters else {
            return false
        }

        let baseArea = baseLength * baseWidth
        let bodyArea = bodyLength * bodyWidth
        return baseLength > bodyLength * 1.20
            || baseWidth > bodyWidth * 1.20
            || baseArea > bodyArea * 1.30
    }

    private func centralSpan(_ values: [Double]) -> Double {
        let lower = quantile(values, at: configuration.trimmingFraction)
        let upper = quantile(values, at: 1 - configuration.trimmingFraction)
        return max(0, upper - lower)
    }

    private func recoverGroundContaminatedObject(
        from points: [SIMD3<Float>],
        contaminatedProjections: Projections
    ) -> FittedPointCloud? {
        guard let minimumY = contaminatedProjections.vertical.min(),
              let maximumY = contaminatedProjections.vertical.max() else {
            return nil
        }

        let contaminatedHeight = maximumY - minimumY
        let bodyStart = minimumY + max(0.025, contaminatedHeight * 0.25)
        let raisedPoints = points.filter { Double($0.y) >= bodyStart }
        let components = connectedComponents(
            raisedPoints,
            maximumDistance: 0.12
        )
        let minimumComponentSupport = max(24, configuration.minimumPointCount * 3)
        let minimumVerticalSupport = max(0.04, contaminatedHeight * 0.20)
        let minimumHorizontalSupport = max(0.04, configuration.minimumDimensionMeters * 4)

        let candidates = components.compactMap { component -> FittedPointCloud? in
            guard component.count >= minimumComponentSupport,
                  let fit = try? fitPointCloud(component),
                  fit.height >= minimumVerticalSupport,
                  fit.width >= minimumHorizontalSupport else {
                return nil
            }
            return fit
        }

        // Picking between multiple box-like raised components would silently
        // measure an arbitrary object. Recovery is intentionally conservative.
        guard candidates.count == 1, let body = candidates.first,
              let firstMinimum = body.projections.first.min(),
              let firstMaximum = body.projections.first.max(),
              let secondMinimum = body.projections.second.min(),
              let secondMaximum = body.projections.second.max() else {
            return nil
        }

        let margin = max(
            configuration.voxelSizeMeters * 2,
            min(body.length, body.width) * 0.02
        )
        let projected = project(points, onto: body.axes)
        let recoveredPoints = points.indices.compactMap { index -> SIMD3<Float>? in
            guard projected.first[index] >= firstMinimum - margin,
                  projected.first[index] <= firstMaximum + margin,
                  projected.second[index] >= secondMinimum - margin,
                  projected.second[index] <= secondMaximum + margin else {
                return nil
            }
            return points[index]
        }

        guard recoveredPoints.count >= minimumComponentSupport,
              let recovered = try? fitPointCloud(recoveredPoints),
              !hasGroundPlaneContamination(in: recovered.projections) else {
            return nil
        }
        return recovered
    }

    private func fitPointCloud(_ points: [SIMD3<Float>]) throws -> FittedPointCloud {
        let pca = try horizontalPCA(of: points)
        let initialProjections = project(points, onto: HorizontalAxes(yaw: pca.yaw))
        let filteredPoints = robustInliers(points: points, projections: initialProjections)
        guard filteredPoints.count >= configuration.minimumPointCount else {
            throw BoundingBoxEstimationError.insufficientUniquePoints(
                actual: filteredPoints.count,
                minimum: configuration.minimumPointCount
            )
        }

        let refinedYaw = minimumAreaYaw(points: filteredPoints, around: pca.yaw)
        var axes = HorizontalAxes(yaw: refinedYaw)
        var projections = project(filteredPoints, onto: axes)
        var length = projections.firstSpan
        var width = projections.secondSpan
        if width > length {
            axes = HorizontalAxes(yaw: refinedYaw + .pi / 2)
            projections = project(filteredPoints, onto: axes)
            swap(&length, &width)
        }

        let height = projections.verticalSpan
        guard length >= configuration.minimumDimensionMeters,
              width >= configuration.minimumDimensionMeters,
              height >= configuration.minimumDimensionMeters else {
            throw BoundingBoxEstimationError.degeneratePointCloud
        }

        return FittedPointCloud(
            points: filteredPoints,
            pca: pca,
            axes: axes,
            projections: projections,
            length: length,
            width: width,
            height: height
        )
    }

    private func connectedComponents(
        _ points: [SIMD3<Float>],
        maximumDistance: Double
    ) -> [[SIMD3<Float>]] {
        guard !points.isEmpty else { return [] }

        var buckets: [VoxelKey: [Int]] = [:]
        buckets.reserveCapacity(points.count)
        var keys: [VoxelKey] = []
        keys.reserveCapacity(points.count)

        for (index, point) in points.enumerated() {
            let key = VoxelKey(
                x: Int64(floor(Double(point.x) / maximumDistance)),
                y: Int64(floor(Double(point.y) / maximumDistance)),
                z: Int64(floor(Double(point.z) / maximumDistance))
            )
            keys.append(key)
            buckets[key, default: []].append(index)
        }

        let maximumDistanceSquared = maximumDistance * maximumDistance
        var visited = Array(repeating: false, count: points.count)
        var components: [[SIMD3<Float>]] = []

        for seed in points.indices where !visited[seed] {
            visited[seed] = true
            var queue = [seed]
            var readIndex = 0
            var component: [SIMD3<Float>] = []

            while readIndex < queue.count {
                let currentIndex = queue[readIndex]
                readIndex += 1
                let current = points[currentIndex]
                component.append(current)
                let key = keys[currentIndex]

                for xOffset in -1...1 {
                    for yOffset in -1...1 {
                        for zOffset in -1...1 {
                            let neighborKey = VoxelKey(
                                x: key.x + Int64(xOffset),
                                y: key.y + Int64(yOffset),
                                z: key.z + Int64(zOffset)
                            )
                            for candidateIndex in buckets[neighborKey, default: []]
                            where !visited[candidateIndex] {
                                let candidate = points[candidateIndex]
                                let deltaX = Double(candidate.x - current.x)
                                let deltaY = Double(candidate.y - current.y)
                                let deltaZ = Double(candidate.z - current.z)
                                let distanceSquared = deltaX * deltaX
                                    + deltaY * deltaY
                                    + deltaZ * deltaZ
                                if distanceSquared <= maximumDistanceSquared {
                                    visited[candidateIndex] = true
                                    queue.append(candidateIndex)
                                }
                            }
                        }
                    }
                }
            }
            components.append(component)
        }
        return components
    }

    private func minimumAreaYaw(points: [SIMD3<Float>], around pcaYaw: Double) -> Double {
        let halfRange = Double.pi / 4
        let step = configuration.orientationSearchStepRadians
        var bestYaw = pcaYaw
        var bestArea = horizontalArea(points: points, yaw: pcaYaw)
        var yaw = pcaYaw - halfRange

        while yaw <= pcaYaw + halfRange + step / 2 {
            let area = horizontalArea(points: points, yaw: yaw)
            if area < bestArea {
                bestArea = area
                bestYaw = yaw
            }
            yaw += step
        }

        // Refine the best grid cell. Rectangle area has a cusp at the true
        // edge, so repeated left/center/right sampling is more stable here
        // than assuming a differentiable objective.
        var refinementStep = step
        for _ in 0..<10 {
            refinementStep /= 2
            let candidates = [bestYaw - refinementStep, bestYaw, bestYaw + refinementStep]
            for candidate in candidates {
                let area = horizontalArea(points: points, yaw: candidate)
                if area < bestArea {
                    bestArea = area
                    bestYaw = candidate
                }
            }
        }
        return bestYaw
    }

    private func horizontalArea(points: [SIMD3<Float>], yaw: Double) -> Double {
        let projections = project(points, onto: HorizontalAxes(yaw: yaw))
        return projections.firstSpan * projections.secondSpan
    }

    private func project(
        _ points: [SIMD3<Float>],
        onto axes: HorizontalAxes
    ) -> Projections {
        var first: [Double] = []
        var second: [Double] = []
        var vertical: [Double] = []
        first.reserveCapacity(points.count)
        second.reserveCapacity(points.count)
        vertical.reserveCapacity(points.count)

        for point in points {
            let horizontal = HorizontalPoint(x: Double(point.x), z: Double(point.z))
            first.append(axes.firstProjection(of: horizontal))
            second.append(axes.secondProjection(of: horizontal))
            vertical.append(Double(point.y))
        }
        return Projections(first: first, second: second, vertical: vertical)
    }

    private func confidence(
        pointCount: Int,
        inlierRatio: Double,
        horizontalStability: Double,
        dimensions: GeometryDimensions,
        maximumScore: Double = 1
    ) -> GeometryMeasurementConfidence {
        let sampleSupport = min(1, Double(pointCount) / 500)
        let dimensionSupport = min(
            1,
            min(
                dimensions.widthMeters / 0.05,
                dimensions.heightMeters / 0.05
            )
        )
        var score = 0.65 * sampleSupport
            + 0.20 * min(1, max(0, inlierRatio))
            + 0.15 * min(1, max(0, dimensionSupport))

        // A square footprint can still have good dimensions, but PCA cannot
        // assign a stable yaw. Keep that uncertainty visible to the caller.
        if horizontalStability < 0.10 {
            score = min(score, 0.69)
        }
        score = min(maximumScore, max(0, score))

        let level: GeometryConfidenceLevel
        switch score {
        case 0.80...: level = .high
        case 0.50...: level = .medium
        default: level = .low
        }

        return GeometryMeasurementConfidence(
            score: score,
            level: level,
            pointCount: pointCount,
            inlierRatio: inlierRatio,
            horizontalStability: horizontalStability
        )
    }

    private func voxelCentroids(
        _ points: [SIMD3<Float>],
        voxelSizeMeters: Double
    ) -> [SIMD3<Float>] {
        var voxels: [VoxelKey: VoxelAccumulator] = [:]
        voxels.reserveCapacity(points.count)

        for point in points {
            let key = VoxelKey(
                x: Int64(floor(Double(point.x) / voxelSizeMeters)),
                y: Int64(floor(Double(point.y) / voxelSizeMeters)),
                z: Int64(floor(Double(point.z) / voxelSizeMeters))
            )
            voxels[key, default: VoxelAccumulator()].add(point)
        }

        return voxels.keys.sorted().compactMap { key in
            voxels[key]?.centroid
        }
    }

    private func quantile(_ values: [Double], at ratio: Double) -> Double {
        let sorted = values.sorted()
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }

        let position = ratio * Double(sorted.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }

    private func normalizeHalfTurn(_ angle: Double) -> Double {
        var result = angle
        while result >= .pi / 2 { result -= .pi }
        while result < -.pi / 2 { result += .pi }
        return result
    }
}

private struct HorizontalPCA {
    let yaw: Double
    let horizontalStability: Double
}

private struct FittedPointCloud {
    let points: [SIMD3<Float>]
    let pca: HorizontalPCA
    let axes: HorizontalAxes
    let projections: Projections
    let length: Double
    let width: Double
    let height: Double
}

private struct HorizontalPoint {
    let x: Double
    let z: Double
}

private struct HorizontalAxes {
    let yaw: Double
    let cosine: Double
    let sine: Double

    init(yaw: Double) {
        self.yaw = yaw
        cosine = cos(yaw)
        sine = sin(yaw)
    }

    func firstProjection(of point: HorizontalPoint) -> Double {
        point.x * cosine + point.z * sine
    }

    func secondProjection(of point: HorizontalPoint) -> Double {
        -point.x * sine + point.z * cosine
    }

    func point(first: Double, second: Double) -> HorizontalPoint {
        HorizontalPoint(
            x: first * cosine - second * sine,
            z: first * sine + second * cosine
        )
    }
}

private struct Projections {
    let first: [Double]
    let second: [Double]
    let vertical: [Double]

    var firstSpan: Double { span(first) }
    var secondSpan: Double { span(second) }
    var verticalSpan: Double { span(vertical) }
    var firstMidpoint: Double { midpoint(first) }
    var secondMidpoint: Double { midpoint(second) }
    var verticalMidpoint: Double { midpoint(vertical) }

    private func span(_ values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return max(0, maximum - minimum)
    }

    private func midpoint(_ values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return (minimum + maximum) / 2
    }
}

private struct VoxelKey: Hashable, Comparable {
    let x: Int64
    let y: Int64
    let z: Int64

    static func < (lhs: VoxelKey, rhs: VoxelKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

private struct VoxelAccumulator {
    private(set) var x = 0.0
    private(set) var y = 0.0
    private(set) var z = 0.0
    private(set) var count = 0

    mutating func add(_ point: SIMD3<Float>) {
        x += Double(point.x)
        y += Double(point.y)
        z += Double(point.z)
        count += 1
    }

    var centroid: SIMD3<Float> {
        let divisor = Double(count)
        return SIMD3<Float>(Float(x / divisor), Float(y / divisor), Float(z / divisor))
    }
}

private extension SIMD3 where Scalar == Float {
    var allComponentsAreFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
