## Context

    ┌──────────────────────┐        ┌──────────────────────┐
    │                      │        │ ┌──────┐             │
    │   the whole screen   │   →    │ │screen│  • one      │
    │      recording       │        │ │      │  • two      │
    │                      │        │ └──────┘  • three    │
    └──────────────────────┘        └──────────────────────┘
      picture, full frame             picture held aside,
                                      scene playing over all of it

Everything cuttr draws, it draws *over* the picture: captions, spinners,
bubbles, scenes, frame sequences. Nothing has ever moved the picture, and
nothing has ever changed how long a clip lasts. A clip occupies programme time
exactly equal to its own length —

    public var end: Double { start + clip.duration }
    func takeTime(forProgramme t: Double) -> Double { clip.start + (t - start) }
    func programmeTime(forTake t: Double) -> Double { start + (t - clip.start) }

— three straight lines, and the resolver, the renderer, the strip, the
transcript and every tracked anchor read them.

## Goals / Non-Goals

**Goals:**

- Move the picture into a rectangle and back, over a ramp.
- Hold the recording without losing any of it.
- Play a scene while it is held.
- Built-in scenes that take a handful of words and lay them out, so the common
  case needs no scene authoring at all.
- A project with no treatments behaves exactly as it does now, byte for byte.

**Non-Goals:**

- Not general speed control. This is stop and go, not 0.5×. A ramp exists to
  make the stop look deliberate, not to be a parameter anybody sets a curve on.
- Not a second compositing path. The scene is an ordinary scene, full frame,
  through the machinery scenes already go through.
- Not picture-in-picture of two takes. One picture, moved aside.
- Not a layout engine. `bullets` and `boxes` are two scenes with parameters, not
  the beginning of a template language.

## Decisions

### The treatment lives on the placement, not in `overlays:`

`TimelineEntry` already carries `overlays:` and `sounds:` written inside it.
Treatments go there too:

    - clip: install-demo
      presentations:
        - at:    00:12.000
          into:  [0.04, 0.22, 0.40, 0.40]
          hold:  6
          ramp:  0.6
          scene: bullets
          with:  {one: "Download it", two: "Open it", three: "Drag it across"}

**Why not an overlay.** An overlay would have been free — spans, the properties
panel, the strip, drag-to-move, `within:` — and it cannot work. An overlay's
span may be written in programme times, the hold *changes* programme times, and
the resolver would need the layout to place the overlay and the overlay to
compute the layout. Anchoring `at:` to the clip's own clock breaks the circle:
the clip's clock is known before anything is laid out.

It is also the truer statement. A hold is a fact about *this use of this
recording* — the same clip used twice elsewhere should not stop there too — and
`presentations:` written inside the entry is the file already saying that, in
the same way `as:` and a nested `overlays:` do.

### The programme stretches, and the mapping becomes piecewise

A resolved clip gains its holds, and the three straight lines become steps:

    programme  ├────────────┤═════ hold ═════├──────────────┤
    take       ├────────────┤                ├──────────────┤
                            ↑ take time stands still here

`duration` is `clip.duration + holds`. `takeTime(forProgramme:)` subtracts the
holds already passed and clamps inside one. `programmeTime(forTake:)` adds them.

**Every reader of those three goes through them and none may do the arithmetic
itself.** That is the whole risk of this change: an anchor is sampled on the
take's clock and mapped forward, so a caller that assumes a straight line puts
a tracked face where the recording would have been if it had not stopped — which
is precisely the drift `within:` exists to prevent. The methods are the only
place that knows, and a test asserts the mapping is inverse to itself across a
hold.

### `into:` is one rectangle, not a zoom and a side

`[x, y, width, height]` in fractions of the frame, as `at:` and `width:` already
are elsewhere. A zoom level plus a position is the same information in two
numbers that can disagree — "40% on the left" has to say what "on the left"
means at 40% — and a rectangle says it once. Aspect is preserved by fitting
inside it, so a rectangle of the wrong shape letterboxes rather than distorts.

### The ramp is one number, and it is not a curve

Seconds, for the travel out and the travel back. Eased, because a picture that
arrives at a stop linearly reads as a jump cut into a still.

A curve was considered and rejected: this is the one gesture in the feature that
nobody will tune more than once, and every parameter that exists has to be
explained, drawn in the properties panel, and carried through the merge.

### The scene is an ordinary scene, full frame

The scene draws over the whole frame and is authored to leave the picture room.
The alternative — handing the scene the vacated rectangle as its canvas — reads
better and would let one scene work at any zoom or side, and it means `Scene`
gains a notion of being drawn into a sub-rectangle that every part, keyframe and
anchor in it would have to respect. Full frame reuses the compositor unchanged.

### `bullets` and `boxes` are scenes, not a new kind of thing

Named scenes resolved like any other, so a project that defines its own `bullets`
wins — the rule `TextStyle.builtIn` already follows. They take `one:` through
`five:`; the ones given are the ones drawn.

`reveal: together` or `reveal: one-by-one`, and one-by-one splits the hold
evenly: five snippets over six seconds appear every 1.2. Nothing to write down,
and dragging the hold longer re-times them.

## Risks / Trade-offs

- **A piecewise mapping that a caller ignores is a drifting overlay.** → The
  three methods are the only place the arithmetic lives; a test asserts they are
  inverse across a hold, and the anchor path gets one of its own.
- **Holding the picture holds its sound.** Narration recorded into the screencast
  stops with it. → It is in the release notes and in `docs/`, said as a
  consequence rather than discovered in a render. The separate recorder track is
  the answer, and it already exists.
- **`AVMutableComposition` has no "freeze".** → A one-frame range scaled to the
  hold's length is the standard answer and is what the renderer does. The
  measurement to watch is whether a long hold on a long-GOP screen recording
  decodes acceptably; a still image inserted as a track is the fallback.
- **The strip and the timeline draw clips by their length.** A clip that is now
  longer than its footage will be drawn wrong by anything that still computes
  `end` itself. → The same rule: `ResolvedClip.duration` is the only answer.
- **The emitter must stay diff-stable.** → `presentations:` is written in the
  order the file had it, like every other nested block, and the round-trip test
  covers a treatment with and without each optional key.
