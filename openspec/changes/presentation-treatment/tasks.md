## 1. The treatment in the file

- [x] 1.1 Add `Presentation` — `at`, `into`, `hold`, `ramp`, `scene`, `with`,
      `reveal` — and `TimelineEntry.presentations`.
- [x] 1.2 `ProjectFile` reads a nested `presentations:` block; `ProjectWriter`
      writes it in the order the file had it, and writes nothing when there are
      none.
- [x] 1.3 Test: round-trips byte for byte, with and without each optional key; a
      project with none writes no block; the same clip placed twice is treated
      only where it was asked.

## 2. The clock, which is the substance of it

- [x] 2.1 `ResolvedClip` carries its treatments, and `duration` becomes its own
      length plus its holds.
- [x] 2.2 `takeTime(forProgramme:)` subtracts the holds already passed and
      stands still inside one; `programmeTime(forTake:)` adds them.
- [x] 2.3 Lay the programme out with the longer durations, so everything after a
      hold begins later.
- [x] 2.4 Test the mapping hardest of anything here: inverse across a hold, still
      inside one, unchanged for a clip with no holds, and correct with two holds
      in one clip.
- [x] 2.5 Find every place that computes a clip's end or converts a time by hand
      and route it through the two methods. An anchor that drifts through a hold
      is the fault this is guarding.

## 3. Moving the picture

- [x] 3.1 A rectangle for the picture at a moment of the programme: whole frame
      outside the treatment, the given rectangle during the hold, eased between
      over the ramp.
- [x] 3.2 Fit inside the rectangle rather than fill it, so a rectangle of the
      wrong aspect letterboxes.
- [x] 3.3 The compositor draws the picture through that rectangle.
- [x] 3.4 Test the arithmetic without rendering: at the ends, in the middle of a
      ramp, with no ramp, and with a square rectangle on a 16:9 picture.

## 4. Holding it, in the render

- [x] 4.1 `Renderer` inserts the clip up to the hold, a held frame for its
      length, and the rest after — a one-frame range scaled to the hold.
- [x] 4.2 The clip's own audio stops with the picture and resumes with it.
- [x] 4.3 Verify by rendering: a known frame is still on screen part way through
      the hold, and the frame after the hold is the one that followed it.

## 5. The scene while it is held

- [x] 5.1 The named scene plays full frame for the hold, resolved the way every
      named scene is.
- [x] 5.2 A treatment naming a scene nothing defines is said, not rendered
      empty.
- [x] 5.3 Test both, and that a project's own `bullets` wins.

## 6. `bullets` and `boxes`

- [x] 6.1 Build them as `Scene` values with parameters `one:`…`five:`, drawn by
      the compositor everything else goes through.
- [x] 6.2 Only the snippets given are drawn, laid out as though they were all
      there were, with no space kept for a gap in the names.
- [x] 6.3 `reveal: together` (the default) and `one-by-one`, dividing the hold
      evenly.
- [x] 6.4 Test the layout for two through five, a gap in the names, and the
      reveal times for five over six seconds.

## 7. Where somebody sees it

- [x] 7.1 The strip and the timeline draw a clip at its resolved length, and mark
      the hold, or a bar will not match what it plays.
- [x] 7.2 The properties panel edits a treatment: the moment, the rectangle, the
      hold, the ramp, the scene and its snippets.
- [x] 7.3 An example project under `examples/` that is the whole feature in one
      file, and a paragraph in `docs/` — including that a hold is silent.

## 8. Finishing

- [x] 8.1 `make test` clean, including the real-decode test.
