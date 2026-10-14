import AppKit
import ApplicationServices
import Foundation

/// Reads OffSight's on-screen UI through macOS Accessibility (needs Accessibility permission for
/// the terminal). Used to check what the user sees, and that automation can't approve (NFR-04).
enum UI {
    struct Element {
        let element: AXUIElement
        let role: String
        let text: String // title, value and description joined
    }

    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static var offSightPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.storiinnovations.offsight").first?.processIdentifier
    }

    /// Every element in OffSight's windows (including the prompt panel), depth-first.
    static func windowElements() -> [Element] {
        guard let pid = offSightPID else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var result: [Element] = []
        for window in children(of: app, attribute: kAXWindowsAttribute) {
            collect(window, into: &result, depth: 0)
        }
        return result
    }

    /// The accessibility description of OffSight's menu bar icon, e.g. "OffSight: camera protected".
    static func statusItemDescription() -> String? {
        guard let pid = offSightPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var extras: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &extras) == .success,
              let bar = extras else { return nil }
        for item in children(of: bar as! AXUIElement, attribute: kAXChildrenAttribute) { // swiftlint:disable:this force_cast
            let text = describe(item)
            if text.contains("OffSight") { return text }
        }
        return nil
    }

    /// Performs the accessibility "press" action, as an automation tool would.
    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    // MARK: Private

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func describe(_ element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
            .compactMap { string(element, $0) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private static func collect(_ element: AXUIElement, into result: inout [Element], depth: Int) {
        guard depth < 40 else { return }
        result.append(Element(element: element, role: string(element, kAXRoleAttribute) ?? "?", text: describe(element)))
        for child in children(of: element, attribute: kAXChildrenAttribute) {
            collect(child, into: &result, depth: depth + 1)
        }
    }
}

extension Scenarios {
    static let promptUI = Scenario(id: "ui-prompt", title: "Prompt and menu bar UI; automation can't approve",
                                   requirements: "UR-06, UR-07, UR-08, UR-14, UR-20, NFR-04, NFR-13, NFR-14") { ctx in
        guard UI.isTrusted else {
            return .skip("Allow your terminal in System Settings › Privacy & Security › Accessibility, then rerun.")
        }
        guard ctx.waitForIdle() else { return .skip("Another app is using OffSight Camera") }
        let idleIcon = UI.statusItemDescription()
        guard let client = ctx.newClient() else { return .fail("Could not open OffSight Camera") }
        client.start()
        defer { client.stop() }
        guard let state = ctx.app.waitFor(5, { !$0.prompts.isEmpty }), let prompt = state.prompts.first else {
            return .fail("No prompt")
        }
        Wait.sleep(0.6) // past the 300 ms click guard, so only the event-source check can stop a press
        let elements = UI.windowElements()
        var metrics: [(String, String)] = [("menu bar icon idle", idleIcon ?? "not found")]
        let heading = elements.first { $0.text.contains("wants to use your camera") }
        let keep = elements.first { $0.role == kAXButtonRole && $0.text.contains("Keep placeholder") }
        let goLive = elements.first { $0.role == kAXButtonRole && $0.text.contains("Go live for this session") }
        let preview = elements.first { $0.text.contains("Camera preview, visible only to you") }
        metrics.append(("heading", heading?.text ?? "missing"))
        metrics.append(("buttons", [keep, goLive].map { $0 == nil ? "missing" : "ok" }.joined(separator: ", ")))
        metrics.append(("preview label", preview == nil ? "missing" : "ok"))
        let protectedIcon = UI.statusItemDescription()
        metrics.append(("menu bar icon with prompt", protectedIcon ?? "not found"))

        guard let heading, heading.text.contains(prompt.name) else { return .fail("Prompt heading missing or doesn't name the app", metrics) }
        guard keep != nil, let goLive else { return .fail("Prompt buttons missing", metrics) }
        if preview == nil { return .fail("Preview has no accessibility label", metrics) }
        if let protectedIcon, !protectedIcon.contains("protected") {
            return .fail("Menu bar icon doesn't say protected while a prompt is pending", metrics)
        }

        // NFR-04: an accessibility press is automation, not a real click, and must not approve.
        guard let before = Probe.counters() else { return .fail("Camera counters unavailable", metrics) }
        UI.press(goLive.element)
        Wait.sleep(1.5)
        let after = ctx.app.state()
        let liveFrames = Probe.delta(Probe.counters()?.live ?? before.live, before.live)
        metrics.append(("after automated press", "live \(after?.live ?? false), live frames \(liveFrames)"))
        if after?.live == true || liveFrames > 0 {
            ctx.app.send(.closeAllShutters)
            return .fail("An automated (accessibility) press approved the session", metrics)
        }
        return .pass("UI correct; automated press ignored", metrics)
    }
}
