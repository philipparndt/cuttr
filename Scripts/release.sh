#!/bin/bash
# Signs, notarises and packages the app for people who are not on this machine.
#
# Developer ID rather than the App Store: this program opens whatever footage
# somebody points it at, from wherever they keep it — an external drive full of
# camera cards, usually — and the store's sandbox is a poor fit for a tool whose
# whole job is other people's files.
#
# The credentials are the `notarytool` keychain profile the other apps on this
# machine already use. On a machine that has none, once, interactively:
#
#   xcrun notarytool store-credentials notarytool \
#       --apple-id <Apple ID> --team-id <team> --password <app-specific>
#
# Usage: Scripts/release.sh          (after `make build CONFIG=release`)
#
# `SKIP_NOTARY=1` signs, packages and checks everything that can be checked on
# this machine and stops before Apple. For working on this script, and for
# seeing what a release would say without spending five minutes and a
# submission on it — the disk image it leaves behind is *not* releasable.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/cuttr.app"
PROFILE="${NOTARY_PROFILE:-notarytool}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

test -d "$APP" || { echo "no $APP — run make build CONFIG=release first"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/cuttr-$VERSION.dmg"

# The identifier it ships under, checked rather than assumed: every permission
# macOS has granted this app — the Movies folder, the drive the footage is on —
# is filed against that string, and a release under a different one arrives as a
# stranger asking for all of them again.
SHIPPING_ID="de.rnd7.cuttr"
BUILT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")
if [ "$BUILT_ID" != "$SHIPPING_ID" ]; then
	echo "refusing to release: $APP is $BUILT_ID, not $SHIPPING_ID" >&2
	exit 1
fi

# --- Sign ------------------------------------------------------------------
#
# Inside out, and without `--deep`: Apple deprecated it, and it signs nested
# code with the *outer* options, which is how a bundle ends up notarised on the
# outside and rejected on the inside. `bundle.sh` uses it for local builds,
# where the only thing that matters is a stable identity for TCC; a release is
# signed properly.
#
# Every Mach-O, whatever it is called and wherever it lives, asked of the file
# rather than assumed from its path — so a second executable added later is
# signed by this without anybody remembering to come back here.
MAIN=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")

echo "==> Signing with: $IDENTITY"
while IFS= read -r -d '' nested; do
	if [ -d "$nested" ] && [ ! -d "$nested/Contents/MacOS" ] && [ ! -d "$nested/Versions" ]; then
		continue
	fi
	codesign --force --timestamp --options runtime --sign "$IDENTITY" "$nested"
	echo "    signed ${nested#"$APP/"}"
done < <(find "$APP/Contents" \
	\( -name "*.framework" -o -name "*.xpc" -o -name "*.bundle" \) -type d -print0
	while IFS= read -r -d '' candidate; do
		[ "$candidate" = "$APP/Contents/MacOS/$MAIN" ] && continue
		file -b "$candidate" | grep -q "Mach-O" && printf '%s\0' "$candidate"
	done < <(find "$APP/Contents" -type f -perm -111 -print0))

codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- Check before Apple does ------------------------------------------------
#
# Notarisation takes minutes and answers "Invalid" with a submission id, and the
# reason is in a log you then have to go and ask for. Both of the usual reasons
# are visible here in a second.
echo "==> Checking every Mach-O before uploading"
FAILED=0
while IFS= read -r -d '' binary; do
	file "$binary" | grep -q "Mach-O" || continue
	DETAILS=$(codesign -dvv "$binary" 2>&1)
	if ! grep -q "Authority=Developer ID Application" <<< "$DETAILS"; then
		echo "    NOT signed with a Developer ID: ${binary#"$APP/"}"
		FAILED=1
	elif ! grep -q "flags=.*runtime" <<< "$DETAILS"; then
		echo "    no hardened runtime: ${binary#"$APP/"}"
		FAILED=1
	fi
done < <(find "$APP/Contents" -type f -perm -111 -print0)

if [ "$FAILED" -ne 0 ]; then
	echo "Stopping: Apple would reject this, and would take several minutes to say so." >&2
	exit 1
fi
echo "    every executable is signed and hardened"

# --- Package ---------------------------------------------------------------
#
# The disk image is what is notarised and what people download: notarising the
# .app alone leaves the ticket nowhere to be stapled for the thing that actually
# crosses the network. Homebrew downloads this same file.
echo "==> Making $DMG"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "cuttr" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# --- Notarise --------------------------------------------------------------
if [ -n "${SKIP_NOTARY:-}" ]; then
	echo "==> SKIP_NOTARY: not sending this to Apple"
	echo "    $DMG is signed but not notarised — Gatekeeper will refuse it"
	echo "==> Gatekeeper (expected to refuse):"
	spctl --assess --type open --context context:primary-signature -vv "$DMG" || true
	exit 0
fi

echo "==> Notarising (this waits for Apple)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapled so it opens on a machine that is offline, or behind a captive portal,
# where Gatekeeper cannot ask Apple about it.
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"

# --- Prove it ---------------------------------------------------------------
#
# What Gatekeeper itself says, rather than what the build hopes.
echo "==> Gatekeeper:"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"

echo "==> Done: $DMG"
