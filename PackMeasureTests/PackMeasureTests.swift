import Foundation
import simd
import Testing
@testable import PackMeasure

struct PackMeasureTests {
    @Test
    func estimatorRecoversRotatedBoxWithinTolerance() {
        let points = syntheticBoxPoints(
            length: 1.2,
            width: 0.6,
            height: 0.75,
            yaw: .pi / 7,
            center: SIMD3<Double>(0, 0.375, 0)
        )

        let estimate = MeasurementEstimator.estimate(from: points, frameCount: 12)

        #expect(estimate != nil)
        #expect(abs((estimate?.lengthMeters ?? 0) - 1.2) < 0.08)
        #expect(abs((estimate?.widthMeters ?? 0) - 0.6) < 0.08)
        #expect(abs((estimate?.heightMeters ?? 0) - 0.75) < 0.08)
    }

    @Test
    func inventoryStoreRoundTripsItems() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let fileManager = TestFileManager(rootURL: tempRoot)
        let store = InventoryStore(fileManager: fileManager)
        let items = [
            MeasuredItem(
                name: "Dish Barrel",
                lengthMeters: 0.6,
                widthMeters: 0.45,
                heightMeters: 0.45,
                quantity: 2,
                confidence: .medium
            )
        ]

        try store.save(items)
        let loaded = try store.load()

        #expect(loaded == items)
    }

    private func syntheticBoxPoints(
        length: Double,
        width: Double,
        height: Double,
        yaw: Double,
        center: SIMD3<Double>
    ) -> [SIMD3<Double>] {
        let rotation = simd_double3x3(
            SIMD3<Double>(cos(yaw), 0, sin(yaw)),
            SIMD3<Double>(0, 1, 0),
            SIMD3<Double>(-sin(yaw), 0, cos(yaw))
        )

        var points: [SIMD3<Double>] = []
        for xi in stride(from: -length / 2, through: length / 2, by: 0.06) {
            for zi in stride(from: -width / 2, through: width / 2, by: 0.06) {
                for yi in stride(from: 0.0, through: height, by: height / 4) {
                    let local = SIMD3<Double>(xi, yi - height / 2, zi)
                    let rotated = rotation * local
                    points.append(rotated + center)
                }
            }
        }

        for xi in stride(from: -length / 2, through: length / 2, by: 0.09) {
            for zi in stride(from: -width / 2, through: width / 2, by: 0.09) {
                let local = SIMD3<Double>(xi, -height / 2, zi)
                let rotated = rotation * local
                points.append(rotated + center)
            }
        }

        return points
    }
}

private final class TestFileManager: FileManager, @unchecked Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
        super.init()
    }

    override func url(
        for directory: SearchPathDirectory,
        in domain: SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        rootURL
    }
}
