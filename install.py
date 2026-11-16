#!/usr/bin/env python3
"""Install iMessage MCP into the Claude Mac app.

    python3 install.py              install or update
    python3 install.py --no-open    same, without opening System Settings
    python3 install.py --remove     uninstall

What it does:
  1. Copies server.py to ~/.local/share/imessage-mcp/.
  2. Builds "iMessage MCP.app", a tiny launcher that macOS grants permissions
     to, and puts it in /Applications.
  3. Registers it under mcpServers in the Claude desktop config (backed up).
  4. Opens the Full Disk Access settings so you can switch it on.
"""

import hashlib
import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import time

VERSION = "0.2.0"
HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = HOME + "/.local/share/imessage-mcp"
SERVER = DATA_DIR + "/server.py"
STAMP = DATA_DIR + "/app.built-for"
APP_NAME = "iMessage MCP"
BUNDLE_ID = "com.shivgodhia.imessage-mcp"
EXECUTABLE = "imessage-mcp"
CLAUDE_CONFIG = HOME + "/Library/Application Support/Claude/claude_desktop_config.json"
USER_CONFIG = HOME + "/.config/imessage-mcp/config.json"
FDA_PANE = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
NAME = "imessage"


def app_path():
    for base in ("/Applications", HOME + "/Applications"):
        if os.path.isdir(os.path.join(base, APP_NAME + ".app")):
            return os.path.join(base, APP_NAME + ".app")
    base = "/Applications" if os.access("/Applications", os.W_OK) else HOME + "/Applications"
    return os.path.join(base, APP_NAME + ".app")


def launcher_path(app):
    return os.path.join(app, "Contents", "MacOS", EXECUTABLE)


def read_claude_config():
    if not os.path.exists(CLAUDE_CONFIG):
        return {}
    with open(CLAUDE_CONFIG) as f:
        return json.load(f)


def write_claude_config(cfg):
    os.makedirs(os.path.dirname(CLAUDE_CONFIG), exist_ok=True)
    if os.path.exists(CLAUDE_CONFIG):
        backup = CLAUDE_CONFIG + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(CLAUDE_CONFIG, backup)
        print("  backed up the Claude config to %s" % backup)
    tmp = CLAUDE_CONFIG + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, CLAUDE_CONFIG)


def source_fingerprint(python):
    h = hashlib.sha256()
    h.update(("%s\n%s\n%s\n" % (VERSION, python, SERVER)).encode())
    for name in ("launcher.c", "app/AppIcon.icns"):
        with open(os.path.join(HERE, name), "rb") as f:
            h.update(f.read())
    return h.hexdigest()


def build_app(app, python):
    """Build the app bundle. Returns True if it was (re)built.

    macOS ties Full Disk Access to this exact build, so it is left alone
    unless something it is made from has changed.
    """
    fingerprint = source_fingerprint(python)
    if os.path.exists(launcher_path(app)) and os.path.exists(STAMP):
        with open(STAMP) as f:
            if f.read().strip() == fingerprint:
                return False

    if not os.path.exists("/usr/bin/cc") or subprocess.run(
        ["/usr/bin/xcode-select", "-p"], capture_output=True
    ).returncode != 0:
        sys.exit(
            "The Xcode command line tools are needed to build the app.\n"
            "Run:  xcode-select --install   then run this installer again."
        )

    build = app + ".building"
    shutil.rmtree(build, ignore_errors=True)
    os.makedirs(os.path.join(build, "Contents", "MacOS"))
    os.makedirs(os.path.join(build, "Contents", "Resources"))
    shutil.copy2(
        os.path.join(HERE, "app", "AppIcon.icns"),
        os.path.join(build, "Contents", "Resources", "AppIcon.icns"),
    )
    info = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundleExecutable": EXECUTABLE,
        "CFBundleIconFile": "AppIcon",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": VERSION,
        "CFBundleVersion": VERSION,
        "CFBundleInfoDictionaryVersion": "6.0",
        "LSMinimumSystemVersion": "12.0",
        "LSUIElement": True,
        "NSAppleEventsUsageDescription": (
            "iMessage MCP sends the texts you approve through the Messages app."
        ),
        "NSHumanReadableCopyright": "MIT License",
    }
    with open(os.path.join(build, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump(info, f)

    cc = subprocess.run(
        [
            "/usr/bin/cc", "-O2", "-Wall",
            '-DPYTHON="%s"' % python, '-DSERVER="%s"' % SERVER,
            "-o", launcher_path(build), os.path.join(HERE, "launcher.c"),
        ],
        capture_output=True, text=True,
    )
    if cc.returncode != 0:
        shutil.rmtree(build, ignore_errors=True)
        sys.exit("Could not build the launcher:\n" + cc.stderr)
    sign = subprocess.run(
        ["/usr/bin/codesign", "--force", "--sign", "-", build],
        capture_output=True, text=True,
    )
    if sign.returncode != 0:
        shutil.rmtree(build, ignore_errors=True)
        sys.exit("Could not sign the app:\n" + sign.stderr)

    shutil.rmtree(app, ignore_errors=True)
    os.rename(build, app)
    # Nudge Finder and System Settings to pick up the icon.
    subprocess.run(["/usr/bin/touch", app])
    with open(STAMP, "w") as f:
        f.write(fingerprint + "\n")
    return True


def full_disk_access():
    """True/False if we can tell whether the app has Full Disk Access."""
    try:
        con = sqlite3.connect(
            "file:/Library/Application Support/com.apple.TCC/TCC.db?mode=ro", uri=True
        )
        row = con.execute(
            "select auth_value from access where service = "
            "'kTCCServiceSystemPolicyAllFiles' and client = ?",
            (BUNDLE_ID,),
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
        print("Removed %s from the Claude config." % NAME)
    app = app_path()
    shutil.rmtree(app, ignore_errors=True)
    shutil.rmtree(DATA_DIR, ignore_errors=True)
    subprocess.run(
        ["/usr/bin/tccutil", "reset", "All", BUNDLE_ID], capture_output=True
    )
    print("Deleted %s and %s." % (app, DATA_DIR))
    print("Your settings in %s were kept." % USER_CONFIG)
    print("Quit and reopen Claude to finish.")


def install(open_settings):
    python = os.path.realpath(sys.executable)
    app = app_path()
    print("Installing %s %s" % (APP_NAME, VERSION))

    os.makedirs(DATA_DIR, exist_ok=True)
    shutil.copy2(os.path.join(HERE, "server.py"), SERVER)
    print("  server:  %s" % SERVER)
    for stale in ("imessage-mcp", "imessage-mcp.built-for"):  # pre-0.2 launcher
        try:
            os.remove(os.path.join(DATA_DIR, stale))
        except FileNotFoundError:
            pass

    rebuilt = build_app(app, python)
    print("  app:     %s%s" % (app, "" if rebuilt else " (unchanged)"))

    if not os.path.exists(USER_CONFIG):
        os.makedirs(os.path.dirname(USER_CONFIG), exist_ok=True)
        with open(USER_CONFIG, "w") as f:
            json.dump(
                {"allowed_chats": [], "send": "confirm", "always_allow_send": []},
                f, indent=2,
            )
            f.write("\n")
    print("  options: %s" % USER_CONFIG)

    entry = {"command": launcher_path(app), "args": []}
    cfg = read_claude_config()
    if cfg.get("mcpServers", {}).get(NAME) != entry:
        cfg.setdefault("mcpServers", {})[NAME] = entry
        write_claude_config(cfg)
    print("  Claude:  registered as \"%s\"" % NAME)

    fda = full_disk_access()
    print()
    if fda and not rebuilt:
        print("Full Disk Access is already on. Quit Claude (Cmd+Q) and reopen it.")
        return
    print("Two steps left:")
    print("  1. In System Settings > Privacy & Security > Full Disk Access,")
    print("     switch on \"%s\". If it is not in the list, drag it in from" % APP_NAME)
    print("     the Finder window that just opened (or click + and pick it).")
    print("  2. Quit Claude completely (Cmd+Q) and reopen it.")
    print()
    print("The first time Claude sends a text, macOS asks whether \"%s\"" % APP_NAME)
    print("may control Messages. Click Allow.")
    if open_settings:
        subprocess.run(["/usr/bin/open", "-R", app])
        subprocess.run(["/usr/bin/open", FDA_PANE])


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("iMessage MCP only runs on macOS.")
    if "--remove" in sys.argv:
        remove()
    else:
        install(open_settings="--no-open" not in sys.argv)
