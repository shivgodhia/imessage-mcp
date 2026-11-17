#!/bin/sh
# One-line installer for iMessage MCP:
#   curl -fsSL https://raw.githubusercontent.com/shivgodhia/imessage-mcp/main/install.sh | sh
#
# Downloads the latest signed, notarized release, puts it in /Applications and
# connects it to the Claude Mac app. Nothing needs to be compiled.
set -e

if [ "$(uname)" != "Darwin" ]; then
    echo "iMessage MCP only runs on macOS." >&2
    exit 1
fi

url="https://github.com/shivgodhia/imessage-mcp/releases/latest/download/iMessage-MCP.dmg"
dest="/Applications"
[ -w "$dest" ] || { dest="$HOME/Applications"; mkdir -p "$dest"; }
app="$dest/iMessage MCP.app"

tmp=$(mktemp -d)
mount="$tmp/mount"
cleanup() {
    hdiutil detach "$mount" -quiet >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

echo "Downloading iMessage MCP..."
curl -fsSL "$url" -o "$tmp/iMessage-MCP.dmg"
hdiutil attach "$tmp/iMessage-MCP.dmg" -nobrowse -readonly -quiet -mountpoint "$mount"
rm -rf "$app"
ditto "$mount/iMessage MCP.app" "$app"

"$app/Contents/MacOS/imessage-mcp" setup "$@"
