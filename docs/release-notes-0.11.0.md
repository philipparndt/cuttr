# cuttr 0.11.0

cuttr can make a screencast now, and it can stop one to explain what is on
screen. Those are the two ends of the same job: the first recording a project
needs, and the thing that turns four minutes of somebody using a computer into
something worth watching.

## Presentations

A screen recording shows what somebody did and not why. The usual answers both
cost something: cutting to a card loses the picture at the moment it was making
its point, and a caption over it fights what is underneath.

    ┌──────────────────────┐        ┌──────────────────────┐
    │                      │        │ ┌──────┐             │
    │   the whole screen   │   →    │ │screen│  • one      │
    │      recording       │        │ │      │  • two      │
    │                      │        │ └──────┘  • three    │
    └──────────────────────┘        └──────────────────────┘

**The picture moves aside, stops, and something plays beside it** — then carries
on from exactly where it stopped. Nothing of the recording is skipped: a
twenty-four second capture with three six-second holds is a forty-two second
programme with every frame still in it.

    - clip: install-demo
      presentations:
        - at:     00:12.000
          into:   [0.04, 0.22, 0.42, 0.56]
          hold:   6
          scene:  bullets
          with:   {one: "Download it", two: "Open it", three: "Drag it across"}
          reveal: one-by-one

**`at:` is on the take's clock**, the same clock the clip's own marks are on. It
has to be: a hold *changes* programme times, so a treatment written in them would
need the layout to know where it was before the layout could know how long the
clip runs. It also means re-trimming the clip or moving it about the timeline
does not move the treatment.

**`into:` is where the recording goes**, not where the words go. The scene lays
itself out in whichever side is left free. Everybody reads this backwards the
first time, so the properties panel now draws it: the frame at the shape of the
output, the recording in its box, and the free side shaded and named for the
scene that will fill it. Drag the box to move it, its corners to resize it.

**`bullets` and `boxes` come with the program.** They take `one:` through
`five:`, draw only the lines given, and lay themselves out in whatever side of
the frame the picture left. `reveal: one-by-one` divides the hold evenly, so
dragging the hold longer re-times the lines and there is nothing to keep in step
by hand. Define a scene of your own called `bullets` and yours wins.

**A hold is silent.** A frozen picture over running narration reads as a dropped
frame rather than as a deliberate stop, so the clip's own sound stops with its
picture. Narration goes on the separate recorder, which is what the offset in a
take file has always been for.

Each treatment is a row of its own in the programme tree, under the clip it
holds — select one and the panel is about that one, space takes a look at the
whole gesture, and it can be copied, dragged onto another clip, or duplicated
like anything else there.

`examples/presentation/` is the whole feature in one file.

## Recording a screencast

Everything else cuttr does begins with a recording it did not make. **File →
Record**, or ⌘6.

    recordings:
      - as:      install-demo
        url:     https://example.com/download
        size:    1280x720
        chrome:  bar

**The browser is cuttr's, not yours.** Started with a profile directory inside
the project: no bookmarks, no extensions, no signed-in account, no
notifications. Your own browser is not touched, restarted or closed. The profile
is kept, so a page that needed a cookie accepted keeps it next month.

**The address bar is in the film.** A screencast is somebody being shown how to
do a thing, and where you are is half of that — "go to the downloads page" is a
sentence about an address bar. The fresh profile is what makes it affordable:
what is left above the page is back, forward, reload and the URL. `chrome: none`
takes it away.

**The window is captured, not the screen.** A notification sliding over it is not
in the recording, and a window nudged half way through does not walk out of
frame.

**Terminals too** — Terminal, Ghostty and Abydos:

    recordings:
      - as:       the-build
        terminal: ghostty
        in:       ~/dev/cuttr
        run:      [make build]
        theme:    midnight

cuttr starts the shell where you say, with a plain prompt and a clear screen, and
runs what you ask. It will not start a shell without your own startup files —
that is not the shell you use — so an alias, a version manager's banner or a
prompt that draws itself will be in the film. The panel says so before the first
recording rather than leaving you to find it in the finished piece.

**What comes out is a take**: the media beside the project and a take file for
it, on the recording's own clock from nought. Recording the same thing twice
never overwrites the first, because the reason to record it again is nearly
always to compare the two.

Under 15 MB a minute at 720p. A screen recording is not footage and compresses
nothing like it — flat colour, hard edges, and long stretches where nothing moves
— so it is HEVC, with keyframes four seconds apart and identical frames not
written at all.

Screen recording needs the system's permission, which is granted in System
Settings and cannot be asked for from inside an app. cuttr checks before opening
anything, including the case that wastes the most time: granted *since cuttr
started*, which reads as granted and records black frames. Quit and open it
again, and it says so.

See `docs/screencasts.md`.

## The scene editor

**A shape can be drawn.** A new one arrives as a block rather than a hairline
rule, and the corner handles of anything with a size of its own — a shape, an
image, a bar, a sequence — now *resize* it rather than multiplying what it
already was. There was no gesture that turned a 0.4 × 0.01 rule into a block;
now there is. Shift keeps the proportions.

**A drag says where it has got to** — the position, the size, the scale or the
angle, on a plate under the part while the mouse is down. The scrubber says it
too: a key dragged along its lane shows the time it will land on, with a thread
back to the mark it came from.

**A background can be a picture.**

    background: {from: "#101418", to: "#1d3557", image: backdrop.png}

Over the fill rather than instead of it, so a PNG with transparency in it sits on
the colour. Filled to the frame, not fitted: a background is the ground, and
ground with a margin round it is not ground.

## Fixed

**A render that failed for good.** A programme made of nothing but title cards
could fail to export with `Cannot Decode` — every time, for ever, with nothing in
the failure naming a cause. Cards are carried on a few seconds of generated
black, and that file was kept between runs under a fixed name; one left behind by
a render that did not finish poisoned every later render of that shape. It is now
written per launch and moved into place whole. It shipped in 0.10.2 and earlier.

**Editing a project no longer stalls the window** for about a second on every
change.

**Editing a timeline entry no longer discards what is written inside it.**
Renaming a clip or nudging its trim silently threw away the `overlays:` and
`sounds:` written in that entry.

**The picture in the properties panel no longer jumps** when a drag ends.
