# imessage-mcp

A local MCP server that lets the Claude Mac app read and send iMessages without
screenshots or driving the Messages window.

- Reads `~/Library/Messages/chat.db` directly, opened read-only.
- Sends through Messages.app with AppleScript.
- One Python file, standard library only. It makes no network calls. The only
  place message text goes is the tool results the Claude app asks for.

## Install

```sh
python3 install.py
```

This copies `server.py` to `~/.local/share/imessage-mcp/`, adds an `imessage`
entry under `mcpServers` in
`~/Library/Application Support/Claude/claude_desktop_config.json` (after backing
the file up), and creates `~/.config/imessage-mcp/config.json`.

Then, by hand:

1. **System Settings > Privacy & Security > Full Disk Access**: add Claude and
   turn it on. macOS will not let anything read the Messages database without
   it. This gives the Claude app, not just this server, access to protected
   files.
2. Quit Claude (Cmd+Q) and reopen it.
3. The first send shows "Claude wants to control Messages". Click Allow.

Re-run `python3 install.py` after changing `server.py`. `python3 install.py
--remove` undoes the install.

## Tools

| Tool | What it does |
| --- | --- |
| `list_chats` | Conversations, newest first, with contact names, unread counts and last message. Filter with `query` or `unread_only`. |
| `read_chat` | Messages in one conversation. `chat` can be an identifier, a number, an email, or a contact or group name. Page with `before_id` / `after_id`. |
| `search_messages` | Case-insensitive text search, optionally within one chat or the last N days. |
| `new_messages` | Incoming messages since a cursor, across all chats. For polling. |
| `send_message` | Send a text to an existing conversation, or to a new number or email. Reports whether Messages recorded it as sent. |
| `get_attachment` | Returns an image attachment as a picture (HEIC is converted), or the file path for anything else. |

SMS, RCS and iMessage threads with the same person are shown as one
conversation.

## Limiting what Claude can see and do

`~/.config/imessage-mcp/config.json`, read on every call so edits apply
immediately:

```json
{
  "allowed_chats": ["+1 555 123 0001", "landlord@example.com", "Flat hunt"],
  "send": "confirm"
}
```

- `allowed_chats`: when non-empty, only these conversations can be listed,
  read, searched or sent to. Entries are phone numbers (any format), emails,
  contact names, group names or chat identifiers. Empty means everything.
- `send`:
  - `"allow"` (default): asking is left to the Claude app, as described below.
  - `"confirm"`: also pops up a macOS dialog showing the exact text and
    recipient, and sends only if you click Send. Claude cannot bypass this,
    and it holds even if the app is set to "always allow".
  - `"off"`: read-only.
- `always_allow_send`: conversations that skip the dialog, so Claude can text
  them without asking. Same kinds of entries as `allowed_chats`. Clicking
  **Always Allow** in the dialog adds the conversation here; delete the entry
  to go back to being asked.

## Who asks before a text goes out

The same way the Gmail connector works. The server marks the five reading
tools as read-only and `send_message` as a write tool. The Claude app asks
before running a tool, showing the recipient and the exact text, and you
approve or deny that one call. Each tool has its own setting in the app
(always allow, ask every time, or blocked), so you can let the reading tools
run freely and keep `send_message` on ask every time.

The app's setting is per tool, not per person. For per-contact approval, set
`"send": "confirm"` and put `send_message` on always allow in the app: the
dialog then asks for everyone except the conversations in `always_allow_send`.
The dialog appears on the Mac's screen, so this setup needs you at the Mac for
anyone not on that list.

Two things sit outside the app's prompt:

- If you set `send_message` to always allow in the app, texts go out without
  asking. Use `"send": "confirm"` if you want a gate that setting cannot remove.
- Running `server.py call send_message` from a shell has no app in front of it,
  so it always shows the macOS dialog, in every mode except `"off"`.

Texts from other people are untrusted input. The server labels them as such in
every result, but an allowlist plus `"send": "confirm"` is the real protection
if you let Claude act on threads with strangers.

## Use from a shell

```sh
python3 server.py check
python3 server.py call list_chats '{"unread_only": true}'
python3 server.py call read_chat '{"chat": "Flat hunt", "limit": 50}'
```

To add it to Claude Code as well:

```sh
claude mcp add --scope user imessage -- python3 ~/.local/share/imessage-mcp/server.py
```

## Tests

```sh
python3 -m unittest discover -s tests
```

They run against a throwaway database, never the real one.

## Known limits

- Cannot mark messages as read, react, edit or unsend.
- Sends text only, no attachments.
- Edited messages show their current text when Messages stores it, otherwise
  `[no text]`.
- A send to a brand-new number tries iMessage first, then SMS (which needs
  Text Message Forwarding from your iPhone).
