import Foundation

enum SingleShotObjectMeasurement {
    static func outcome(
        labelMask: PhotoInstanceLabelMask,
        depthGrid: DepthGrid,
        calibration: PhotoCameraCalibration,
        policy: PhotoObjectMeasurementPolicy = .init()
    ) -> MeasurementEstimationOutcome {
        do {
            let pointCloud = try PhotoObjectMeasurement(policy: policy).makePointCloud(
                labelMask: labelMask,
                depthGrid: depthGrid,
                calibration: calibration
            )
            return MeasurementEstimator.outcome(
                from: pointCloud.worldPoints,
                frameCount: 1
            )
        } catch let error as PhotoObjectMeasurementError {
            return .failure(failure(for: error))
        } catch {
            return .failure(.geometry(.degeneratePointCloud))
        }
    }

    static func failure(for error: PhotoObjectMeasurementError) -> MeasurementEstimationFailure {
        switch error {
        case .invalidLabelMaskDimensions,
             .invalidDepthMaskDimensions,
             .invalidPolicy,
             .unsupportedLabelMaskPixelFormat,
             .invalidLabelMaskPixelValue,
             .maskCalibrationAspectRatioMismatch,
             .depthGridResolutionMismatch,
             .invalidCameraCalibration,
             .invalidWorldPoint:
            return .geometry(.degeneratePointCloud)

        case .noForegroundInstance,
             .ambiguousForegroundInstances,
             .maskAreaTooSmall,
             .maskAreaTooLarge,
             .maskTouchesImageEdge,
             .insufficientDepthSamples,
             .insufficientDepthCoverage,
             .insufficientHorizontalDepthSupport,
             .insufficientVerticalDepthSupport:
            return .targetRejected(.insufficientSurfaceEvidence)
        }
    }
}
