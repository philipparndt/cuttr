# cuttr 0.3.0

A programme no longer has to be made of footage.

Cards are time with nothing behind them, scenes are things built out of parts
and keyframes, and between them a project can be a whole intro screen — no
takes, no media, nothing outside the file it is written in. There is a window
for building one, a place for music under it, and four more ways to interfere
with the picture.

## Intro screens

**Cards.** `- card: 00:04.000` is a stretch of programme with a colour or a
two-stop gradient behind it, and it takes `as:`, transitions and nesting like
any other entry. A shot dissolves into one and out of it.

**A scene window.** The third window kind, beside the cutting and composing
ones, because building a title card in the corner of the project panel was
never going to work. It draws the scene through the same painter the renderer
uses, so what is on the stage is what will be encoded — proved frame for frame,
36 to 43 dB PSNR against the export, h.264 and nothing else. Drag a part to
move it, a corner to scale, a handle to turn it; every drag writes a key at the
playhead. A lane per part in the scrubber, a diamond per key, and an inspector
that shows an inherited value dim and in brackets with a `set` beside it, so
what a key actually *states* is never in doubt.

**More to build with.** A background part, solid or a gradient. Colour that
moves between keys. Letter-spacing. Shapes that are shapes of something —
rectangle, ellipse, triangle, diamond, star, hexagon — and a key that names a
different one **morphs** to it rather than cutting: both outlines are cut into
the same points around the middle and matched up, so the halfway frame is
neither end. A **progress bar** and the programme's own **spinner** as parts,
both filled by `progress:` on a key.

**Scenes are material.** They sit with the takes in the project window, drag
onto the programme like clips — a drop brings its own card and hangs the scene
on it by name — and `Add ▸ Scene…` copies one out of another project, which is
what a template is for.

## Sound

`sounds:` is audio that is not from a take: music, an atmosphere, a sting. A
file, a span in the same `when:` grammar overlays use, a gain, fades, and
`ducks:` to pull the speech under it. Measured on a render: `ducks: 8` takes
speech from −18.1 to −26.1 dB and leaves the music alone.

## Four more ways to spoil a picture, deliberately

**Film mode** — bars closing to a wider shape, a stock, grain, a vignette, all
moving together with the fade at each end, so a shot can go to film and come
back inside its own length. **Chromatic aberration**, radial or flat.
**VHS tape** — tracking wobble, a noise band drifting up the frame, chroma
bleed, scanlines and dropouts, all deterministic from a seed. **Rain**, as
another lit 3-D effect with depth and wind in it, beside the confetti and snow.

**And an order.** Overlays are drawn in the order they are written, and film
mode takes its place in that list like anything else — so an aberration written
before a film overlay is under its letterbox and the bars stay clean, and one
written after it bends them too. Two arrows in the panel move a row up and
down. Captions, spinners and scenes are the exception and the panel says so on
the row: they are Core Animation layers laid over the finished picture in a
second pass, and always on top.

## Memes

Search Giphy from the project window, download, and what arrives is **a take
with one clip in it** — so nothing downstream needed a new idea. The media goes
in `memes/` beside the project and the take records where it came from. Put a
key in `~/.config/cuttr/config.yaml` or press ⌘, and paste it.

## Also

- **Masks are eight times finer.** The person mask was a 256-pixel shape
  stretched to fill a 1920 frame, which is what the staircase on a caption
  behind somebody was. Accurate now — 2016 × 1512, 52 ms a frame, and only on
  frames that need one.
- **A silent video renders.** A take whose video has no audio track failed to
  export at all. So did a programme that opened on one: the holes in a lane were
  written into an edit list, and the second shot's sound arrived at the top.
- **Right-click a clip** on the programme or in the library to be taken to
  where it was cut — the first frame *that placement* shows.
- **Delete** works in the four lists that have a minus button.
- Every entry row says what it carries: the trim, how it arrives, its `as:`
  name and what hangs on it.
- Six **examples** that render on any machine, in `examples/`.
- A **settings file** at `~/.config/cuttr/config.yaml`, and ⌘, to edit it.

## Requirements

macOS 14 or newer, Apple silicon or Intel.
