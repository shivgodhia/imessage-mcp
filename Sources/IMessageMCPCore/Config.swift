import Foundation

public let version = "1.0.0"
public let bundleIdentifier = "com.shivgodhia.imessage-mcp"

/// Something the caller did wrong or that the Mac refused. Shown to Claude as the tool's error.
public struct ToolError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Where the server finds things. Tests point these at throwaway files.
public struct Environment {
    public var chatDB: String
    public var configPath: String
    public var addressBooks: () -> [String]

    public init(chatDB: String, configPath: String, addressBooks: @escaping () -> [String]) {
        self.chatDB = chatDB
        self.configPath = configPath
        self.addressBooks = addressBooks
    }

    public static func live() -> Environment {
        let home = NSHomeDirectory()
        let overrides = ProcessInfo.processInfo.environment
        return Environment(
            chatDB: overrides["IMESSAGE_DB"] ?? home + "/Library/Messages/chat.db",
            configPath: overrides["IMESSAGE_MCP_CONFIG"] ?? home + "/.config/imessage-mcp/config.json",
            addressBooks: {
                let root = home + "/Library/Application Support/AddressBook"
                var paths = [root + "/AddressBook-v22.abcddb"]
                let sources = (try? FileManager.default.contentsOfDirectory(atPath: root + "/Sources")) ?? []
                for source in sources.sorted() {
                    paths.append(root + "/Sources/" + source + "/AddressBook-v22.abcddb")
                }
                return paths.filter { FileManager.default.fileExists(atPath: $0) }
            }
        )
    }
}

/// The user's options, from ~/.config/imessage-mcp/config.json. Read on every call.
public struct Config {
    /// Empty = every conversation is visible. Otherwise only these can be listed,
    /// read, searched or sent to.
    public var allowedChats: [String] = []
    /// "confirm": show a dialog with the recipient and exact text, send only on a click.
    /// "allow": leave the asking to the MCP client, the way connectors like Gmail work.
    /// "off": never send.
    public var send = "confirm"
    /// Conversations that skip the dialog. The dialog's Always Allow button adds one.
    public var alwaysAllowSend: [String] = []

    static func strings(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return [] }
        return list.map { ($0 as? String) ?? "\($0)" }
    }

    public static func load(_ path: String) throws -> Config {
        var config = Config()
        guard FileManager.default.fileExists(atPath: path) else { return config }
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw ToolError("Could not read config \(path): it is not valid JSON.")
        }
        config.allowedChats = strings(json["allowed_chats"])
        config.alwaysAllowSend = strings(json["always_allow_send"])
        if let send = json["send"] as? String { config.send = send }
        return config
    }

    /// Adds a conversation to always_allow_send, keeping the rest of the file.
    public static func rememberAlwaysAllow(_ entry: String, path: String) throws {
        var json: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var entries = strings(json["always_allow_send"])
        if !entries.contains(entry) { entries.append(entry) }
        json["always_allow_send"] = entries
        try writeJSON(json, to: path)
    }

    public static func createDefaultIfMissing(_ path: String) throws {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let json: [String: Any] = ["allowed_chats": [String](), "send": "confirm", "always_allow_send": [String]()]
        try writeJSON(json, to: path)
    }
}

func writeJSON(_ json: [String: Any], to path: String, mode: Int = 0o600) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    data.append(0x0A)
    try data.write(to: url, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
}
