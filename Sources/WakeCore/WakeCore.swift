import Foundation
public enum CallIntent: String, CaseIterable { case startOrUnmute, mute, end }
public struct WakeGate {
    public var listening = false
    public var name = "Lucy"
    private var last: [CallIntent: TimeInterval] = [:]
    public init() {}
    public mutating func stop() { listening = false; last.removeAll() }
    public mutating func accept(_ phrase: String, now: TimeInterval) -> CallIntent? {
        guard listening else { return nil }
        let p = phrase.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let n = name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let intent: CallIntent
        if p == "hey \(n)" { intent = .startOrUnmute }
        else if p == "mute \(n)" { intent = .mute }
        else if p == "bye \(n)" { intent = .end }
        else { return nil }
        if let t = last[intent], now - t < 1.5 { return nil }
        last[intent] = now
        return intent
    }
}
public enum KeywordTokens {
    public static func encode(_ phrase: String, vocabulary: [String], scores: [String: Double] = [:]) -> String? {
        let usable = vocabulary.filter { !$0.hasPrefix("<") && !$0.isEmpty }.sorted { $0.count > $1.count }
        var result: [String] = []
        for word in phrase.uppercased().split(separator: " ") {
            let text = Array("▁" + word)
            var memo: [Int: (Double, [String])] = [text.count: (0, [])]
            func solve(_ i: Int) -> (Double, [String])? {
                if let v = memo[i] { return v }
                var best: (Double, [String])?
                for token in usable {
                    let chars = Array(token)
                    if i + chars.count <= text.count && Array(text[i..<i+chars.count]) == chars, let tail = solve(i+chars.count) {
                        let score = (scores[token] ?? -1) + tail.0
                        if best == nil || score > best!.0 { best = (score, [token] + tail.1) }
                    }
                }
                if let best { memo[i] = best }; return best
            }
            guard let tokens = solve(0) else { return nil }; result += tokens.1
        }
        return result.joined(separator: " ")
    }
}
/// Invalidates in-flight permission replies and queued detector callbacks on Stop.
public struct ListeningEpoch {
    private var value = 0
    public init() {}
    public mutating func advance() -> Int { value += 1; return value }
    public func accepts(_ token: Int) -> Bool { token == value }
}
