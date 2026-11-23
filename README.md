<p align="center">
  <img src="app/icon.png" width="128" alt="iMessage MCP icon">
</p>

<h1 align="center">iMessage MCP</h1>

<p align="center">Let Claude read and answer your texts, entirely on your Mac.</p>

<p align="center">
  <a href="https://github.com/shivgodhia/imessage-mcp/releases/latest/download/iMessage-MCP.dmg"><b>Download for Mac</b></a>
</p>

iMessage MCP is a local [MCP](https://modelcontextprotocol.io) server for the
Claude Mac app. Claude can list your conversations, read a thread, search,
check for new messages and send a reply. Nothing is sent until you allow it
in Claude.

- **Local.** It reads the Messages database on your Mac and sends through the
  Messages app. It makes no network calls and has no server, account or API key.
- **Asks first.** Claude shows you the recipient and the exact text and asks
  before it sends. You click Allow, and it sends.
- **Small.** One signed, notarized app of about 1.5 MB, with no dependencies.
  The source is about 1,500 lines of Swift.

## Install

1. [Download iMessage MCP](https://github.com/shivgodhia/imessage-mcp/releases/latest/download/iMessage-MCP.dmg),
   open the disk image and drag the app into Applications.
2. Open **iMessage MCP** from Applications. It connects itself to the Claude
   app and tells you what is left.
3. In **System Settings > Privacy & Security > Full Disk Access**, switch on
   **iMessage MCP**. macOS will not let anything read your messages without this.
4. Quit Claude with Cmd+Q and reopen it.

Or do steps 1 and 2 from a terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/shivgodhia/imessage-mcp/main/install.sh | sh
```

Ask Claude "what texts did I get today?" to try it. The first time Claude sends
a text, macOS asks whether iMessage MCP may control Messages. Click Allow.

Needs macOS 12 or later and the [Claude Mac app](https://claude.ai/download).
Updating is the same as installing; your permissions carry over.

## What Claude can do

| Tool | What it does |
| --- | --- |
| `list_chats` | Conversations, newest first, with contact names, unread counts and the last message. |
| `read_chat` | Messages in one conversation, found by number, email, contact name, group name, or the people in a group. |
| `search_messages` | Text search, optionally within one conversation or the last N days. |
| `new_messages` | Incoming messages since a cursor, for checking what arrived. |
| `send_message` | Send a text to an existing conversation or group, or to a new number or email. Reports whether Messages recorded it as sent. |
| `get_attachment` | Returns a photo as an image (HEIC is converted), or the file path for anything else. |

SMS, RCS and iMessage threads with the same person appear as one conversation.

### Group chats

Groups work like any other conversation. Claude can find one by its name, or
by the people in it: "the group with Ana and Ben" finds the chat with exactly
those two, which is how you reach a group that has no name.

Messages lets another app send to a conversation that already exists, but not
create a group. So when you ask Claude to text several people who are not in a
group together yet, iMessage MCP opens a new message in the Messages app with
the people and the text filled in.

- **With the Accessibility permission** (System Settings > Privacy & Security >
  Accessibility > iMessage MCP), it checks that the new message has exactly
  those people and that text, presses Return, and switches back to the app you
  were in. Messages comes to the front for a few seconds while this happens. You
  approve the text first, the same way as any other send.
- **Without it**, the new message waits in Messages and you press Return.

macOS asks for Accessibility the first time Claude starts a group. After the
first message the group exists and Claude sends to it directly, with no
keypress.

It cannot mark messages as read, react, edit, unsend, or send attachments.

## Who approves a text

`send_message` is the only tool that changes anything, and you approve it in
Claude, the same way you approve any other connector. Claude shows the
recipient and the exact text and asks. Click Allow and the text goes out;
decline and nothing is sent.

In the Claude app each tool has its own setting: ask every time, always allow,
or blocked. Leave `send_message` on ask every time if you want to see every
text before it is sent. Always allow lets Claude send without asking.

If you want a second check on the Mac itself, set `"send": "confirm"` in the
options below. iMessage MCP then shows its own dialog with the recipient and
the exact text and three buttons: Don't Send, Always Allow, Send. *Always
Allow* remembers that conversation and skips the dialog for it next time.
Nothing is sent if nobody answers within five minutes.

## Options

`~/.config/imessage-mcp/config.json` is read on every call, so edits apply
immediately:

```json
{
  "allowed_chats": ["+1 555 123 0001", "landlord@example.com", "Flat hunt"],
  "send": "allow"
}
```

- `allowed_chats`: when non-empty, only these conversations can be listed,
  read, searched or sent to. Everything else is invisible to Claude. Empty
  means all conversations.
- `send`: `"allow"` sends once you approve it in Claude (default), `"confirm"`
  adds the dialog on your Mac, `"off"` makes it read-only.
- `always_allow_send`: only used with `"confirm"`. Conversations that skip the
  dialog. The Always Allow button adds to this list; delete an entry to be
  asked again.

Installed before 1.1.0? Your options file says `"send": "confirm"`, which was
the old default. Change it to `"allow"` to stop seeing the extra dialog.

Entries can be phone numbers in any format, emails, contact names, group names
or the identifiers `list_chats` prints.

## A note on trust

Texts are written by other people, and a message can contain instructions
aimed at an AI reading it. iMessage MCP labels message content as untrusted in
every result, but the protections that hold are your approval of each send
and the allowlist. If you let Claude work through threads with strangers, keep
`send_message` on ask every time in the Claude app and consider listing only
those threads in `allowed_chats`.

Full Disk Access is broad: it lets iMessage MCP read any file your account
can. The app only opens the Messages database, your Contacts databases (for
names), and attachments you ask for. It opens them read-only and never
connects to the network; the source is here to check.

Accessibility is optional and also broad: it lets an app read and press keys
in other apps. iMessage MCP only uses it to read the new-message window in
Messages and press Return there, and only when starting a new group chat.

The options file is not a barrier against other software running as you,
which could edit it.

## How it works

```
Claude app  ──stdin/stdout──▶  iMessage MCP.app
                                 ├─ reads ~/Library/Messages/chat.db (read-only)
                                 ├─ reads Contacts for names
                                 ├─ sends via AppleScript to Messages
                                 └─ new groups: presses Return in the Messages draft (Accessibility)
```

Unlike a hosted connector, there is nothing on the internet here. The Claude
app starts iMessage MCP as a child process when it opens and talks to it over a
pipe. It is registered in a config file on your Mac
(`~/Library/Application Support/Claude/claude_desktop_config.json`), so it
works in the Claude app on this Mac only, not on claude.ai or your phone.

**Why it is an app and not a script.** The Claude app tells macOS it is not
responsible for the servers it starts, so macOS checks the server's own
executable for permissions. A script would mean giving Full Disk Access to
`python3` or `node`, which covers every script on your Mac. A dedicated app
keeps the permission that narrow, and it shows up in System Settings with a
name and an icon.

**Why it decodes blobs.** Recent macOS versions leave the `text` column empty
for most messages and keep the text in a binary `attributedBody` field.
`decodeBody` in `Server.swift` pulls it out.

## Use it from a shell or Claude Code

```sh
alias imsg='"/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp"'
imsg check
imsg call list_chats '{"unread_only": true}'
imsg call read_chat '{"chat": "Flat hunt", "limit": 50}'
```

A send from a shell prints the recipient and the text and asks `Send? [y/N]`
in the terminal. In a script, where there is nobody to ask, add `--yes`:

```sh
imsg call send_message '{"chat": "Flat hunt", "text": "On my way"}' --yes
```

To add the server to Claude Code:

```sh
claude mcp add --scope user imessage -- "/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp"
```

From a terminal, macOS checks the terminal app's permissions rather than
iMessage MCP's, so the terminal needs Full Disk Access too.

## Uninstall

```sh
"/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp" uninstall
```

Then move the app to the Trash. Your options file is left in place.

## Build from source

Needs Xcode or the Swift toolchain.

```sh
swift test                    # runs against a throwaway database
scripts/build.sh --install    # build, copy to /Applications, connect to Claude
```

Without a Developer ID certificate the build is signed ad hoc, which works for
your own Mac; macOS will ask for Full Disk Access again after each rebuild.
`scripts/build.sh --release` builds, notarizes and publishes a release.

The icon is drawn by `app/make_icon.swift`.

## License

MIT. Not affiliated with Apple or Anthropic. iMessage is a trademark of Apple
Inc.
