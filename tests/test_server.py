"""Tests against a throwaway chat.db, never the real one.

    python3 -m unittest discover -s tests
"""

import json
import os
import re
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import server  # noqa: E402

SCHEMA = """
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
"""


def body(text):
    """A minimal typedstream blob shaped like the ones Messages writes."""
    raw = text.encode()
    if len(raw) < 0x80:
        length = bytes([len(raw)])
    else:
        length = b"\x81" + len(raw).to_bytes(2, "little")
    return (
        b"\x04\x0bstreamtyped\x81\xe8\x03\x84\x01@\x84\x84\x84\x12NSAttributedString"
        b"\x00\x84\x84\x08NSObject\x00\x85\x92\x84\x84\x84\x08NSString\x01\x94\x84\x01+"
        + length + raw + b"\x86\x84\x02iI\x01"
    )


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = os.path.join(self.tmp.name, "chat.db")
        self.cfg = os.path.join(self.tmp.name, "config.json")
        con = sqlite3.connect(self.db)
        con.executescript(SCHEMA)
        now = server.to_apple_ns(datetime.now())
        con.executemany(
            "insert into chat values (?,?,?,?,?)",
            [
                (1, "iMessage;-;+15551230001", 45, "+15551230001", None),
                (2, "SMS;-;+15551230001", 45, "+15551230001", None),
                (3, "iMessage;+;chat777", 43, "chat777", "Flat hunt"),
                (4, "iMessage;-;landlord@example.com", 45, "landlord@example.com", None),
            ],
        )
        con.executemany(
            "insert into handle values (?,?)",
            [(1, "+15551230001"), (2, "+15551230002"), (3, "landlord@example.com")],
        )
        con.executemany(
            "insert into chat_handle_join values (?,?)", [(1, 1), (2, 1), (3, 1), (3, 2), (4, 3)]
        )
        msgs = [
            # rowid, text, body, age in minutes, from_me, handle, chat, is_read
            (1, "old sms", None, 5000, 0, 1, 2, 1),
            (2, None, body("Is the flat still available?"), 30, 1, 0, 1, 1),
            (3, None, body("Yes, viewing at 6pm — café next door"), 20, 0, 1, 1, 0),
            (4, None, body("x" * 300), 10, 0, 2, 3, 0),
            (5, None, body("Rent is $3,200"), 5, 0, 3, 4, 0),
        ]
        for rowid, text, blob, age, mine, handle, chat, is_read in msgs:
            date = now - int(age * 60 * 1e9)
            con.execute(
                "insert into message (ROWID, text, attributedBody, date, is_from_me, "
                "handle_id, is_read) values (?,?,?,?,?,?,?)",
                (rowid, text, blob, date, mine, handle, is_read),
            )
            con.execute("insert into chat_message_join values (?,?,?)", (chat, rowid, date))
        con.commit()
        con.close()
        self.old = (server.CHAT_DB, server.CONFIG_PATH, server.ADDRESS_BOOK_GLOBS)
        server.CHAT_DB = self.db
        server.CONFIG_PATH = self.cfg
        server.ADDRESS_BOOK_GLOBS = []
        server._contacts.update(at=0, map={})

    def tearDown(self):
        server.CHAT_DB, server.CONFIG_PATH, server.ADDRESS_BOOK_GLOBS = self.old
        self.tmp.cleanup()

    def configure(self, **cfg):
        with open(self.cfg, "w") as f:
            json.dump(cfg, f)


class DecodeTests(unittest.TestCase):
    def test_short_long_and_unicode(self):
        for text in ("hi", "café \U0001f600", "y" * 127, "z" * 128, "w" * 5000):
            self.assertEqual(server.decode_body(body(text)), text)

    def test_garbage(self):
        self.assertIsNone(server.decode_body(None))
        self.assertIsNone(server.decode_body(b"nothing here"))

    def test_norm(self):
        self.assertEqual(server.norm("+1 (555) 123-0001"), server.norm("5551230001"))
        self.assertEqual(server.norm(" Landlord@Example.com "), "landlord@example.com")
        self.assertEqual(server.norm("chat777"), "chat777")


class ReadTests(Fixture):
    def test_list_merges_services_and_counts_unread(self):
        out = server.call_tool("list_chats", {})
        rows = [l for l in out.splitlines() if re.search(r" \| unread \d", l)]
        self.assertEqual(len(rows), 3)
        self.assertTrue(rows[0].startswith("landlord@example.com"))
        phone = [l for l in rows if l.startswith("+15551230001")][0]
        self.assertIn("unread 1", phone)
        self.assertIn("Them: Yes, viewing at 6pm", phone)
        self.assertIn('group "Flat hunt"', out)

    def test_unread_only_and_query(self):
        out = server.call_tool("list_chats", {"query": "flat"})
        self.assertEqual(len([l for l in out.splitlines() if re.search(r" \| unread \d", l)]), 1)

    def test_read_chat_by_loose_number(self):
        out = server.call_tool("read_chat", {"chat": "(555) 123-0001"})
        lines = [l for l in out.splitlines() if l.startswith("[")]
        self.assertEqual([l.split("]")[0] for l in lines], ["[1", "[2", "[3"])
        self.assertIn("Me: Is the flat still available?", lines[1])
        self.assertIn("(unread)", lines[2])
        self.assertIn("café", lines[2])

    def test_read_chat_paging(self):
        out = server.call_tool("read_chat", {"chat": "+15551230001", "after_id": 2})
        self.assertEqual(len([l for l in out.splitlines() if l.startswith("[")]), 1)
        out = server.call_tool("read_chat", {"chat": "+15551230001", "before_id": 2})
        self.assertIn("old sms", out)
        self.assertNotIn("viewing", out)

    def test_read_chat_by_group_name(self):
        self.assertIn("xxx", server.call_tool("read_chat", {"chat": "flat hunt"}))

    def test_unknown_chat(self):
        with self.assertRaises(server.ToolError):
            server.call_tool("read_chat", {"chat": "nobody"})

    def test_search(self):
        out = server.call_tool("search_messages", {"query": "RENT"})
        self.assertIn("Rent is $3,200", out)
        self.assertIn("{landlord@example.com", out)
        self.assertIn("No messages", server.call_tool("search_messages", {"query": "zzzz"}))

    def test_new_messages_cursor(self):
        out = server.call_tool("new_messages", {"since_minutes": 60})
        self.assertEqual(len([l for l in out.splitlines() if l.startswith("[")]), 3)
        self.assertIn("cursor: 5", out)
        out = server.call_tool("new_messages", {"after_id": 4})
        self.assertEqual(len([l for l in out.splitlines() if l.startswith("[")]), 1)
        self.assertIn("No new messages", server.call_tool("new_messages", {"after_id": 5}))

    def test_new_messages_limit_keeps_cursor_resumable(self):
        out = server.call_tool("new_messages", {"after_id": 0, "limit": 2})
        self.assertIn("cursor: 3", out)
        self.assertIn("More messages are waiting", out)


class AllowlistTests(Fixture):
    def test_only_allowed_chats_are_visible(self):
        self.configure(allowed_chats=["landlord@example.com"])
        out = server.call_tool("list_chats", {})
        self.assertEqual(len([l for l in out.splitlines() if re.search(r" \| unread \d", l)]), 1)
        with self.assertRaises(server.ToolError):
            server.call_tool("read_chat", {"chat": "+15551230001"})
        self.assertIn("No messages", server.call_tool("search_messages", {"query": "viewing"}))
        out = server.call_tool("new_messages", {"after_id": 0})
        self.assertEqual(len([l for l in out.splitlines() if l.startswith("[")]), 1)

    def test_allow_by_number_format_and_group_name(self):
        self.configure(allowed_chats=["555-123-0001", "Flat hunt"])
        out = server.call_tool("list_chats", {})
        self.assertEqual(len([l for l in out.splitlines() if re.search(r" \| unread \d", l)]), 2)
        self.assertNotIn("landlord", out)


class SendTests(Fixture):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.results = []
        self.real = server.osascript

        def fake(script, argv, timeout):
            self.calls.append(argv)
            return self.results.pop(0) if self.results else (0, "")

        server.osascript = fake

    def tearDown(self):
        server.osascript = self.real
        super().tearDown()

    def test_send_off(self):
        self.configure(send="off")
        with self.assertRaises(server.ToolError):
            server.call_tool("send_message", {"chat": "+15551230001", "text": "hi"})
        self.assertEqual(self.calls, [])

    def test_send_uses_most_recent_chat_guid(self):
        wait, server.SEND_WAIT = server.SEND_WAIT, 0
        try:
            out = server.call_tool("send_message", {"chat": "+15551230001", "text": "hi"})
        finally:
            server.SEND_WAIT = wait
        self.assertIn("do not resend", out)
        self.assertEqual(self.calls[0], ["hi", "iMessage;-;+15551230001", "chat"])

    def test_send_blocked_outside_allowlist(self):
        self.configure(allowed_chats=["landlord@example.com"])
        for chat in ("+15551230001", "+15559990000"):
            with self.assertRaises(server.ToolError):
                server.call_tool("send_message", {"chat": chat, "text": "hi"})
        self.assertEqual(self.calls, [])

    def test_send_refuses_unknown_name(self):
        with self.assertRaises(server.ToolError):
            server.call_tool("send_message", {"chat": "some name", "text": "hi"})
        self.assertEqual(self.calls, [])

    def test_confirm_declined(self):
        self.configure(send="confirm")
        self.results = [(0, "Don't Send")]
        with self.assertRaises(server.ToolError):
            server.call_tool("send_message", {"chat": "+15551230001", "text": "hi"})
        self.assertEqual(len(self.calls), 1)

    def test_automation_denied_stops_and_explains(self):
        self.results = [(1, "execution error: Not authorized to send Apple events to Messages. (-1743)")]
        with self.assertRaises(server.ToolError) as e:
            server.call_tool("send_message", {"chat": "+15551230001", "text": "hi"})
        self.assertIn("Automation", str(e.exception))
        self.assertEqual(len(self.calls), 1)


    def test_timeout_does_not_try_a_second_route(self):
        self.results = [(1, "timed out after 60s")]
        with self.assertRaises(server.ToolError) as e:
            server.call_tool("send_message", {"chat": "+15551230001", "text": "hi"})
        self.assertIn("click Allow", str(e.exception))
        self.assertEqual(len(self.calls), 1)

    def test_clean_rejection_falls_back_to_next_route(self):
        self.results = [(1, "execution error: Can't get chat id. (-1728)")]
        wait, server.SEND_WAIT = server.SEND_WAIT, 0
        try:
            server.call_tool("send_message", {"chat": "+15551230001", "text": "hi"})
        finally:
            server.SEND_WAIT = wait
        self.assertEqual(self.calls[1], ["hi", "+15551230001", "imessage"])


class ProtocolTests(Fixture):
    def test_handshake_and_errors(self):
        init = server.handle({"method": "initialize", "params": {"protocolVersion": "2025-03-26"}})
        self.assertEqual(init["protocolVersion"], "2025-03-26")
        tools = server.handle({"method": "tools/list"})["tools"]
        self.assertEqual(len(tools), 6)
        self.assertNotIn("fn", tools[0])
        bad = server.handle({"method": "tools/call", "params": {"name": "read_chat", "arguments": {"chat": "nobody"}}})
        self.assertTrue(bad["isError"])
        with self.assertRaises(LookupError):
            server.handle({"method": "resources/list"})


if __name__ == "__main__":
    unittest.main()
