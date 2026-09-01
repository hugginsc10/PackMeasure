import Foundation
import simd

struct PhotoRigidItemMultiplicityEvidence: Equatable, Sendable {
    enum Basis: String, Equatable, Sendable {
        case standardBoundaryPair = "standard_boundary_pair"
        case strongBoundaryPair = "strong_boundary_pair"
        case strongSingleBoundary = "strong_single_boundary"
    }

    let splitHeightFraction: Float
    let maximumBoundaryShiftMeters: Float
    let normalizedBoundaryShift: Float
    let significantBoundaryCount: Int
    let basis: Basis
    let maximumQualifyingNoiseMeters: Float
    let lowerBodyHeightFraction: Float
    let upperBodyHeightFraction: Float
    let lowerBodyPointFraction: Float
    let upperBodyPointFraction: Float

    init(
        splitHeightFraction: Float,
        maximumBoundaryShiftMeters: Float,
        normalizedBoundaryShift: Float,
        significantBoundaryCount: Int,
        basis: Basis = .standardBoundaryPair,
        maximumQualifyingNoiseMeters: Float = 0,
        lowerBodyHeightFraction: Float = 0,
        upperBodyHeightFraction: Float = 0,
        lowerBodyPointFraction: Float = 0,
        upperBodyPointFraction: Float = 0
    ) {
        self.splitHeightFraction = splitHeightFraction
        self.maximumBoundaryShiftMeters = maximumBoundaryShiftMeters
        self.normalizedBoundaryShift = normalizedBoundaryShift
        self.significantBoundaryCount = significantBoundaryCount
        self.basis = basis
        self.maximumQualifyingNoiseMeters = maximumQualifyingNoiseMeters
        self.lowerBodyHeightFraction = lowerBodyHeightFraction
        self.upperBodyHeightFraction = upperBodyHeightFraction
        self.lowerBodyPointFraction = lowerBodyPointFraction
        self.upperBodyPointFraction = upperBodyPointFraction
    }
}

enum PhotoRigidItemMultiplicityAssessment: Equatable, Sendable {
    case insufficientEvidence
    case singleRigidItem
    case multipleRigidItems(PhotoRigidItemMultiplicityEvidence)

    var diagnosticLabel: String {
        switch self {
        case .insufficientEvidence:
            "insufficient_evidence"
        case .singleRigidItem:
            "single_rigid_item"
        case .multipleRigidItems:
            "multiple_rigid_items"
        }
    }
}

enum PhotoRigidItemMultiplicityIndeterminateReason: String, Equatable, Sendable {
    case invalidConfiguration = "invalid_configuration"
    case tooFewPoints = "too_few_points"
    case degenerateVerticalSpan = "degenerate_vertical_span"
    case footprintBelowMinimum = "footprint_below_minimum"
    case noComparableSplit = "no_comparable_split"
    case oneStrongBoundary = "one_strong_boundary"
    case incompleteProfileCoverage = "incomplete_profile_coverage"
}

struct PhotoRigidItemMultiplicityEvaluation: Equatable, Sendable {
    let assessment: PhotoRigidItemMultiplicityAssessment
    let finitePointCount: Int
    let minimumPointCount: Int
    let usableBinCount: Int
    let comparableSplitCount: Int
    let indeterminateReason: PhotoRigidItemMultiplicityIndeterminateReason?
    let eligibleSplitCount: Int
    let candidateEvidence: PhotoRigidItemMultiplicityEvidence?

    init(
        assessment: PhotoRigidItemMultiplicityAssessment,
        finitePointCount: Int,
        minimumPointCount: Int,
        usableBinCount: Int,
        comparableSplitCount: Int,
        indeterminateReason: PhotoRigidItemMultiplicityIndeterminateReason?,
        eligibleSplitCount: Int = 0,
        candidateEvidence: PhotoRigidItemMultiplicityEvidence? = nil
    ) {
        self.assessment = assessment
        self.finitePointCount = finitePointCount
        self.minimumPointCount = minimumPointCount
        self.usableBinCount = usableBinCount
        self.comparableSplitCount = comparableSplitCount
        self.indeterminateReason = indeterminateReason
        self.eligibleSplitCount = eligibleSplitCount
        self.candidateEvidence = candidateEvidence
    }

    var diagnosticRoute: String {
        if case .multipleRigidItems(let evidence) = assessment {
            return evidence.basis.rawValue
        }
        if let candidateEvidence {
            return candidateEvidence.basis.rawValue
        }
        if assessment == .singleRigidItem {
            return "complete_no_boundary"
        }
        if indeterminateReason == .incompleteProfileCoverage {
            return "incomplete_profile"
        }
        return "not_classified"
    }

    var comparableSplitFraction: Float {
        guard eligibleSplitCount > 0 else { return 0 }
        return Float(comparableSplitCount) / Float(eligibleSplitCount)
    }
}

/// Verifies a selected Box-mode point cloud across its interior
/// gravity-aligned profile. Two corroborating footprint-boundary changes are
/// strong evidence of multiple rigid bodies. One strong change or incomplete
/// profile coverage is uncertain and fails closed without claiming that the
/// selection definitely contains multiple boxes.
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
    var minimumStrongBodyHeightFraction: Float = 0.15
    var minimumStrongBodyPointFraction: Float = 0.15
    var minimumStrongBoundaryShiftMeters: Float = 0.08
    var minimumStrongRelativeBoundaryShift: Float = 0.18
    var strongNoiseMultiplier: Float = 3

    func assess(
        worldPoints: [SIMD3<Float>]
    ) -> PhotoRigidItemMultiplicityAssessment {
        evaluate(worldPoints: worldPoints).assessment
    }

    func evaluate(
        worldPoints: [SIMD3<Float>]
    ) -> PhotoRigidItemMultiplicityEvaluation {
        let finitePoints = worldPoints.filter(Self.isFinite)
        guard configurationIsValid else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: 0,
                comparableSplitCount: 0,
                indeterminateReason: .invalidConfiguration
            )
        }

        guard finitePoints.count >= minimumPointCount else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: 0,
                comparableSplitCount: 0,
                indeterminateReason: .tooFewPoints
            )
        }

        let verticalCoordinates = finitePoints.map(\.y).sorted()
        guard let lowerY = quantile(0.02, in: verticalCoordinates),
              let upperY = quantile(0.98, in: verticalCoordinates) else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: 0,
                comparableSplitCount: 0,
                indeterminateReason: .degenerateVerticalSpan
            )
        }
        let verticalSpan = upperY - lowerY
        guard verticalSpan > .ulpOfOne else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: 0,
                comparableSplitCount: 0,
                indeterminateReason: .degenerateVerticalSpan
            )
        }

        let horizontalX = finitePoints.map(\.x).sorted()
        let horizontalZ = finitePoints.map(\.z).sorted()
        guard let lowerX = quantile(footprintQuantile, in: horizontalX),
              let upperX = quantile(1 - footprintQuantile, in: horizontalX),
              let lowerZ = quantile(footprintQuantile, in: horizontalZ),
              let upperZ = quantile(1 - footprintQuantile, in: horizontalZ) else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: 0,
                comparableSplitCount: 0,
                indeterminateReason: .footprintBelowMinimum
            )
        }
        let footprintScale = max(upperX - lowerX, upperZ - lowerZ)
        guard footprintScale >= minimumHorizontalSpanMeters else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: 0,
                comparableSplitCount: 0,
                indeterminateReason: .footprintBelowMinimum
            )
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
        let usableBinCount = signatures.reduce(into: 0) { count, signature in
            if signature != nil { count += 1 }
        }
        let minimumEligibleBodyHeightFraction = min(
            minimumBodyHeightFraction,
            minimumStrongBodyHeightFraction
        )
        let minimumSplitBin = max(
            comparisonBinCount,
            Int(ceil(minimumEligibleBodyHeightFraction * Float(verticalBinCount)))
        )
        let maximumSplitBin = min(
            verticalBinCount - comparisonBinCount - 1,
            Int(floor((1 - minimumEligibleBodyHeightFraction) * Float(verticalBinCount))) - 1
        )
        guard minimumSplitBin <= maximumSplitBin else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: usableBinCount,
                comparableSplitCount: 0,
                indeterminateReason: .noComparableSplit
            )
        }

        let boundaryThreshold = max(
            minimumBoundaryShiftMeters,
            footprintScale * minimumRelativeBoundaryShift
        )
        var eligibleSplitCount = 0
        var bestCorroboratedEvidence: PhotoRigidItemMultiplicityEvidence?
        var bestOneBoundaryEvidence: PhotoRigidItemMultiplicityEvidence?
        var comparableSplitCount = 0

        for splitBin in minimumSplitBin...maximumSplitBin {
            let splitFraction = (Float(splitBin) + 0.5) / Float(verticalBinCount)
            let splitY = lowerY + splitFraction * verticalSpan
            let lowerPointCount = finitePoints.reduce(into: 0) { count, point in
                if point.y < splitY { count += 1 }
            }
            let lowerPointFraction = Float(lowerPointCount) / Float(finitePoints.count)
            let upperPointFraction = 1 - lowerPointFraction
            let lowerHeightFraction = splitFraction
            let upperHeightFraction = 1 - splitFraction
            let isStandardBodySplit = lowerHeightFraction >= minimumBodyHeightFraction
                && upperHeightFraction >= minimumBodyHeightFraction
                && lowerPointFraction >= minimumBodyPointFraction
                && upperPointFraction >= minimumBodyPointFraction
            let isStrongBodySplit = lowerHeightFraction >= minimumStrongBodyHeightFraction
                && upperHeightFraction >= minimumStrongBodyHeightFraction
                && lowerPointFraction >= minimumStrongBodyPointFraction
                && upperPointFraction >= minimumStrongBodyPointFraction
            guard isStandardBodySplit || isStrongBodySplit else {
                continue
            }
            // A split is eligible only when both candidate bodies meet the
            // configured height and observed-point support floors. Perspective
            // can make an outer geometric split ineligible even with dense,
            // complete coverage; it must not count as a missing profile band.
            eligibleSplitCount += 1

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

            comparableSplitCount += 1

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
            let significantBoundaryIndices = shifts.indices.filter { index in
                let localNoise = max(lowerNoise[index], upperNoise[index])
                return shifts[index] >= boundaryThreshold
                    && shifts[index] >= localNoise * noiseMultiplier
            }

            if isStandardBodySplit,
               significantBoundaryIndices.count >= minimumSignificantBoundaryCount,
               let evidence = multiplicityEvidence(
                    splitFraction: splitFraction,
                    qualifyingIndices: significantBoundaryIndices,
                    shifts: shifts,
                    lowerNoise: lowerNoise,
                    upperNoise: upperNoise,
                    footprintScale: footprintScale,
                    basis: .standardBoundaryPair,
                    lowerHeightFraction: lowerHeightFraction,
                    upperHeightFraction: upperHeightFraction,
                    lowerPointFraction: lowerPointFraction,
                    upperPointFraction: upperPointFraction
                )
            {
                if isStronger(evidence, than: bestCorroboratedEvidence) {
                    bestCorroboratedEvidence = evidence
                }
            }

            let strongBoundaryThreshold = max(
                minimumStrongBoundaryShiftMeters,
                footprintScale * minimumStrongRelativeBoundaryShift
            )
            let strongBoundaryIndices = shifts.indices.filter { index in
                let localNoise = max(lowerNoise[index], upperNoise[index])
                return shifts[index] >= strongBoundaryThreshold
                    && shifts[index] >= localNoise * strongNoiseMultiplier
            }
            if isStrongBodySplit,
               !strongBoundaryIndices.isEmpty,
               let evidence = multiplicityEvidence(
                    splitFraction: splitFraction,
                    qualifyingIndices: strongBoundaryIndices,
                    shifts: shifts,
                    lowerNoise: lowerNoise,
                    upperNoise: upperNoise,
                    footprintScale: footprintScale,
                    basis: strongBoundaryIndices.count >= minimumSignificantBoundaryCount
                        ? .strongBoundaryPair
                        : .strongSingleBoundary,
                    lowerHeightFraction: lowerHeightFraction,
                    upperHeightFraction: upperHeightFraction,
                    lowerPointFraction: lowerPointFraction,
                    upperPointFraction: upperPointFraction
               )
            {
                if strongBoundaryIndices.count >= minimumSignificantBoundaryCount {
                    if isStronger(evidence, than: bestCorroboratedEvidence) {
                        bestCorroboratedEvidence = evidence
                    }
                } else if isStronger(evidence, than: bestOneBoundaryEvidence) {
                    bestOneBoundaryEvidence = evidence
                }
            }
        }

        if let bestCorroboratedEvidence {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .multipleRigidItems(bestCorroboratedEvidence),
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: usableBinCount,
                comparableSplitCount: comparableSplitCount,
                indeterminateReason: nil,
                eligibleSplitCount: eligibleSplitCount
            )
        }
        if let bestOneBoundaryEvidence {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: usableBinCount,
                comparableSplitCount: comparableSplitCount,
                indeterminateReason: .oneStrongBoundary,
                eligibleSplitCount: eligibleSplitCount,
                candidateEvidence: bestOneBoundaryEvidence
            )
        }
        guard comparableSplitCount > 0 else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: usableBinCount,
                comparableSplitCount: 0,
                indeterminateReason: .noComparableSplit,
                eligibleSplitCount: eligibleSplitCount
            )
        }
        guard comparableSplitCount == eligibleSplitCount else {
            return PhotoRigidItemMultiplicityEvaluation(
                assessment: .insufficientEvidence,
                finitePointCount: finitePoints.count,
                minimumPointCount: minimumPointCount,
                usableBinCount: usableBinCount,
                comparableSplitCount: comparableSplitCount,
                indeterminateReason: .incompleteProfileCoverage,
                eligibleSplitCount: eligibleSplitCount
            )
        }
        return PhotoRigidItemMultiplicityEvaluation(
            assessment: .singleRigidItem,
            finitePointCount: finitePoints.count,
            minimumPointCount: minimumPointCount,
            usableBinCount: usableBinCount,
            comparableSplitCount: comparableSplitCount,
            indeterminateReason: nil,
            eligibleSplitCount: eligibleSplitCount
        )
    }

    private func multiplicityEvidence(
        splitFraction: Float,
        qualifyingIndices: [Int],
        shifts: [Float],
        lowerNoise: [Float],
        upperNoise: [Float],
        footprintScale: Float,
        basis: PhotoRigidItemMultiplicityEvidence.Basis,
        lowerHeightFraction: Float,
        upperHeightFraction: Float,
        lowerPointFraction: Float,
        upperPointFraction: Float
    ) -> PhotoRigidItemMultiplicityEvidence? {
        guard let maximumShift = qualifyingIndices.map({ shifts[$0] }).max(),
              let maximumNoise = qualifyingIndices.map({
                  max(lowerNoise[$0], upperNoise[$0])
              }).max() else {
            return nil
        }
        return PhotoRigidItemMultiplicityEvidence(
            splitHeightFraction: splitFraction,
            maximumBoundaryShiftMeters: maximumShift,
            normalizedBoundaryShift: maximumShift / footprintScale,
            significantBoundaryCount: qualifyingIndices.count,
            basis: basis,
            maximumQualifyingNoiseMeters: maximumNoise,
            lowerBodyHeightFraction: lowerHeightFraction,
            upperBodyHeightFraction: upperHeightFraction,
            lowerBodyPointFraction: lowerPointFraction,
            upperBodyPointFraction: upperPointFraction
        )
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
            && minimumStrongBodyHeightFraction > 0
            && minimumStrongBodyHeightFraction < 0.5
            && minimumStrongBodyPointFraction > 0
            && minimumStrongBodyPointFraction < 0.5
            && minimumStrongBoundaryShiftMeters > minimumBoundaryShiftMeters
            && minimumStrongRelativeBoundaryShift > minimumRelativeBoundaryShift
            && strongNoiseMultiplier >= noiseMultiplier
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
