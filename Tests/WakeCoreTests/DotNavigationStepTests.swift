import XCTest
@testable import WakeCore

final class DotNavigationStepTests: XCTestCase {
    func step(present: Bool = false, ready: Bool = false, expand: Bool = false,
              home: Bool = true, opened: Bool = false, sentHome: Bool = false,
              sentTarget: Bool = false) -> DotNavigationStep {
        .resolve(targetPresent: present, targetReady: ready, canExpand: expand,
                 homeReady: home, openedSidebar: opened, sentHome: sentHome, sentTarget: sentTarget)
    }
    func testVisibleDotGoesDirectlyWithoutHome() {
        XCTAssertEqual(step(present: true, ready: true, expand: true), .target)
    }
    func testSpaceFallsBackToHome() {
        XCTAssertEqual(step(), .home)
    }
    func testCollapsedSidebarExpandsBeforeHome() {
        XCTAssertEqual(step(expand: true), .expandSidebar)
        XCTAssertEqual(step(expand: true, opened: true), .home)
    }
    func testVisibleButNotReadyWaitsInsteadOfNavigatingAway() {
        XCTAssertEqual(step(present: true, expand: true), .wait)
    }
    func testNoRepeatedHomeOrDotPress() {
        XCTAssertEqual(step(sentHome: true), .wait)
        XCTAssertEqual(step(present: true, ready: true, sentHome: true), .target)
        XCTAssertEqual(step(present: true, ready: true, sentTarget: true), .wait)
        XCTAssertEqual(step(home: false), .wait)
    }
}
