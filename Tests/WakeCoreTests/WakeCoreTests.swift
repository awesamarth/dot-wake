import XCTest
@testable import WakeCore
final class WakeCoreTests: XCTestCase {
    func testNamesAndIndependentDebounce() {
        for name in ["Lucy", "Sam", "Nova Ray", "Nova  Ray"] {
            var gate = WakeGate(); gate.name = name
            XCTAssertNil(gate.accept("Hey \(name)", now: 0)); gate.listening = true
            XCTAssertEqual(gate.accept("Hey \(name)", now: 1), .startOrUnmute)
            XCTAssertNil(gate.accept("Hey \(name)", now: 2))
            XCTAssertEqual(gate.accept("Mute \(name)", now: 2), .mute)
            XCTAssertEqual(gate.accept("Bye \(name)", now: 2), .end)
            XCTAssertNil(gate.accept("Bye \(name)", now: 3))
            XCTAssertNil(gate.accept("Mute \(name)", now: 3))
            XCTAssertEqual(gate.accept("Hey \(name)", now: 3), .startOrUnmute)
            XCTAssertEqual(gate.accept("Mute \(name)", now: 4), .mute)
            XCTAssertEqual(gate.accept("Bye \(name)", now: 4), .end)
            XCTAssertNil(gate.accept("Hey Other", now: 5)); gate.stop()
            XCTAssertNil(gate.accept("Bye \(name)", now: 6)); gate.listening = true
            XCTAssertEqual(gate.accept("Bye \(name)", now: 6), .end)
        }
    }
    func testThreeLabelsUseSameLiveAndFixtureMapping() {
        var gate = WakeGate(); gate.listening = true
        for (index, pair) in [("hey", CallIntent.startOrUnmute), ("mute", .mute), ("bye", .end)].enumerated() {
            let phrase = KeywordPhrases.phrase(for: pair.0, name: "Lucy")!
            XCTAssertEqual(gate.accept(phrase, now: Double(index)), pair.1)
        }
        for label in ["unknown", "by", "end", "stop", "unmute"] {
            XCTAssertNil(KeywordPhrases.phrase(for: label, name: "Lucy"))
        }
    }
    func testNoStopOrExtraVoiceCommands() {
        var gate = WakeGate(); gate.listening = true
        for phrase in ["Stop Listening", "Unmute Lucy", "By Lucy", "Bye", "Mute", "Mute Other", "Bye Other"] {
            XCTAssertNil(gate.accept(phrase, now: 10))
        }
        XCTAssertTrue(gate.listening)
    }
    func testThreeCommandsNeverStopDetectorGate() {
        var gate = WakeGate(); gate.listening = true
        for (index, phrase) in ["Hey Lucy", "Mute Lucy", "Bye Lucy"].enumerated() {
            XCTAssertNotNil(gate.accept(phrase, now: Double(index)))
            XCTAssertTrue(gate.listening)
        }
    }
    func testSimulatedAdapterDistinctMuteAndEnd() {
        var adapter = SimulatedCallAdapter(); adapter.send(.startOrUnmute)
        XCTAssertEqual(adapter.state, .unavailable)
        adapter.connect(true); XCTAssertEqual(adapter.state, .simulatedInactive)
        adapter.send(.mute); XCTAssertEqual(adapter.state, .simulatedInactive)
        adapter.send(.startOrUnmute); XCTAssertEqual(adapter.state, .simulatedActive)
        adapter.send(.mute); XCTAssertEqual(adapter.state, .simulatedMuted)
        adapter.send(.startOrUnmute); XCTAssertEqual(adapter.state, .simulatedActive)
        adapter.send(.end); XCTAssertEqual(adapter.state, .simulatedInactive)
        adapter.send(.end); XCTAssertEqual(adapter.state, .simulatedInactive)
        adapter.connect(false); XCTAssertEqual(adapter.state, .unavailable)
    }
    func testCancellation() {
        var epoch = ListeningEpoch(); let start = epoch.advance()
        XCTAssertTrue(epoch.accepts(start)); _ = epoch.advance(); XCTAssertFalse(epoch.accepts(start))
        let restart = epoch.advance(); XCTAssertTrue(epoch.accepts(restart)); XCTAssertFalse(epoch.accepts(start))
    }
    func testTokens() {
        XCTAssertEqual(KeywordTokens.encode("Hey Lucy", vocabulary: ["▁HEY", "▁LU", "C", "Y"]), "▁HEY ▁LU C Y")
        XCTAssertNil(KeywordTokens.encode("Sam", vocabulary: ["▁HEY"]))
    }
}
