# cuttr

Cutting video as text.

Two halves, both plain text. A **take** is one recording and a list of the named
pieces cut out of it. A **project** is a programme assembled from those pieces
across many takes, with captions and tracked overlays laid over it. One window,
a tab for each.

    ┌─ 00:00:07.233 ── take-01.mov ── take-01-mic.wav ── offset +00:01.234 ─┐
    │                                                                       │
    │                        [ the picture ]              intro             │
    │                                                     demo-install      │
    │                                                     wrap-up           │
    ├───────────────────────────────────────────────────────────────────────┤
    │ 00:00   00:05   00:10   00:15   00:20   00:25   00:30                 │
    │ ▓▓ intro ▓▓▓│▓▓ demo-install ▓▓▓▓▓▓▓▓▓│                               │
    │ ╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫  camera                        │
    │ ╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫╫  recorder                      │
    └───────────────────────────────────────────────────────────────────────┘

## Install

    brew install --cask philipparndt/cuttr/cuttr

Or take the disk image from [the releases page][releases], open it, and drag
cuttr to Applications. Either way it is the same build: signed with a Developer
ID and notarised, so it opens without a detour through System Settings.

To update, later:

    brew update && brew upgrade --cask cuttr

`brew update` refreshes the tap — the cask is a file in a repository, and brew
reads the copy it already has until it is told to fetch a new one, which is why
`upgrade` on its own can cheerfully report that the version from last month is
the newest one there is.

Needs macOS 14 or newer. To build it yourself instead, see [Building](#building).

[releases]: https://github.com/philipparndt/cuttr/releases

## What it does

- Opens a video, or a video **and** a separately recorded audio file.
- Lines the two up — automatically, by correlating what both microphones heard,
  and then by ear and by hand to the millisecond.
- Cuts the take into named subclips, at speed, from the keyboard.
- Writes a cut list an editor and a `git diff` can both read.
- Imports subclips you already made in DaVinci Resolve.

## The cut list

YAML, one file per take, next to the recording. Times are on the **video's**
clock, counted from its first frame; the audio's offset is the one number that
relates the separate recorder to it, so re-aligning never moves a cut.

```yaml
# cuttr take — a plain-text cut list. Edit it here or in the app.
cuttr: 1

video: take-01.mov
audio:
  file:   take-01-mic.wav
  offset: +00:01.234   # audio + offset = video clock

clips:
  - slug:  intro
    name:  Intro — hello and welcome
    start: 00:00.000
    end:   00:12.300   # 00:12.300

  - slug:  demo-install
    name:  Installing the driver
    start: 00:14.020
    end:   01:03.880   # 00:49.860
    color: rose
    note:  retake; the second one is cleaner
```

The **slug** is the part that matters to everything downstream: it is what the
project assembly file will reference, so it is lower-case, hyphenated, unique
within the take, and never changed behind your back once you have typed one
yourself. The **name** is prose and may say anything.

`start`/`end` accept `MM:SS.mmm`, `HH:MM:SS.mmm` or plain seconds — write
whichever you like, the app writes the first two. The duration after each clip
is a comment, not a field: it is `end - start`, and a second place for it to be
wrong is not worth having.

Unknown keys are carried through unchanged, so a file written by a later version
survives being opened and saved by this one.

Times can also be typed straight into the Start and End columns of the clip
list, which is the precise way to trim; dragging a clip's edge on the timeline
is the fast way. Both snap to the video's frame grid.

## Keys

The program is the keyboard. Cutting a forty-minute recording is the same three
seconds eighty times — mark, name, carry on — so every verb is a bare key and
naming a clip is the same keystroke that made it.

| | |
|---|---|
| `space` | play / pause |
| `J` `K` `L` | rewind · stop · forward (`⇧` for 4×) |
| `←` `→` | one frame (`⌥` 0.1 s, `⇧` 1 s) |
| `⌘←` `⌘→` | previous / next cut mark |
| **`S`** | **split here — or close off the clip since the last one** |
| `I` `O` | set in / out |
| `⏎` | make a clip from the in/out span — or, with none, jump to the selected clip's start |
| `N`, double-click | rename the selected clip, in place on its bar |
| `1`…`6` | colour the selected clip, and the next one you cut |
| `⌫` | delete the selected clip |
| `A` | find the audio offset automatically |
| `[` `]` or `,` `.` | nudge the offset by 1 ms (`⇧` 10 ms, `⌥` 100 ms) |
| `M` | cycle what you hear |
| `F` `Z` `-` `=` | fit · zoom to clip · out · in |
| `⌘Z` `⇧⌘Z` | undo · redo |
| `⌘S` | save |
| `⇧⌘I` | import subclips from Resolve |

Everything above is also in the menu bar, on `⌘` equivalents. That is not
duplication: bare keys cannot go in a menu — a menu's key equivalent is matched
before anything else sees it, so a bare `S` there would mean no clip could ever
be called "Slides" — and a verb that exists only as an undocumented keystroke
is a verb with one user.

The bare punctuation keys are matched by physical position as well as by
character, because `=`, `[` and `]` are not unshifted keys on every layout —
on a German keyboard they are Shift+0, AltGr+8 and AltGr+9.

`S` is the whole contiguous pass: play the take and press it at each boundary.
Each press closes off everything since the last clip ended. It does **not** stop
to ask for a name — that is why new clips are called `clip-1`, `clip-2`,
`clip-3`: they are usable references from the moment they exist, and naming is
a second pass. (It used to open a name field on every mark, which put a text
box in front of the very next `S`.)

Mouse: click or drag to scrub, drag a clip's edge to trim, `⇧`-drag to mark a
span, `⌥`-drag the audio waveform to slide it, `⌘`- or `⌥`-scroll to zoom.
Double-click a clip's bar to name it where it is. Right-click one for trim,
colour and delete.

## Colours are lanes

A clip's colour is **which line of clips you are cutting**. Marking looks only at
clips of the same colour: it splits one of those if the playhead is inside it,
and otherwise closes off everything since the last clip *of that colour* ended.
Clips of other colours are invisible to it.

That is what makes overlapping clips possible. A pass in green gives the
programme's sections; a pass in rose over the same minutes gives the alternate
takes; neither pass works around the other, and each colour gets its own bar on
the timeline.

Pick a lane from the swatches in the toolbar, with `1`…`6`, or by clicking the
bar. **Choosing a lane changes nothing that already exists** — recolouring a
clip, which moves it to another bar, is on its context menu.

The colour is your scheme; cuttr does not assign it a meaning. In the file it is
a name (`color: rose`) and it is omitted when it is the usual one.

## Tags and order

Clips carry tags, and tags are what a project selects on: the slug names *this*
clip, a tag names a kind of clip. `order:` (default 1000) decides where a clip
sorts among others selected together — 500 puts it first, 1500 last, and nothing
has to be renumbered.

## Aligning two recordings

`A` correlates the two waveforms and usually lands within a millisecond. It
reports the match strength beside the answer and jumps to the twenty seconds it
measured, so you can check it rather than trust it.

Then use your ears. Set the monitor to **Both** and nudge with `[` and `]`:
two recordings of one room comb-filter against each other, and the hollow,
flanging sound disappears at exactly the right offset. That is a far finer
instrument than lining up two waveforms by eye.

## Importing from DaVinci Resolve

Resolve does not export its media pool, so put the subclips on a timeline and
export that — **EDL**, **FCPXML**, or the older **Final Cut Pro 7 XML**. All
three are read (`⇧⌘I`, or drop the file on the window).

An EDL's source timecodes are the camera's, not the file's, and nothing in the
file says where the file starts. When every imported clip lands past the end of
the recording, the whole set is shifted so the earliest one starts at zero — and
the app says so rather than moving your marks quietly.

## Building

```
make          # build and launch
make dev      # debug build, in the foreground, logs on the terminal
make test     # the suite
make xcode    # generate and open the Xcode project
```

Needs [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install
xcodegen`). The `.xcodeproj` is generated from `project.yml` and is not checked
in; the SwiftPM package is the source of truth, so `swift build` and Xcode build
the same files.

## The composer

The second half, and the half you start from: a programme assembled from clips
across many separately-cut takes, with things drawn over it.

The project window has an editor for all of this down the right-hand side — and
it is a **teaching aid** as much as an editor. Every field is labelled with the
key it writes (`fps`, `from`, `match.reference`) rather than a friendly
paraphrase, and the pane at the bottom shows the YAML your current selection
produces, live, straight out of the same emitter that writes the file. Nothing
in it renders a *description* of the format; it shows the format.

The intended arc is that you use the panel, read what it wrote, and after a week
stop using the panel. A tool whose interface hides its file is one you can never
graduate from.

Typing in it follows the file's own rules, because it is the same rule: `intro`
is a clip, `#b-roll and not #reject` is a query, `@introduction` is a section.

Takes edited in another tab update the programme at once — re-cut a clip, track
a face, and the project window has it before you have switched back.

The project window lists its takes down the side — name, clip count, and where
each one is. Double-click to open one in a tab beside the project; **Add Take…**
puts an existing `.cuttr` in, **New Take…** cuts a fresh one from a recording,
writes it into `takes/` and opens it. A project has to be saved before it can
point at anything, because every path in it is relative to where it sits, so the
first add is what asks where to put it. Also plain text, also meant to be edited by
hand — `programme.cuttrproj`:

```yaml
cuttr-project: 1
takes:
  - takes/take-01.cuttr
  - takes/take-02.cuttr

output:
  size: 1920x1080
  fps:  25
  file: programme.mov

timeline:
  - group: introduction
    clips:
      - intro
      - demo-install
  - group: the-build
    clips:
      - query: "#b-roll and not #reject"
      - take-02/wrap

overlays:
  - text:  Installing the driver
    style: lower-third
    group: introduction
    in:    {slide: left,  over: 0.4}
    out:   {slide: right, over: 0.4}

  - spinner: dots
    group:   the-build
    anchor:  mia-eye
    offset:  [0, 0.16]
    words:
      - thinking
      - {text: still thinking, for: 3}
      - got it
```

An empty project is a project: it can be created, saved and reopened before
anything is on its timeline. Whether there is anything to *render* is asked at
render time, where the answer matters.

**Clips are named, never timed.** A project references a take's slug, so
re-cutting a take — moving a boundary, renaming a clip, adding three more —
leaves every project still correct. That is what the slug is for.

**A timeline entry is one clip, a list, a query, or a group.**

| | |
|---|---|
| `- intro` | one clip |
| `- clips: [a, b, c]` | several, in the order written |
| `- query: "#b-roll and not #reject"` | every clip the query selects |
| `- tag: b-roll` | sugar for `query: "#b-roll"` |
| `- group: name` + `clips:` | a named section; they nest |

Queries are over the tags you put on clips in the cutting window: `#tag`,
`take-01/#tag`, `take-01/*`, a bare slug, combined with `and`, `or`, `not` and
brackets. Two terms side by side mean `and`. What a query returns is ordered by
each clip's own `order:` (default 1000, so you can put things before *and*
after without renumbering), then by take, then by time — so it returns the same
programme twice running. A query that matches nothing is an error, not a
silently shorter programme.

**Overlays are bound to clips or to sections**, not to times: `group:
introduction`, or `from: @a to: @b`, or `from: intro to: demo`. The in and out
animations are taken from inside the span, so two overlays whose spans meet
cross at the boundary — the first slides out to the right exactly as the second
slides in from the left, with nothing to keep in step by hand.

### Anchors — things pinned to a face

**Anchors live in the take, not the project.** Where somebody's eye is in a
recording is a fact about the recording: it is the same fact in every programme
that uses the clip, so it is marked once, in the cutting window, and every
project that references the clip gets it.

Right-click the picture in a take → **Track Eye Here**. Vision finds the face
nearest the click, locks to that eye's landmark and follows it, re-detecting
every 100 ms rather than propagating a patch — so it survives the head turning
and comes back after an occlusion. A teal ring with the anchor's name follows
the solved path in the preview, and is drawn *only where the path has data*, so
a tracker that wandered onto a lamp is obvious in the second it happens rather
than after a render.

**An anchor tracks a shot, not a subclip.** It is followed outward from where
you marked it until the face is lost, and the range it managed is written back
into the take. Any subclip overlapping that range can use it, however many there
are, and re-cutting the take does not invalidate the tracking. Marking does not
even need a clip to exist yet.

A blink does not end it. Vision keeps finding the face when somebody shuts their
eyes or squints hard, but often stops returning the *eye* — so the tracker
remembers where the eye sits on the head and holds it there until the landmark
comes back. Without that, following one real shot stopped after 78 seconds; with
it, 155.

It follows to the ends of the recording, or until the face is genuinely lost —
there is no search limit. On five minutes of 1080p that is a couple of minutes
of Vision; it shows a bar and it can be cancelled, which is the right way to
make a long job bearable rather than stopping early and making you ask again.

**When it does stop, continue.** Right-click later in the picture and pick
*Continue "mia" Here*. The new stretch is merged into the same anchor, leaving a
hole where the tracker genuinely could not see — one name, two spans of truth,
and nothing drawn over the gap.

**More than one at a time.** A two-shot is two anchors; they are named apart
automatically and tracked independently, and each frame's face is matched to the
nearest previous position, which is what keeps two people from swapping.

The take names a sidecar per anchor, relative to itself:

```yaml
anchors:
  - name:   left-eye
    from:   00:00.100   # what the tracker managed to follow
    to:     01:18.000
    at:     01:05.000   # where you clicked, and when
    point:  [0.5290, 0.6470]
    method: face-landmark
    path:   anchors/left-eye.path
```

The sidecar is three columns of plain text, so a frame where the tracker
wandered is two numbers to correct in an editor rather than a re-solve and a
hope.

Measured on real 1080p footage: one mark followed a face for 78 seconds — 780
samples — and two subclips six seconds apart in the take both drew from it with
no second solve. Two eyes tracked at once over fifteen seconds gave 152 samples
each, one frozen frame apiece, and never collapsed onto each other: their
separation held between 0.041 and 0.044 of the frame width throughout.

`cuttr-render --faces video.mov --at 12` says what Vision can see in one frame
and where, which answers "is there a face here to lock on to" before you spend a
minute finding out.

Not implemented: `method: point`, the non-face tracker. It is in the format and
currently holds position rather than tracking.

### Levelling and grading

Measured once per recording, applied by every programme.

```
cuttr-render programme.cuttrproj --analyse
```

writes into each take what it found:

```yaml
measured:
  loudness: -21.4   # LUFS
  peak:     -3.1    # dBFS
  cast:     [0.2630, 0.2970, 0.2848]   # mean linear RGB
```

**Loudness is EBU R128** — K-weighted and gated, not RMS and not peak. A clip
with one door slam has a fine peak and a respectable RMS while the speech under
it is inaudible; normalising on either leaves every voice at a different level,
which is the problem. The gates are what make it work on real material: the
absolute one throws away silence, the relative one throws away the pauses
between sentences, so a take full of gaps measures the same as one without.
Verified against a 1 kHz sine at −23 dBFS RMS: it reads −23.004 LUFS.

It measures **only the spans the take contributes**, not the whole file. On real
footage that was a fourteen-unit difference — a five-minute recording of which
twenty seconds is used otherwise measures four and a half minutes of ambience.
Re-cut, re-analyse; it takes a second.

The project says what to aim at:

```yaml
output:
  audio: {target: -20, ceiling: -1}   # LUFS, dBFS
  match: {reference: first-bit}

profiles:
  camera-a:
    saturation:  1.10
    temperature: 300
```

The ceiling turns a clip *down* rather than limiting it — a limiter changes what
the recording sounds like, and doing that silently to somebody's audio is not
this program's business. When the ceiling binds, the clip lands under target and
the number says so.

**Colour matching** divides one take's average by the reference's, per channel,
which corrects exposure and white balance in one number each. It is bounded, so
a shot that is genuinely a different scene comes out partly matched rather than
stained. Profiles are hand-written looks that a take names; the match composes
over them, so "this camera, and then warmer" means what it reads like.

Round trip, on real footage: target −20 LUFS in, render out, measure the render
— −20.0 LUFS, peak −5.6 dBFS.

Known limit: a recording with several audio tracks is measured and rendered from
the first one only.

### Film mode

An overlay that is the picture rather than something over it: the bars close in
to a wider shape, the colour goes to a stock, the grain arrives, and all three
move together with the fade at each end. A shot can go to film and come back
inside its own length, and nothing else in the project has to know.

```yaml
overlays:
  - film:     warm       # none · warm · cool · sepia · noir · bleach
    ratio:    "2.39:1"
    grain:    0.5
    vignette: 0.35
    from:     the-build
    to:       the-build
    in:       {fade: true, over: 1}
    out:      {fade: true, over: 1}
```

`ratio` is the shape the bars close to — `2.39:1` over a 16:9 programme, or
`16:9` over one cut for a phone, which is where it reads most like the cinema.
A shape the programme already is costs nothing and shows nothing. `strength`
mixes the stock in rather than switching it on, so half is half way there.

The grain moves from frame to frame; grain that sits still is dirt on the lens
and the eye finds it in about two seconds. At the start and end of the fade
nothing at all is applied — the frames on either side of a film sequence go
through no filter, which is what keeps the rest of the cut exact.

### Naming clips after whoever is talking

**An anchor is a person.** Rename a tracked face to `mia` and clips she speaks
in are named `mia-1`, `mia-2`, …

The method is mouth movement, not sound: telling voices apart from audio needs a
model and a good deal of hope, where telling which face in shot is moving its
mouth needs the landmarks Vision already returns for the tracking. Movement
rather than openness, because a held smile is a wide mouth saying nothing.

It happens *after* the mark, never during it — the marking loop must not stop
for a second of Vision — so a clip appears as `clip-4` and becomes `mia-2` a
moment later. It declines when nobody is clearly talking or when two candidates
are too close to call, and it never overwrites a slug somebody typed. A clip
called `clip-4` is better than one confidently named after the wrong person.

`cuttr-render --speaking take.cuttr --from 62 --to 68` asks the same question
from a terminal. On real footage, talking spans measured 0.007–0.015 of mouth
movement a sample and quiet ones fell below the 0.006 threshold.

### Memes as material

**File ▸ Find a Meme…** (⇧⌘M, or the button in the library) searches GIPHY or
Tenor and downloads the one you pick. Both serve an `.mp4` of everything they
hold, which is the reason those two: AVFoundation will not open a GIF as a
movie.

What arrives is a **take**, because that is what a meme is — a short recording
with one span cut out of it:

    memes/facepalm.mov          the download, next to the project
    takes/facepalm.cuttr        the take, where the project's takes go

```yaml
video: ../memes/facepalm.mov

source:
  provider:    giphy
  id:          XD4qHZpkyUFfq
  title:       facepalm GIF
  page:        https://giphy.com/gifs/facepalm-XD4qHZpkyUFfq
  attribution: Powered By GIPHY   # the service's terms ask for this to be shown

clips:
  - slug:  facepalm
    name:  facepalm GIF
    start: 00:00.000
    end:   00:04.840
```

So nothing downstream had to learn the word: it is in the library under
**memes**, it drags onto the programme, and it renders. The `source:` block is
what makes a project publishable — it says where the material came from and
carries the mark the service requires — and, like every other key in a take
file, an older build will not throw it away.

A meme is silent, and a silent clip is one AVFoundation's exporter refuses to
write on its own, so the download gives it a track of its own silence. The
picture is copied rather than re-encoded.

The project has to be saved first, exactly as it does before a take can be
added: every path in a project is relative to the project file.

**A key is needed**, and there is none in this repository. Put one in
`~/.config/cuttr/config.yaml`:

```yaml
giphy:
  key: your-key-here
tenor:
  key: your-other-key
```

or press ⌘, and paste it into **Settings**, which writes that same file.
`GIPHY_API_KEY` and `TENOR_API_KEY` in the environment win where they are set,
which is what makes `GIPHY_API_KEY=… make dev` a one-off — but an app launched
from the Dock inherits no shell, so the file is the one that always works. Keys
are free: [GIPHY](https://developers.giphy.com/dashboard/),
[Tenor](https://developers.google.com/tenor/guides/quickstart).

### Exporting a project

**File ▸ Export Project to Folder…** copies the project and everything it
depends on into one folder, with every path rewritten to point inside it:

    programme.cuttrproj
    takes/
      take-01.cuttr
      anchors/take-01/mia.path
    media/
      IMG_1800.mov
      mia.wav

What comes out can be zipped, put on a disk, and opened on a machine that has
never seen the originals. Names that collide are suffixed — two takes both
called `take` become `take` and `take-2` — and a recording referenced by several
takes is copied once and pointed at from each. Sidecars go under their take's
name, because two takes may both have an anchor called `mia`.

It copies whole recordings, not the parts in use. Trimming to the cut would make
a smaller folder and a worse one: clips are *named ranges of a recording*, and a
recording cut down is no longer the thing those ranges are ranges of — the
exported project could never be re-cut.

Missing files are reported rather than fatal. One recording left on a card
should not stop the other nine being exported, and the take still points at
where the file should be, so dropping it in later is the whole fix.

### Rendering

```
cuttr-render programme.cuttrproj            # writes output.file
cuttr-render programme.cuttrproj -o out.mov --solve
```

Or **Render…** in the composing window.

The preview and the export are the same thing, by construction: one
`AVComposition` for the cut and one Core Animation tree for the overlays, played
in the window and handed to the encoder for the file. There is no second drawing
path to disagree with the first.

The composing window watches the project file and re-reads it when it changes,
so the intended way to work is to keep it open beside your editor.

## Layout

    Sources/CuttrKit/       takes: clips, slugs, tags, timecode, waveforms, alignment
    Sources/CuttrCompose/   projects: queries, groups, overlays, anchors, renderer
    Sources/CuttrUI/        both tabs of the one window
    Sources/cuttr/          the app
    Sources/cuttr-render/   the renderer, without a window

## What is next

- **A transcript pane.** The model was built for it: a transcript is one more
  way to place a mark, not a different kind of document.
- **Cross-fades.** `transition:` is in the format and read; the renderer cuts.
