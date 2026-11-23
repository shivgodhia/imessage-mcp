import AppKit
import ApplicationServices
import Foundation

/// Sending a new group text by pressing Return in the Messages draft.
///
/// Messages has no way for another app to create a group, so the only route is
/// the new-message window the imessage:// link opens. With the Accessibility
/// permission iMessage MCP can read that window, check it is addressed to the
/// right people with the right text, and press Return in it.
extension LiveBridge {
    public static let accessibilityURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// Whether macOS lets this app use Accessibility. With `prompt`, macOS shows
    /// its "would like to control this computer" request the first time, which
    /// also adds iMessage MCP to the list in System Settings.
    public static func accessibilityAllowed(prompt: Bool = false) -> Bool {
        if !prompt { return AXIsProcessTrusted() }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func canPressReturn() -> Bool { LiveBridge.accessibilityAllowed(prompt: true) }

    /// Do the recipient tokens in a draft's To field name exactly these people?
    /// A token reads like "Ana Ruiz, +15551230001" or "a@b.com, Not registered".
    static func tokensMatch(_ tokens: [String], _ recipients: [String]) -> Bool {
        guard tokens.count == recipients.count else { return false }
        let tokenHandles = tokens.map { token in
            Set(token.split(separator: ",").map { norm(String($0)) })
        }
        var used = Set<Int>()
        for recipient in recipients {
            let key = norm(recipient)
            guard let index = tokenHandles.indices.first(where: { !used.contains($0) && tokenHandles[$0].contains(key) })
            else { return false }
            used.insert(index)
        }
        return true
    }

    func composeAndPressReturn(recipients: [String], text: String) -> ComposeResult {
        guard let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first
            ?? launchMessages()
        else { return .failed("Messages is not running and could not be started.") }
        let previous = NSWorkspace.shared.frontmostApplication
        defer { LiveBridge.bringBack(previous, unless: messages) }

        // Without -g: macOS no longer lets a background app bring another app
        // forward, but `open` can, and keystrokes only land in the frontmost app.
        let link = LiveBridge.composeLink(recipients: recipients, text: text)
        let opened = runProcess("/usr/bin/open", ["-a", "Messages", link], input: "", timeout: 20)
        if opened.status != 0 || opened.timedOut {
            return .failed("Could not open a new message in Messages. \(opened.output)")
        }

        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = messages.processIdentifier
        var box: AXUIElement?
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            guard messages.isActive, let draft = LiveBridge.draft(in: pid) else { continue }
            let typed = (LiveBridge.value(draft.message) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if typed == wanted && LiveBridge.tokensMatch(draft.recipients, recipients) {
                box = draft.message
                break
            }
        }
        guard let message = box else {
            return .draft(
                "iMessage MCP could not confirm the new message had exactly these people and this text, "
                    + "so it did not press Return")
        }

        AXUIElementSetAttributeValue(message, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.2)
        // Check again right before the key: the user may have clicked elsewhere.
        guard messages.isActive, LiveBridge.isFocused(message, in: pid),
              (LiveBridge.value(message) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == wanted
        else {
            return .draft("the Messages window lost focus before Return could be pressed")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.postToPid(pid)  // Return
        }

        // Messages empties the box once the text is on its way.
        let sentBy = Date().addingTimeInterval(3)
        while Date() < sentBy {
            Thread.sleep(forTimeInterval: 0.2)
            let left = (LiveBridge.value(message) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if left.isEmpty { return .sent }
        }
        return .draft("Return was pressed but the text is still in the message box")
    }

    private func launchMessages() -> NSRunningApplication? {
        _ = runProcess("/usr/bin/open", ["-g", "-a", "Messages"], input: "", timeout: 20)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first {
                return app
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    private static func bringBack(_ previous: NSRunningApplication?, unless messages: NSRunningApplication) {
        guard let previous = previous, previous.processIdentifier != messages.processIdentifier,
              let bundle = previous.bundleIdentifier
        else { return }
        // Messages can take focus back while it finishes its own activation, so
        // check the switch stuck.
        for _ in 0..<4 {
            _ = runProcess("/usr/bin/open", ["-b", bundle], input: "", timeout: 10)
            Thread.sleep(forTimeInterval: 0.4)
            if previous.isActive { return }
        }
    }

    // MARK: Reading the Messages window

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func value(_ element: AXUIElement) -> String? {
        attribute(element, kAXValueAttribute) as? String
    }

    private static func isFocused(_ element: AXUIElement, in pid: pid_t) -> Bool {
        guard let focused = attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) else { return false }
        return CFEqual(focused, element)
    }

    /// The new-message fields in Messages' front window, and the recipient tokens.
    private static func draft(in pid: pid_t) -> (message: AXUIElement, recipients: [String])? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 3)
        guard let window = (attribute(app, kAXFocusedWindowAttribute) ?? attribute(app, kAXMainWindowAttribute))
        else { return nil }
        var fields: [String: AXUIElement] = [:]
        var budget = 4000
        collect(window as! AXUIElement, into: &fields, budget: &budget)
        guard let to = fields["To:"], let message = fields["Message"] else { return nil }
        return (message, tokens(in: to))
    }

    private static func collect(_ element: AXUIElement, into fields: inout [String: AXUIElement], budget: inout Int) {
        if budget <= 0 || fields.count == 2 { return }
        budget -= 1
        if attribute(element, kAXRoleAttribute) as? String == kAXTextFieldRole,
           let label = attribute(element, kAXDescriptionAttribute) as? String,
           label == "To:" || label == "Message", fields[label] == nil {
            fields[label] = element
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            collect(child, into: &fields, budget: &budget)
        }
    }

    /// Each recipient in the To field is an attachment character whose element
    /// describes the person ("+1 (555) 555-0123, +15555550123").
    private static func tokens(in field: AXUIElement) -> [String] {
        let count = (attribute(field, kAXNumberOfCharactersAttribute) as? Int) ?? 0
        guard count > 0 else { return [] }
        var range = CFRange(location: 0, length: count)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return [] }
        var out: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            field, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &out) == .success,
            let text = out as? NSAttributedString
        else { return [] }
        var labels: [String] = []
        text.enumerateAttribute(
            NSAttributedString.Key(kAXAttachmentTextAttribute.takeUnretainedValue() as String),
            in: NSRange(location: 0, length: text.length)
        ) { value, _, _ in
            guard let value = value, CFGetTypeID(value as CFTypeRef) == AXUIElementGetTypeID() else { return }
            let token = value as! AXUIElement
            if let label = attribute(token, kAXDescriptionAttribute) as? String, !label.isEmpty {
                labels.append(label)
            }
        }
        return labels
    }
}
