import Darwin
import Foundation
import IMessageMCPCore

let usage = """
    iMessage MCP \(version): lets AI agents on this Mac read and send your texts, locally.

    Usage:
      imessage-mcp                 serve MCP over stdin/stdout (how AI apps run it)
      imessage-mcp setup           connect every AI app found on this Mac, open Full Disk Access
      imessage-mcp setup --no-open same, without opening System Settings
      imessage-mcp check           show options and whether the Messages database can be read
      imessage-mcp call <tool> '<json arguments>'
      imessage-mcp call send_message '<json>' --yes   send without the "Send? [y/N]" question
      imessage-mcp uninstall       disconnect from every AI app
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
// Shortens how long the optional confirmation dialog (send: "confirm") waits. It can only make "not sent" happen sooner.
if let seconds = ProcessInfo.processInfo.environment["IMESSAGE_MCP_CONFIRM_TIMEOUT"].flatMap(Double.init), seconds > 0 {
    bridge.confirmTimeout = min(seconds, bridge.confirmTimeout)
}
let server = Server(environment: .live(), bridge: bridge)
var arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
let command = arguments.isEmpty ? nil : arguments.removeFirst()

// Before anything touches Messages: make macOS check permissions against this app, not
// whichever editor, terminal or agent started it. Not for a Finder double-click, which already is.
if command != nil || stdinIsPipe() || isatty(STDIN_FILENO) != 0 {
    Responsibility.becomeResponsibleProcess(executable: Setup.executablePath())
}

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
    let executable = Setup.executablePath()
    let results = Setup.registerAll(executable: executable)
    do {
        try Config.createDefaultIfMissing(server.environment.configPath)
    } catch {
        fail((error as? ToolError)?.message ?? error.localizedDescription)
    }
    Setup.removeLegacyInstall()
    print("iMessage MCP \(version)")
    print("  app:     \(executable)")
    print("  options: \(server.environment.configPath)")
    print("")
    if results.isEmpty {
        print("No AI app found to connect. Add it to yours as a local (stdio) MCP server:")
        print("  command: \(executable)")
    }
    for result in results {
        let state: String
        switch result.change {
        case .added: state = "connected, \(result.client.restart)"
        case .updated: state = "updated, \(result.client.restart)"
        case .unchanged: state = "already connected"
        case let .failed(why): state = "NOT connected: \(why)"
        case .removed, .absent: state = ""
        }
        print("  \(result.client.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(state)")
    }
    print("")
    print("Last step: in System Settings > Privacy & Security > Full Disk Access, switch on")
    print("iMessage MCP. That one switch covers every app above. The first time a text is")
    print("sent, macOS asks whether iMessage MCP may control Messages. Click Allow.")
    print("")
    print("Optional: switch on iMessage MCP under Privacy & Security > Accessibility too, so")
    print("a new group chat can be sent without you pressing Return in Messages.")
    if !arguments.contains("--no-open") {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [Setup.fullDiskAccessURL]
        try? open.run()
    }

case "uninstall":
    for result in Setup.unregisterAll() {
        switch result.change {
        case .removed: print("  \(result.client.name): disconnected")
        case let .failed(why): print("  \(result.client.name): could not disconnect: \(why)")
        default: break
        }
    }
    print("Your options in \(server.environment.configPath) were kept.")
    print("To finish, restart those apps and move iMessage MCP to the Trash.")

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
        print(LiveBridge.accessibilityAllowed()
            ? "accessibility: on, new group chats are sent automatically"
            : "accessibility: off, new group chats open as a draft for you to send")
    } catch let error as ToolError {
        print("messages database: FAILED\n  \(error.message)")
        exit(1)
    } catch {
        fail(error.localizedDescription)
    }

case "call":
    let yes = arguments.contains("--yes") || arguments.contains("-y")
    arguments.removeAll { $0 == "--yes" || $0 == "-y" }
    guard let tool = arguments.first else { fail("usage: imessage-mcp call <tool> '<json arguments>'") }
    var toolArguments: [String: Any] = [:]
    if arguments.count > 1 {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(arguments[1].utf8)) as? [String: Any] else {
            fail("arguments must be a JSON object, like '{\"limit\": 5}'")
        }
        toolArguments = parsed
    }
    // Nobody has approved a send typed into a shell, so ask right here.
    let interactive = isatty(STDIN_FILENO) != 0
    if tool == "send_message" && !yes && !interactive {
        fail("Not sent: there is no terminal to ask in. Add --yes to send without asking.")
    }
    do {
        let content = try server.call(tool, toolArguments) { text, recipient in
            if yes { return true }
            print("To: \(recipient)\n\n\(text)\n\nSend? [y/N] ", terminator: "")
            let answer = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return answer == "y" || answer == "yes"
        }
        for item in content {
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

case "version", "--version", "-v":
    print(version)

default:
    print(usage)
}
