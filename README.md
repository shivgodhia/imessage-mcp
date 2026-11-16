<p align="center">
  <img src="app/icon.png" width="128" alt="iMessage MCP icon">
</p>

<h1 align="center">iMessage MCP</h1>

<p align="center">Let Claude read and answer your texts, entirely on your Mac.</p>

iMessage MCP is a local [MCP](https://modelcontextprotocol.io) server for the
Claude Mac app. Claude can list your conversations, read a thread, search,
check for new messages and send a reply, and it asks you before any text goes
out.

- **Local.** It reads the Messages database on your Mac and sends through the
  Messages app. It makes no network calls and has no server, account or API key.
- **Small.** One Python file using only the standard library, plus a short C
  launcher. Short enough to read before you trust it with your messages.
- **Asks first.** Every send shows you the recipient and the exact text. You
  can let specific people through without asking, one contact at a time.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/shivgodhia/imessage-mcp/main/install.sh | sh
```

Or clone the repo and run `python3 install.py`. Both need the Claude Mac app
and the Xcode command line tools (`xcode-select --install`).

The installer puts **iMessage MCP** in your Applications folder, registers it
with the Claude app, and opens System Settings. Then:

1. In **Privacy & Security > Full Disk Access**, switch on **iMessage MCP**.
   macOS will not let anything read your messages without this.
2. Quit Claude with Cmd+Q and reopen it.

Ask Claude "what texts did I get today?" to try it. The first time Claude sends
a text, macOS asks whether iMessage MCP may control Messages. Click Allow.

To uninstall: `python3 install.py --remove`.

## What Claude can do

| Tool | What it does |
| --- | --- |
| `list_chats` | Conversations, newest first, with contact names, unread counts and the last message. |
| `read_chat` | Messages in one conversation, found by number, email, contact name or group name. |
| `search_messages` | Text search, optionally within one conversation or the last N days. |
| `new_messages` | Incoming messages since a cursor, for checking what arrived. |
| `send_message` | Send a text to an existing conversation, or to a new number or email. Reports whether Messages recorded it as sent. |
| `get_attachment` | Returns a photo as an image (HEIC is converted), or the file path for anything else. |

SMS, RCS and iMessage threads with the same person appear as one conversation.

It cannot mark messages as read, react, edit, unsend, or send attachments.

## Who approves a text

`send_message` is the only tool that changes anything. Two things stand
between Claude and a sent text:

- **The Claude app** asks before running a tool. Each tool has its own setting
  (always allow, ask every time, blocked), the same way connectors like Gmail
  work. That setting is per tool, not per person.
- **A dialog on your Mac**, shown by iMessage MCP itself, with the recipient
  and the exact text and three buttons: Don't Send, Always Allow, Send.
  *Always Allow* sends it and remembers that conversation, so Claude can text
  that person again without asking. Nothing is sent if nobody answers within
  five minutes.

To avoid being asked twice, set `send_message` to always allow in the Claude
app and let the dialog be the gate. If you want to approve texts while away
from your Mac, do the reverse: set `"send": "allow"` below and keep the app on
ask every time.

## Options

`~/.config/imessage-mcp/config.json` is read on every call, so edits apply
immediately:

```json
{
  "allowed_chats": ["+1 555 123 0001", "landlord@example.com", "Flat hunt"],
  "send": "confirm",
  "always_allow_send": ["+1 555 123 0001"]
}
```

- `allowed_chats`: when non-empty, only these conversations can be listed,
  read, searched or sent to. Everything else is invisible to Claude. Empty
  means all conversations.
- `send`: `"confirm"` shows the dialog (default), `"allow"` leaves asking to
  the Claude app, `"off"` makes it read-only.
- `always_allow_send`: conversations that skip the dialog. The Always Allow
  button adds to this list; delete an entry to be asked again.

Entries can be phone numbers in any format, emails, contact names, group names
or the identifiers `list_chats` prints.

## A note on trust

Texts are written by other people, and a message can contain instructions
aimed at an AI reading it. iMessage MCP labels message content as untrusted in
every result, but the protections that hold are the dialog and the allowlist.
If you let Claude work through threads with strangers, keep `send` on
`"confirm"` and consider listing only those threads in `allowed_chats`.

Full Disk Access is broad: it lets iMessage MCP read any file your account
can. The app only ever runs the `server.py` this repo installs, and that file
only opens the Messages and Contacts databases.

## How it works

```
Claude app  ──stdin/stdout──▶  iMessage MCP.app  ──▶  python3 server.py
                                                         ├─ reads ~/Library/Messages/chat.db (read-only)
                                                         ├─ reads Contacts for names
                                                         └─ sends via AppleScript to Messages
```

Unlike a hosted connector, there is nothing on the internet here. The Claude
app starts the server as a child process when it opens and talks to it over a
pipe. It is registered in a config file on your Mac, so it works in the Claude
app on this Mac only, not on claude.ai or your phone.

**Why there is an app at all.** The Claude app tells macOS it is not
responsible for the servers it starts, so macOS checks the server's own
executable for permissions. Giving Full Disk Access to `python3` would cover
every Python script on your Mac. `launcher.c` compiles to a small app that
only ever runs this server, so the permission is that narrow, and it shows up
in System Settings with a name and an icon.

macOS ties the permission to the exact build of the app. The installer
rebuilds it only when the launcher or your Python changes; after a rebuild,
switch Full Disk Access on again. Updating `server.py` does not need a rebuild.

**Why the server decodes blobs.** Recent macOS versions leave the `text`
column empty for most messages and keep the text in a binary `attributedBody`
field. `decode_body` in `server.py` pulls it out.

## Use it from a shell or Claude Code

```sh
alias imsg='"/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp"'
imsg check
imsg call list_chats '{"unread_only": true}'
imsg call read_chat '{"chat": "Flat hunt", "limit": 50}'
```

A send from a shell always shows the dialog. To add the server to Claude Code:

```sh
claude mcp add --scope user imessage -- "/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp"
```

From a terminal, macOS checks the terminal app's permissions rather than
iMessage MCP's, so the terminal needs Full Disk Access too.

## Development

```sh
python3 -m unittest discover -s tests   # runs against a throwaway database
python3 install.py                      # reinstall after editing
swift app/make_icon.swift app/icon.png && sh app/make_icns.sh   # redraw the icon
```

## License

MIT. Not affiliated with Apple or Anthropic. iMessage is a trademark of Apple
Inc.
