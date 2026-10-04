/// Shared by live capture callbacks and synthetic CLI checks. Unknown labels never act.
public enum KeywordPhrases {
    public static func phrase(for label: String, name: String) -> String? {
        switch label {
        case "hey": return "Hey \(name)"
        case "mute": return "Mute \(name)"
        case "bye": return "Bye \(name)"
        default: return nil
        }
    }
}
