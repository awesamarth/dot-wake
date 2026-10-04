import AppKit
import ApplicationServices
import WakeCore

private struct LucyAXFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func axValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}
private func axString(_ element: AXUIElement, _ key: String) -> String { axValue(element, key) as? String ?? "" }
private func axActions(_ element: AXUIElement) -> [String] {
    var actions: CFArray?
    guard AXUIElementCopyActionNames(element, &actions) == .success else { return [] }
    return actions as? [String] ?? []
}
private func axEnabled(_ element: AXUIElement) -> Bool { (axValue(element, "AXEnabled") as? NSNumber)?.boolValue == true }
private struct LucyAXSnapshot {
    let observation: LucyObservation
    let controls: [String: [AXUIElement]]
    func unique(_ name: String) throws -> AXUIElement {
        guard let list = controls[name], list.count == 1 else { throw LucyAXFailure(message: "Missing or ambiguous \(name) control") }
        return list[0]
    }
}

private final class DotForegroundOpenResult {
    private let lock = NSLock()
    private var result: (NSRunningApplication?, String?)?
    func finish(_ app: NSRunningApplication?, _ error: String?) {
        lock.lock(); result = (app, error); lock.unlock()
    }
    func read() -> (NSRunningApplication?, String?)? {
        lock.lock(); defer { lock.unlock() }; return result
    }
}

/// Existing windows use background AX only. User-authorized foreground open is used
/// once only for a missing app/window; no restart, pointer/keyboard events or helpers.
struct LucyAXBackend {
    let target: DotTarget
    let cancelled: () -> Bool
    private func check() throws {
        if cancelled() { throw LucyAXFailure(message: "Call action cancelled") }
    }
    private func snapshot(_ app: AXUIElement) throws -> LucyAXSnapshot {
        try check()
        guard let windows = axValue(app, "AXWindows") as? [AXUIElement] else { throw LucyAXFailure(message: "ChatGPT windows are unavailable") }
        var pages: [AXUIElement] = []; var visited = 0
        func findPages(_ element: AXUIElement, _ depth: Int) throws {
            try check()
            guard depth < 20, visited < 2500 else { throw LucyAXFailure(message: "Accessibility page scan exceeded its bound") }; visited += 1
            if axString(element, "AXRole") == "AXWebArea" {
                if target.matchesPage(axString(element, "AXTitle")) { pages.append(element) }
                return
            }
            if let children = axValue(element, "AXChildren") as? [AXUIElement] { for child in children { try findPages(child, depth + 1) } }
        }
        for window in windows { try findPages(window, 0) }
        guard pages.count == 1 else { throw LucyAXFailure(message: "Missing or ambiguous \(target.name) page; no call action sent") }
        var controls: [String: [AXUIElement]] = [:]
        let labels: Set<String> = ["Start call", "Hang up", "Mute microphone", "Unmute microphone"]
        visited = 0
        func collect(_ element: AXUIElement, _ depth: Int) throws {
            try check()
            guard depth < 55, visited < 2500 else { throw LucyAXFailure(message: "Accessibility control scan exceeded its bound") }; visited += 1
            let identifier = axString(element, "AXDOMIdentifier")
            // Call controls live inside the chat panel. Traverse structure, but never read
            // static text, message bodies or editable values. Call-state scan excludes sidebar.
            if identifier == "app-shell-sidebar" { return }
            let role = axString(element, "AXRole")
            if ["AXStaticText", "AXTextArea", "AXTextField"].contains(role) { return }
            if ["AXButton", "AXCheckBox", "AXPopUpButton"].contains(role) {
                let title = axString(element, "AXTitle")
                if labels.contains(title) { controls[title, default: []].append(element) }
                if target.matchesProfileControl(title: title, role: role) { controls["target-profile", default: []].append(element) }
            }
            if let children = axValue(element, "AXChildren") as? [AXUIElement] { for child in children { try collect(child, depth + 1) } }
        }
        try collect(pages[0], 0)
        guard visited < 2500 else { throw LucyAXFailure(message: "Accessibility tree exceeds bounded scan") }
        for list in controls.values where list.count > 1 { throw LucyAXFailure(message: "Ambiguous dot call controls") }
        let identity = controls["target-profile"]?.count == 1
        func enabled(_ label: String) -> Bool { controls[label]?.first.map(axEnabled) ?? false }
        return LucyAXSnapshot(observation: LucyObservation(targetVerified: identity, startEnabled: enabled("Start call"), hangupEnabled: enabled("Hang up"), muteEnabled: enabled("Mute microphone"), unmuteEnabled: enabled("Unmute microphone")), controls: controls)
    }
    /// Match only sidebar action metadata; never read message bodies or editable values.
    private func navigation(_ app: AXUIElement) throws -> (buttons: [AXUIElement], expand: [AXUIElement], collapse: [AXUIElement], home: [AXUIElement]) {
        var matches: [AXUIElement] = []; var expand: [AXUIElement] = []; var collapse: [AXUIElement] = []; var home: [AXUIElement] = []; var visited = 0
        func scan(_ element: AXUIElement, _ depth: Int, _ sidebar: Bool) throws {
            try check()
            guard depth < 55, visited < 2500 else { throw LucyAXFailure(message: "Dot navigation scan exceeded its bound") }
            visited += 1
            let role = axString(element, "AXRole")
            if ["AXStaticText", "AXTextField", "AXTextArea"].contains(role) { return }
            let inSidebar = sidebar || axString(element, "AXDOMIdentifier") == "app-shell-sidebar"
            if role == "AXButton" {
                let title = axString(element, "AXTitle")
                if inSidebar, target.matchesNavigation(title) { matches.append(element) }
                if inSidebar, title == "Home" { home.append(element) }
                if title == "Show sidebar" { expand.append(element) }
                if title == "Hide sidebar" { collapse.append(element) }
            }
            if let children = axValue(element, "AXChildren") as? [AXUIElement] {
                for child in children { try scan(child, depth + 1, inSidebar) }
            }
        }
        if let windows = axValue(app, "AXWindows") as? [AXUIElement] {
            for window in windows { try scan(window, 0, false) }
        }
        guard matches.count <= 1 else { throw LucyAXFailure(message: "More than one navigation target named \(target.name); no action sent") }
        return (matches, expand, collapse, home)
    }
    private func pressSidebar(_ elements: [AXUIElement]) throws {
        guard elements.count == 1, axEnabled(elements[0]), axActions(elements[0]).contains("AXPress") else {
            throw LucyAXFailure(message: "No unique available sidebar control; no input sent")
        }
        try check()
        guard AXUIElementPerformAction(elements[0], "AXPress" as CFString) == .success else {
            throw LucyAXFailure(message: "Could not open the sidebar.")
        }
    }
    private func reachTarget(_ app: AXUIElement, openedSidebar: inout Bool, recovering: Bool) throws {
        let deadline = Date().addingTimeInterval(recovering ? 30 : 8)
        var sent = false; var sentHome = false
        var lastSnapshotError = "Target page is not selected"
        repeat {
            try check()
            do {
                let selected = try snapshot(app)
                if selected.observation.targetVerified { return }
                lastSnapshotError = "Target profile identity is not available"
            } catch { lastSnapshotError = error.localizedDescription }
            let candidates = try navigation(app)
            func ready(_ list: [AXUIElement]) -> Bool {
                list.count == 1 && axEnabled(list[0]) && axActions(list[0]).contains("AXPress")
            }
            switch DotNavigationStep.resolve(targetPresent: !candidates.buttons.isEmpty,
                targetReady: ready(candidates.buttons), canExpand: ready(candidates.expand),
                homeReady: ready(candidates.home), openedSidebar: openedSidebar,
                sentHome: sentHome, sentTarget: sent) {
            case .target:
                try check()
                let result = AXUIElementPerformAction(candidates.buttons[0], "AXPress" as CFString)
                guard result == .success else { throw LucyAXFailure(message: "Could not open \(target.name).") }
                sent = true
            case .expandSidebar:
                try pressSidebar(candidates.expand)
                openedSidebar = true
            case .home:
                // Space/other sections do not expose dot shortcuts. Home restores that list.
                try check()
                let result = AXUIElementPerformAction(candidates.home[0], "AXPress" as CFString)
                guard result == .success else { throw LucyAXFailure(message: "Could not open Home in ChatGPT.") }
                sentHome = true
            case .wait: break
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        let context = sent ? "Dot shortcut pressed; identity not verified" : (sentHome ? "Home opened; dot shortcut not available" : "Dot shortcut is not accessible or ready")
        throw LucyAXFailure(message: "Could not reach \(target.name). \(context). \(lastSnapshotError). No call action sent.")
    }
    private func createForegroundWindow(_ running: NSRunningApplication) throws {
        try check()
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        guard running.activate(options: []) else {
            throw LucyAXFailure(message: "Could not bring windowless ChatGPT forward; no call attempted")
        }
        if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        else { Thread.sleep(forTimeInterval: 0.2) }
        if let windows = axValue(app, "AXWindows") as? [AXUIElement], !windows.isEmpty { return }
        var matches: [AXUIElement] = []; var visited = 0
        func scan(_ element: AXUIElement, _ depth: Int) throws {
            try check()
            guard depth < 14, visited < 600 else { throw LucyAXFailure(message: "New Window menu scan exceeded its bound") }
            visited += 1
            if axString(element, "AXRole") == "AXMenuItem", axString(element, "AXTitle") == "New Window" { matches.append(element) }
            if let children = axValue(element, "AXChildren") as? [AXUIElement] { for child in children { try scan(child, depth + 1) } }
        }
        guard let menu = axValue(app, "AXMenuBar"), CFGetTypeID(menu) == AXUIElementGetTypeID() else {
            throw LucyAXFailure(message: "ChatGPT New Window menu is unavailable")
        }
        try scan(menu as! AXUIElement, 0)
        guard matches.count == 1, axEnabled(matches[0]), axActions(matches[0]).contains("AXPress") else {
            throw LucyAXFailure(message: "No unique available New Window action; no input sent")
        }
        try check()
        guard AXUIElementPerformAction(matches[0], "AXPress" as CFString) == .success else {
            throw LucyAXFailure(message: "Could not open a ChatGPT window.")
        }
    }
    private func openForeground(existing: NSRunningApplication?) throws -> NSRunningApplication {
        try check()
        let url = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard Bundle(url: url)?.bundleIdentifier == "com.openai.codex" else {
            throw LucyAXFailure(message: "The expected ChatGPT app is missing; no alternate app launched")
        }
        let result = DotForegroundOpenResult()
        let start = {
            guard !cancelled() else { result.finish(nil, "Call action cancelled"); return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                result.finish(app, error?.localizedDescription)
            }
        }
        if let existing {
            try createForegroundWindow(existing)
            result.finish(existing, nil)
        } else if Thread.isMainThread { start() } else { DispatchQueue.main.async(execute: start) }
        let deadline = Date().addingTimeInterval(20)
        repeat {
            try check()
            if let (opened, error) = result.read() {
                if let error { throw LucyAXFailure(message: "Could not open ChatGPT: \(error)") }
                guard let opened, opened.bundleIdentifier == "com.openai.codex", opened.bundleURL?.path == url.path else {
                    throw LucyAXFailure(message: "Foreground open did not resolve the expected ChatGPT app")
                }
                let app = AXUIElementCreateApplication(opened.processIdentifier)
                AXUIElementSetMessagingTimeout(app, 1)
                if let windows = axValue(app, "AXWindows") as? [AXUIElement], !windows.isEmpty { return opened }
            }
            if Thread.isMainThread { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            else { Thread.sleep(forTimeInterval: 0.1) }
        } while Date() < deadline
        throw LucyAXFailure(message: "ChatGPT did not open a window. Open ChatGPT and try again.")
    }
    func perform(_ intent: CallIntent?, navigateOnly: Bool = false) throws -> String {
        try check()
        guard AXIsProcessTrusted() else {
            throw LucyAXFailure(message: "Accessibility required for Dot Wake.app. Allow Dot Wake in System Settings to control calls.")
        }
        var running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.openai.codex" && $0.bundleURL?.path == "/Applications/ChatGPT.app"
        })
        var hasWindow = false
        if let current = running {
            let currentAX = AXUIElementCreateApplication(current.processIdentifier)
            AXUIElementSetMessagingTimeout(currentAX, 1)
            guard let windows = axValue(currentAX, "AXWindows") as? [AXUIElement] else {
                throw LucyAXFailure(message: "ChatGPT window state is unreadable; no launch or blind action attempted")
            }
            hasWindow = !windows.isEmpty
        }
        let decision = DotSurfaceDecision.resolve(intent: intent, running: running != nil, hasWindow: hasWindow)
        if decision == .noLocalSession { return "No local \(target.name) call; ChatGPT is not running" }
        if navigateOnly, !hasWindow { throw LucyAXFailure(message: "Navigation check requires an existing window; no launch attempted") }
        if decision == .inspectOnly, !hasWindow {
            return "ChatGPT has no window; Hey \(target.name) will open it in the foreground."
        }
        let recovered = decision == .openForeground
        if recovered { running = try openForeground(existing: running) }
        guard let running else { throw LucyAXFailure(message: "ChatGPT is unavailable") }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        let recoveryNote = recovered ? " · ChatGPT opened" : ""
        let originalEnhanced = axValue(app, "AXEnhancedUserInterface")
        guard let original = originalEnhanced as? NSNumber else { throw LucyAXFailure(message: "ChatGPT enhanced accessibility state could not be read") }
        // Current app asynchronously honors this request despite returning -25208.
        // We trust only advertised AXPress plus observed postconditions, not that return code.
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        defer {
            _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, original.boolValue ? kCFBooleanTrue : kCFBooleanFalse)
        }
        if intent == nil, !navigateOnly {
            // Enhanced renderer accessibility hydrates asynchronously. A first empty scan
            // is not proof the dot is missing. Readonly never presses Home/sidebar/dot.
            let deadline = Date().addingTimeInterval(3)
            repeat {
                try check()
                if let selected = try? snapshot(app), let state = try? selected.observation.state() {
                    return "Dot session UI: \(state.rawValue) · remote connection unverified"
                }
                let available = try navigation(app)
                if available.buttons.count == 1 { return "Ready to reach \(target.name) in the background" }
                if available.expand.count == 1 || available.home.count == 1 {
                    return "Say Hey \(target.name); I’ll locate your dot from this section."
                }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline
            // Target identity/session remains UNKNOWN until a command resolves it.
            return "ChatGPT is open. Your dot will be checked when you give a command."
        }
        var openedSidebar = false
        defer {
            if openedSidebar, let current = try? navigation(app), current.collapse.count == 1 {
                try? pressSidebar(current.collapse)
            }
        }
        try reachTarget(app, openedSidebar: &openedSidebar, recovering: recovered)
        if navigateOnly { return "Dot navigation verified for \(target.name); no call action sent" }
        let readyDeadline = Date().addingTimeInterval(6)
        var initial: LucyAXSnapshot?
        repeat {
            try check()
            if let candidate = try? snapshot(app), let state = try? candidate.observation.state() {
                if let intent {
                    let action = try candidate.observation.action(for: intent)
                    if let action {
                        if let element = try? candidate.unique(action.rawValue), axActions(element).contains("AXPress") { initial = candidate; break }
                    } else { return "Dot session UI: \(state.rawValue) · already requested state; no action" + recoveryNote }
                } else { return "Dot session UI: \(state.rawValue) · remote connection unverified" }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < readyDeadline
        guard let initial, let intent, let action = try initial.observation.action(for: intent) else {
            // Surface the precise currently observable error instead of silently falling back.
            let current = try snapshot(app)
            _ = try current.observation.state()
            throw LucyAXFailure(message: "Call controls are not ready. Try again when ChatGPT has finished loading.")
        }
        // Re-resolve state immediately before sending; never use a cached toggle decision.
        let fresh = try snapshot(app)
        guard try fresh.observation.action(for: intent) == action else { throw LucyAXFailure(message: "Call state changed before action; retry deliberately") }
        let target = try fresh.unique(action.rawValue)
        guard axEnabled(target), axActions(target).contains("AXPress") else { throw LucyAXFailure(message: "Call control is unavailable.") }
        try check()
        let result = AXUIElementPerformAction(target, "AXPress" as CFString)
        guard result == .success else { throw LucyAXFailure(message: "Could not update the call.") }
        let deadline = Date().addingTimeInterval(10)
        repeat {
            try check()
            if let after = try? snapshot(app), let state = try? after.observation.state() {
                let expected: Bool
                let description: String
                switch action {
                case .start: expected = state == .unmuted; description = "start requested"
                case .unmute: expected = state == .unmuted; description = "unmuted"
                case .mute: expected = state == .muted; description = "muted"
                case .end: expected = state == .inactive; description = "call ended"
                }
                if expected { return "Dot \(description)" + (action == .end ? "" : " · remote connection unverified") + recoveryNote }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        throw LucyAXFailure(message: "Could not confirm \(action.rawValue). Check the call state.")
    }
}

/// Serial bounded worker; Stop/name changes invalidate queued work.
final class LucyCallController {
    private let queue = DispatchQueue(label: "DotWake.LucyAX")
    private let lock = NSLock()
    private var generation = 0
    private var busy = false
    func cancel() { lock.lock(); generation += 1; lock.unlock() }
    private func release() { lock.lock(); busy = false; lock.unlock() }
    private func current(_ value: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == value }
    func request(_ intent: CallIntent?, target: DotTarget, completion: @escaping (String) -> Void) {
        lock.lock()
        if busy {
            lock.unlock()
            DispatchQueue.main.async { completion("A call update is in progress. Try again when it finishes.") }
            return
        }
        let value = generation; busy = true; lock.unlock()
        queue.async { [self] in
            guard current(value) else { release(); return }
            let backend = LucyAXBackend(target: target, cancelled: { !self.current(value) })
            let result: String
            do { result = try backend.perform(intent) }
            catch { result = "Call control error: \(error.localizedDescription)" }
            release()
            DispatchQueue.main.async { [self] in if current(value) { completion(result) } }
        }
    }
}
