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
- Transcribes it on your own machine, so a sentence you can read is a clip you
  can make.
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
| `W` | name the selected clip after its first words |
| `⌥⌘T` | transcribe this take, on this Mac |
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

## The transcript — cutting by reading

`⌥⌘T`, or the button on the **words** pane, transcribes the take **on this
Mac**. `SpeechAnalyzer` with a `SpeechTranscriber` module, asked for word-level
times; on a system without it, `SFSpeechRecognizer` pinned to on-device. Nothing
is uploaded, and the one recogniser that might have — an `SFSpeechRecognizer`
that says it cannot work offline for your language — is refused rather than
used, with a message saying so. The first take in a language may spend a minute
fetching the model; it stays on the machine.

Then the take is words you can cut with:

- **drag across a sentence** and it becomes the in/out span — `⏎` makes a clip
  of exactly what was said;
- **click a word** and the playhead goes there;
- **play**, and the word being spoken is lit;
- **type a phrase** in the field to be taken to it, selected and ready for `⏎`;
- **`W`** names the selected clip after its first words, which is how `clip-7`
  becomes `so-the-driver-installs` without anybody typing it.

**The times are on the video's clock.** The recogniser listens to whichever file
has the better microphone — the separate recorder, on a real shoot — and that
file has a clock of its own, so `audio + offset = video` is applied to every
word before it is written down. Re-align the take afterwards and the transcript
is as re-alignable as the cuts are.

The words go in a sidecar the take names, the way an anchor's path does:

```yaml
words:
  path:       words/take-01.words
  recogniser: speech-analyzer   # on this machine; nothing was uploaded
  locale:     de-DE
```

```
# cuttr transcript — take-01
# speech-analyzer, de-DE, times on the video's clock
# start      end        word
7.867      8.167      Jetzt
8.167      8.407      hat
```

Three columns, because a recogniser mishears a name once per take and always
the same way, and in this format that is one line to correct in an editor. The
recogniser and the locale are in the take file because a transcript is a claim,
and next year "what wrote this, and in what language" is the first question.
`words: words/by-hand.words` on its own is the short form, for a file you made
yourself.

It is asked for **once**. The sidecar is read when the take is opened; the
button says "Again" when there are already words, because re-transcribing is a
minute of your machine for an answer that has not changed.

Measured against a five-minute German take whose recorder was rolling 11.093 s
before the camera: 430 words in twelve seconds of wall clock. Twenty-seven
places where speech restarts after a pause, checked against the camera's *own*
microphone with ffmpeg's `silencedetect`, agreed to a median of 89 ms and were
as close at 303 seconds as at 7 — no drift, only the difference between a close
mic and one across the room. Transcribing the camera's track instead needs no
offset at all, and the two independent transcripts agree on when speech starts
to a median of **7 ms**.

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

**Things are made where they will live.** The timeline's `+` offers everything
that can go on one — a clip, a section, a card, any kind of overlay, a sound —
and so does `Add ▸` on any row's own menu. What is added lands relative to what
is selected: inside a selected section, after anything else, and an overlay
added on a clip is *written inside that clip*, where it covers that placement
and needs no name to be found by. Drag one from a shot to a section and it
belongs to the section; drag it to the heading at the end and it becomes one of
the global ones, still on at exactly the moments it was on before. Sounds move
the same way, and are shown in the same tree.

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
| `- card: 00:04.000` | time with no take behind it |

Any of them may carry `overlays:` and `sounds:`, which are the lists below
written two levels in.


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

**`at:` says where a movement sits against the mark.** `in:` and `out:` say how
an overlay arrives and leaves, `over:` says how long that takes, and `at:` says
where that length goes:

| | |
|---|---|
| `at: before` | the movement has finished by the time the mark arrives |
| `at: across` | the mark falls in the middle of the movement |
| `at: after` | the movement begins at the mark |

```yaml
  - film:  sepia
    from:  demo-install
    in:    {fade: true, over: 1, at: before}
```

Read against the mark, so one set of words does both ends — which is why the
*defaults* are different words at the two: `after` at the first mark and
`before` at the last, because that is the arrangement in which nothing is on
screen outside the span. `before` therefore reads as a change at the start of an
overlay and as the way it already was at the end. Same word, same meaning; the
mark it is measured from is what moved.

An overlay whose movement is placed outside its span is **drawn** outside it,
and that is the point — a grade finished when the clip starts has to have
started before it. The span itself does not move: it is still what the file
says, still what the timeline draws, and still what a `keys:` entry's `t` counts
from, so adding `at:` re-times nothing. A cut has no length and takes no `at:`.

**An overlay can also be written inside the entry it is drawn over.** Given no
range of its own it covers exactly that placement — which is the one thing a
name cannot say, because `from: intro` finds *every* use of `intro`:

```yaml
timeline:
  - clip: intro
    overlays:
      - text: The first time
  - clip: demo
  - clip: intro
    overlays:
      - text: And the second

overlays:            # still here, for the ones on the programme's own clock
  - text: Chapter one
    from: 00:10.000
    to:   00:14.000
```

Two placements of one shot, a different caption on each, and no names invented
to tell them apart. A nested overlay that *does* write a range — `within:`,
`from:`/`to:`, `when:` — means exactly what it would mean at the top level;
being written there is then only a statement about where it is filed. The same
keys either way, so there is one shape to learn.

An entry carries `sounds:` on exactly the same terms: written there and given no
range, a sting plays for as long as that placement is on.

### Scenes — intro screens and title cards

A **scene** is a thing made of parts and keyframes that an overlay puts on the
programme: an intro screen, a title card, an end plate. It lives under
`scenes:` in the project file, so it diffs, it is reviewed, it is copied
between projects, and it is edited by anything that edits text. `{{title}}` in
a part's words is filled in by the overlay that uses it, which is what makes
one scene serve every episode.

Four kinds of part:

| written | what it is |
| --- | --- |
| `- text: "{{title}}"` | words, in a named `style:`, optionally `tracking:` |
| `- shape: "#ffffff"` | a shape — `kind:` rectangle, ellipse, triangle, diamond, star or hexagon |
| `- image: logo.png` | a file beside the project, fitted in its box |
| `- background: "#101418"` | the whole frame — or `{from:, to:, angle:}` for a ramp |
| `- bar: "#ffffff"` | a progress bar, with a `track:` behind it and a `direction:` |
| `- spinner: dots` | the spinner this program already has, standing in a scene |

A part that names a key the reader cannot read is **refused**, with the line
quoted back. A dropped line is the worst error this format can have: the file
says one thing and the program works from another, and the only sign is a frame
that does not look right.

Each part has `keys:`, one to a line, and **a key states only what changes**:
everything else is what it was at the key before, which is why a part that only
moves says its position twice and its opacity once. A key can say `t`, `x`,
`y`, `opacity`, `scale`, `rotation`, `width`, `height`, `progress`, `shape`,
`color`, `to`, `angle` and `ease`.

Four of those are what make a scene do things rather than sit there:

- **`color:`** overrides whatever the part was declared with, so a title
  arriving white and settling into the house colour is two keys and one field.
  On a background it is the *near* stop of the ramp — the part's `from`.
- **`to:`** and **`angle:`** are the rest of a background's gradient: the far
  stop and the direction. With them a ground ramps out of one gradient and into
  another, and it turns. A flat fill is a gradient whose two stops are the same
  colour, which is why a flat background can ramp into a gradient with nothing
  said about it beyond the `to:` it arrives at. The angle turns the **short way
  round** between two keys — 350 and 10 are twenty degrees apart — so a whole
  turn is written as the keys it turns through rather than as `0` and `360`,
  which are the same direction. `examples/scenes/gradient.cuttrproj` is both.
- **`progress:`** is how full a bar is, nought to one — and a spinner given one
  stops going round and fills a ring to that fraction instead. A bar filling
  over three seconds is `progress: 0` at one key and `progress: 1` at another,
  and it gets the easing that key already carries for nothing.
- **`shape:`** names a kind, and naming a different one from the key before
  **morphs** between them across that interval. Both outlines are cut into the
  same number of points at the same angles round the middle and matched up in
  order, which is honest about what it can do: the shape stays closed and
  convincing throughout, and no corner of either end survives exactly except
  where the angles happen to land on one.

There is a **window for making one**: the scenes are listed in the library
beside the programme, and double-clicking one opens it — or Compose ▸ Edit
Scenes…, or File ▸ New Scene…. It has the scene drawn at the output's size,
playing, with the parts dragged on it directly: a corner handle scales, the
handle above turns, and a drag writes into the key at the playhead or makes one
there. A shape's kind is a menu on the part and again on a key, where naming a
different one is how a morph gets written down. The panel beside it is in two
halves under two headings — **the part**, which is what it is before the first
key says otherwise, and **keys**, which is what changes and when — with the rule
relating them printed between the two, and every field's explanation behind the
`?` on its heading, the same as the properties panel. Inherited values are dim
and in brackets, with a button to claim them.

A scene has no length of its own, and the editor's "runs for" box is not
written to the file. A scene plays for as long as the overlay using it is on
screen — which is what lets one intro run four seconds in this episode and six
in the next.

### Cards — programme with nothing behind it

An intro screen is a stretch of programme that exists to be drawn on, so it is
not a reference to anything. A card is a length and a colour:

```yaml
timeline:
  - card:  00:04.000
    fill:  "#101014"
    as:    intro
  - intro-shot
```

`fill:` is one colour, or two read down the page — `fill: ["#202030",
"#050508"]` — for a vertical gradient, and it is left out altogether when the
card is black, which is what a card is when nobody says. Everything else about a
card is what any entry has: `as:` names the placement so an overlay can hang on
`@intro`, `transition:` lets the first shot dissolve out of it, and it goes
inside a `group:` like anything else. Overlays and film mode draw over a card
exactly as they draw over a shot, because a card is only the picture underneath.

Nothing plays under a card: the sound stops where the shot before it stopped and
starts again with the next one.

### Sounds — audio that is not from a take

Music, an atmosphere, a sting. A take is a recording somebody cut into clips,
and a music bed is not that, so it lives at the top level beside the overlays:

```yaml
sounds:
  - file:  music/opening.wav
    group: intro
    gain:  -6
    in:    {fade: true, over: 0.5}
    out:   {fade: true, over: 1.5}
    ducks: 8
```

**When it plays is said in exactly the words an overlay uses** — `group:`,
`from:`/`to:`, `within:` a clip and its two times, or plain programme times —
because it is the same question, and the same rule applies: bound to marks, a
sound moves when the takes are re-cut. A clip used twice is two places, so a
sound hung on it plays twice rather than across the middle.

`gain:` is decibels on the file as it is. `in:` and `out:` are fades (only a
fade means anything to a sound; it cannot slide in from the left). `ducks:` is
how far the programme's own sound is pulled under this one, in decibels — it
goes down as the sound fades up and comes back as it fades away, so it reads as
room being made rather than as a drop. A sound shorter than its span stops
rather than starting again.

Sounds that are not on at once share one lane; two that overlap get one each.
Paths are relative to the project file, the same as the takes, and a file that
is not there is named rather than left as a silent track.

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

### Bubbles — somebody in the picture saying something

A speech bubble, a thought bubble, or a box with an arrow, drawn by hand and
pointed at a face. One line to say it, one more to say who it is about:

```yaml
overlays:
  - bubble: still thinks glitter is a colour
    anchor: mia-eye
    within: mia-close
    from:   00:02.000
    to:     00:06.000
```

**`anchor:` here means what it points at as well as where it sits** — the one
place in this format where that word does two things, and the difference is the
point. The paper stands off from the anchor by `offset:` and travels with it; the
tail reaches back to it and is redrawn at every sample of the tracked path. So
she can walk across the shot with the bubble going along beside her and the tail
swinging round to keep up.

**How it travels is the interesting half.** A bubble is *read*, and words that
jitter under the reader cannot be — and a tracker's answer does jitter, because
each sample is a fresh measurement and not an object with momentum. So the paper
follows the *slow* part of the anchor: a centred, cosine-weighted average over
six tenths of a second, which is nine of the anchor's ten-a-second samples.
Centred, so it costs no lag at all — a symmetric average reproduces a steady walk
exactly, and the suite measures it at 575.99 px where the face moved 576.00.
What it costs instead is three tenths of a second of anticipation: the paper
begins to drift a moment before the face does, which on a walk is invisible and
is much the better trade, since a bubble that trails a face looks dragged. The
jitter comes out a hundred times smaller: 0.03 px a frame against 2.91.

A face that walks out of the side of the shot cannot take the words with it. The
paper slows as it comes up to the frame's margin and settles against it — a soft
knee rather than a clamp, so it comes to rest instead of stopping dead on one
frame — and the tail goes on alone.

`follow: false` puts it back the way it was: placed once, where the face was when
it came on, and still, with only the tail following. Right for a bubble pinned to
the corner of a graphic, and for a shot where the stillest thing is the best
thing.

Where the tracking stops, the tail stops: outside the stretch the anchor was
actually solved over, the bubble keeps its words and simply loses its tail. A
tail held on the doorway somebody left through says the tracking is still
working when it is not. If she is still in the shot but outside the frame, the
tail lies along the edge she went out by and goes on pointing that way.

`at: [x, y]` points at a fixed spot instead — for the things that are not faces,
and for a programme with no footage in it at all, which is what lets
`examples/overlays/bubbles.cuttrproj` render on any machine.

**Two positions, and they are two words.** A tracker follows what a tracker can
follow, which in practice is an eye. Where the tail should *land* is usually
somewhere else — the mouth, the top of the head, the hand, the thing she is
holding — so a bubble carries both:

```yaml
overlays:
  - bubble: the good chair
    shape:  box
    anchor: mia-eye
    offset: [0.14, 0.2]     # where the paper sits
    tail:   [0, -0.18]      # where the tip goes — her mouth, below the eye
```

Both are measured from the same place, the thing the bubble is about, and both
are in fractions of the frame **height** on each axis, as every offset in this
format is. `offset:` moves the paper; `tail:` moves the tip; neither moves the
other. `tail:` is nought by default — the anchor itself — so the two-line bubble
stays two lines, and because it is measured from the anchor rather than from the
frame, a tail aimed at her mouth is still on her mouth once she has walked.

The tail follows the raw anchor rather than the smoothed one the paper uses: a
tail is a line and is allowed to be lively, and one lagging the face by the width
of the smoothing would visibly miss the mouth it is coming out of.

| | |
|---|---|
| `bubble:` | what it says. The whole of the common case |
| `shape:` | `speech` (a tail), `thought` (a trail of shrinking puffs), `box` (a bent arrow) |
| `style:` | a style from `styles:`; the built-in `bubble` is dark ink on nothing |
| `fill:` `line:` | the paper and the drawn line |
| `width:` | how wide the words may get, as a fraction of the frame. **A maximum, not a size** |
| `seed:` | the wobble |
| `breath:` | how much the line breathes. 1 by default, 0 for the still drawing |
| `follow:` | whether the paper travels with the anchor. It does; `false` leaves it where it was put |
| `at:` | a fixed spot to point at, when no anchor does |
| `offset:` | **where the paper sits**, from that spot. Written into the file the first time it is saved, because a default nobody can see is a default nobody can nudge |
| `tail:` | **where the tip goes**, from the same spot. `[0, 0.08]` on an eye is the head above it |

**Nothing says how big it is.** The words wrap to `width` and the paper grows to
whatever comes out — downwards. A long joke gives a taller bubble, never one off
the side of the screen, and the box is pushed back into frame if it was written
too near an edge.

**The wobble is a seed**, exactly as an effect's cloud is: the same number draws
the same shaky line on every machine and in every render, so a bubble somebody
approved is a bubble they can get back. Two renders of one project decode to the
same bytes, and the suite checks it by rendering both and comparing.

**And the line breathes.** A drawn bubble that is perfectly still next to a
moving face reads as a sticker, so it is redrawn — eight times a second, each
drawing *held* until the next, which is what a cartoon does when it holds a
drawing for two or three frames. Twenty-five a second is not more alive, it is
noise: above the rate an eye can follow, a drawn line stops reading as a hand and
starts reading as a fault, and it is exhausting to watch next to a face. The line
moves by about a pixel at 720p — a third of its own width — so what is seen is
the same bubble put down again, not a bubble changing shape.

The beat is the programme's, and the drawing is a function of the seed and the
time and nothing else: the same instant of the same project is the same drawing
however it was reached, so a preview scrubbed backwards and an export agree, and
nudging a `from:` does not redraw a single frame. What breathes is the outline,
the thought bubble's puffs and the box arrow's shaft — never the words, and never
the arrow's tip, which goes on pointing at exactly what it pointed at.

`breath: 0` is the still drawing, byte for byte the bubble this program drew
before any of this existed, for a bubble pinned to a corner of a graphic where
being alive is not the point. `breath: 2` is twice as lively; four is what the
last card of `examples/overlays/bubbles.cuttrproj` is there to warn about.

An anchored bubble's tail — and the paper, and the words on it — is stepped with
everything else while it is breathing: where the bubble sits and where the tail
points are both part of the drawing, and a bubble gliding under an outline that is
stepping is two different hands. It costs up to an eighth of a second behind the
face, less than the spacing the anchor was solved at, and it buys type that is
*identical* for three frames at a time rather than resampled onto the pixel grid
on every one of them — a travelling bubble is as sharp as a still one, which is
the thing following usually costs. A still bubble interpolates as it always did.

`keys:` are refused, by name: a bubble has nothing a keyframe could honestly
move. It arrives and leaves by `in:` and `out:` — a fade, by default, because a
bubble that slid in from the left would be one whose tail swung across the frame
looking for the face — and what it says at each of several appearances goes
under `when:`, the same as a caption's.

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

### Effects that come on — `keys:`

`in:` and `out:` scale the whole of an effect on its way in and out. That is one
shape, and it is the shape of *arriving*. `keys:` move the parameters
themselves, so an aberration can grow, rain can start as a drizzle and turn into
a downpour, and a tape can get worse for two seconds and settle — while the
effect is fully on.

```yaml
overlays:
  - aberration: radial
    amount:  0.2
    keys:
      - {t: 0}
      - {t: 1.5, amount: 1.2, ease: out}
      - {t: 3.0, amount: 0.1, ease: in}
```

The vocabulary is the one scenes already use, and deliberately not a second
spelling of it: `t` is seconds from the start of the overlay's own appearance,
a key states only what changes, anything it leaves out is what it was at the key
before, and `ease` is `linear`, `in`, `out` or `inOut`. Before the first key
everything is what the overlay itself says above, so adding `keys:` never
silently changes what an overlay was.

| | |
|---|---|
| `film:` | `ratio` `strength` `grain` `vignette` |
| `aberration:` | `amount` `angle` |
| `tape:` | `jitter` `band` `chroma` `scanlines` `dropouts` |
| `effect:` | `density` `speed` `size` `wind` |

`ratio` on a key is the single number the shape is — `2.39`, not `2.39:1` —
because a key states the quantity that moves.

**Anything not in that table is refused by name, with the reason.** A seed
cannot move: the same number giving the same cloud on every render is the whole
of what a seed is for, and one that changed half way through would be two clouds
cut together rather than one cloud moving. A stock, a condition, a finish and a
style cannot move either — there is nothing half way between `warm` and `noir`.
Cross-fade a second overlay over the first for those. A key asking for one of
them stops the file from opening rather than being quietly dropped, because an
animation that silently does nothing looks exactly like an animation nobody
wrote.

**`speed` and `wind` are integrated, not multiplied.** A drop's position is the
area under its speed; multiplying the speed at this instant by the time so far
surges the whole cloud the moment the number changes — seven times the distance
in the frame after the key, for a speed going from one to four over a second.
The wind is integrated *against* the speed, because a piece falling twice as
fast covers twice the ground sideways while it does it.

**`density` does not make new pieces.** A cloud is built once and cannot grow a
piece half way through a render, so an animated density is read as the fraction
of the cloud allowed to fall: the shower is built for the heaviest it ever gets,
and a piece that is not falling this time round is held back above the top of
the frame rather than vanishing where you can see it.

`examples/effects/coming-on.cuttrproj` is all of it in ten seconds, and renders
with no footage at all.

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

A meme from either service has **no sound**: both serve them as silent mp4s, because they are GIFs underneath. Giphy's Clips — the ones with audio — are behind an endpoint that answers 403 to an ordinary key.

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

### Every pause leaves a version

Where a project lives in a git repository, saving it leaves a commit, so that
when something is wrong an hour later there is a version to go back to.
**File ▸ Versions…** (`⇧⌘Y`) lists them — when, and what changed — and puts one
back.

A version per thought, not per keystroke. The project window writes its file on
every edit, so a commit is made after a few seconds of quiet and once more when
the window closes. Nothing is kept when nothing changed, when the project is not
in a work tree — a footage volume is not one, and that is the ordinary case — or
while a merge or a rebase is in progress.

What goes in is the project and everything textual it is made of: the
`.cuttrproj`, every `.cuttr` it names, and their sidecars — the `words:` files
and the anchor paths. Not footage, not renders. Going back has to restore a
coherent state rather than half of one, because a project whose takes have since
been re-cut points at clips that have moved.

**It does not touch your repository.** Not the working tree, not the index, not
`HEAD`, not the branch you are on, and it never pushes. Versions are hashed and
committed with git plumbing onto `refs/cuttr/saves`, which is a ref and not a
branch — so it stays out of `git branch`, out of Fork's sidebar, and out of this
program's own branch menu in the title bar, where tens of machine-made commits a
day would have buried the one useful list. Read it like any other ref:

```
git log --stat refs/cuttr/saves
git show refs/cuttr/saves:takes/take-01.cuttr
```

Restoring writes files and moves nothing, and the state you are leaving is kept
as a version first — so going back is not a way to lose what you were doing. It
waits for any take window open on that repository to be closed, for the same
reason a checkout does: a take window holds its cuts in memory and would write
them straight back over the version.

## Layout

    Sources/CuttrKit/       takes: clips, slugs, tags, timecode, waveforms, alignment
    Sources/CuttrCompose/   projects: queries, groups, overlays, anchors, renderer
    Sources/CuttrUI/        both tabs of the one window
    Sources/cuttr/          the app
    Sources/cuttr-render/   the renderer, without a window

## What is next

- **Splitting on pauses, finding filler words, grouping repeated takes.** All
  three are easy now that the words and their times exist, and all three are
  about a transcript rather than about transcribing.
- **Cross-fades.** `transition:` is in the format and read; the renderer cuts.
