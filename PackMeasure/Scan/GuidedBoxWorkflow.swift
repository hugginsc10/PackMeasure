import Foundation

enum GuidedBoxWorkflowStep: Int, CaseIterable, Equatable, Sendable {
    case referenceCorner
    case lengthEndpoint
    case widthEndpoint
    case heightEndpoint
    case review
    case complete

    var point: GuidedBoxPoint? {
        switch self {
        case .referenceCorner: .referenceCorner
        case .lengthEndpoint: .lengthEndpoint
        case .widthEndpoint: .widthEndpoint
        case .heightEndpoint: .heightEndpoint
        case .review, .complete: nil
        }
    }
}

enum GuidedBoxWorkflowUpdate: Equatable, Sendable {
    case advanced(to: GuidedBoxWorkflowStep)
    case ready(GuidedBoxMeasurement)
    case needsReplacement(point: GuidedBoxPoint, error: GuidedBoxMeasurementError)
    case failed(GuidedBoxMeasurementError)
    case ignored
}

/// Pure state machine for the four-reticle guided box flow. The coordinator
/// supplies world points; this type owns ordering, validation recovery, and
/// conversion into the scanner's existing save model.
struct GuidedBoxWorkflow: Sendable {
    private let measurementEstimator: GuidedBoxMeasurementEstimator

    private var referenceCorner: SIMD3<Float>?
    private var lengthEndpoint: SIMD3<Float>?
    private var widthEndpoint: SIMD3<Float>?
    private var heightEndpoint: SIMD3<Float>?
    private var gravity = SIMD3<Float>(0, -1, 0)
    private var validationError: GuidedBoxMeasurementError?

    private(set) var step: GuidedBoxWorkflowStep = .referenceCorner
    private(set) var pointToReplace: GuidedBoxPoint?
    private(set) var measurement: GuidedBoxMeasurement?
    private(set) var estimate: MeasurementEstimate?

    init(measurementEstimator: GuidedBoxMeasurementEstimator = .init()) {
        self.measurementEstimator = measurementEstimator
    }

    var prompt: String {
        if let validationError {
            return validationError.localizedDescription
        }

        switch step {
        case .referenceCorner:
            return "Tap one visible box corner."
        case .lengthEndpoint:
            return "Tap the end of the length edge from that corner."
        case .widthEndpoint:
            return "Tap the end of the width edge from that corner."
        case .heightEndpoint:
            return "Tap the end of the height edge from that corner."
        case .review:
            return "Review the dimensions, then confirm."
        case .complete:
            return "Box measurement complete."
        }
    }

    @discardableResult
    mutating func record(
        point: SIMD3<Float>,
        gravity: SIMD3<Float>
    ) -> GuidedBoxWorkflowUpdate {
        guard let capturePoint = step.point else {
            return .ignored
        }

        self.gravity = gravity
        set(point, for: capturePoint)
        validationError = nil
        pointToReplace = nil
        measurement = nil
        estimate = nil

        guard let capture = completeCapture else {
            step = firstMissingStep
            return .advanced(to: step)
        }

        do {
            let result = try measurementEstimator.estimate(capture)
            measurement = result
            step = .review
            return .ready(result)
        } catch let error as GuidedBoxMeasurementError {
            return handleValidation(error)
        } catch {
            return handleValidation(.invalidConfiguration)
        }
    }

    /// Finalizes review using medium confidence: the dimensions are validated
    /// user taps, but not a dense automatic point cloud.
    @discardableResult
    mutating func confirm() -> MeasurementEstimate? {
        if step == .complete {
            return estimate
        }
        guard step == .review, let measurement else {
            return nil
        }

        let dimensions = measurement.dimensions
        let result = MeasurementEstimate(
            lengthMeters: dimensions.lengthMeters,
            widthMeters: dimensions.widthMeters,
            heightMeters: dimensions.heightMeters,
            confidence: .medium,
            sampleCount: GuidedBoxWorkflowStep.heightEndpoint.rawValue + 1,
            frameCount: GuidedBoxWorkflowStep.heightEndpoint.rawValue + 1
        )
        estimate = result
        step = .complete
        validationError = nil
        pointToReplace = nil
        return result
    }

    mutating func back() {
        validationError = nil
        pointToReplace = nil
        estimate = nil

        switch step {
        case .referenceCorner:
            break
        case .lengthEndpoint:
            step = .referenceCorner
        case .widthEndpoint:
            step = .lengthEndpoint
        case .heightEndpoint:
            step = .widthEndpoint
        case .review:
            measurement = nil
            step = .heightEndpoint
        case .complete:
            step = .review
        }
    }

    mutating func reset() {
        referenceCorner = nil
        lengthEndpoint = nil
        widthEndpoint = nil
        heightEndpoint = nil
        gravity = SIMD3<Float>(0, -1, 0)
        validationError = nil
        pointToReplace = nil
        measurement = nil
        estimate = nil
        step = .referenceCorner
    }

    private var completeCapture: GuidedBoxCapture? {
        guard let referenceCorner,
              let lengthEndpoint,
              let widthEndpoint,
              let heightEndpoint else {
            return nil
        }
        return GuidedBoxCapture(
            referenceCorner: referenceCorner,
            lengthEndpoint: lengthEndpoint,
            widthEndpoint: widthEndpoint,
            heightEndpoint: heightEndpoint,
            gravity: gravity
        )
    }

    private var firstMissingStep: GuidedBoxWorkflowStep {
        if referenceCorner == nil { return .referenceCorner }
        if lengthEndpoint == nil { return .lengthEndpoint }
        if widthEndpoint == nil { return .widthEndpoint }
        return .heightEndpoint
    }

    private mutating func set(_ point: SIMD3<Float>, for capturePoint: GuidedBoxPoint) {
        switch capturePoint {
        case .referenceCorner:
            referenceCorner = point
        case .lengthEndpoint:
            lengthEndpoint = point
        case .widthEndpoint:
            widthEndpoint = point
        case .heightEndpoint:
            heightEndpoint = point
        }
    }

    private mutating func handleValidation(
        _ error: GuidedBoxMeasurementError
    ) -> GuidedBoxWorkflowUpdate {
        measurement = nil
        estimate = nil
        validationError = error

        guard let replacement = replacementPoint(for: error) else {
            pointToReplace = nil
            return .failed(error)
        }
        pointToReplace = replacement
        step = workflowStep(for: replacement)
        return .needsReplacement(point: replacement, error: error)
    }

    private func replacementPoint(
        for error: GuidedBoxMeasurementError
    ) -> GuidedBoxPoint? {
        switch error {
        case .invalidConfiguration:
            nil
        case .invalidGravity:
            .heightEndpoint
        case let .nonFinitePoint(point):
            point
        case let .edgeTooShort(edge, _, _),
             let .edgeNotHorizontal(edge, _, _):
            capturePoint(for: edge)
        case .heightNotGravityAligned:
            .heightEndpoint
        case let .edgesNotPerpendicular(_, second, _, _):
            capturePoint(for: second)
        }
    }

    private func capturePoint(for edge: GuidedBoxEdge) -> GuidedBoxPoint {
        switch edge {
        case .length: .lengthEndpoint
        case .width: .widthEndpoint
        case .height: .heightEndpoint
        }
    }

    private func workflowStep(for point: GuidedBoxPoint) -> GuidedBoxWorkflowStep {
        switch point {
        case .referenceCorner: .referenceCorner
        case .lengthEndpoint: .lengthEndpoint
        case .widthEndpoint: .widthEndpoint
        case .heightEndpoint: .heightEndpoint
        }
    }
}
