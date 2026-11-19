import Foundation

/// An app that can run local MCP servers, and how to add iMessage MCP to it.
public struct Client {
    public enum Format {
        /// A JSON file with servers under `key`. `typed` adds `"type": "stdio"` (VS Code wants it).
        case json(key: String, typed: Bool)
        /// Codex's `~/.codex/config.toml`.
        case codexTOML
        /// Claude Code, through its own `claude mcp` command (it rewrites ~/.claude.json constantly).
        case claudeCode(cli: String)
    }

    public let name: String
    public let configPath: String
    public let format: Format
    /// Restart hint shown after connecting.
    public let restart: String

    public init(name: String, configPath: String, format: Format, restart: String) {
        self.name = name
        self.configPath = configPath
        self.format = format
        self.restart = restart
    }
}

public enum ClientChange: Equatable {
    case added, updated, unchanged, removed, absent
    case failed(String)
}

public enum Clients {
    public static let serverName = "imessage"

    /// $HOME first, like the `claude` command and other CLIs, so setup and those tools agree.
    public static var home: String { ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory() }

    /// Every client we know how to connect that looks installed for this user.
    public static func installed(home: String = Clients.home, fileManager: FileManager = .default) -> [Client] {
        func exists(_ path: String) -> Bool { fileManager.fileExists(atPath: path) }
        var found: [Client] = []
        let support = home + "/Library/Application Support"
        if exists(support + "/Claude") || exists("/Applications/Claude.app") {
            found.append(Client(
                name: "Claude", configPath: support + "/Claude/claude_desktop_config.json",
                format: .json(key: "mcpServers", typed: false), restart: "quit with Cmd+Q and reopen"))
        }
        let claudeCLI = [home + "/.local/bin/claude", home + "/.claude/local/claude",
                         "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].first(where: exists)
        if let cli = claudeCLI {
            found.append(Client(
                name: "Claude Code", configPath: home + "/.claude.json",
                format: .claudeCode(cli: cli), restart: "start a new session"))
        }
        if exists(home + "/.codex") {
            found.append(Client(
                name: "Codex", configPath: home + "/.codex/config.toml",
                format: .codexTOML, restart: "start a new session"))
        }
        if exists(home + "/.cursor") {
            found.append(Client(
                name: "Cursor", configPath: home + "/.cursor/mcp.json",
                format: .json(key: "mcpServers", typed: false), restart: "restart Cursor"))
        }
        if exists(support + "/Code/User") {
            found.append(Client(
                name: "VS Code", configPath: support + "/Code/User/mcp.json",
                format: .json(key: "servers", typed: true), restart: "restart VS Code"))
        }
        if exists(home + "/.codeium/windsurf") {
            found.append(Client(
                name: "Windsurf", configPath: home + "/.codeium/windsurf/mcp_config.json",
                format: .json(key: "mcpServers", typed: false), restart: "restart Windsurf"))
        }
        if exists(home + "/.gemini") {
            found.append(Client(
                name: "Gemini CLI", configPath: home + "/.gemini/settings.json",
                format: .json(key: "mcpServers", typed: false), restart: "start a new session"))
        }
        if exists(home + "/.lmstudio") {
            found.append(Client(
                name: "LM Studio", configPath: home + "/.lmstudio/mcp.json",
                format: .json(key: "mcpServers", typed: false), restart: "restart LM Studio"))
        }
        return found
    }

    /// Points `client` at `executable`. Never throws: one broken config must not stop the others.
    public static func register(_ client: Client, executable: String) -> ClientChange {
        do {
            switch client.format {
            case let .json(key, typed):
                return try registerJSON(path: client.configPath, key: key, typed: typed, executable: executable)
            case .codexTOML:
                return try registerTOML(path: client.configPath, executable: executable)
            case let .claudeCode(cli):
                return registerClaudeCode(cli: cli, configPath: client.configPath, executable: executable)
            }
        } catch {
            return .failed((error as? ToolError)?.message ?? error.localizedDescription)
        }
    }

    public static func unregister(_ client: Client) -> ClientChange {
        do {
            switch client.format {
            case let .json(key, _):
                return try unregisterJSON(path: client.configPath, key: key)
            case .codexTOML:
                return try unregisterTOML(path: client.configPath)
            case let .claudeCode(cli):
                guard claudeCodeCommand(configPath: client.configPath) != nil else { return .absent }
                let result = runProcess(cli, ["mcp", "remove", "--scope", "user", serverName], input: "", timeout: 30)
                return result.status == 0 ? .removed : .failed(result.output)
            }
        } catch {
            return .failed((error as? ToolError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: JSON clients

    static func readJSON(_ path: String) throws -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Never overwrite a file we cannot read back (it may have comments, for example).
            throw ToolError("\(path) is not plain JSON, so it was left alone.")
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

    static func registerJSON(path: String, key: String, typed: Bool, executable: String) throws -> ClientChange {
        var json = try readJSON(path)
        var servers = (json[key] as? [String: Any]) ?? [:]
        let existing = servers[serverName] as? [String: Any]
        if let existing, existing["command"] as? String == executable, ((existing["args"] as? [Any]) ?? []).isEmpty {
            return .unchanged
        }
        var entry: [String: Any] = ["command": executable, "args": [String]()]
        if typed { entry["type"] = "stdio" }
        servers[serverName] = entry
        json[key] = servers
        backUp(path)
        try writeJSON(json, to: path)
        return existing == nil ? .added : .updated
    }

    static func unregisterJSON(path: String, key: String) throws -> ClientChange {
        var json = try readJSON(path)
        guard var servers = json[key] as? [String: Any], servers[serverName] != nil else { return .absent }
        servers[serverName] = nil
        json[key] = servers.isEmpty ? nil : servers
        backUp(path)
        try writeJSON(json, to: path)
        return .removed
    }

    // MARK: Codex

    static let tomlHeader = "[mcp_servers.\(serverName)]"

    static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The file's lines with our table (and any `[mcp_servers.imessage.*]` subtables) cut out,
    /// plus what was cut. Edits by line so the rest of the user's file stays exactly as it was.
    static func splitTOML(_ text: String) -> (kept: [String], ours: [String]) {
        var kept: [String] = [], ours: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inside = trimmed == tomlHeader || trimmed.hasPrefix("[mcp_servers.\(serverName).")
            }
            if inside { ours.append(line) } else { kept.append(line) }
        }
        return (kept, ours)
    }

    static func registerTOML(path: String, executable: String) throws -> ClientChange {
        let text = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let (kept, ours) = splitTOML(text)
        let commandLine = "command = " + tomlString(executable)
        if ours.contains(where: { $0.trimmingCharacters(in: .whitespaces) == commandLine }) { return .unchanged }
        var body = kept.joined(separator: "\n")
        while body.hasSuffix("\n\n") { body.removeLast() }
        if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
        if !body.isEmpty { body += "\n" }
        body += [tomlHeader, commandLine, "args = []", ""].joined(separator: "\n")
        backUp(path)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return ours.isEmpty ? .added : .updated
    }

    static func unregisterTOML(path: String) throws -> ClientChange {
        guard let data = FileManager.default.contents(atPath: path) else { return .absent }
        let (kept, ours) = splitTOML(String(decoding: data, as: UTF8.self))
        guard !ours.isEmpty else { return .absent }
        var body = kept.joined(separator: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        if !body.isEmpty { body += "\n" }
        backUp(path)
        try Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        return .removed
    }

    // MARK: Claude Code

    static func claudeCodeCommand(configPath: String) -> String? {
        guard let json = try? readJSON(configPath),
              let entry = (json["mcpServers"] as? [String: Any])?[serverName] as? [String: Any]
        else { return nil }
        return entry["command"] as? String ?? ""
    }

    static func registerClaudeCode(cli: String, configPath: String, executable: String) -> ClientChange {
        let existing = claudeCodeCommand(configPath: configPath)
        if existing == executable { return .unchanged }
        if existing != nil {
            _ = runProcess(cli, ["mcp", "remove", "--scope", "user", serverName], input: "", timeout: 30)
        }
        let result = runProcess(
            cli, ["mcp", "add", "--scope", "user", serverName, "--", executable], input: "", timeout: 30)
        guard result.status == 0 else { return .failed(result.output) }
        return existing == nil ? .added : .updated
    }
}
