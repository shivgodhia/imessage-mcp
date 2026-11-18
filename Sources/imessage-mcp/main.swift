import Darwin
import Foundation
import IMessageMCPCore

let usage = """
    iMessage MCP \(version): lets Claude read and send your texts, locally.

    Usage:
      imessage-mcp                 serve MCP over stdin/stdout (how the Claude app runs it)
      imessage-mcp setup           connect to the Claude app and open Full Disk Access settings
      imessage-mcp setup --no-open same, without opening System Settings
      imessage-mcp check           show options and whether the Messages database can be read
      imessage-mcp call <tool> '<json arguments>'
      imessage-mcp uninstall       disconnect from the Claude app
      imessage-mcp version

    Tools: list_chats, read_chat, search_messages, new_messages, send_message, get_attachment
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

/// True when something is feeding us requests, which is how an MCP client starts a server.
func stdinIsPipe() -> Bool {
    var info = stat()
    guard fstat(STDIN_FILENO, &info) == 0 else { return false }
    let kind = info.st_mode & S_IFMT
    return kind == S_IFIFO || kind == S_IFSOCK
}

let bridge = LiveBridge()
// Shortens how long the confirmation dialog waits. It can only make "not sent" happen sooner.
if let seconds = ProcessInfo.processInfo.environment["IMESSAGE_MCP_CONFIRM_TIMEOUT"].flatMap(Double.init), seconds > 0 {
    bridge.confirmTimeout = min(seconds, bridge.confirmTimeout)
}
let server = Server(environment: .live(), bridge: bridge)
var arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
let command = arguments.isEmpty ? nil : arguments.removeFirst()

switch command {
case nil:
    if stdinIsPipe() {
        LiveBridge.runOffMainThread { server.serve() }
    } else if isatty(STDIN_FILENO) != 0 {
        print(usage)
    } else {
        Setup.runInteractive(server: server)  // double-clicked in Finder
    }

case "setup":
    do {
        let executable = Setup.executablePath()
        let changed = try Setup.register(executable: executable)
        try Config.createDefaultIfMissing(server.environment.configPath)
        Setup.removeLegacyInstall()
        print("iMessage MCP \(version)")
        print("  app:     \(executable)")
        print("  options: \(server.environment.configPath)")
        print("  Claude:  \(changed ? "registered" : "already registered") as \"\(Setup.serverName)\"")
        print("")
        print("Two steps left:")
        print("  1. In System Settings > Privacy & Security > Full Disk Access, switch on iMessage MCP.")
        print("  2. Quit Claude completely (Cmd+Q) and reopen it.")
        print("")
        print("The first time Claude sends a text, macOS asks whether iMessage MCP may")
        print("control Messages. Click Allow.")
        if !arguments.contains("--no-open") {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [Setup.fullDiskAccessURL]
            try? open.run()
        }
    } catch {
        fail((error as? ToolError)?.message ?? error.localizedDescription)
    }

case "uninstall":
    do {
        let removed = try Setup.unregister()
        print(removed ? "Disconnected from the Claude app." : "The Claude app was not using iMessage MCP.")
        print("Your options in \(server.environment.configPath) were kept.")
        print("To finish, quit Claude and move iMessage MCP to the Trash.")
    } catch {
        fail((error as? ToolError)?.message ?? error.localizedDescription)
    }

case "check":
    let path = server.environment.configPath
    do {
        let config = try Config.load(path)
        let found = FileManager.default.fileExists(atPath: path) ? "found" : "defaults"
        print("iMessage MCP \(version)")
        print("config: \(path) (\(found))")
        print("  allowed_chats: \(config.allowedChats.isEmpty ? "all conversations" : config.allowedChats.joined(separator: ", "))")
        print("  send: \(config.send)")
        print("  always_allow_send: \(config.alwaysAllowSend.isEmpty ? "nobody" : config.alwaysAllowSend.joined(separator: ", "))")
        let counts = try server.messageCount()
        print("messages database: ok, \(counts.messages) messages, \(counts.conversations) conversations")
        print("contacts: \(server.contactCount()) numbers and emails with names")
    } catch let error as ToolError {
        print("messages database: FAILED\n  \(error.message)")
        exit(1)
    } catch {
        fail(error.localizedDescription)
    }

case "call":
    guard let tool = arguments.first else { fail("usage: imessage-mcp call <tool> '<json arguments>'") }
    var toolArguments: [String: Any] = [:]
    if arguments.count > 1 {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(arguments[1].utf8)) as? [String: Any] else {
            fail("arguments must be a JSON object, like '{\"limit\": 5}'")
        }
        toolArguments = parsed
    }
    // Off the main thread so the confirmation dialog stays responsive.
    LiveBridge.runOffMainThread {
        do {
            for item in try server.call(tool, toolArguments, fromShell: true) {
                if let text = item["text"] as? String {
                    print(text)
                } else if let data = item["data"] as? String {
                    print("<image, \(data.count) base64 characters>")
                }
            }
        } catch let error as ToolError {
            fail(error.message)
        } catch {
            fail("\(error)")
        }
    }

case "version", "--version", "-v":
    print(version)

default:
    print(usage)
}
