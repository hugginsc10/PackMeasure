import simd
import ARKit
import RoomPlan
import SwiftUI

struct RoomCaptureBridge: UIViewControllerRepresentable {
    let finishing: Bool
    let onProgress: @MainActor (Int) -> Void
    let onDiagnostic: @MainActor (String) -> Void
    let onResult: @MainActor (Result<MeasuredRoom, Error>) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onResult: onResult, onProgress: onProgress, onDiagnostic: onDiagnostic)
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

        private let onProgress: @MainActor (Int) -> Void
        private let onDiagnostic: @MainActor (String) -> Void
        private var startedAt: Date?

        init(onResult: @escaping @MainActor (Result<MeasuredRoom, Error>) -> Void,
             onProgress: @escaping @MainActor (Int) -> Void,
             onDiagnostic: @escaping @MainActor (String) -> Void) {
            self.onProgress = onProgress
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
            publishProgress(room)
        }

        nonisolated func captureSession(_ session: RoomCaptureSession, didAdd room: CapturedRoom) {
            publishProgress(room)
        }

        nonisolated func captureSession(_ session: RoomCaptureSession, didChange room: CapturedRoom) {
            publishProgress(room)
        }

        nonisolated func captureSession(_ session: RoomCaptureSession, didRemove room: CapturedRoom) {
            publishProgress(room)
        }

        private nonisolated func publishProgress(_ room: CapturedRoom) {
            let count = room.walls.count
            Task { @MainActor [weak self] in
                guard let self, !delivered, !stopped else { return }
                onProgress(count)
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
                    let walls = processedResult.walls.map { wall in
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
                        return MeasuredRoom.Wall(id: wall.identifier,
                            start: SIMD2(start.x, start.z), end: SIMD2(end.x, end.z),
                            height: wall.dimensions.y, confidence: confidence)
                    }
                    let elapsed = self?.startedAt.map { Date.now.timeIntervalSince($0) } ?? 0
                    let wallDetails = processedResult.walls.enumerated().map { index, wall in
                        "wall=\(index + 1) dimensions_m=\(wall.dimensions)"
                    }.joined(separator: "\n")
                    self?.onDiagnostic("""
                    duration_s=\(Int(elapsed)) detected_walls=\(walls.count) valid_walls=\(walls.filter(\.isValid).count)
                    doors=\(processedResult.doors.count) windows=\(processedResult.windows.count) openings=\(processedResult.openings.count)
                    \(wallDetails)
                    """)
                    self?.deliver(.success(try MeasuredRoom(walls: walls)))
                } catch {
                    self?.deliver(.failure(error))
                }
            }
        }

        private func deliver(_ result: Result<MeasuredRoom, Error>) {
            guard !delivered else { return }
            delivered = true
            onResult(result)
        }
    }
}
