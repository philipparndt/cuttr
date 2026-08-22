# House rules

How not to break this while working on cuttr.

## Never push or publish unasked

Not on your own initiative, and not as the tidy end of a job somebody asked for:
a commit somebody can read is the deliverable, and pushing it is a separate
decision that is theirs.

When they do ask — in so many words, for this release — go ahead and run it
through. `make release-publish VERSION=x.y.z` tags, pushes, uploads the
notarised image and re-points the tap; `docs/releasing.md` says what it needs
and what it refuses. Asking once covers that release and no other.

## Never `make install`

It replaces the app in `/Applications` — the one somebody may be using. Build
and run `build/cuttr.app/Contents/MacOS/cuttr` directly, or `make dev`.

## `xcrun swift`, never plain `swift`

A toolchain manager puts its own `swift` first on the `PATH`, and that one is
pinned to a release older than the SDK. `xcrun` asks the selected Xcode, which
is what `Scripts/bundle.sh` builds with.

## The take file is the product

Everything else — the window, the waveform, the player — exists to produce
`.cuttr` files and to be checked against them. Two rules follow:

- **The emitter is hand-written and stays that way.** `TakeWriter` fixes key
  order, column alignment and quoting so that re-saving an unchanged take
  produces an unchanged file. A general YAML emitter turns "I renamed one clip"
  into a rewritten file, and an as-text tool whose files churn is worthless.
  `writingIsStableForTheSameTake` guards it.
- **Unknown keys are carried through.** A file written by a later version must
  survive being opened and saved by an older one.

## Slugs are references, not labels

A slug is what the project assembly file points at. Deriving one from a name is
fine until somebody types one themselves — after that, renaming the clip must
not change it. `TakeDocument.manualSlugs` is that distinction and it is not in
the file, because it is a fact about the session and not about the take.

## One clock

Every time in a take is on the video's clock. The separate recorder's offset is
the only thing that relates the two, so alignment can be corrected at any point
without touching a single cut mark. Anything that stores an audio-relative time
breaks that and will be found out the first time somebody re-aligns.

Positive offset means the recorder was started *after* the camera. A test and a
doc comment already disagreed about this once.

## Before you finish

`make test`, clean. The suite includes a real decode: it writes two WAVs, runs
them through `AVAssetReader`, and asserts the aligner recovers a known offset to
within 2 ms. If that one goes red, the bug is real.
