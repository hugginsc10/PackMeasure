import Foundation

enum ScannerPhotoRetryCategory: Equatable, Sendable {
    case framing
    case isolation
    case depth
    case processing
}

enum SingleShotFailureDisposition: Equatable, Sendable {
    case targetRejected
    case unavailable
}

enum SingleShotCapturePath: String, Equatable, Sendable {
    case visionMask = "vision_mask"
    case reticleDepthFallback = "reticle_depth_fallback"
}

enum SingleShotFallbackResult: Equatable, Sendable {
    case notAttempted
    case accepted
    case targetRejected(CenteredTargetRejection)
    case unavailable

    var diagnosticDescription: String {
        switch self {
        case .notAttempted:
            "not_attempted"
        case .accepted:
            "accepted"
        case .targetRejected(.floorSurface):
            "target_rejected,reason=floor_surface"
        case .targetRejected(.insufficientSurfaceEvidence):
            "target_rejected,reason=insufficient_surface_evidence"
        case .unavailable:
            "unavailable"
        }
    }
}

enum ForegroundMaskStage: String, Equatable, Sendable {
    case lowResolutionDecode = "low_resolution_decode"
    case instanceSelection = "instance_selection"
    case scaledMaskDecode = "scaled_mask_decode"
}

enum ForegroundMaskAdapterError: Error, Equatable, Sendable {
    case requestFailed(domain: String, code: Int)
    case noObservation
    case observationBridgeFailed
    case scaledMaskFailed(domain: String, code: Int)
    case maskProcessingFailed(stage: String, domain: String, code: Int)
    case photo(stage: ForegroundMaskStage, error: PhotoObjectMeasurementError)
}

enum SingleShotCaptureFailure: Error, Equatable, Sendable {
    case sceneDepthUnavailable
    case depthGridUnreadable
    case foreground(ForegroundMaskAdapterError)
    case photo(PhotoObjectMeasurementError)
    case unexpectedProcessingFailure(domain: String, code: Int)

    var shouldAttemptReticleDepthFallback: Bool {
        switch self {
        case .foreground(
            .photo(stage: .instanceSelection, error: .noForegroundInstance)
        ),
             .photo(.noForegroundInstance):
            true
        default:
            false
        }
    }

    var retryCategory: ScannerPhotoRetryCategory {
        switch self {
        case .sceneDepthUnavailable:
            .depth
        case .depthGridUnreadable, .unexpectedProcessingFailure:
            .processing
        case .foreground(let error):
            error.retryCategory
        case .photo(let error):
            error.retryCategory
        }
    }

    var disposition: SingleShotFailureDisposition {
        switch self {
        case .sceneDepthUnavailable,
             .depthGridUnreadable,
             .unexpectedProcessingFailure:
            .unavailable
        case .foreground(let error):
            error.disposition
        case .photo(let error):
            error.retryCategory == .processing ? .unavailable : .targetRejected
        }
    }

    var diagnosticCode: String {
        switch self {
        case .sceneDepthUnavailable:
            "C01"
        case .depthGridUnreadable:
            "C02"
        case .foreground(let error):
            error.diagnosticCode
        case .photo(let error):
            error.diagnosticCode
        case .unexpectedProcessingFailure:
            "C03"
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .sceneDepthUnavailable:
            "scene_depth_unavailable"
        case .depthGridUnreadable:
            "depth_grid_unreadable"
        case .foreground(let error):
            error.diagnosticDescription
        case .photo(let error):
            error.diagnosticDescription
        case let .unexpectedProcessingFailure(domain, code):
            "unexpected_processing_failure,domain=\(domain),code=\(code)"
        }
    }
}

extension ForegroundMaskAdapterError {
    var retryCategory: ScannerPhotoRetryCategory {
        switch self {
        case .noObservation:
            .isolation
        case .photo(_, let error):
            error.retryCategory
        case .requestFailed,
             .observationBridgeFailed,
             .scaledMaskFailed,
             .maskProcessingFailed:
            .processing
        }
    }

    var diagnosticCode: String {
        switch self {
        case .requestFailed:
            "V01"
        case .noObservation:
            "V02"
        case .observationBridgeFailed:
            "V03"
        case .scaledMaskFailed:
            "V04"
        case .maskProcessingFailed:
            "V05"
        case .photo(_, let error):
            error.diagnosticCode
        }
    }

    var diagnosticDescription: String {
        switch self {
        case let .requestFailed(domain, code):
            "vision_request_failed,domain=\(domain),code=\(code)"
        case .noObservation:
            "vision_no_foreground_observation"
        case .observationBridgeFailed:
            "vision_observation_bridge_failed"
        case let .scaledMaskFailed(domain, code):
            "vision_scaled_mask_failed,domain=\(domain),code=\(code)"
        case let .maskProcessingFailed(stage, domain, code):
            "vision_mask_processing_failed,stage=\(stage),domain=\(domain),code=\(code)"
        case let .photo(stage, error):
            "vision_mask_\(error.diagnosticDescription),stage=\(stage.rawValue)"
        }
    }

    var disposition: SingleShotFailureDisposition {
        switch self {
        case .noObservation:
            .targetRejected
        case .photo(_, let error):
            error.retryCategory == .processing ? .unavailable : .targetRejected
        case .requestFailed,
             .observationBridgeFailed,
             .scaledMaskFailed,
             .maskProcessingFailed:
            .unavailable
        }
    }
}

extension PhotoObjectMeasurementError {
    var retryCategory: ScannerPhotoRetryCategory {
        switch self {
        case .maskAreaTooLarge, .maskTouchesImageEdge:
            .framing
        case .noForegroundInstance,
             .ambiguousForegroundInstances,
             .noReticleDepthSurface,
             .maskAreaTooSmall,
             .multipleRigidItemsDetected:
            .isolation
        case .insufficientDepthSamples,
             .insufficientDepthCoverage,
             .insufficientHorizontalDepthSupport,
             .insufficientVerticalDepthSupport,
             .insufficientHorizontalDepthEndpointCoverage,
             .insufficientVerticalDepthEndpointCoverage:
            .depth
        case .invalidLabelMaskDimensions,
             .invalidDepthMaskDimensions,
             .invalidPolicy,
             .unsupportedLabelMaskPixelFormat,
             .invalidLabelMaskPixelValue,
             .maskCalibrationAspectRatioMismatch,
             .depthGridResolutionMismatch,
             .invalidCameraCalibration,
             .invalidWorldPoint:
            .processing
        }
    }

    var diagnosticCode: String {
        switch self {
        case .noForegroundInstance:
            "F01"
        case .ambiguousForegroundInstances:
            "F02"
        case .maskAreaTooSmall:
            "F03"
        case .maskAreaTooLarge:
            "F04"
        case .maskTouchesImageEdge:
            "F05"
        case .noReticleDepthSurface:
            "F06"
        case .multipleRigidItemsDetected:
            "F08"
        case .insufficientDepthSamples:
            "D01"
        case .insufficientDepthCoverage:
            "D02"
        case .insufficientHorizontalDepthSupport:
            "D03"
        case .insufficientVerticalDepthSupport:
            "D04"
        case .insufficientHorizontalDepthEndpointCoverage:
            "D05"
        case .insufficientVerticalDepthEndpointCoverage:
            "D06"
        case .invalidLabelMaskDimensions:
            "P01"
        case .invalidDepthMaskDimensions:
            "P02"
        case .invalidPolicy:
            "P03"
        case .unsupportedLabelMaskPixelFormat:
            "P04"
        case .invalidLabelMaskPixelValue:
            "P05"
        case .maskCalibrationAspectRatioMismatch:
            "P06"
        case .depthGridResolutionMismatch:
            "P07"
        case .invalidCameraCalibration:
            "P08"
        case .invalidWorldPoint:
            "P09"
        }
    }

    var diagnosticDescription: String {
        switch self {
        case .invalidLabelMaskDimensions:
            "invalid_label_mask_dimensions"
        case .invalidDepthMaskDimensions:
            "invalid_depth_mask_dimensions"
        case .invalidPolicy:
            "invalid_photo_measurement_policy"
        case .unsupportedLabelMaskPixelFormat(let format):
            "unsupported_label_mask_pixel_format,format=\(format)"
        case .invalidLabelMaskPixelValue:
            "invalid_label_mask_pixel_value"
        case .noForegroundInstance:
            "no_foreground_instance"
        case .ambiguousForegroundInstances(let labels):
            "ambiguous_foreground_instances,labels=\(labels.map(String.init).joined(separator: ","))"
        case .noReticleDepthSurface:
            "no_reticle_depth_surface"
        case let .maskAreaTooSmall(actual, minimum):
            "mask_area_too_small,actual=\(Self.metric(actual)),minimum=\(Self.metric(minimum))"
        case let .maskAreaTooLarge(actual, maximum):
            "mask_area_too_large,actual=\(Self.metric(actual)),maximum=\(Self.metric(maximum))"
        case .maskTouchesImageEdge:
            "mask_touches_image_edge"
        case .maskCalibrationAspectRatioMismatch:
            "mask_calibration_aspect_ratio_mismatch"
        case .depthGridResolutionMismatch:
            "depth_grid_resolution_mismatch"
        case let .insufficientDepthSamples(actual, minimum):
            "insufficient_depth_samples,actual=\(actual),minimum=\(minimum)"
        case let .insufficientDepthCoverage(actual, minimum):
            "insufficient_depth_coverage,actual=\(Self.metric(actual)),minimum=\(Self.metric(minimum))"
        case let .insufficientHorizontalDepthSupport(actual, minimum):
            "insufficient_horizontal_depth_support,actual=\(Self.metric(actual)),minimum=\(Self.metric(minimum))"
        case let .insufficientVerticalDepthSupport(actual, minimum):
            "insufficient_vertical_depth_support,actual=\(Self.metric(actual)),minimum=\(Self.metric(minimum))"
        case let .insufficientHorizontalDepthEndpointCoverage(actual, minimum):
            "insufficient_horizontal_depth_endpoint_coverage,actual=\(Self.metric(actual)),minimum=\(Self.metric(minimum))"
        case let .insufficientVerticalDepthEndpointCoverage(actual, minimum):
            "insufficient_vertical_depth_endpoint_coverage,actual=\(Self.metric(actual)),minimum=\(Self.metric(minimum))"
        case let .multipleRigidItemsDetected(evidence):
            "multiple_rigid_items_detected,split_height_fraction=\(Self.metric(evidence.splitHeightFraction)),maximum_boundary_shift_meters=\(Self.metric(evidence.maximumBoundaryShiftMeters)),normalized_boundary_shift=\(Self.metric(evidence.normalizedBoundaryShift)),significant_boundary_count=\(evidence.significantBoundaryCount)"
        case .invalidCameraCalibration:
            "invalid_camera_calibration"
        case .invalidWorldPoint:
            "invalid_world_point"
        }
    }

    private static func metric(_ value: Float) -> String {
        String(format: "%.6f", value)
    }
}

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
             .noReticleDepthSurface,
             .maskAreaTooSmall,
             .maskAreaTooLarge,
             .maskTouchesImageEdge,
             .insufficientDepthSamples,
             .insufficientDepthCoverage,
             .insufficientHorizontalDepthSupport,
             .insufficientVerticalDepthSupport,
             .insufficientHorizontalDepthEndpointCoverage,
             .insufficientVerticalDepthEndpointCoverage,
             .multipleRigidItemsDetected:
            return .targetRejected(.insufficientSurfaceEvidence)
        }
    }
}
