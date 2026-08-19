#!/bin/bash
# Cuts a release: stamps the version, tags it, builds and notarises from that
# tag, uploads the signed disk image, and points the Homebrew tap at it.
#
# One command, because a release done by hand is a release where the tag, the
# thing people download and the cask disagree about which build they are. The
# order is the argument: the version is written first so the app reports it, the
# tag is made before the build so the binary is stamped with the commit it
# claims, the upload happens after notarisation so a failed one never leaves a
# release with nothing in it, and the tap is updated last so it never advertises
# a download that is not there.
#
# Usage:
#   make release-publish VERSION=0.2.0
#
# Needs: a Developer ID certificate, a stored `notarytool` keychain profile (see
# Scripts/release.sh), and `gh` logged in.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: publish-release.sh <version>   e.g. 0.2.0"; exit 2; }
# `v` belongs on the tag and nowhere else: CFBundleShortVersionString is a
# number, and Homebrew compares it as one.
VERSION="${VERSION#v}"
TAG="v$VERSION"
DMG="build/cuttr-$VERSION.dmg"
NOTES_FILE="docs/release-notes-$VERSION.md"

command -v gh >/dev/null || { echo "gh is not installed — brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in — gh auth login"; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" \
	|| { echo "no Developer ID Application certificate in the keychain"; exit 1; }
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-notarytool}" >/dev/null 2>&1 \
	|| { echo "no usable notarytool keychain profile — see Scripts/release.sh"; exit 1; }

# A release is built from what is committed. A dirty tree means the tag would
# point at something nobody else can reproduce.
if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "the working tree has changes — commit or stash them first"; exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
	echo "$TAG already exists"; exit 1
fi

# The notes are the release. Grouped by what somebody would notice rather than
# by what changed, written before the tag and reviewed like anything else —
# which is the point of them being a file rather than something typed into a box
# at the end. A version without them stops here.
[ -f "$NOTES_FILE" ] || {
	echo "no release notes at $NOTES_FILE" >&2
	echo "write them first — they are the release, not a formality" >&2
	exit 1
}

# The suite, before the tag. A release that fails its own tests is worse than a
# release a minute later, and the decode test in there is the one that says the
# aligner still recovers a known offset.
echo "==> Testing"
xcrun swift test >/dev/null || { echo "the tests fail — not releasing"; exit 1; }

BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "==> Releasing $TAG from $BRANCH"

# --- The version the app reports -------------------------------------------
#
# In project.yml, because that is where the Info.plist gets it from: the plist
# says $(MARKETING_VERSION) and Xcode substitutes it. Stamping the plist would
# be stamping the template.
CURRENT=$(awk -F'"' '/MARKETING_VERSION:/ {print $2}' project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ {print $2}' project.yml)
if [ "$CURRENT" != "$VERSION" ]; then
	/usr/bin/sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$VERSION\"/" project.yml
	/usr/bin/sed -i '' "s/CURRENT_PROJECT_VERSION: \"$BUILD\"/CURRENT_PROJECT_VERSION: \"$((BUILD + 1))\"/" project.yml
	git add project.yml
	git commit -q -m "Release $VERSION"
	echo "    version $CURRENT → $VERSION (build $BUILD → $((BUILD + 1)))"
fi

git tag -a "$TAG" -m "cuttr $VERSION"

# --- Build, sign, notarise --------------------------------------------------
#
# After the tag, so what is signed is what the tag names.
make --no-print-directory build CONFIG=release
Scripts/release.sh

test -f "$DMG" || { echo "expected $DMG and it is not there"; exit 1; }

# A checksum beside the image: the signature says Apple trusts it, this says it
# is the same file that left this machine — and it is what the cask carries.
shasum -a 256 "$DMG" | sed "s#build/##" > "$DMG.sha256"

# --- Publish ----------------------------------------------------------------
#
# The tag is pushed before the release is created: `gh release create` on a tag
# GitHub has never seen makes one at whatever the default branch happens to be,
# which is not necessarily what was built.
git push origin "$BRANCH"
git push origin "$TAG"

NOTES=$(mktemp)
{
	cat "$NOTES_FILE"
	echo
	echo "### Install"
	echo
	echo '    brew install --cask philipparndt/cuttr/cuttr'
	echo
	echo "Or download \`$(basename "$DMG")\`, open it and drag cuttr to Applications."
	echo "The build is signed with a Developer ID and notarised, so Gatekeeper opens it"
	echo "without a detour through System Settings."
	echo
	echo "    shasum -a 256 -c $(basename "$DMG").sha256"
	echo
	echo "Requires macOS 14 or newer."
} > "$NOTES"

# No `--generate-notes`: it appends GitHub's own list of commit subjects, which
# next to notes somebody wrote reads as the same release described twice, once
# badly.
gh release create "$TAG" \
	"$DMG" "$DMG.sha256" \
	--title "cuttr $VERSION" \
	--notes-file "$NOTES"
rm -f "$NOTES"

# --- And the tap ------------------------------------------------------------
Scripts/update-tap.sh "$VERSION"

echo "==> Published $TAG"
gh release view "$TAG" --json url --jq .url
