import Foundation
import SQLite3
import XCTest

@testable import IMessageMCPCore

/// Stands in for the screen and the Messages app, and records what was asked of it.
final class FakeBridge: SystemBridge {
    var confirmAnswers: [ConfirmAnswer] = []
    var sendResults: [(ok: Bool, output: String)] = []
    var confirms: [(text: String, recipient: String)] = []
    var sends: [(text: String, target: String, mode: String)] = []

    func confirm(text: String, recipient: String) -> ConfirmAnswer {
        confirms.append((text, recipient))
        return confirmAnswers.isEmpty ? .dontSend : confirmAnswers.removeFirst()
    }

    func send(text: String, target: String, mode: String) -> (ok: Bool, output: String) {
        sends.append((text, target, mode))
        return sendResults.isEmpty ? (true, "") : sendResults.removeFirst()
    }
}

/// A minimal typedstream blob shaped like the ones Messages writes.
func body(_ text: String) -> Data {
    let raw = Array(text.utf8)
    var data = Data([0x04, 0x0B])
    data.append(contentsOf: Array("streamtyped".utf8))
    data.append(contentsOf: [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12])
    data.append(contentsOf: Array("NSAttributedString".utf8))
    data.append(contentsOf: [0x00, 0x84, 0x84, 0x08])
    data.append(contentsOf: Array("NSObject".utf8))
    data.append(contentsOf: [0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08])
    data.append(contentsOf: Array("NSString".utf8))
    data.append(contentsOf: [0x01, 0x94, 0x84, 0x01, 0x2B])
    if raw.count < 0x80 {
        data.append(UInt8(raw.count))
    } else {
        data.append(contentsOf: [0x81, UInt8(raw.count & 0xFF), UInt8(raw.count >> 8)])
    }
    data.append(contentsOf: raw)
    data.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x49, 0x01])
    return data
}

/// Tests run against a throwaway chat.db, never the real one.
class Fixture: XCTestCase {
    var directory: URL!
    var server: Server!
    var bridge: FakeBridge!
    var dbPath: String { directory.appendingPathComponent("chat.db").path }
    var configPath: String { directory.appendingPathComponent("config.json").path }

    static let schema = """
        create table chat (ROWID integer primary key, guid text, style integer,
            chat_identifier text, display_name text);
        create table handle (ROWID integer primary key, id text);
        create table chat_handle_join (chat_id integer, handle_id integer);
        create table message (ROWID integer primary key, text text, attributedBody blob,
            date integer, is_from_me integer default 0, handle_id integer default 0,
            cache_has_attachments integer default 0, associated_message_type integer default 0,
            item_type integer default 0, is_read integer default 0,
            date_retracted integer default 0, date_edited integer default 0,
            error integer default 0, is_sent integer default 0,
            is_delivered integer default 0, service text);
        create table chat_message_join (chat_id integer, message_id integer, message_date integer);
        create table attachment (ROWID integer primary key, filename text,
            transfer_name text, mime_type text, total_bytes integer);
        create table message_attachment_join (message_id integer, attachment_id integer);
        insert into chat values (1, 'iMessage;-;+15551230001', 45, '+15551230001', null);
        insert into chat values (2, 'SMS;-;+15551230001', 45, '+15551230001', null);
        insert into chat values (3, 'iMessage;+;chat777', 43, 'chat777', 'Flat hunt');
        insert into chat values (4, 'iMessage;-;landlord@example.com', 45, 'landlord@example.com', null);
        insert into handle values (1, '+15551230001');
        insert into handle values (2, '+15551230002');
        insert into handle values (3, 'landlord@example.com');
        insert into chat_handle_join values (1, 1), (2, 1), (3, 1), (3, 2), (4, 3);
        """

    func execute(_ sql: String) {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
        sqlite3_close(handle)
    }

    func insertMessage(_ rowid: Int, text: String?, blob: Data?, minutesAgo: Double, mine: Bool, handle: Int, chat: Int, read: Bool) {
        let date = appleNanoseconds(secondsAgo: minutesAgo * 60)
        var db: OpaquePointer?
        sqlite3_open(dbPath, &db)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(
            db,
            "insert into message (ROWID, text, attributedBody, date, is_from_me, handle_id, is_read) values (?,?,?,?,?,?,?)",
            -1, &statement, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(statement, 1, Int64(rowid))
        if let text = text { sqlite3_bind_text(statement, 2, text, -1, transient) } else { sqlite3_bind_null(statement, 2) }
        if let blob = blob {
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(blob.count), transient) }
        } else {
            sqlite3_bind_null(statement, 3)
        }
        sqlite3_bind_int64(statement, 4, date)
        sqlite3_bind_int64(statement, 5, mine ? 1 : 0)
        sqlite3_bind_int64(statement, 6, Int64(handle))
        sqlite3_bind_int64(statement, 7, read ? 1 : 0)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        sqlite3_close(db)
        execute("insert into chat_message_join values (\(chat), \(rowid), \(date))")
    }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("imessage-mcp-tests-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        execute(Fixture.schema)
        insertMessage(1, text: "old sms", blob: nil, minutesAgo: 5000, mine: false, handle: 1, chat: 2, read: true)
        insertMessage(2, text: nil, blob: body("Is the flat still available?"), minutesAgo: 30, mine: true, handle: 0, chat: 1, read: true)
        insertMessage(3, text: nil, blob: body("Yes, viewing at 6pm \u{2014} caf\u{E9} next door"), minutesAgo: 20, mine: false, handle: 1, chat: 1, read: false)
        insertMessage(4, text: nil, blob: body(String(repeating: "x", count: 300)), minutesAgo: 10, mine: false, handle: 2, chat: 3, read: false)
        insertMessage(5, text: nil, blob: body("Rent is $3,200"), minutesAgo: 5, mine: false, handle: 3, chat: 4, read: false)
        bridge = FakeBridge()
        server = Server(
            environment: Environment(chatDB: dbPath, configPath: configPath, addressBooks: { [] }),
            bridge: bridge)
        server.sendWait = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func configure(_ json: [String: Any]) {
        try! JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: configPath))
    }

    @discardableResult
    func call(_ tool: String, _ args: [String: Any] = [:], fromShell: Bool = false) throws -> String {
        try server.call(tool, args, fromShell: fromShell).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    func rows(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { $0.range(of: #" \| unread \d"#, options: .regularExpression) != nil }
    }

    func messages(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
    }
}

final class DecodeTests: XCTestCase {
    func testShortLongAndUnicode() {
        for text in ["hi", "caf\u{E9} \u{1F600}", String(repeating: "y", count: 127), String(repeating: "z", count: 128), String(repeating: "w", count: 5000)] {
            XCTAssertEqual(decodeBody(body(text)), text)
        }
    }

    func testGarbage() {
        XCTAssertNil(decodeBody(nil))
        XCTAssertNil(decodeBody(Data("nothing here".utf8)))
        XCTAssertNil(decodeBody(Data("NSString".utf8)))
        XCTAssertNil(decodeBody(Data("NSString".utf8) + Data([0x01, 0x2B])))
    }

    func testNorm() {
        XCTAssertEqual(norm("+1 (555) 123-0001"), norm("5551230001"))
        XCTAssertEqual(norm(" Landlord@Example.com "), "landlord@example.com")
        XCTAssertEqual(norm("chat777"), "chat777")
    }
}

final class ReadTests: Fixture {
    func testListMergesServicesAndCountsUnread() throws {
        let out = try call("list_chats")
        let lines = rows(out)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("landlord@example.com"))
        let phone = lines.first { $0.hasPrefix("+15551230001") }!
        XCTAssertTrue(phone.contains("unread 1"))
        XCTAssertTrue(phone.contains("Them: Yes, viewing at 6pm"))
        XCTAssertTrue(out.contains("group \"Flat hunt\""))
    }

    func testQueryAndUnreadOnly() throws {
        XCTAssertEqual(rows(try call("list_chats", ["query": "flat"])).count, 1)
        execute("update message set is_read = 1 where ROWID = 5")
        XCTAssertEqual(rows(try call("list_chats", ["unread_only": true])).count, 2)
    }

    func testReadChatByLooseNumber() throws {
        let lines = messages(try call("read_chat", ["chat": "(555) 123-0001"]))
        XCTAssertEqual(lines.map { String($0.prefix(3)) }, ["[1]", "[2]", "[3]"])
        XCTAssertTrue(lines[1].contains("Me: Is the flat still available?"))
        XCTAssertTrue(lines[2].contains("(unread)"))
        XCTAssertTrue(lines[2].contains("caf\u{E9}"))
    }

    func testReadChatPaging() throws {
        XCTAssertEqual(messages(try call("read_chat", ["chat": "+15551230001", "after_id": 2])).count, 1)
        let older = try call("read_chat", ["chat": "+15551230001", "before_id": 2])
        XCTAssertTrue(older.contains("old sms"))
        XCTAssertFalse(older.contains("viewing"))
    }

    func testReadChatByGroupName() throws {
        XCTAssertTrue(try call("read_chat", ["chat": "flat hunt"]).contains("xxx"))
    }

    func testDuplicateIdentifierForSameNumberPicksLiveThread() throws {
        execute("insert into chat values (9, 'iMessage;-;tel:+15551230001', 45, 'tel:+15551230001', null)")
        XCTAssertTrue(try call("read_chat", ["chat": "555 123 0001"]).hasPrefix("Conversation +15551230001 "))
    }

    func testUnknownChat() {
        XCTAssertThrowsError(try call("read_chat", ["chat": "nobody"]))
    }

    func testSearch() throws {
        let out = try call("search_messages", ["query": "RENT"])
        XCTAssertTrue(out.contains("Rent is $3,200"))
        XCTAssertTrue(out.contains("{landlord@example.com"))
        XCTAssertTrue(try call("search_messages", ["query": "zzzz"]).contains("No messages"))
    }

    func testNewMessagesCursor() throws {
        let recent = try call("new_messages", ["since_minutes": 60])
        XCTAssertEqual(messages(recent).count, 3)
        XCTAssertTrue(recent.contains("cursor: 5"))
        XCTAssertEqual(messages(try call("new_messages", ["after_id": 4])).count, 1)
        XCTAssertTrue(try call("new_messages", ["after_id": 5]).contains("No new messages"))
    }

    func testNewMessagesLimitKeepsCursorResumable() throws {
        let out = try call("new_messages", ["after_id": 0, "limit": 2])
        XCTAssertTrue(out.contains("cursor: 3"))
        XCTAssertTrue(out.contains("More messages are waiting"))
    }

    func testAttachmentIsListedAndHiddenOutsideAllowlist() throws {
        execute("insert into attachment values (7, '/nonexistent/photo.heic', 'photo.heic', 'image/heic', 1234)")
        execute("insert into message_attachment_join values (5, 7)")
        execute("update message set cache_has_attachments = 1 where ROWID = 5")
        XCTAssertTrue(try call("read_chat", ["chat": "landlord@example.com"]).contains("[attachment 7: photo.heic, image/heic]"))
        XCTAssertTrue(try call("get_attachment", ["attachment_id": 7]).contains("not downloaded"))
        configure(["allowed_chats": ["Flat hunt"]])
        XCTAssertThrowsError(try call("get_attachment", ["attachment_id": 7]))
    }
}

final class AllowlistTests: Fixture {
    func testOnlyAllowedChatsAreVisible() throws {
        configure(["allowed_chats": ["landlord@example.com"]])
        XCTAssertEqual(rows(try call("list_chats")).count, 1)
        XCTAssertThrowsError(try call("read_chat", ["chat": "+15551230001"]))
        XCTAssertTrue(try call("search_messages", ["query": "viewing"]).contains("No messages"))
        XCTAssertEqual(messages(try call("new_messages", ["after_id": 0])).count, 1)
    }

    func testAllowByNumberFormatAndGroupName() throws {
        configure(["allowed_chats": ["555-123-0001", "Flat hunt"]])
        let out = try call("list_chats")
        XCTAssertEqual(rows(out).count, 2)
        XCTAssertFalse(out.contains("landlord"))
    }
}

final class SendTests: Fixture {
    let hi: [String: Any] = ["chat": "+15551230001", "text": "hi"]

    func testAsksByDefaultWhenThereIsNoConfig() {
        XCTAssertThrowsError(try call("send_message", hi))
        XCTAssertEqual(bridge.confirms.count, 1)
        XCTAssertEqual(bridge.confirms[0].text, "hi")
        XCTAssertTrue(bridge.confirms[0].recipient.contains("+15551230001"))
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testSendOff() {
        configure(["send": "off"])
        XCTAssertThrowsError(try call("send_message", hi))
        XCTAssertTrue(bridge.confirms.isEmpty)
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testAllowModeSendsToMostRecentChatWithoutDialog() throws {
        configure(["send": "allow"])
        let out = try call("send_message", hi)
        XCTAssertTrue(bridge.confirms.isEmpty)
        XCTAssertEqual(bridge.sends.count, 1)
        XCTAssertEqual(bridge.sends[0].target, "iMessage;-;+15551230001")
        XCTAssertEqual(bridge.sends[0].mode, "chat")
        XCTAssertTrue(out.contains("do not resend"))
    }

    func testReportsSentWhenMessagesRecordsIt() throws {
        configure(["send": "allow"])
        server.sendWait = 2
        final class Recording: SystemBridge {
            let onSend: () -> Void
            init(_ onSend: @escaping () -> Void) { self.onSend = onSend }
            func confirm(text: String, recipient: String) -> ConfirmAnswer { .dontSend }
            func send(text: String, target: String, mode: String) -> (ok: Bool, output: String) {
                onSend()
                return (true, "")
            }
        }
        server.bridge = Recording { [self] in
            insertMessage(6, text: nil, blob: body("hi"), minutesAgo: 0, mine: true, handle: 0, chat: 1, read: true)
            execute("update message set is_sent = 1, service = 'iMessage' where ROWID = 6")
        }
        XCTAssertTrue(try call("send_message", hi).contains("via iMessage (message 6, sent)"))
    }

    func testReportsFailureWhenMessagesRecordsAnError() {
        configure(["send": "allow"])
        server.sendWait = 2
        final class Failing: SystemBridge {
            let onSend: () -> Void
            init(_ onSend: @escaping () -> Void) { self.onSend = onSend }
            func confirm(text: String, recipient: String) -> ConfirmAnswer { .dontSend }
            func send(text: String, target: String, mode: String) -> (ok: Bool, output: String) {
                onSend()
                return (true, "")
            }
        }
        server.bridge = Failing { [self] in
            insertMessage(6, text: nil, blob: body("hi"), minutesAgo: 0, mine: true, handle: 0, chat: 1, read: true)
            execute("update message set error = 22 where ROWID = 6")
        }
        XCTAssertThrowsError(try call("send_message", hi)) { error in
            XCTAssertTrue((error as! ToolError).message.contains("Not Delivered"))
        }
    }

    func testBlockedOutsideAllowlist() {
        configure(["send": "allow", "allowed_chats": ["landlord@example.com"]])
        for chat in ["+15551230001", "+15559990000"] {
            XCTAssertThrowsError(try call("send_message", ["chat": chat, "text": "hi"]))
        }
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testRefusesUnknownName() {
        configure(["send": "allow"])
        XCTAssertThrowsError(try call("send_message", ["chat": "some name", "text": "hi"]))
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testNewNumberStartsAConversation() throws {
        configure(["send": "allow"])
        try call("send_message", ["chat": "+1 555 999 0000", "text": "hi"])
        XCTAssertEqual(bridge.sends[0].target, "+1 555 999 0000")
        XCTAssertEqual(bridge.sends[0].mode, "imessage")
    }

    func testConfirmDeclinedOrTimedOutDoesNotSend() {
        configure(["send": "confirm"])
        for answer in [ConfirmAnswer.dontSend, .timedOut] {
            bridge.confirmAnswers = [answer]
            XCTAssertThrowsError(try call("send_message", hi))
        }
        XCTAssertEqual(bridge.confirms.count, 2)
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testConfirmAcceptedSends() throws {
        configure(["send": "confirm"])
        bridge.confirmAnswers = [.send]
        try call("send_message", hi)
        XCTAssertEqual(bridge.sends.count, 1)
        XCTAssertNil(try Config.load(configPath).alwaysAllowSend.first)
    }

    func testShellSendAlwaysAsksEvenInAllowMode() {
        configure(["send": "allow"])
        XCTAssertThrowsError(try call("send_message", hi, fromShell: true))
        XCTAssertEqual(bridge.confirms.count, 1)
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testAlwaysAllowContactSkipsDialog() throws {
        configure(["send": "confirm", "always_allow_send": ["(555) 123-0001"]])
        let out = try call("send_message", hi)
        XCTAssertTrue(bridge.confirms.isEmpty)
        XCTAssertEqual(bridge.sends.count, 1)
        _ = out
    }

    func testAlwaysAllowIsPerContact() {
        configure(["send": "confirm", "always_allow_send": ["+15551230001"]])
        XCTAssertThrowsError(try call("send_message", ["chat": "landlord@example.com", "text": "hi"]))
        XCTAssertEqual(bridge.confirms.count, 1)
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testAlwaysAllowButtonIsRemembered() throws {
        configure(["send": "confirm", "allowed_chats": [String]()])
        bridge.confirmAnswers = [.alwaysAllow]
        try call("send_message", hi)
        XCTAssertEqual(bridge.confirms.count, 1)
        XCTAssertEqual(bridge.sends.count, 1)
        let saved = try Config.load(configPath)
        XCTAssertEqual(saved.alwaysAllowSend, ["+15551230001"])
        XCTAssertEqual(saved.send, "confirm")
        try call("send_message", hi)
        XCTAssertEqual(bridge.confirms.count, 1)  // not asked the second time
        XCTAssertEqual(bridge.sends.count, 2)
    }

    func testAlwaysAllowDoesNotOverrideOffOrAllowlist() {
        configure(["send": "off", "always_allow_send": ["+15551230001"]])
        XCTAssertThrowsError(try call("send_message", hi))
        configure(["send": "confirm", "allowed_chats": ["landlord@example.com"], "always_allow_send": ["+15551230001"]])
        XCTAssertThrowsError(try call("send_message", hi))
        XCTAssertTrue(bridge.sends.isEmpty)
    }

    func testAutomationDeniedStopsAndExplains() {
        configure(["send": "allow"])
        bridge.sendResults = [(false, "execution error: Not authorized to send Apple events to Messages. (-1743)")]
        XCTAssertThrowsError(try call("send_message", hi)) { error in
            XCTAssertTrue((error as! ToolError).message.contains("Automation"))
        }
        XCTAssertEqual(bridge.sends.count, 1)
    }

    func testTimeoutDoesNotTryASecondRoute() {
        configure(["send": "allow"])
        bridge.sendResults = [(false, "timed out after 60s")]
        XCTAssertThrowsError(try call("send_message", hi)) { error in
            XCTAssertTrue((error as! ToolError).message.contains("click Allow"))
        }
        XCTAssertEqual(bridge.sends.count, 1)
    }

    func testCleanRejectionFallsBackToNextRoute() throws {
        configure(["send": "allow"])
        bridge.sendResults = [(false, "execution error: Can't get chat id. (-1728)")]
        try call("send_message", hi)
        XCTAssertEqual(bridge.sends.count, 2)
        XCTAssertEqual(bridge.sends[1].target, "+15551230001")
        XCTAssertEqual(bridge.sends[1].mode, "imessage")
    }
}

final class ProtocolTests: Fixture {
    func testHandshakeAndErrors() {
        let initialize = server.handle(method: "initialize", params: ["protocolVersion": "2025-03-26"])!
        XCTAssertEqual(initialize["protocolVersion"] as? String, "2025-03-26")
        let tools = server.handle(method: "tools/list", params: [:])!["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 6)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(tools))
        let bad = server.handle(method: "tools/call", params: ["name": "read_chat", "arguments": ["chat": "nobody"]])!
        XCTAssertEqual(bad["isError"] as? Bool, true)
        XCTAssertNil(server.handle(method: "resources/list", params: [:]))
    }

    func testSendIsTheOnlyWriteTool() {
        let tools = server.handle(method: "tools/list", params: [:])!["tools"] as! [[String: Any]]
        let writes = tools.filter { ($0["annotations"] as! [String: Any])["readOnlyHint"] as? Bool == false }
        XCTAssertEqual(writes.map { $0["name"] as! String }, ["send_message"])
    }

    func testBlockedDatabaseExplainsFullDiskAccess() {
        server.environment.chatDB = directory.appendingPathComponent("missing.db").path
        let result = server.handle(method: "tools/call", params: ["name": "list_chats"])!
        let text = (result["content"] as! [[String: Any]])[0]["text"] as! String
        XCTAssertTrue(text.contains("Full Disk Access"))
        XCTAssertEqual(result["isError"] as? Bool, true)
    }
}

final class SetupTests: Fixture {
    var claude: String { directory.appendingPathComponent("claude_desktop_config.json").path }

    func read() -> [String: Any] {
        try! JSONSerialization.jsonObject(with: FileManager.default.contents(atPath: claude)!) as! [String: Any]
    }

    func testRegisterKeepsEverythingElseAndIsIdempotent() throws {
        let original: [String: Any] = [
            "preferences": ["menuBarEnabled": false, "sidebarMode": "chat"],
            "mcpServers": ["other": ["command": "/bin/other", "args": ["x"]]],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: URL(fileURLWithPath: claude))
        XCTAssertTrue(try Setup.register(executable: "/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp", claudeConfig: claude))
        XCTAssertFalse(try Setup.register(executable: "/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp", claudeConfig: claude))
        let json = read()
        let servers = json["mcpServers"] as! [String: Any]
        XCTAssertEqual((servers["imessage"] as! [String: Any])["command"] as? String, "/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp")
        XCTAssertEqual((servers["other"] as! [String: Any])["command"] as? String, "/bin/other")
        let preferences = json["preferences"] as! [String: Any]
        XCTAssertEqual(preferences["menuBarEnabled"] as? Bool, false)
        XCTAssertEqual(preferences["sidebarMode"] as? String, "chat")
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".bak-") }
        XCTAssertEqual(backups.count, 1)
    }

    func testRegisterCreatesAMissingConfig() throws {
        XCTAssertTrue(try Setup.register(executable: "/x/imessage-mcp", claudeConfig: claude))
        XCTAssertNotNil((read()["mcpServers"] as! [String: Any])["imessage"])
    }

    func testUnregister() throws {
        try Setup.register(executable: "/x/imessage-mcp", claudeConfig: claude)
        XCTAssertTrue(try Setup.unregister(claudeConfig: claude))
        XCTAssertNil(read()["mcpServers"])
        XCTAssertFalse(try Setup.unregister(claudeConfig: claude))
    }

    func testUnreadableConfigIsLeftAlone() throws {
        try Data("{not json".utf8).write(to: URL(fileURLWithPath: claude))
        XCTAssertThrowsError(try Setup.register(executable: "/x/imessage-mcp", claudeConfig: claude))
        XCTAssertEqual(String(decoding: FileManager.default.contents(atPath: claude)!, as: UTF8.self), "{not json")
    }

    func testDefaultOptionsAskBeforeSending() throws {
        try Config.createDefaultIfMissing(configPath)
        XCTAssertEqual(try Config.load(configPath).send, "confirm")
    }
}
