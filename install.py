#!/usr/bin/env python3
"""Install imessage-mcp into the Claude Mac app.

Copies server.py to ~/.local/share/imessage-mcp/ (so the app does not depend on
this checkout), registers it under mcpServers in the Claude desktop config, and
reports which macOS permissions are still missing.

    python3 install.py            install or update
    python3 install.py --remove   unregister and delete the installed copy
"""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
INSTALL_DIR = HOME + "/.local/share/imessage-mcp"
CLAUDE_CONFIG = HOME + "/Library/Application Support/Claude/claude_desktop_config.json"
USER_CONFIG = HOME + "/.config/imessage-mcp/config.json"
CLAUDE_BUNDLE_ID = "com.anthropic.claudefordesktop"
NAME = "imessage"


def read_claude_config():
    if not os.path.exists(CLAUDE_CONFIG):
        return {}
    with open(CLAUDE_CONFIG) as f:
        return json.load(f)


def write_claude_config(cfg):
    if os.path.exists(CLAUDE_CONFIG):
        backup = CLAUDE_CONFIG + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(CLAUDE_CONFIG, backup)
        print("backed up Claude config to %s" % backup)
    tmp = CLAUDE_CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CLAUDE_CONFIG)


def full_disk_access():
    """True/False if we can tell whether Claude.app has Full Disk Access."""
    try:
        con = sqlite3.connect(
            "file:/Library/Application Support/com.apple.TCC/TCC.db?mode=ro", uri=True
        )
        row = con.execute(
            "select auth_value from access where service = "
            "'kTCCServiceSystemPolicyAllFiles' and client = ?",
            (CLAUDE_BUNDLE_ID,),
        ).fetchone()
        return bool(row and row[0] == 2)
    except sqlite3.Error:
        return None


def remove():
    cfg = read_claude_config()
    if NAME in cfg.get("mcpServers", {}):
        del cfg["mcpServers"][NAME]
        if not cfg["mcpServers"]:
            del cfg["mcpServers"]
        write_claude_config(cfg)
        print("removed %s from the Claude config" % NAME)
    shutil.rmtree(INSTALL_DIR, ignore_errors=True)
    print("deleted %s. Quit and reopen Claude to finish." % INSTALL_DIR)


def install():
    os.makedirs(INSTALL_DIR, exist_ok=True)
    target = os.path.join(INSTALL_DIR, "server.py")
    shutil.copy2(os.path.join(HERE, "server.py"), target)
    print("installed %s" % target)

    if not os.path.exists(USER_CONFIG):
        os.makedirs(os.path.dirname(USER_CONFIG), exist_ok=True)
        with open(USER_CONFIG, "w") as f:
            json.dump({"allowed_chats": [], "send": "allow"}, f, indent=2)
            f.write("\n")
        print("created %s" % USER_CONFIG)

    python = os.path.realpath(sys.executable)
    entry = {"command": python, "args": [target]}
    cfg = read_claude_config()
    if cfg.get("mcpServers", {}).get(NAME) == entry:
        print("Claude config already has the %s server" % NAME)
    else:
        cfg.setdefault("mcpServers", {})[NAME] = entry
        write_claude_config(cfg)
        print("registered the %s server in the Claude config" % NAME)

    print()
    subprocess.run([python, target, "check"])
    print()
    fda = full_disk_access()
    print("Still to do by hand:")
    if fda:
        print("  [done] Claude has Full Disk Access")
    else:
        print(
            "  1. System Settings > Privacy & Security > Full Disk Access: add "
            "and turn on Claude%s" % ("" if fda is False else " (could not check)")
        )
    print("  2. Quit Claude completely (Cmd+Q) and reopen it")
    print(
        "  3. The first send shows a one-time prompt, 'Claude wants to control "
        "Messages': click Allow"
    )


if __name__ == "__main__":
    remove() if "--remove" in sys.argv else install()
