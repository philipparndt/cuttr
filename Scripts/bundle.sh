#!/bin/bash
#
# Builds cuttr.app.
#
# The app is built by Xcode, from a project generated out of project.yml. What
# is left to this script is the part Xcode does not do: generating the project,
# choosing the configuration, putting the result where the Makefile expects it,
# and signing it with a stable identity.
#
# Usage: Scripts/bundle.sh [debug|release]   (default: release)

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/cuttr.app"

XCODE_CONFIG="Release"
[ "$CONFIG" = "debug" ] && XCODE_CONFIG="Debug"
DERIVED="build/DerivedData"
# The log sits beside the derived data, so the directory has to exist before
# the redirection is set up — a shell opens the file before it runs xcodebuild.
mkdir -p build

# The project is generated and gitignored, so it may not exist and may be older
# than the file it comes from. Regenerating is a second and is idempotent.
command -v xcodegen >/dev/null || {
	echo "xcodegen not found — brew install xcodegen"
	exit 1
}
if [ ! -d cuttr.xcodeproj ] || [ project.yml -nt cuttr.xcodeproj ]; then
	echo "==> Generating cuttr.xcodeproj from project.yml"
	xcodegen generate --quiet
fi

echo "==> Building ($XCODE_CONFIG)"
xcodebuild -project cuttr.xcodeproj -scheme cuttr \
	-destination 'platform=OS X' \
	-derivedDataPath "$DERIVED" -configuration "$XCODE_CONFIG" \
	CODE_SIGNING_ALLOWED=NO \
	build > "$DERIVED.log" 2>&1 || {
		echo "    build failed — see $DERIVED.log"
		tail -25 "$DERIVED.log"
		exit 1
	}

BUILT="$DERIVED/Build/Products/$XCODE_CONFIG/cuttr.app"
[ -d "$BUILT" ] || { echo "    no app at $BUILT — see $DERIVED.log"; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p build
cp -R "$BUILT" "$APP"

# Which build this actually is.
#
# A crash report names the app's version, and the version in the project file
# is whatever was last released — so a report from a build made an hour ago
# says 0.4.1 (5) and points the reader at the released binary. That happened,
# and it cost half an hour of looking at the wrong tree. The commit goes in
# before signing, because changing the plist afterwards breaks the signature.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet 2>/dev/null || COMMIT="$COMMIT+"
/usr/libexec/PlistBuddy -c "Add :CuttrCommit string $COMMIT" "$APP/Contents/Info.plist" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Set :CuttrCommit $COMMIT" "$APP/Contents/Info.plist"
# A crash report prints `CFBundleVersion` and nothing of our own, so for a
# build nobody released the commit goes there as well. A tagged commit keeps
# its plain number: that one *is* the thing it says it is.
#
# Decided by the tag rather than by Debug/Release, because the build somebody
# actually runs is `make build`, which is a *release* build of whatever is
# checked out — and a crash report from one of those saying plain `0.4.1 (5)`
# is what sent me looking at the wrong tree this morning.
if ! git describe --exact-match --tags HEAD >/dev/null 2>&1; then
	BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD-$COMMIT" "$APP/Contents/Info.plist"
fi
echo "==> Built from $COMMIT"

# Signed with a Developer ID rather than ad-hoc, and not for distribution —
# this app is never shipped anywhere. TCC remembers "cuttr may read your Movies
# folder" against the app's identity, and an ad-hoc signature has none: it is
# the hash of the binary, which changes on every rebuild, so each build is a
# different app to macOS and silently drops the access the last one was given.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
	| grep "Developer ID Application" | head -1 | awk '{print $2}')"

if [ -n "$IDENTITY" ]; then
	echo "==> Signing with Developer ID $IDENTITY"
	codesign --force --deep --options runtime --sign "$IDENTITY" "$APP" || {
		echo "    warning: signing failed; falling back to ad-hoc"
		codesign --force --deep --sign - "$APP" 2>/dev/null
	}
else
	echo "==> Signing ad-hoc (no Developer ID in the keychain)"
	echo "    note: macOS will forget this app's file permissions on every rebuild"
	codesign --force --deep --sign - "$APP" 2>/dev/null || \
		echo "    warning: ad-hoc codesign failed; the app may not launch"
fi

echo "==> Done: $APP"
