import Foundation
import simd

struct PhotoRigidItemMultiplicityEvidence: Equatable, Sendable {
    let splitHeightFraction: Float
    let maximumBoundaryShiftMeters: Float
    let normalizedBoundaryShift: Float
    let significantBoundaryCount: Int
}

enum PhotoRigidItemMultiplicityAssessment: Equatable, Sendable {
    case insufficientEvidence
    case singleRigidItem
    case multipleRigidItems(PhotoRigidItemMultiplicityEvidence)
}

/// Rejects a selected Box-mode point cloud only when its horizontal footprint
/// changes abruptly across an interior gravity-aligned plane. A persistent
/// change in at least two robust footprint boundaries is strong evidence that
/// the selection spans two stacked rigid bodies; a texture seam, one noisy
/// edge, or a small protrusion is not.
///
/// Set `PhotoObjectMeasurement.rigidItemMultiplicityGuard` to `nil` for a
/// general-item scan whose shape is not expected to be one rigid body.
struct PhotoRigidItemMultiplicityGuard: Sendable {
    private struct FootprintSignature {
        let boundaries: [Float]
    }

    var verticalBinCount = 20
    var minimumPointCount = 160
    var minimumPointsPerBin = 16
    var comparisonBinCount = 3
    var minimumBodyHeightFraction: Float = 0.24
    var minimumBodyPointFraction: Float = 0.22
    var footprintQuantile: Float = 0.10
    var minimumHorizontalSpanMeters: Float = 0.12
    var minimumBoundaryShiftMeters: Float = 0.035
    var minimumRelativeBoundaryShift: Float = 0.09
    var minimumSignificantBoundaryCount = 2
    var noiseMultiplier: Float = 2.5

    func assess(
        worldPoints: [SIMD3<Float>]
    ) -> PhotoRigidItemMultiplicityAssessment {
        guard configurationIsValid else { return .insufficientEvidence }

        let finitePoints = worldPoints.filter(Self.isFinite)
        guard finitePoints.count >= minimumPointCount else {
            return .insufficientEvidence
        }

        let verticalCoordinates = finitePoints.map(\.y).sorted()
        guard let lowerY = quantile(0.02, in: verticalCoordinates),
              let upperY = quantile(0.98, in: verticalCoordinates) else {
            return .insufficientEvidence
        }
        let verticalSpan = upperY - lowerY
        guard verticalSpan > .ulpOfOne else { return .insufficientEvidence }

        let horizontalX = finitePoints.map(\.x).sorted()
        let horizontalZ = finitePoints.map(\.z).sorted()
        guard let lowerX = quantile(footprintQuantile, in: horizontalX),
              let upperX = quantile(1 - footprintQuantile, in: horizontalX),
              let lowerZ = quantile(footprintQuantile, in: horizontalZ),
              let upperZ = quantile(1 - footprintQuantile, in: horizontalZ) else {
            return .insufficientEvidence
        }
        let footprintScale = max(upperX - lowerX, upperZ - lowerZ)
        guard footprintScale >= minimumHorizontalSpanMeters else {
            return .insufficientEvidence
        }

        var bins = Array(repeating: [SIMD2<Float>](), count: verticalBinCount)
        for point in finitePoints where point.y >= lowerY && point.y <= upperY {
            let fraction = (point.y - lowerY) / verticalSpan
            let bin = min(
                verticalBinCount - 1,
                max(0, Int(fraction * Float(verticalBinCount)))
            )
            bins[bin].append(SIMD2<Float>(point.x, point.z))
        }

        let signatures = bins.map(signature(for:))
        let minimumSplitBin = max(
            comparisonBinCount,
            Int(ceil(minimumBodyHeightFraction * Float(verticalBinCount)))
        )
        let maximumSplitBin = min(
            verticalBinCount - comparisonBinCount - 1,
            Int(floor((1 - minimumBodyHeightFraction) * Float(verticalBinCount))) - 1
        )
        guard minimumSplitBin <= maximumSplitBin else {
            return .insufficientEvidence
        }

        let boundaryThreshold = max(
            minimumBoundaryShiftMeters,
            footprintScale * minimumRelativeBoundaryShift
        )
        var bestEvidence: PhotoRigidItemMultiplicityEvidence?

        for splitBin in minimumSplitBin...maximumSplitBin {
            // One transition bin is intentionally excluded. A real stacking
            // plane can straddle a coarse LiDAR row, while the stable slices
            // immediately beyond it still describe the two rigid bodies.
            let lowerRange = (splitBin - comparisonBinCount)...(splitBin - 1)
            let upperRange = (splitBin + 1)...(splitBin + comparisonBinCount)
            let lowerSignatures = lowerRange.compactMap { signatures[$0] }
            let upperSignatures = upperRange.compactMap { signatures[$0] }
            guard lowerSignatures.count == comparisonBinCount,
                  upperSignatures.count == comparisonBinCount,
                  let lowerMedian = medianSignature(lowerSignatures),
                  let upperMedian = medianSignature(upperSignatures) else {
                continue
            }

            let splitFraction = (Float(splitBin) + 0.5) / Float(verticalBinCount)
            let splitY = lowerY + splitFraction * verticalSpan
            let lowerPointCount = finitePoints.reduce(into: 0) { count, point in
                if point.y < splitY { count += 1 }
            }
            let lowerPointFraction = Float(lowerPointCount) / Float(finitePoints.count)
            let upperPointFraction = 1 - lowerPointFraction
            guard lowerPointFraction >= minimumBodyPointFraction,
                  upperPointFraction >= minimumBodyPointFraction else {
                continue
            }

            let lowerNoise = maximumDeviations(
                of: lowerSignatures,
                from: lowerMedian
            )
            let upperNoise = maximumDeviations(
                of: upperSignatures,
                from: upperMedian
            )
            let shifts = zip(
                lowerMedian.boundaries,
                upperMedian.boundaries
            ).map { abs($0 - $1) }
            let significantBoundaryCount = shifts.indices.reduce(into: 0) { count, index in
                let localNoise = max(lowerNoise[index], upperNoise[index])
                if shifts[index] >= boundaryThreshold,
                   shifts[index] >= localNoise * noiseMultiplier {
                    count += 1
                }
            }
            guard significantBoundaryCount >= minimumSignificantBoundaryCount,
                  let maximumShift = shifts.max() else {
                continue
            }

            let evidence = PhotoRigidItemMultiplicityEvidence(
                splitHeightFraction: splitFraction,
                maximumBoundaryShiftMeters: maximumShift,
                normalizedBoundaryShift: maximumShift / footprintScale,
                significantBoundaryCount: significantBoundaryCount
            )
            if isStronger(evidence, than: bestEvidence) {
                bestEvidence = evidence
            }
        }

        if let bestEvidence {
            return .multipleRigidItems(bestEvidence)
        }
        let usableBinCount = signatures.reduce(into: 0) { count, signature in
            if signature != nil { count += 1 }
        }
        guard usableBinCount >= comparisonBinCount * 2 else {
            return .insufficientEvidence
        }
        return .singleRigidItem
    }

    private var configurationIsValid: Bool {
        verticalBinCount >= comparisonBinCount * 2 + 2
            && minimumPointCount > 0
            && minimumPointsPerBin > 0
            && comparisonBinCount > 0
            && minimumBodyHeightFraction > 0
            && minimumBodyHeightFraction < 0.5
            && minimumBodyPointFraction > 0
            && minimumBodyPointFraction < 0.5
            && footprintQuantile > 0
            && footprintQuantile < 0.5
            && minimumHorizontalSpanMeters > 0
            && minimumBoundaryShiftMeters > 0
            && minimumRelativeBoundaryShift > 0
            && minimumSignificantBoundaryCount >= 2
            && noiseMultiplier > 0
    }

    private func signature(for points: [SIMD2<Float>]) -> FootprintSignature? {
        guard points.count >= minimumPointsPerBin else { return nil }
        let xs = points.map(\.x).sorted()
        let zs = points.map(\.y).sorted()
        guard let xLower = quantile(footprintQuantile, in: xs),
              let xUpper = quantile(1 - footprintQuantile, in: xs),
              let zLower = quantile(footprintQuantile, in: zs),
              let zUpper = quantile(1 - footprintQuantile, in: zs) else {
            return nil
        }
        return FootprintSignature(
            boundaries: [xLower, xUpper, zLower, zUpper]
        )
    }

    private func medianSignature(
        _ signatures: [FootprintSignature]
    ) -> FootprintSignature? {
        guard let boundaryCount = signatures.first?.boundaries.count,
              boundaryCount > 0,
              signatures.allSatisfy({ $0.boundaries.count == boundaryCount }) else {
            return nil
        }
        var medians: [Float] = []
        medians.reserveCapacity(boundaryCount)
        for index in 0..<boundaryCount {
            let values = signatures.map { $0.boundaries[index] }.sorted()
            guard let median = quantile(0.5, in: values) else { return nil }
            medians.append(median)
        }
        return FootprintSignature(boundaries: medians)
    }

    private func maximumDeviations(
        of signatures: [FootprintSignature],
        from median: FootprintSignature
    ) -> [Float] {
        median.boundaries.indices.map { index in
            signatures.reduce(Float.zero) { maximum, signature in
                max(maximum, abs(signature.boundaries[index] - median.boundaries[index]))
            }
        }
    }

    private func quantile(_ fraction: Float, in sortedValues: [Float]) -> Float? {
        guard !sortedValues.isEmpty,
              fraction.isFinite,
              fraction >= 0,
              fraction <= 1 else {
            return nil
        }
        let position = fraction * Float(sortedValues.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }
        let weight = position - Float(lowerIndex)
        return sortedValues[lowerIndex] * (1 - weight)
            + sortedValues[upperIndex] * weight
    }

    private func isStronger(
        _ candidate: PhotoRigidItemMultiplicityEvidence,
        than current: PhotoRigidItemMultiplicityEvidence?
    ) -> Bool {
        guard let current else { return true }
        if candidate.significantBoundaryCount != current.significantBoundaryCount {
            return candidate.significantBoundaryCount > current.significantBoundaryCount
        }
        return candidate.normalizedBoundaryShift > current.normalizedBoundaryShift
    }

    private static func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}
