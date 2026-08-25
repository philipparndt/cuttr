## Why

A screen recording explains what somebody did. It does not explain *why*, and
watching a full-frame capture for four minutes is watching somebody else use a
computer.

What a good explainer does is stop, move the recording aside, and put the point
on screen beside it — three bullets, a box, a name — then carry on from exactly
where it stopped. cuttr can put things *over* the picture and it can cut to a
card with nothing behind it. It cannot make room beside the picture, and it
cannot stop the picture without losing the footage that would have played.

## What Changes

- **A placement can carry presentation treatments.** Each one says: at this
  moment of the clip, take the picture into this rectangle, hold it for this
  long, and play this scene while it is held.
- **The picture goes into a rectangle**, given in fractions of the frame. That
  is the zoom and the side in one thing — `into: [0.04, 0.2, 0.4, 0.4]` is a
  small picture on the left — and it is the same vocabulary overlays already
  use to place themselves.
- **A ramp**, in seconds, over which the picture travels from full frame to that
  rectangle and slows to a stop, and travels back at the end. One number for
  both ends.
- **The hold stretches the programme.** The recording stops where it stopped and
  resumes there; nothing is skipped and everything after moves later. **This is
  the first thing in cuttr that makes programme time and take time disagree**,
  and it is the substance of the change.
- **The scene plays full frame**, as scenes do now, authored to leave room where
  the picture will sit.
- **Built-in parametric scenes**: `bullets` and `boxes`, each taking two to five
  snippets. Together, or revealed evenly across the hold. They are named scenes
  like any other and can be overridden by a project that defines its own.
- **BREAKING for nothing.** A project with no treatments resolves, renders and
  reads exactly as it does now.

## Capabilities

### New Capabilities

- `presentation-treatment`: what a treatment is, where it lives in the file, how
  the picture moves and holds, and what that does to the programme's clock.
- `parametric-scenes`: the built-in `bullets` and `boxes`, their parameters, and
  how a reveal is timed.

### Modified Capabilities

None. `openspec/specs/` is still empty — three completed changes are waiting to
be archived — so there is nothing yet to write a delta against.

## Impact

- **Changed**: `TimelineEntry` gains `presentations`; `ProjectFile` and
  `ProjectWriter` read and write them. `Resolver` stops assuming a clip occupies
  exactly its own length, which is the real work: `ResolvedClip.end`,
  `takeTime(forProgramme:)` and `programmeTime(forTake:)` all become piecewise.
  `Renderer` inserts a held frame where a hold falls, and the compositor
  transforms the picture into the rectangle. `ProgrammeStrip` and the timeline
  draw the hold, or a clip's bar will not match its length.
- **Unchanged**: every file that has no treatments. The takes, the vocabulary,
  sharing, the material tree.
- **The consequence worth writing down**: holding the picture holds its sound.
  A treatment is silent unless something else is playing — a separate recorder
  track, or music. Narration recorded *into* the screencast stops with it. That
  is what "nothing is skipped" costs, and the doc says so rather than leaving
  somebody to find out in a render.
- **Risk**: anchors are sampled on the take's clock and mapped to programme
  time. A piecewise mapping that anything forgets to use is a tracked face that
  drifts during a hold, and drift is exactly the fault `within:` was introduced
  to stop.
