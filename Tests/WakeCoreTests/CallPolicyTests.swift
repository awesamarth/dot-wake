import XCTest
@testable import WakeCore
final class CallPolicyTests: XCTestCase {
    func observe(_ start: Bool = false, _ hangup: Bool = false, _ mute: Bool = false, _ unmute: Bool = false, identity: Bool = true) -> LucyObservation {
        LucyObservation(targetVerified: identity, startEnabled: start, hangupEnabled: hangup, muteEnabled: mute, unmuteEnabled: unmute)
    }
    func testHeyStartsOnlyInactive() throws { XCTAssertEqual(try observe(true).action(for: .startOrUnmute), .start) }
    func testHeyUnmutesAndAlreadyUnmutedIsNoop() throws {
        XCTAssertEqual(try observe(false, true, false, true).action(for: .startOrUnmute), .unmute)
        XCTAssertNil(try observe(false, true, true).action(for: .startOrUnmute))
    }
    func testMuteKeepsCallOpenAndNeverStartsOne() throws {
        XCTAssertEqual(try observe(false, true, true).action(for: .mute), .mute)
        XCTAssertNil(try observe(false, true, false, true).action(for: .mute))
        XCTAssertNil(try observe(true).action(for: .mute))
    }
    func testByeEndsMutedAndUnmutedCalls() throws {
        XCTAssertEqual(try observe(false, true, false, true).action(for: .end), .end)
        XCTAssertEqual(try observe(false, true, true).action(for: .end), .end)
        XCTAssertEqual(LucyAction.end.rawValue, "Hang up")
        XCTAssertNil(try observe(true).action(for: .end))
    }
    func testWrongTargetNeverActs() {
        for intent in CallIntent.allCases {
            XCTAssertThrowsError(try observe(true, identity: false).action(for: intent))
            XCTAssertThrowsError(try observe(false, true, true, identity: false).action(for: intent))
        }
    }
    func testAllBooleanControlCombinationsFailClosedExceptThreeValidStates() throws {
        for bits in 0..<16 {
            let observation = observe(bits & 1 != 0, bits & 2 != 0, bits & 4 != 0, bits & 8 != 0)
            switch bits {
            case 1: XCTAssertEqual(try observation.state(), .inactive)
            case 6: XCTAssertEqual(try observation.state(), .unmuted)
            case 10: XCTAssertEqual(try observation.state(), .muted)
            default:
                for intent in CallIntent.allCases { XCTAssertThrowsError(try observation.action(for: intent)) }
            }
        }
    }
    func testExactlyThreeIntents() {
        XCTAssertEqual(Set(CallIntent.allCases), Set([.startOrUnmute, .mute, .end]))
    }
}
