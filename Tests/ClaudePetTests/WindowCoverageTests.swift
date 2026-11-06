import CoreGraphics
import XCTest
@testable import ClaudePet

final class WindowCoverageTests: XCTestCase {
    private let strip = CGRect(x: 10, y: 10, width: 408, height: 62)

    func testCoveredSpriteCanPauseWhileAgendaBelowRemainsVisible() {
        XCTAssertTrue(WindowCoverage.covers(strip, with: [CGRect(x: 0, y: 0, width: 500, height: 80)]))
        XCTAssertFalse(WindowCoverage.covers(CGRect(x: 10, y: 10, width: 408, height: 392),
                                             with: [CGRect(x: 0, y: 0, width: 500, height: 80)]))
    }

    func testSeveralWindowsCanCoverTheWholeStrip() {
        XCTAssertTrue(WindowCoverage.covers(strip, with: [
            CGRect(x: 0, y: 0, width: 210, height: 100),
            CGRect(x: 210, y: 0, width: 210, height: 100)
        ]))
    }

    func testEvenSmallVisibleGapKeepsAnimationRunning() {
        XCTAssertFalse(WindowCoverage.covers(strip, with: [
            CGRect(x: 0, y: 0, width: 210, height: 100),
            CGRect(x: 210.5, y: 0, width: 210, height: 100)
        ]))
    }

    func testOverlappingUnrelatedAndEmptyWindows() {
        XCTAssertFalse(WindowCoverage.covers(strip, with: [.zero, CGRect(x: -500, y: -500, width: 100, height: 100)]))
        XCTAssertTrue(WindowCoverage.covers(strip, with: [
            CGRect(x: 0, y: 0, width: 500, height: 45),
            CGRect(x: 0, y: 40, width: 500, height: 100)
        ]))
    }
}
