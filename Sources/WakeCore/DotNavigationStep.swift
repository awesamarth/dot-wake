/// One semantic navigation action at a time; never repeat Home or a dot press.
public enum DotNavigationStep: Equatable {
    case target, expandSidebar, home, wait
    public static func resolve(targetPresent: Bool, targetReady: Bool, canExpand: Bool,
                               homeReady: Bool, openedSidebar: Bool, sentHome: Bool,
                               sentTarget: Bool) -> Self {
        if sentTarget { return .wait }
        if targetPresent { return targetReady ? .target : .wait }
        if canExpand && !openedSidebar { return .expandSidebar }
        if homeReady && !sentHome { return .home }
        return .wait
    }
}
