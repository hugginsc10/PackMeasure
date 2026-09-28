import XCTest
import simd
@testable import PackMeasure

final class PhotoFocusedSelectionTests: XCTestCase {
    private func mask(_ rect: ClosedRange<Int>, y: ClosedRange<Int> = 30...60) throws -> PhotoInstanceLabelMask {
        var labels = Array(repeating: UInt32(0), count: 100 * 100)
        for row in y { for x in rect { labels[row * 100 + x] = 1 } }
        return try PhotoInstanceLabelMask(width: 100, height: 100, labels: labels)
    }

    func testCropPromptAndRegistrationPreserveOriginalCoordinates() throws {
        let window = PhotoFocusWindow(x: 20, y: 30, width: 100, height: 100)
        let target = SIMD2<Float>(0.35, 0.4)
        XCTAssertEqual(window.prompt(target, imageWidth: 200, imageHeight: 200), SIMD2<Float>(0.5, 0.5))
        let selected = try PhotoForegroundInstanceSelector().select(in: mask(30...60))
        let registered = try XCTUnwrap(window.registered(selected, imageWidth: 200, imageHeight: 200))
        XCTAssertEqual(registered.labels[60 * 200 + 50], 1)
        XCTAssertEqual(registered.labels[90 * 200 + 80], 1)
        XCTAssertEqual(registered.labels[59 * 200 + 50], 0)
        XCTAssertEqual(registered.labels.filter { $0 != 0 }.count, 31 * 31)
    }

    func testClippedCandidatesCannotHideInsideFullFramePadding() throws {
        let window = PhotoFocusWindow(x: 20, y: 20, width: 100, height: 100)
        for candidate in [try mask(0...60), try mask(30...99),
                          try mask(30...60, y: 0...60), try mask(30...60, y: 30...99)] {
            let selected = try PhotoForegroundInstanceSelector().select(in: candidate)
            XCTAssertNil(try window.registered(selected, imageWidth: 200, imageHeight: 200))
        }
    }

    func testTwoAgreeingMasksPreserveUnionAndCannotAcquireAnotherObject() throws {
        let original = try PhotoForegroundInstanceSelector().select(in: mask(20...80, y: 20...80))
        let a = try mask(30...60), b = try mask(31...61)
        let merged = try XCTUnwrap(PhotoFocusedSelectionConsensus.merge(a, b, within: original))
        XCTAssertEqual(merged.labels.filter { $0 != 0 }.count, 32 * 31)
        XCTAssertNil(try PhotoFocusedSelectionConsensus.merge(a, mask(40...70), within: original))
        XCTAssertNil(try PhotoFocusedSelectionConsensus.merge(mask(10...40), mask(10...40), within: original))
    }

    func testWindowsStayInBoundsAtImageCornersAndRejectInvalidPrompt() {
        for point in [SIMD2<Float>(0,0), SIMD2<Float>(1,1), SIMD2<Float>(0.6,0.4)] {
            let windows = PhotoFocusWindow.candidates(width: 1920, height: 1440, target: point)
            XCTAssertEqual(windows.count, 3)
            for window in windows {
                XCTAssertGreaterThanOrEqual(window.x, 0); XCTAssertGreaterThanOrEqual(window.y, 0)
                XCTAssertLessThanOrEqual(window.x + window.width, 1920)
                XCTAssertLessThanOrEqual(window.y + window.height, 1440)
                let prompt = window.prompt(point, imageWidth: 1920, imageHeight: 1440)
                XCTAssertTrue((0...1).contains(prompt.x) && (0...1).contains(prompt.y))
            }
        }
        XCTAssertTrue(PhotoFocusWindow.candidates(width: 100, height: 100, target: SIMD2<Float>(.nan,0)).isEmpty)
    }
}
