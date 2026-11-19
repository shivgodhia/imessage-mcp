#!/bin/bash
# Builds "iMessage MCP.app" into build/.
#
#   scripts/build.sh             universal app, signed with a Developer ID if this
#                                Mac has one, otherwise ad hoc (fine for your own use)
#   scripts/build.sh --install   also copy it to /Applications and connect the AI apps found
#   scripts/build.sh --dmg       also make build/iMessage-MCP.dmg, notarized and stapled
#   scripts/build.sh --release   --dmg, then publish it as GitHub release v<version>
#
# Notarizing needs a Developer ID certificate and an App Store Connect API key:
# ASC_KEY_ID and ASC_ISSUER_ID in the environment or in the first
# ~/.appstoreconnect/*.env, with the key at
# ~/.appstoreconnect/private_keys/AuthKey_<id>.p8.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0 DMG=0 RELEASE=0
for arg in "$@"; do
	case "$arg" in
	--install) INSTALL=1 ;;
	--dmg) DMG=1 ;;
	--release) DMG=1 RELEASE=1 ;;
	*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

VERSION=$(sed -n 's/^public let version = "\(.*\)"$/\1/p' Sources/IMessageMCPCore/Config.swift)
[[ -n "$VERSION" ]] || { echo "could not read the version" >&2; exit 1; }
APP="build/iMessage MCP.app"
OUT="build/iMessage-MCP.dmg"

echo "== building $VERSION"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tail -1
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/imessage-mcp

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/imessage-mcp"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/__VERSION__/$VERSION/g" app/Info.plist > "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning | grep -m1 -o '"Developer ID Application[^"]*"' | tr -d '"' || true)
if [[ -n "$IDENTITY" ]]; then
	echo "== signing with $IDENTITY"
	codesign --force --options runtime --timestamp \
		--entitlements app/entitlements.plist --sign "$IDENTITY" "$APP"
else
	echo "== no Developer ID on this Mac, signing ad hoc"
	codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/imessage-mcp"))"

if [[ $DMG == 1 ]]; then
	[[ -n "$IDENTITY" ]] || { echo "a Developer ID certificate is needed to notarize" >&2; exit 1; }
	if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
		ENV_FILE=$(ls ~/.appstoreconnect/*.env 2>/dev/null | head -1 || true)
		# shellcheck disable=SC1090
		[[ -n "$ENV_FILE" ]] && { set -a; source "$ENV_FILE"; set +a; }
	fi
	: "${ASC_KEY_ID:?Set ASC_KEY_ID (App Store Connect API key) to notarize}"
	: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to notarize}"
	ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"

	echo "== packaging"
	STAGE=$(mktemp -d)
	ditto "$APP" "$STAGE/iMessage MCP.app"
	ln -s /Applications "$STAGE/Applications"
	hdiutil create -quiet -volname "iMessage MCP" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT"
	rm -rf "$STAGE"
	codesign --force --timestamp --sign "$IDENTITY" "$OUT"

	echo "== notarizing (usually a few minutes)"
	xcrun notarytool submit "$OUT" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
		--issuer "$ASC_ISSUER_ID" --wait
	xcrun stapler staple "$OUT"
	spctl --assess --type open --context context:primary-signature -v "$OUT"
	echo "built $OUT"
fi

if [[ $INSTALL == 1 ]]; then
	echo "== installing"
	rm -rf "/Applications/iMessage MCP.app"
	ditto "$APP" "/Applications/iMessage MCP.app"
	"/Applications/iMessage MCP.app/Contents/MacOS/imessage-mcp" setup --no-open
fi

if [[ $RELEASE == 1 ]]; then
	echo "== publishing v$VERSION"
	gh release create "v$VERSION" "$OUT" --title "iMessage MCP $VERSION" --generate-notes
fi
