import CoreGraphics
import SwiftUI
import simd

/// A small, pure projection of the scanner's item and capture choices. It
/// normalizes impossible combinations before they reach the camera pipeline.
struct ScannerModeSelection: Equatable, Sendable {
    private(set) var subject: TargetLockSubject
    private(set) var mode: ScannerMeasurementMode

    init(
        subject: TargetLockSubject = .box,
        mode: ScannerMeasurementMode = .automaticPhotos
    ) {
        self.subject = subject
        self.mode = subject == .generalItem ? .automaticPhotos : mode
    }

    @discardableResult
    mutating func selectSubject(_ subject: TargetLockSubject) -> Bool {
        guard self.subject != subject else { return false }
        self.subject = subject
        if subject == .generalItem {
            mode = .automaticPhotos
        }
        return true
    }

    @discardableResult
    mutating func selectMode(_ mode: ScannerMeasurementMode) -> Bool {
        guard mode != .guidedCorners || subject == .box else { return false }
        guard self.mode != mode else { return false }
        self.mode = mode
        return true
    }
}

enum ScannerGuidedEntrySituation: Equatable, Sendable {
    case setup
    case automaticFailure
    case replaceAcceptedPhotoAngles
}

struct ScannerGuidedEntryPresentation: Equatable, Sendable {
    let actionTitle: String
    let supportingNote: String?
    let replacesAutomaticEvidence: Bool

    static func presentation(
        for situation: ScannerGuidedEntrySituation
    ) -> ScannerGuidedEntryPresentation {
        switch situation {
        case .setup:
            ScannerGuidedEntryPresentation(
                actionTitle: ScannerCrowdedSceneCopy.enterGuidedAction,
                supportingNote: ScannerCrowdedSceneCopy.setupNote,
                replacesAutomaticEvidence: false
            )
        case .automaticFailure:
            ScannerGuidedEntryPresentation(
                actionTitle: ScannerCrowdedSceneCopy.retryWithGuidedAction,
                supportingNote: ScannerCrowdedSceneCopy.setupNote,
                replacesAutomaticEvidence: false
            )
        case .replaceAcceptedPhotoAngles:
            ScannerGuidedEntryPresentation(
                actionTitle: ScannerCrowdedSceneCopy.restartWithGuidedAction,
                supportingNote: ScannerCrowdedSceneCopy.restartReplacementNote,
                replacesAutomaticEvidence: true
            )
        }
    }
}

enum ScannerTargetStatusPresentation {
    static func text(ownsAcceptedEvidence: Bool) -> String {
        ScannerCrowdedSceneCopy.targetStatus(
            ownsAcceptedEvidence: ownsAcceptedEvidence
        )
    }
}

enum ScannerGuidedAction: String, CaseIterable, Equatable, Sendable {
    case back
    case takePoint
    case confirm

    var title: String {
        switch self {
        case .back: "Back"
        case .takePoint: "Take point"
        case .confirm: "Confirm"
        }
    }
}

enum ScannerGuidedFeedback: Equatable, Sendable {
    case none
    case replacement(point: GuidedBoxPoint, message: String)
    case error(String)
}

struct ScannerGuidedCapturePresentation: Equatable, Sendable {
    let step: GuidedBoxWorkflowStep
    let prompt: String
    let feedbackMessage: String?
    let replacementPoint: GuidedBoxPoint?
    let actions: [ScannerGuidedAction]

    init(
        step: GuidedBoxWorkflowStep,
        feedback: ScannerGuidedFeedback = .none
    ) {
        self.step = step

        switch feedback {
        case .none:
            feedbackMessage = nil
            replacementPoint = nil
        case let .replacement(point, message):
            feedbackMessage = message
            replacementPoint = point
        case .error(let message):
            feedbackMessage = message
            replacementPoint = nil
        }

        if case .replacement(let point, _) = feedback {
            prompt = Self.prompt(for: point)
        } else {
            prompt = Self.prompt(for: step)
        }

        switch step {
        case .referenceCorner:
            actions = [.takePoint]
        case .lengthEndpoint, .widthEndpoint, .heightEndpoint:
            actions = [.back, .takePoint]
        case .review:
            actions = [.back, .confirm]
        case .complete:
            actions = []
        }
    }

    private static func prompt(for step: GuidedBoxWorkflowStep) -> String {
        guard let point = step.point else {
            return switch step {
            case .review:
                "Review the four points, then confirm the dimensions."
            case .complete:
                "Guided box measurement complete."
            case .referenceCorner, .lengthEndpoint, .widthEndpoint, .heightEndpoint:
                ""
            }
        }
        return prompt(for: point)
    }

    private static func prompt(for point: GuidedBoxPoint) -> String {
        switch point {
        case .referenceCorner:
            "1. Reference corner: place the reticle on one visible box corner."
        case .lengthEndpoint:
            "2. Length endpoint: place the reticle at the other end of the length edge."
        case .widthEndpoint:
            "3. Width endpoint: place the reticle at the other end of the width edge."
        case .heightEndpoint:
            "4. Height endpoint: place the reticle at the other end of the vertical edge."
        }
    }
}

enum ScannerEvidencePresentationKind: Equatable, Sendable {
    case automaticPhotoAngles
    case guidedBoxMeasurement
}

enum ScannerEvidencePresentationPolicy {
    static func presentation(
        for source: MeasurementEvidenceSource,
        subject: TargetLockSubject,
        mode: ScannerMeasurementMode
    ) -> ScannerEvidencePresentationKind? {
        switch (source, subject, mode) {
        case (.automaticPhoto, _, .automaticPhotos):
            .automaticPhotoAngles
        case (.guidedLidarCorners, .box, .guidedCorners):
            .guidedBoxMeasurement
        case (.automaticPhoto, _, .guidedCorners),
             (.guidedLidarCorners, _, .automaticPhotos),
             (.guidedLidarCorners, .generalItem, .guidedCorners):
            nil
        }
    }
}

struct ScannerNormalizedPreviewPoint: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat

    init?(x: CGFloat, y: CGFloat) {
        guard x.isFinite,
              y.isFinite,
              (0 ... 1).contains(x),
              (0 ... 1).contains(y) else {
            return nil
        }
        self.x = x
        self.y = y
    }

    init?(_ point: SIMD2<Float>) {
        self.init(x: CGFloat(point.x), y: CGFloat(point.y))
    }

    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * y)
    }
}

struct GuidedBoxProjectedPoint: Identifiable, Equatable, Sendable {
    let point: GuidedBoxPoint
    let position: ScannerNormalizedPreviewPoint

    var id: String { point.rawValue }
    var number: Int { point.markerNumber }
}

struct GuidedBoxProjectedReferenceLine: Identifiable, Equatable, Sendable {
    let reference: GuidedBoxProjectedPoint
    let endpoint: GuidedBoxProjectedPoint

    var id: String { endpoint.id }
}

struct GuidedBoxProjectedOverlay: Equatable, Sendable {
    let markers: [GuidedBoxProjectedPoint]
    let referenceLines: [GuidedBoxProjectedReferenceLine]

    init(projectedPoints: [GuidedBoxProjectedPoint]) {
        markers = GuidedBoxPoint.captureOrder.compactMap { point in
            projectedPoints.first { $0.point == point }
        }

        guard let reference = markers.first(where: {
            $0.point == .referenceCorner
        }) else {
            referenceLines = []
            return
        }
        referenceLines = markers.compactMap { marker in
            guard marker.point != .referenceCorner else { return nil }
            return GuidedBoxProjectedReferenceLine(
                reference: reference,
                endpoint: marker
            )
        }
    }

    static let empty = GuidedBoxProjectedOverlay(projectedPoints: [])
}

enum ScannerBuild33Layout {
    static let minimumHitTarget: CGFloat = 44
}

enum ScannerBuild33AccessibilityID {
    static let subjectBox = "scanner.subject.box"
    static let subjectGeneralItem = "scanner.subject.general-item"
    static let modeAutomaticPhotos = "scanner.mode.automatic-photos"
    static let modeGuidedCorners = "scanner.mode.guided-four-points"
    static let guidedEntry = "scanner.guided.entry"
    static let targetStatus = "scanner.target.status"
    static let guidedPrompt = "scanner.guided.prompt"
    static let guidedFeedback = "scanner.guided.feedback"

    static func guidedAction(_ action: ScannerGuidedAction) -> String {
        switch action {
        case .back: "scanner.guided.back"
        case .takePoint: "scanner.guided.take-point"
        case .confirm: "scanner.guided.confirm"
        }
    }

    static func guidedMarker(number: Int) -> String {
        "scanner.guided.marker.\(number)"
    }
}

struct ScannerModeSelector: View {
    let selection: ScannerModeSelection
    var canChangeSubject = true
    var canChangeMode = true
    let onSelectSubject: (TargetLockSubject) -> Void
    let onSelectMode: (ScannerMeasurementMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Item type")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                choiceButton(
                    title: "Box",
                    isSelected: selection.subject == .box,
                    isEnabled: canChangeSubject,
                    identifier: ScannerBuild33AccessibilityID.subjectBox
                ) {
                    onSelectSubject(.box)
                }
                choiceButton(
                    title: "General Item",
                    isSelected: selection.subject == .generalItem,
                    isEnabled: canChangeSubject,
                    identifier: ScannerBuild33AccessibilityID.subjectGeneralItem
                ) {
                    onSelectSubject(.generalItem)
                }
            }

            Text("Measure with")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                choiceButton(
                    title: "Photos",
                    isSelected: selection.mode == .automaticPhotos,
                    isEnabled: canChangeMode,
                    identifier: ScannerBuild33AccessibilityID.modeAutomaticPhotos
                ) {
                    onSelectMode(.automaticPhotos)
                }
                choiceButton(
                    title: "4 points",
                    isSelected: selection.mode == .guidedCorners,
                    isEnabled: canChangeMode && selection.subject == .box,
                    identifier: ScannerBuild33AccessibilityID.modeGuidedCorners
                ) {
                    onSelectMode(.guidedCorners)
                }
                .accessibilityHint(
                    selection.subject == .box
                        ? "Starts guided box measurement"
                        : "Four-point measurement is available for boxes"
                )
            }
        }
    }

    private func choiceButton(
        title: String,
        isSelected: Bool,
        isEnabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(maxWidth: .infinity)
                .frame(minHeight: ScannerBuild33Layout.minimumHitTarget)
                .background(
                    isSelected
                        ? Color.accentColor
                        : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }
}

struct ScannerGuidedEntryControl: View {
    let presentation: ScannerGuidedEntryPresentation
    var isEnabled = true
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Button(action: onEnter) {
                Label(presentation.actionTitle, systemImage: "scope")
                    .frame(minHeight: ScannerBuild33Layout.minimumHitTarget)
            }
            .buttonStyle(.bordered)
            .disabled(!isEnabled)
            .accessibilityIdentifier(ScannerBuild33AccessibilityID.guidedEntry)

            if let supportingNote = presentation.supportingNote {
                Text(supportingNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct ScannerTargetStatusBadge: View {
    let ownsAcceptedEvidence: Bool

    var body: some View {
        Text(
            ScannerTargetStatusPresentation.text(
                ownsAcceptedEvidence: ownsAcceptedEvidence
            )
        )
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(minHeight: ScannerBuild33Layout.minimumHitTarget)
        .background(.black.opacity(0.55), in: Capsule())
        .accessibilityIdentifier(ScannerBuild33AccessibilityID.targetStatus)
    }
}

struct ScannerGuidedCaptureControls: View {
    let presentation: ScannerGuidedCapturePresentation
    var isTakingPoint = false
    var actionsEnabled = true
    let onBack: () -> Void
    let onTakePoint: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.prompt)
                .font(.body.weight(.semibold))
                .accessibilityIdentifier(ScannerBuild33AccessibilityID.guidedPrompt)

            if let feedbackMessage = presentation.feedbackMessage {
                Label(feedbackMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        ScannerBuild33AccessibilityID.guidedFeedback
                    )
            }

            HStack(spacing: 10) {
                if presentation.actions.contains(.back) {
                    actionButton(.back, action: onBack)
                        .buttonStyle(.bordered)
                }
                if presentation.actions.contains(.takePoint) {
                    actionButton(.takePoint, action: onTakePoint)
                        .buttonStyle(.borderedProminent)
                }
                if presentation.actions.contains(.confirm) {
                    actionButton(.confirm, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func actionButton(
        _ action: ScannerGuidedAction,
        action handler: @escaping () -> Void
    ) -> some View {
        Button(action: handler) {
            HStack(spacing: 6) {
                if action == .takePoint, isTakingPoint {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(action.title)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: ScannerBuild33Layout.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .disabled(!actionsEnabled || (action == .takePoint && isTakingPoint))
        .accessibilityIdentifier(
            ScannerBuild33AccessibilityID.guidedAction(action)
        )
    }
}

struct GuidedBoxProjectedOverlayView: View {
    let overlay: GuidedBoxProjectedOverlay

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(overlay.referenceLines) { line in
                    Path { path in
                        path.move(to: line.reference.position.point(in: proxy.size))
                        path.addLine(to: line.endpoint.position.point(in: proxy.size))
                    }
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .accessibilityHidden(true)
                }

                ForEach(overlay.markers) { marker in
                    ZStack {
                        Circle()
                            .fill(.cyan)
                        Circle()
                            .stroke(.black.opacity(0.75), lineWidth: 2)
                        Text("\(marker.number)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                    }
                    .frame(width: 32, height: 32)
                    .position(marker.position.point(in: proxy.size))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Guided point \(marker.number), \(marker.point.rawValue)"
                    )
                    .accessibilityIdentifier(
                        ScannerBuild33AccessibilityID.guidedMarker(
                            number: marker.number
                        )
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
