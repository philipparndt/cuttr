# Releasing

One command:

    make release-publish VERSION=0.2.0

That stamps the version, tags it, builds and notarises from the tag, uploads the
signed disk image to [philipparndt/cuttr][repo], and points
[philipparndt/homebrew-cuttr][tap] at it. When it finishes:

    brew install --cask philipparndt/cuttr/cuttr

## What it needs, once

- **A Developer ID Application certificate** in the login keychain. Not the App
  Store one: this program opens whatever footage somebody points it at, from
  wherever they keep it, and the store's sandbox is a poor fit for a tool whose
  whole job is other people's files.
- **A `notarytool` keychain profile**, which is how Apple is asked to notarise
  without a password in a script:

      xcrun notarytool store-credentials notarytool \
          --apple-id <Apple ID> --team-id <team> --password <app-specific>

- **`gh`, logged in** (`gh auth login`), with push rights on both repositories.

The script checks all three before it does anything, because finding out after
the tag is made is how a release ends up half cut.

## What it will refuse

- A dirty working tree — the tag would point at something nobody else can build.
- A tag that already exists.
- A failing test suite.
- A missing `docs/release-notes-<version>.md`.

That last one is deliberate. The notes are the release: grouped by what somebody
would notice rather than by what changed, written before the tag and reviewed
like anything else. GitHub's generated list of commit subjects is not a
substitute, and a download nobody can read the changes for is worse than one
that is a day later.

## The order, and why

1. **Version** into `project.yml` — the Info.plist says `$(MARKETING_VERSION)`
   and Xcode substitutes it, so that is the one place it lives.
2. **Tag**, before the build, so what gets signed is what the tag names.
3. **Build, sign, notarise, staple** (`Scripts/release.sh`). Every Mach-O in the
   bundle is signed with the hardened runtime and checked *here* — Apple answers
   "Invalid" several minutes later with a submission id and no reason.
4. **Checksum** beside the image. The signature says Apple trusts it; this says
   it is the same file that left the machine, and it is what the cask carries.
5. **Push, then release.** `gh release create` on a tag GitHub has never seen
   makes one at whatever the default branch happens to be.
6. **Tap last** (`Scripts/update-tap.sh`), so it never advertises a download
   that is not there yet. `brew install` does not wait.

## The cask

Written from scratch each time rather than edited, from three facts the release
just produced: version, checksum, URL. The tap is cloned into a temporary
directory and thrown away afterwards — a checkout kept around is one that gets
edited by hand and then silently overwritten by the next release.

Steps 3 to 6 can be run on their own: `make release` builds and notarises
without touching git, and `make tap VERSION=0.2.0` re-points the tap at a
release that already exists.

[repo]: https://github.com/philipparndt/cuttr
[tap]: https://github.com/philipparndt/homebrew-cuttr
