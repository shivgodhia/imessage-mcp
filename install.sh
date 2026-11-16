#!/bin/sh
# One-line installer for iMessage MCP:
#   curl -fsSL https://raw.githubusercontent.com/shivgodhia/imessage-mcp/main/install.sh | sh
set -e

if [ "$(uname)" != "Darwin" ]; then
    echo "iMessage MCP only runs on macOS." >&2
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
    echo "The Xcode command line tools are needed (they provide python3 and a compiler)." >&2
    echo "Run:  xcode-select --install   then run this installer again." >&2
    exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL https://github.com/shivgodhia/imessage-mcp/archive/refs/heads/main.tar.gz \
    | tar -xz -C "$tmp" --strip-components 1
python3 "$tmp/install.py" "$@"
