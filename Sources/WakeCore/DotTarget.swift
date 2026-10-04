import Foundation

/// The configured dot's UI identity; no hardcoded Lucy-only routing.
public struct DotTarget: Equatable {
    public let name: String
    public init(name: String) throws {
        let normalized = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= 64,
              normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw DotTargetError.invalidName
        }
        self.name = normalized
    }
    private func canonical(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "’", with: "'")
    }
    public func matchesPage(_ title: String) -> Bool { canonical(title) == canonical(name) }
    public func matchesNavigation(_ title: String) -> Bool {
        // ChatGPT adds this exact accessibility status to a dot's active-call shortcut.
        // Never accept arbitrary prefixes/substrings (e.g. Lucy 2 or Sent via Lucy).
        matchesPage(title) || canonical(title) == canonical("\(name) Call in progress")
    }
    /// Current ChatGPT labels the profile popup with just the dot name. Only a
    /// popup on the independently matched dot page may use this variant.
    public func matchesProfileControl(title: String, role: String) -> Bool {
        matchesProfile(title) || (role == "AXPopUpButton" && matchesPage(title))
    }
    public func matchesProfile(_ title: String) -> Bool {
        canonical(title) == canonical("Open \(name)'s profile")
    }
}
public enum DotTargetError: Error { case invalidName }

/// Availability is not inferred from a cached UI error or an unrelated page.
public enum DotSurfaceDecision: Equatable {
    case inspectOnly, noLocalSession, useExistingWindow, openForeground
    public static func resolve(intent: CallIntent?, running: Bool, hasWindow: Bool) -> Self {
        guard let intent else { return .inspectOnly }
        if !running { return intent == .startOrUnmute ? .openForeground : .noLocalSession }
        return hasWindow ? .useExistingWindow : .openForeground
    }
}
