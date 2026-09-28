import simd
import ARKit
import RoomPlan
import SwiftUI

struct RoomCaptureBridge: UIViewControllerRepresentable {
    let finishing: Bool
    let onStart: @MainActor () -> Void
    let onProgress: @MainActor (RoomCaptureObservation) -> Void
    let onInstruction: @MainActor (RoomCoachingInstruction) -> Void
    let onDiagnostic: @MainActor (String) -> Void
    let onResult: @MainActor (Result<MeasuredRoom, Error>) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onResult: onResult, onStart: onStart, onProgress: onProgress,
                   onInstruction: onInstruction, onDiagnostic: onDiagnostic)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        if finishing { controller.finish() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.cancel()
    }

    final class Controller: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
        private var captureView: RoomCaptureView?
        private var started = false
        private var stopped = false
        private var finishRequested = false
        private var delivered = false
        private let onResult: @MainActor (Result<MeasuredRoom, Error>) -> Void

        private let onStart: @MainActor () -> Void
        private let onProgress: @MainActor (RoomCaptureObservation) -> Void
        private let onInstruction: @MainActor (RoomCoachingInstruction) -> Void
        private let onDiagnostic: @MainActor (String) -> Void
        private var startedAt: Date?

        init(onResult: @escaping @MainActor (Result<MeasuredRoom, Error>) -> Void,
             onStart: @escaping @MainActor () -> Void,
             onProgress: @escaping @MainActor (RoomCaptureObservation) -> Void,
             onInstruction: @escaping @MainActor (RoomCoachingInstruction) -> Void,
             onDiagnostic: @escaping @MainActor (String) -> Void) {
            self.onStart = onStart
            self.onProgress = onProgress
            self.onInstruction = onInstruction
            self.onDiagnostic = onDiagnostic
            self.onResult = onResult
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            let capture = RoomCaptureView(frame: view.bounds)
            capture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            capture.delegate = self
            capture.captureSession.delegate = self
            view.addSubview(capture)
            captureView = capture
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !started, !stopped else { return }
            started = true
            startedAt = .now
            onStart()
            captureView?.captureSession.run(configuration: .init())
            if finishRequested { finish() }
        }

        func finish() {
            finishRequested = true
            guard started, !stopped else { return }
            stopped = true
            captureView?.captureSession.stop()
        }

        func cancel() {
            delivered = true
            captureView?.delegate = nil
            captureView?.captureSession.delegate = nil
            if started && !stopped { captureView?.captureSession.stop() }
            stopped = true
            captureView?.captureSession.arSession.pause()
        }

        nonisolated func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
            publishProgress(room, session: session)
        }

        // Only didUpdate is a complete room snapshot. didAdd/didChange/didRemove
        // carry deltas (often no walls), so treating them as snapshots clears the
        // live count and repeatedly resets the unchanged-outline timer.

        nonisolated func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
            let next: RoomCoachingInstruction
            switch instruction {
            case .normal: next = .normal
            case .moveAwayFromWall: next = .moveAwayFromWall
            case .moveCloseToWall: next = .moveCloseToWall
            case .slowDown: next = .slowDown
            case .turnOnLight: next = .turnOnLight
            case .lowTexture: next = .lowTexture
            @unknown default: next = .unknown
            }
            Task { @MainActor [weak self] in
                guard let self, started, !delivered, !stopped else { return }
                onInstruction(next)
            }
        }

        private nonisolated func publishProgress(_ room: CapturedRoom, session: RoomCaptureSession) {
            let tracking: String
            switch session.arSession.currentFrame?.camera.trackingState {
            case .normal: tracking = "normal"
            case .limited(let reason): tracking = "limited:\(reason)"
            case .notAvailable: tracking = "notAvailable"
            case nil: tracking = "unavailable"
            }
            let observation = RoomCaptureObservation(walls: Self.measuredWalls(room), tracking: tracking)
            Task { @MainActor [weak self] in
                guard let self, started, !delivered, !stopped else { return }
                onProgress(observation)
            }
        }

        nonisolated func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
            if let error {
                Task { @MainActor [weak self] in
                    self?.onDiagnostic("RoomPlan session error: \(error.localizedDescription)")
                    self?.deliver(.failure(error))
                }
            }
        }

        nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
            if let error {
                Task { @MainActor [weak self] in self?.deliver(.failure(error)) }
                return false
            }
            return true
        }

        nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            Task { @MainActor [weak self] in
                guard self?.delivered == false else { return }
                if let error {
                    self?.deliver(.failure(error))
                    return
                }
                do {
                    let walls = Self.measuredWalls(processedResult)
                    let elapsed = self?.startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
                    let wallDetails = processedResult.walls.enumerated().map { index, wall in
                        "wall=\(index + 1) id=\(wall.identifier) dimensions_m=\(wall.dimensions) start_xz=\(walls[index].start) end_xz=\(walls[index].end) confidence=\(walls[index].confidence)"
                    }.joined(separator: "\n")
                    self?.onDiagnostic("""
                    duration_s=\(Int(elapsed)) detected_walls=\(walls.count) valid_walls=\(walls.filter(\.isValid).count)
                    doors=\(processedResult.doors.count) windows=\(processedResult.windows.count) openings=\(processedResult.openings.count)
                    \(wallDetails)
                    """)
                    self?.deliver(.success(try MeasuredRoom(walls: walls, captureSource: .processed)))
                } catch {
                    self?.deliver(.failure(error))
                }
            }
        }

        private nonisolated static func measuredWalls(_ room: CapturedRoom) -> [MeasuredRoom.Wall] {
            room.walls.map { wall in
                let half = wall.dimensions.x / 2
                let start = wall.transform * SIMD4<Float>(-half, 0, 0, 1)
                let end = wall.transform * SIMD4<Float>(half, 0, 0, 1)
                let confidence: String
                switch wall.confidence {
                case .high: confidence = "high"
                case .medium: confidence = "medium"
                case .low: confidence = "low"
                @unknown default: confidence = "unknown"
                }
                return MeasuredRoom.Wall(id: wall.identifier, start: SIMD2(start.x, start.z),
                                         end: SIMD2(end.x, end.z), height: wall.dimensions.y, confidence: confidence)
            }
        }

        private func deliver(_ result: Result<MeasuredRoom, Error>) {
            guard !delivered else { return }
            delivered = true
            onResult(result)
        }
    }
}
