# cuttr 0.1.0

The first release. Cutting video as text: two plain-text files, one window, and
a renderer that turns them into a programme.

This is the version that became usable on real footage rather than on examples —
a forty-minute recording cut into named pieces, assembled with captions and
tracked overlays, and rendered. It is a first release and it is called 0.1.0 for
a reason, but nothing in it is a sketch: every part of the format round-trips,
and everything the window does, it does to the file.

## Cutting

A take is one recording and the named pieces cut out of it. Open a video — or a
video **and** a separately recorded audio file — and cut it from the keyboard:
`S` at each boundary, and each press closes off everything since the last clip
ended. Clips arrive called `clip-1`, `clip-2`, `clip-3` so they are usable
references from the moment they exist; naming is a second pass.

- **Two recordings, one clock.** Every time in a take is on the video's clock.
  The separate recorder's offset is the one number that relates them, so an
  alignment corrected later never moves a cut mark.
- **`A` finds that offset** by correlating what both microphones heard, usually
  within a millisecond, and jumps to the twenty seconds it measured so you can
  check it rather than trust it. Then use your ears: monitor **Both** and nudge
  with `[` and `]` until the flanging disappears.
- **Colours are lanes.** Marking looks only at clips of the same colour, which is
  what makes overlapping passes possible — sections in green, alternate takes in
  rose, neither working around the other.
- **Tracked anchors.** Click a face; Vision follows it, and an overlay hung on
  that anchor follows it in the render.
- **Import from DaVinci Resolve** — EDL, FCPXML or the older FCP7 XML.

## Composing

A project is a programme assembled from clips across many takes. Clips are
referenced by name, never by time, so re-cutting a take updates every project
that draws on it.

- **Sections, lists and queries.** `#b-roll and not #reject` selects on tags, so
  an assembly stays correct when a thirteenth b-roll shot is cut next week.
- **The same clip, used twice**, each use trimmed differently and named with
  `as:` so an overlay can point at one of them.
- **Ten transitions** — dissolve, dip to black, dip to white, wipe, push, slide,
  blur, flash and iris, four of them directional. Each is an overlap: the
  incoming shot starts before the outgoing one ends, and the programme is that
  much shorter.
- **Captions, spinners, scenes and effects.** Text in a named style; a spinner
  that cycles what it says; keyframed scenes built out of parts in the project
  file; and confetti, snow and sparkles rendered as lit 3-D geometry with matte,
  metallic and glitter finishes.
- **Overlays can go behind people.** Vision segments whoever is in the frame, on
  this machine, so confetti falls behind the person rather than sticking to the
  lens — and a caption can sit behind her too.
- **Times that survive being moved.** An overlay hangs on a clip or a section
  rather than on the programme's clock, so inserting a shot does not send every
  caption out by four seconds.

## The editor, and the file

The project window has a panel for all of it, and it is a teaching aid as much
as an editor: every field is labelled with the key it writes, and a pane shows
the YAML your selection produces, live, out of the same emitter that writes the
file.

- **Dialogs where guessing was.** Trimming plays the clip with its sound, on a
  timeline, with `I` and `O` to put the marks on the frame you are watching.
  Choosing what an overlay hangs on shows every clip under its take, searchable,
  with `as:` placements listed beside the sections.
- **The take's grade**, in the cutting window, with the picture beside it —
  exposure, temperature, tint, saturation and contrast, previewed live through
  the same arithmetic the renderer uses. It belongs to the take because a camera
  that runs warm runs warm in every programme that ever draws on the footage.
- **Stable files.** The emitter fixes key order, column alignment and quoting, so
  re-saving an unchanged take produces an unchanged file and "I renamed one clip"
  is a one-line diff. Unknown keys are carried through, so a file written by a
  later version survives being opened and saved by this one.

## Rendering

`cuttr-render project.cuttrproj`, or **Render…** in the window. The frames that
come out are the frames that went in: with nothing to grade and nothing drawn
over it, the picture never goes through a filter at all, which is what keeps a
cut exact. Where something *is* drawn, colour management is off end to end —
measured against the source, 117 against 118.

Audio is levelled to a target and ramped across every dissolve.

## Requirements

macOS 14 or newer, Apple silicon or Intel.
