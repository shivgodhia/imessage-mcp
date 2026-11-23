import AppKit
import Foundation

/// Connecting iMessage MCP to the Claude Mac app.
public enum Setup {
    public static let serverName = "imessage"
    public static let fullDiskAccessURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    public static var claudeConfigPath: String {
        NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    static func readClaudeConfig(_ path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Never overwrite a file we cannot read back.
            throw ToolError("The Claude config at \(path) is not valid JSON, so it was left alone.")
        }
        return json
    }

    static func backUp(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        try? FileManager.default.copyItem(atPath: path, toPath: path + ".bak-" + formatter.string(from: Date()))
    }

    /// Points the Claude app at this executable. Returns true if the config changed.
    @discardableResult
    public static func register(executable: String, claudeConfig: String? = nil) throws -> Bool {
        let path = claudeConfig ?? claudeConfigPath
        var json = try readClaudeConfig(path)
        var servers = (json["mcpServers"] as? [String: Any]) ?? [:]
        if let existing = servers[serverName] as? [String: Any],
           existing["command"] as? String == executable,
           ((existing["args"] as? [Any]) ?? []).isEmpty {
            return false
        }
        servers[serverName] = ["command": executable, "args": [String]()] as [String: Any]
        json["mcpServers"] = servers
        backUp(path)
        try writeJSON(json, to: path)
        return true
    }

    /// Removes this server from the Claude app's config. Returns true if it was there.
    @discardableResult
    public static func unregister(claudeConfig: String? = nil) throws -> Bool {
        let path = claudeConfig ?? claudeConfigPath
        var json = try readClaudeConfig(path)
        guard var servers = json["mcpServers"] as? [String: Any], servers[serverName] != nil else {
            return false
        }
        servers[serverName] = nil
        json["mcpServers"] = servers.isEmpty ? nil : servers
        backUp(path)
        try writeJSON(json, to: path)
        return true
    }

    /// Versions before 1.0 kept a Python server in ~/.local/share/imessage-mcp.
    public static func removeLegacyInstall() {
        let directory = NSHomeDirectory() + "/.local/share/imessage-mcp"
        for name in ["server.py", "app.built-for", "imessage-mcp", "imessage-mcp.built-for", "__pycache__"] {
            try? FileManager.default.removeItem(atPath: directory + "/" + name)
        }
        if let rest = try? FileManager.default.contentsOfDirectory(atPath: directory), rest.isEmpty {
            try? FileManager.default.removeItem(atPath: directory)
        }
    }

    public static func isInApplications(_ bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    public static func executablePath() -> String {
        (Bundle.main.executableURL?.resolvingSymlinksInPath().path) ?? CommandLine.arguments[0]
    }

    private static func alert(_ title: String, _ body: String, buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        for button in buttons { alert.addButton(withTitle: button) }
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    /// What happens when the app is double-clicked: connect to Claude and say what is left.
    public static func runInteractive(server: Server) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        guard isInApplications(Bundle.main.bundlePath) else {
            _ = alert(
                "Move iMessage MCP to Applications first",
                "Drag iMessage MCP into your Applications folder, then open it from there.",
                buttons: ["OK"])
            exit(0)
        }
        do {
            try register(executable: executablePath())
            try Config.createDefaultIfMissing(server.environment.configPath)
            removeLegacyInstall()
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            _ = alert("iMessage MCP could not finish setting up", message, buttons: ["OK"])
            exit(1)
        }

        if (try? server.messageCount()) != nil {
            _ = alert(
                "iMessage MCP is ready",
                "Quit Claude with Cmd+Q and reopen it, then ask Claude about your texts.\n\n"
                    + "The first time Claude sends a text, macOS asks whether iMessage MCP may "
                    + "control Messages. Click Allow.\n\n"
                    + "Optional: switch on iMessage MCP under Privacy & Security > Accessibility "
                    + "so Claude can start new group chats without you pressing Return.\n\n"
                    + "Claude asks before it sends anything.",
                buttons: ["Done"])
        } else {
            let choice = alert(
                "One switch left",
                "iMessage MCP is now connected to the Claude app. macOS needs your permission "
                    + "before it can read your messages:\n\n"
                    + "1. Click Open Settings and switch on iMessage MCP under Full Disk Access.\n"
                    + "2. Quit Claude with Cmd+Q and reopen it.\n\n"
                    + "Everything stays on this Mac. Claude asks before it sends anything.",
                buttons: ["Open Settings", "Later"])
            if choice == 0, let url = URL(string: fullDiskAccessURL) {
                NSWorkspace.shared.open(url)
            }
        }
        exit(0)
    }
}
