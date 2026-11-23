import AppKit
import Foundation

/// Connecting iMessage MCP to the AI apps on this Mac.
public enum Setup {
    public static let serverName = Clients.serverName
    public static let fullDiskAccessURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    public struct Result {
        public let client: Client
        public let change: ClientChange
    }

    /// Adds this executable to every installed MCP client.
    public static func registerAll(executable: String, home: String = Clients.home) -> [Result] {
        Clients.installed(home: home).map { Result(client: $0, change: Clients.register($0, executable: executable)) }
    }

    public static func unregisterAll(home: String = Clients.home) -> [Result] {
        Clients.installed(home: home).map { Result(client: $0, change: Clients.unregister($0)) }
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

    /// What happens when the app is double-clicked: connect the AI apps and say what is left.
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
        let results = registerAll(executable: executablePath())
        do {
            try Config.createDefaultIfMissing(server.environment.configPath)
            removeLegacyInstall()
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            _ = alert("iMessage MCP could not finish setting up", message, buttons: ["OK"])
            exit(1)
        }
        let connected = results.filter { if case .failed = $0.change { return false }; return true }
        let failed = results.compactMap { result -> String? in
            if case let .failed(why) = result.change { return "\(result.client.name): \(why)" }
            return nil
        }
        var connectedText: String
        if connected.isEmpty {
            connectedText = "No AI app was found to connect automatically. Add this to your app's MCP "
                + "servers as a local (stdio) server:\n\n\(executablePath())"
        } else {
            connectedText = "Connected to " + connected.map(\.client.name).joined(separator: ", ")
                + ". Restart them to load it."
        }
        if !failed.isEmpty { connectedText += "\n\nNot connected:\n" + failed.joined(separator: "\n") }

        if (try? server.messageCount()) != nil {
            _ = alert(
                "iMessage MCP is ready",
                connectedText + "\n\nThe first time a text is sent, macOS asks whether iMessage MCP may "
                    + "control Messages. Click Allow.\n\n"
                    + "Optional: switch on iMessage MCP under Privacy & Security > Accessibility "
                    + "so new group chats can be sent without you pressing Return.",
                buttons: ["Done"])
        } else {
            let choice = alert(
                "One switch left",
                connectedText + "\n\nmacOS needs your permission before iMessage MCP can read your "
                    + "messages. Click Open Settings and switch on iMessage MCP under Full Disk Access. "
                    + "That one switch covers every app above.\n\nEverything stays on this Mac.",
                buttons: ["Open Settings", "Later"])
            if choice == 0, let url = URL(string: fullDiskAccessURL) {
                NSWorkspace.shared.open(url)
            }
        }
        exit(0)
    }
}
