import WakeCore
public enum CallState: String { case unavailable, simulatedInactive, simulatedMuted, simulatedActive }
public protocol CallControl { var state: CallState { get }; mutating func send(_ intent: CallIntent) }
public struct SimulatedCallAdapter: CallControl {
    public var state: CallState = .unavailable
    public init() {}
    public mutating func connect(_ enabled: Bool) { state = enabled ? .simulatedInactive : .unavailable }
    public mutating func send(_ intent: CallIntent) {
        guard state != .unavailable else { return }
        switch intent {
        case .startOrUnmute: state = .simulatedActive
        case .mute: if state == .simulatedActive { state = .simulatedMuted }
        case .end: state = .simulatedInactive
        }
    }
}
