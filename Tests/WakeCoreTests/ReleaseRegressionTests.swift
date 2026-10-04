import XCTest
@testable import WakeCore

final class ReleaseRegressionTests: XCTestCase {
    func testConfiguredMultiwordNamesAndIndependentCommandBoundaries() {
        for name in ["Jane Doe", "alice", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"] {
            var gate = WakeGate(); gate.name = name; gate.listening = true
            XCTAssertEqual(gate.accept(" Hey  \(name.uppercased()) \n", now: 0), .startOrUnmute)
            XCTAssertNil(gate.accept("Hey \(name)", now: 1.499))
            XCTAssertEqual(gate.accept("Mute \(name)", now: 0.1), .mute)
            XCTAssertEqual(gate.accept("Bye \(name)", now: 0.2), .end)
            XCTAssertEqual(gate.accept("Hey \(name)", now: 1.5), .startOrUnmute)
            gate.stop()
            for command in ["Hey", "Mute", "Bye"] { XCTAssertNil(gate.accept("\(command) \(name)", now: 10)) }
            gate.listening = true
            XCTAssertEqual(gate.accept("Mute \(name)", now: 0), .mute)
        }
    }
    func testNearMatchAndUnsupportedLabelsNeverBecomeCallIntents() {
        var gate = WakeGate(); gate.name = "Jane Doe"; gate.listening = true
        for phrase in ["Hey Jane", "Mute Jane Doe extra", "Bye Doe", "By Jane Doe", "Unmute Jane Doe", "Stop Listening", "Hey Other"] {
            XCTAssertNil(gate.accept(phrase, now: 0), phrase)
        }
        for label in ["", "HEY", "unknown", "start", "by", "stop"] {
            XCTAssertNil(KeywordPhrases.phrase(for: label, name: gate.name))
        }
    }
    func testStaleEpochRejectedAcrossRepeatedStopsAndRestarts() {
        var epoch = ListeningEpoch(); var old: [Int] = []
        for _ in 0..<50 {
            let active = epoch.advance()
            XCTAssertTrue(epoch.accepts(active))
            for prior in old { XCTAssertFalse(epoch.accepts(prior)) }
            old.append(active)
            _ = epoch.advance()
            XCTAssertFalse(epoch.accepts(active))
        }
    }
}
