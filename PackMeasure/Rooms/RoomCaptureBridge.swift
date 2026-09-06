import simd
import ARKit
import RoomPlan
import SwiftUI

struct RoomCaptureBridge: UIViewControllerRepresentable {
    let finishing: Bool
    let onResult: @MainActor (Result<MeasuredRoom, Error>) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onResult: onResult)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        if finishing { controller.finish() }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.cancel()
    }

    final class Controller: UIViewController, RoomCaptureViewDelegate {
        private var captureView: RoomCaptureView?
        private var started = false
        private var stopped = false
        private var finishRequested = false
        private var delivered = false
        private let onResult: @MainActor (Result<MeasuredRoom, Error>) -> Void

        init(onResult: @escaping @MainActor (Result<MeasuredRoom, Error>) -> Void) {
            self.onResult = onResult
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            let capture = RoomCaptureView(frame: view.bounds)
            capture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            capture.delegate = self
            view.addSubview(capture)
            captureView = capture
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !started, !stopped else { return }
            started = true
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
            if started && !stopped { captureView?.captureSession.stop() }
            stopped = true
            captureView?.captureSession.arSession.pause()
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
