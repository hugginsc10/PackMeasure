import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Interior outlines and insert clearance")
struct InteriorGeometryTests {
    func loop(_ coordinates: [(Double, Double)]) -> [InteriorPoint] {
        coordinates.map { InteriorPoint(x: $0.0, y: $0.1) }
    }
    var rectangle: [InteriorPoint] { loop([(0,0), (400,0), (400,300), (0,300)]) }
    var notch: [InteriorPoint] { loop([(0,0), (400,0), (400,200), (200,200), (200,300), (0,300)]) }

    @Test func rectangularClearanceSubtractsBothSidesWithoutCargoRounding() throws {
        let result = try InteriorGeometry.inset([rectangle], clearance: 2)[0]
        #expect(result == loop([(2,2), (398,2), (398,298), (2,298)]))
    }
    @Test func concaveNotchIsPreserved() throws {
        let result = try InteriorGeometry.inset([notch], clearance: 2)[0]
        #expect(result == loop([(2,2), (398,2), (398,198), (198,198), (198,298), (2,298)]))
        #expect(!InteriorGeometry.contains(.init(x: 250, y: 250), in: result))
    }
    @Test func obstacleExpandsWhileOuterPerimeterShrinks() throws {
        let hole = loop([(100,100), (150,100), (150,150), (100,150)])
        let result = try InteriorGeometry.inset([rectangle, hole], clearance: 2)
        #expect(InteriorGeometry.area(result[0]) > 0)
        #expect(InteriorGeometry.area(result[1]) < 0)
        #expect(result[1].map(\.x).min() == 98)
        #expect(result[1].map(\.x).max() == 152)
    }
    @Test func windingDoesNotChangeAreaOrClearance() throws {
        let a = try InteriorGeometry.inset([notch], clearance: 3)
        let b = try InteriorGeometry.inset([Array(notch.reversed())], clearance: 3)
        #expect(abs(InteriorGeometry.area(a[0]) - InteriorGeometry.area(b[0])) < 0.001)
    }
    @Test func rejectsCrossingsRepeatedPointsAndBacktracking() {
        for bad in [loop([(0,0),(100,100),(0,100),(100,0)]),
                    loop([(0,0),(100,0),(100,0),(0,100)]),
                    loop([(0,0),(100,0),(50,0),(50,100),(0,100)])] {
            #expect(throws: (any Error).self) { try InteriorGeometry.validate([bad]) }
        }
    }
    @Test func rejectsOutsideTouchingOverlappingAndNestedObstacles() {
        let inside = loop([(100,100),(200,100),(200,200),(100,200)])
        for holes in [
            [loop([(390,100),(410,100),(410,150),(390,150)])],
            [loop([(0,100),(30,100),(30,150),(0,150)])],
            [inside, loop([(150,150),(220,150),(220,220),(150,220)])],
            [inside, loop([(120,120),(140,120),(140,140),(120,140)])]
        ] {
            #expect(throws: (any Error).self) { try InteriorGeometry.validate([rectangle] + holes) }
        }
    }
    @Test func rejectsClearanceThatClosesNarrowPassage() {
        let narrow = loop([(0,0),(100,0),(100,45),(200,45),(200,0),(300,0),
                           (300,100),(200,100),(200,55),(100,55),(100,100),(0,100)])
        #expect(throws: (any Error).self) { try InteriorGeometry.inset([narrow], clearance: 6) }
    }
    @Test func rejectsObstacleGrowingIntoWall() {
        let nearWall = loop([(2,100),(40,100),(40,140),(2,140)])
        #expect(throws: (any Error).self) { try InteriorGeometry.inset([rectangle, nearWall], clearance: 2) }
    }
    @Test func rejectsInvalidClearanceAndCollapsedRectangle() {
        for c in [-1, Double.nan, Double.infinity, 160, 300] {
            #expect(throws: (any Error).self) { try InteriorGeometry.inset([rectangle], clearance: c) }
        }
        #expect(throws: (any Error).self) {
            try InteriorGeometry.validate([loop([(0,0),(.nan,1),(1,0)])])
        }
    }
    @Test func zeroClearanceKeepsGeometry() throws {
        #expect(try InteriorGeometry.inset([rectangle], clearance: 0) == [rectangle])
    }
    @Test func angledWallsAndCollinearCurveSamplesRemainValid() throws {
        let angled = loop([(0,0),(200,0),(400,0),(360,180),(280,260),(0,300)])
        let result = try InteriorGeometry.inset([angled], clearance: 2)
        #expect(result[0].count == angled.count)
        #expect(InteriorGeometry.area(result[0]) < InteriorGeometry.area(angled))
    }
    @Test func svgUsesMillimeterScaleAndHoleWinding() throws {
        let hole = loop([(100,100),(150,100),(150,150),(100,150)])
        let scan = InteriorMeasurement(contours: [rectangle, hole], heightMM: 100)
        let svg = try scan.svg()
        #expect(svg.contains("width=\"396.000mm\" height=\"296.000mm\""))
        #expect(svg.contains("viewBox=\"0 0 396.000 296.000\""))
        #expect(svg.contains("fill-rule=\"evenodd\""))
        #expect(svg.contains("98.000 mm"))
        #expect(svg.components(separatedBy: " Z").count == 3)
    }
    @Test func invalidHeightCannotExport() {
        for height in [0, 1, Double.nan, Double.infinity] {
            let scan = InteriorMeasurement(contours: [rectangle], heightMM: height)
            #expect(throws: (any Error).self) { try scan.svg() }
        }
    }
    var world: [[SIMD3<Float>]] {
        [[.init(1,0,-1), .init(1.4,0,-1), .init(1.4,0,-0.7), .init(1,0,-0.7)]]
    }
    @Test func projectsWorldCoordinatesToMillimetersWithoutHalfInchRounding() throws {
        let scan = try InteriorGeometry.project(world, heightPoint: .init(1,0.103,-1))
        #expect(abs(scan.contours[0][1].x - 400) < 0.01)
        #expect(abs(scan.heightMM - 103) < 0.01)
    }
    @Test func rejectsUnevenFloorOrHeightOnAnotherWall() {
        var uneven = world
        uneven[0][2].y = 0.02
        #expect(throws: (any Error).self) { try InteriorGeometry.project(uneven, heightPoint: .init(1,0.1,-1)) }
        #expect(throws: (any Error).self) { try InteriorGeometry.project(world, heightPoint: .init(1.4,0.1,-1)) }
        #expect(throws: (any Error).self) { try InteriorGeometry.project(world, heightPoint: .init(1,-0.1,-1)) }
    }
    @Test func storesContoursObstaclesAndClearanceWithoutTouchingInventory() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "interiors.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = InteriorStore(url: url)
        #expect(try store.load().isEmpty)
        let record = InteriorMeasurement(contours: [notch], heightMM: 123, sideClearanceMM: 3.5, topClearanceMM: 4)
        try store.save([record])
        #expect(try store.load() == [record])
        try store.save([])
        #expect(try store.load().isEmpty)
    }
    @Test @MainActor func pendingCaptureCannotChangeBoundaryAndInterruptionInvalidatesRequest() {
        let state = InteriorScanState()
        world[0].forEach { state.receive($0) }
        state.requestPoint()
        let requestID = state.requestID
        state.requestPoint()
        state.undo()
        state.finishLoop(addObstacle: true)
        state.finishLoop(addObstacle: false)
        #expect(state.requestID == requestID)
        #expect(state.loops.count == 1)
        #expect(state.loops[0].count == 4)
        #expect(!state.takingHeight)
        state.invalidate("Interrupted")
        #expect(!state.isCapturingPoint)
        #expect(state.requestID != requestID)
        #expect(state.loops == [[]])
    }
    @Test @MainActor func interruptionClearsUnfinishedGeometryAndHeightMode() {
        let state = InteriorScanState()
        world[0].forEach { state.receive($0) }
        state.finishLoop(addObstacle: false)
        #expect(state.takingHeight)
        state.invalidate("Interrupted")
        #expect(state.loops == [[]])
        #expect(!state.takingHeight)
        #expect(state.result == nil)
    }
    @Test @MainActor func orderedConcaveCaptureObstacleUndoAndHeightProduceDraft() throws {
        let state = InteriorScanState()
        world[0].forEach { state.receive($0) }
        state.finishLoop(addObstacle: true)
        #expect(state.loops.count == 2)
        state.undo()
        #expect(state.loops.count == 1)
        state.finishLoop(addObstacle: false)
        state.receive(.init(1,0.1,-1))
        let result = try #require(state.result)
        #expect(result.contours[0].count == 4)
        state.invalidate("Background during review")
        #expect(state.result == result)
    }
}
