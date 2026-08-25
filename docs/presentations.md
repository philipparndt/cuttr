# Presentations — the picture moved aside and held

A screen recording shows what somebody did. It does not show why, and the two
usual ways of adding the why both cost something: cutting away to a card loses
the picture at the moment it was making its point, and putting a caption over it
means the words and the thing they are about are fighting for the same frame.

A **presentation treatment** is the third way. At a moment you choose, the
picture travels into a rectangle, stops, and something plays beside it for as
long as you want; then it travels back and the recording carries on from exactly
where it stopped.

    - clip: install-demo
      presentations:
        - at:    00:12.000
          into:  [0.04, 0.22, 0.42, 0.56]
          hold:  6
          ramp:  0.6
          scene: bullets
          with:  {one: "Download it", two: "Open it", three: "Drag it across"}
          reveal: one-by-one

`examples/presentation/` is the whole feature in two files, with the footage it
needs made by a third.

## The keys

| | |
|---|---|
| `at:` | when it happens, **on the take's clock** |
| `into:` | where the picture goes: `[x, y, width, height]` in fractions of the frame, origin bottom left |
| `hold:` | how long the picture stands still, in seconds |
| `ramp:` | how long the travel takes at each end, in seconds — `0.6` unless you say otherwise |
| `scene:` | what plays while it is held |
| `with:` | what to fill the scene with |
| `reveal:` | `together`, or `one-by-one` to spread the lines across the hold |

## Four things that are not obvious

**`at:` is on the take's clock, not the programme's.** It is the same clock the
clip's own `start:` and `end:` are on, which means re-trimming the clip or moving
it about the timeline does not move the treatment. It has to be that way round:
a hold *changes* programme times, so a treatment written in them would have to
know where it was before the programme could be laid out.

**The programme gets longer, and nothing is skipped.** A twenty-four second
recording with three holds of five, six and four seconds is a thirty-nine second
programme. Every frame of the recording is still in it. This is the difference
between a hold and a cut to a still: afterwards, the picture picks up on the
frame it stopped on.

**A hold is silent.** The clip's own sound stops with its picture — a frozen
frame over running narration reads as a dropped frame rather than as a deliberate
stop. So anything said over a hold goes on the separate recorder, which is what
`audio:` in a take file is for and why alignment lives there rather than in the
project. Music and sound written in `sounds:` are unaffected: they are on the
programme's clock and play straight through.

**Fit, not fill.** The picture keeps its shape inside `into:`, so a rectangle of
the wrong aspect letterboxes rather than stretching the recording. Sketch the box
roughly and it will still look right.

## `bullets` and `boxes`

Two scenes come with the program. They take `one:` through `five:`, draw only the
lines given — a gap in the names closes up rather than leaving a space — and lay
themselves out in whichever side of the frame the picture has left free, so the
same scene works with the picture on either side.

`reveal: one-by-one` divides the hold evenly: five lines over six seconds appear
every 1.2. Drag the hold longer and they re-time themselves; there is nothing to
keep in step by hand.

They are ordinary scenes, resolved by name like any other, which means **a scene
of your own called `bullets` wins** — the same rule the built-in text styles
follow. `examples/presentation/explainer.cuttrproj` does exactly that for its
third treatment, and it is the answer to anything the built-ins cannot say: they
centre their lines, because a scene part is placed by its middle and nothing can
measure a line of type before it is drawn. A list ranged left is two dozen lines
of authored scene.

## In the app

**A treatment is a row of its own.** In the programme tree it is filed under the
clip it holds, beside the overlays and sounds written there — one clip with
three treatments is one row with three under it, each saying when it happens,
which way the picture goes and how long it stops. Select one and the properties
panel is about that one: the moment and the hold, `left` and `right` buttons for
the two placements anybody wants, the rectangle if you want to be exact, and the
scene with its lines. Delete takes it off, the arrows move it past its
neighbours, and the clip's own form has the button that makes a new one.

**Space takes a look at it** — the whole gesture, from the picture starting to
move to the moment it is back: the ramp out, the hold with its scene, and the
ramp home. Not only the hold, because what you are usually checking is whether
the travel reads right, and a look that began with the picture already aside
would show you everything except the thing you were about to tune.

The programme strip marks the hold on the clip, because a clip with a treatment
is longer on the strip than its footage is and an unmarked bar would not match
anything you could measure in the take.
