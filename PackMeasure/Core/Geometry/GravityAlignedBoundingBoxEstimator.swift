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

        let pca = try horizontalPCA(of: uniquePoints)
        let initialAxes = HorizontalAxes(yaw: pca.yaw)
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

        let refinedYaw = minimumAreaYaw(points: inlierPoints, around: pca.yaw)
        var axes = HorizontalAxes(yaw: refinedYaw)
        var projections = project(inlierPoints, onto: axes)
        var extentAlongLengthAxis = projections.firstSpan
        var extentAlongWidthAxis = projections.secondSpan

        if extentAlongWidthAxis > extentAlongLengthAxis {
            axes = HorizontalAxes(yaw: refinedYaw + .pi / 2)
            projections = project(inlierPoints, onto: axes)
            swap(&extentAlongLengthAxis, &extentAlongWidthAxis)
        }

        let height = projections.verticalSpan
        guard extentAlongLengthAxis >= configuration.minimumDimensionMeters,
              extentAlongWidthAxis >= configuration.minimumDimensionMeters,
              height >= configuration.minimumDimensionMeters else {
            throw BoundingBoxEstimationError.degeneratePointCloud
        }
        guard !hasGroundPlaneContamination(in: projections) else {
            throw BoundingBoxEstimationError.groundPlaneContamination
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
        let inlierRatio = Double(inlierPoints.count) / Double(uniquePoints.count)
        let confidence = confidence(
            pointCount: inlierPoints.count,
            inlierRatio: inlierRatio,
            horizontalStability: pca.horizontalStability,
            dimensions: dimensions
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
                inlierPointCount: inlierPoints.count,
                filteredNonFinitePointCount: points.count - finitePoints.count,
                deduplicatedPointCount: finitePoints.count - uniquePoints.count,
                rejectedOutlierCount: uniquePoints.count - inlierPoints.count
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
        dimensions: GeometryDimensions
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
        score = min(1, max(0, score))

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
