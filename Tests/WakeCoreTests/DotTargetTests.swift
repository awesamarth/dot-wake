import XCTest
@testable import WakeCore

final class DotTargetTests: XCTestCase {
    func testNormalizationAndConfiguredNames() throws {
        for name in ["Lucy", "Sam", "Samantha", "Jane Doe"] {
            let target = try DotTarget(name: "  \(name) \n")
            XCTAssertEqual(target.name, name)
            XCTAssertTrue(target.matchesPage(name.lowercased()))
            XCTAssertTrue(target.matchesNavigation(name.uppercased()))
            XCTAssertTrue(target.matchesProfile("Open \(name.lowercased())’s profile"))
            XCTAssertTrue(target.matchesProfile("Open \(name)'s profile"))
            XCTAssertFalse(target.matchesPage("Other dot"))
            XCTAssertFalse(target.matchesProfile("Open Other dot’s profile"))
            XCTAssertFalse(target.matchesProfile("Open profile menu"))
            XCTAssertFalse(target.matchesProfile("Open \(name)’s profile extra"))
        }
    }
    func testActiveCallNavigationLabelIsExactAndNotPageIdentity() throws {
        for name in ["Lucy", "Sam", "Jane Doe"] {
            let target = try DotTarget(name: name)
            XCTAssertTrue(target.matchesNavigation("\(name.lowercased()) Call in progress"))
            XCTAssertFalse(target.matchesPage("\(name) Call in progress"))
            for label in ["\(name) 2", "\(name) Call in progress extra", "Sent via \(name)", "Other \(name)"] {
                XCTAssertFalse(target.matchesNavigation(label))
            }
        }
    }
    func testObservedProfilePopupLabelStaysStrict() throws {
        let target = try DotTarget(name: "Lucy")
        XCTAssertTrue(target.matchesProfileControl(title: "lucy", role: "AXPopUpButton"))
        XCTAssertTrue(target.matchesProfileControl(title: "Open lucy’s profile", role: "AXPopUpButton"))
        XCTAssertFalse(target.matchesProfileControl(title: "Lucy", role: "AXButton"))
        XCTAssertFalse(target.matchesProfileControl(title: "Lucy", role: "AXStaticText"))
        XCTAssertFalse(target.matchesProfileControl(title: "Lucy 2", role: "AXPopUpButton"))
        XCTAssertFalse(target.matchesProfileControl(title: "lucy Call in progress", role: "AXPopUpButton"))
    }
    func testBadNames() {
        XCTAssertThrowsError(try DotTarget(name: " \n\t"))
        XCTAssertThrowsError(try DotTarget(name: String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try DotTarget(name: "Sam\0"))
    }
    func testMissingAppNeverCreatesCallForMuteOrBye() {
        XCTAssertEqual(DotSurfaceDecision.resolve(intent: .mute, running: false, hasWindow: false), .noLocalSession)
        XCTAssertEqual(DotSurfaceDecision.resolve(intent: .end, running: false, hasWindow: false), .noLocalSession)
        XCTAssertEqual(DotSurfaceDecision.resolve(intent: .startOrUnmute, running: false, hasWindow: false), .openForeground)
    }
    func testExistingWindowAndUnknownClosedSession() {
        for intent in [CallIntent.startOrUnmute, .mute, .end] {
            XCTAssertEqual(DotSurfaceDecision.resolve(intent: intent, running: true, hasWindow: true), .useExistingWindow)
            XCTAssertEqual(DotSurfaceDecision.resolve(intent: intent, running: true, hasWindow: false), .openForeground)
        }
    }
    func testReadOnlyNeverLaunchesOrNavigates() {
        for running in [false, true] { for window in [false, true] {
            XCTAssertEqual(DotSurfaceDecision.resolve(intent: nil, running: running, hasWindow: window), .inspectOnly)
        }}
    }
}
