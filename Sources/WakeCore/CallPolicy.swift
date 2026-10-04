import Foundation

/// Local call UI state. These states do not assert remote audio connection.
public enum LucySessionState: String { case inactive, muted, unmuted }
public enum LucyAction: String { case start = "Start call", mute = "Mute microphone", unmute = "Unmute microphone", end = "Hang up" }
public enum LucyPolicyError: String, LocalizedError {
    case wrongTarget, contradictoryControls, unknownState
    public var errorDescription: String? {
        switch self {
        case .wrongTarget: return "Configured dot identity could not be verified; no call action sent"
        case .contradictoryControls: return "Contradictory call controls; no call action sent"
        case .unknownState: return "Call state is unknown or controls are missing; no blind toggle sent"
        }
    }
}
public struct LucyObservation {
    public let targetVerified: Bool
    public let startEnabled: Bool
    public let hangupEnabled: Bool
    public let muteEnabled: Bool
    public let unmuteEnabled: Bool
    public init(targetVerified: Bool, startEnabled: Bool, hangupEnabled: Bool, muteEnabled: Bool, unmuteEnabled: Bool) {
        self.targetVerified = targetVerified; self.startEnabled = startEnabled; self.hangupEnabled = hangupEnabled
        self.muteEnabled = muteEnabled; self.unmuteEnabled = unmuteEnabled
    }
    public func state() throws -> LucySessionState {
        guard targetVerified else { throw LucyPolicyError.wrongTarget }
        guard !(muteEnabled && unmuteEnabled), !(startEnabled && (hangupEnabled || muteEnabled || unmuteEnabled)) else {
            throw LucyPolicyError.contradictoryControls
        }
        if hangupEnabled && muteEnabled { return .unmuted }
        if hangupEnabled && unmuteEnabled { return .muted }
        if startEnabled && !hangupEnabled && !muteEnabled && !unmuteEnabled { return .inactive }
        throw LucyPolicyError.unknownState
    }
    /// nil means a verified idempotent no-op, never an unknown-state fallback.
    public func action(for intent: CallIntent) throws -> LucyAction? {
        let state = try state()
        switch (intent, state) {
        case (.startOrUnmute, .inactive): return .start
        case (.startOrUnmute, .muted): return .unmute
        case (.mute, .unmuted): return .mute
        case (.end, .muted), (.end, .unmuted): return .end
        default: return nil
        }
    }
}
