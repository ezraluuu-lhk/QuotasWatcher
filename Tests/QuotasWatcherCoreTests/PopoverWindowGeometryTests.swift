import XCTest
@testable import QuotasWatcherCore

final class PopoverWindowGeometryTests: XCTestCase {
    // A 1440x900 screen whose auto-hidden menu bar leaves a 25-point strip
    // unreachable at the top.
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let margin = PopoverWindowGeometry.defaultMargin

    func testAlreadyVisibleFrameIsUnchanged() {
        let frame = CGRect(x: 900, y: 500, width: 470, height: 240)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(corrected, frame)
    }

    func testTopClippedFrameIsMovedFullyInside() {
        // Popover top extends 40 points past the visible frame's top edge,
        // as happens when the fullscreen auto-hidden menu bar slides away.
        let frame = CGRect(x: 900, y: 675, width: 470, height: 240)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(corrected.size, frame.size)
        XCTAssertEqual(corrected.maxY, visibleFrame.maxY - margin, accuracy: 0.0001)
        XCTAssertEqual(corrected.minX, frame.minX, accuracy: 0.0001)
        XCTAssertTrue(visibleFrame.insetBy(dx: margin, dy: margin).contains(corrected))
    }

    func testBottomOverflowIsConstrained() {
        let frame = CGRect(x: 900, y: -60, width: 470, height: 240)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(corrected.minY, visibleFrame.minY + margin, accuracy: 0.0001)
        XCTAssertEqual(corrected.size, frame.size)
    }

    func testLeftOverflowIsConstrained() {
        let frame = CGRect(x: -100, y: 500, width: 470, height: 240)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(corrected.minX, visibleFrame.minX + margin, accuracy: 0.0001)
        XCTAssertEqual(corrected.size, frame.size)
    }

    func testRightOverflowIsConstrained() {
        let frame = CGRect(x: 1400, y: 500, width: 470, height: 240)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(corrected.maxX, visibleFrame.maxX - margin, accuracy: 0.0001)
        XCTAssertEqual(corrected.size, frame.size)
    }

    func testOversizedFrameIsHandledDeterministically() {
        // Both dimensions exceed the inset visible frame: the frame cannot
        // fit, so it is pinned to the minimum edges deterministically.
        let frame = CGRect(x: 500, y: 500, width: 2000, height: 1200)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(corrected.origin, CGPoint(x: visibleFrame.minX + margin, y: visibleFrame.minY + margin))
        XCTAssertEqual(corrected.size, frame.size)

        let repeatResult = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(repeatResult, corrected)
    }

    func testEdgeMarginIsHonored() {
        // Fully inside the visible frame but only 1 point from its top edge:
        // inside the margin, so it must move to respect the margin.
        let frame = CGRect(x: 900, y: 634, width: 470, height: 240)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY - 1, accuracy: 0.0001)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame)
        XCTAssertEqual(corrected.maxY, visibleFrame.maxY - margin, accuracy: 0.0001)
        XCTAssertNotEqual(corrected, frame)
    }

    func testZeroMarginAllowsFrameAtVisibleFrameEdges() {
        let frame = CGRect(x: 0, y: 635, width: 470, height: 240)
        XCTAssertEqual(frame.maxY, visibleFrame.maxY, accuracy: 0.0001)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: visibleFrame, margin: 0)
        XCTAssertEqual(corrected, frame)
    }

    func testInvalidVisibleFrameLeavesFrameUnchanged() {
        let frame = CGRect(x: 900, y: 675, width: 470, height: 240)
        let corrected = PopoverWindowGeometry.correctedFrame(frame, visibleFrame: .zero)
        XCTAssertEqual(corrected, frame)
    }
}
