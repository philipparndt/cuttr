# cuttr 0.8.0

Pictures drawn somewhere else go on the frame, and a React-shaped component is
drawn by the browser macOS already has — nothing to install. Audio gets the fine
knob it was missing: a curve over the take, and a page for balancing takes
against each other. And an overlay written inside a clip now stays with the
clip.

## A component, drawn on the fly

`component:` is a part this program does not draw. A file of JavaScript is
handed to a `WKWebView` that is never in a window, and comes back as a folder of
PNGs that composite like any other picture — about seven milliseconds a frame at
1920×1080, off-screen, with no window.

`docs/remotion.md` costed the obvious way at half a gigabyte of Node and
Chromium, JIT entitlements and a notarisation surface, and concluded it was not
worth it. What it had not costed was the browser already on the machine. Nothing
is installed, nothing is fetched, and the bundle grows by React's 143 kB.

It is not Remotion and the key does not claim to be. What is implemented is the
shape — `useCurrentFrame`, `<Sequence>`, `interpolate`, `spring`, `Easing`,
`random(seed)`, `React.createElement` as `h` — and `Component` lists what is
not, which is `<Composition>`, `registerRoot`, `<Video>`, `delayRender`, every
`@remotion/*` package, and JSX, because a transpiler is three megabytes and a
compiler version that every baked frame depends on and nobody can see.

**Determinism is enforced rather than asked for.** `Math.random()` throws and
names `random(seed)`, the clock reads the epoch, `requestAnimationFrame` throws,
and a content rule list blocks every load the page could make — which is what
catches an `<img src="http…">` or a webfont, where overwriting `fetch` would do
nothing. A font family this machine has not got refuses the bake by name: a
browser substituting silently is a wrong render nobody is told about.

WebKit's own rasterisation moves between macOS releases, so **the baked frames
are the artefact** — cached beside the project, exported with it, and re-derived
only when the `bake` record no longer matches the size, the rate, the duration,
the props, the source or the runtime. Nothing bakes implicitly: not on save, and
never while drawing. In between, the resolver says which component is stale and
why. A JavaScript error arrives as `walks.js:34:` and the message, on the line
somebody wrote.

`examples/components/chart.cuttrproj` is the case that earns it: twelve bars
whose every position is arithmetic on the data, which as a `scenes:` block is
forty parts and a hundred and twenty keys holding the *result* of a layout
instead of the layout.

## Frame sequences

A `frames:` overlay takes a folder of numbered pictures, a frame rate, and the
vocabulary every other overlay has. Whatever drew them — Remotion, Blender, a
Python script — they arrive as pixels, so there is nothing for a second drawing
implementation to disagree about.

The sequence is *the numbered files in the folder, in numeric order*, not a
`%04d.png` pattern. A pattern reads a numbering claim out of the project file,
and then the file and the folder can disagree — which forces a rule about holes,
and every candidate rule is a frame nobody can see. This way there is no such
thing as a missing frame, and it does not matter that `remotion render
--sequence` counts from nought while `ffmpeg` counts from one. `--describe` says
how many pictures there are.

`fps:` is required: a folder carries no rate, and a guessed one runs the
animation at some fraction of the speed it was drawn at. `ends:` is `hold` or
`loop`; `stretch` is refused by name, because fitting the sequence to the span
would re-time somebody else's animation from a fact about the cut.

`tools/remotion/` is a Remotion project with a chart and a route and a script
that renders either into a frame folder. It is not in `make`, not in the suite,
and not in the bundle — a machine with no Node builds cuttr and renders any
project whose frames are already on disk.

## A level that changes over the take

There were two levels in a take and both are one number for a span: the
recording's own, which balances it against the others, and a clip's, which
balances the clips inside it. Neither can do anything about the door that slams
in the middle of a sentence. The only way to get a plosive down was to cut
around it, and cutting around it loses the sentence.

So a third, and the fine one: **`levels:`, a list of points in decibels on the
video's clock**, added to the other two rather than replacing them — the coarse
knobs stay useful, and taming a plop does not have to know what the take was
levelled to.

Straight lines between points, linear in amplitude, because that is exactly what
`setVolumeRamp` does: one ramp per interval, nothing subdivided, so the monitor,
the render and the line drawn over the waveform are one piece of arithmetic
rather than three approximations of it. Defined in decibels instead, the middle
of a fade would sit five decibels from where the mix puts it, and the drawing
would be a picture of something nobody would hear.

It is drawn on the lane that will be heard, and the waveform is drawn *through*
it, so a dip shows the plosive coming down. That is the point: a dip that takes
the plosive off and a dip that takes the word off are the same four numbers, and
the difference is only visible in the envelope and audible in the cutting room.
Press on the line to make a point and pull it down; ⌫ or the context menu takes
one away. The curve answers only a bare click, and anywhere further than four
points from the line still scrubs.

**"Tame the Peaks"** looks for short moments that are both out of keeping with
the passage they are in *and* near the top of the recording's own range, and
offers a dip over each. Both halves are needed: measured on five minutes of two
children in a room, the local test alone proposed a hundred and forty dips over
eight per cent of the take — a compressor, not a repair. With the second it
proposes seven, over half a per cent, and a gated loudness meter agrees they are
five units louder than what surrounds them. Offered dashed on the timeline until
⏎, because nothing automatic writes into somebody's audio unasked.

Verified by rendering: a tone with a burst twenty decibels over it, a dip across
the burst, exported twice. The burst came down 11.9 dB where the curve asked for
12, and the rest of the programme measured the same to a hundredth of a decibel.

## Levels: a page for comparing takes

A take's level was set in the take editor's set-up popover — a field in a window
showing one recording. But levelling is a *comparison*, and one take at a time
is the one thing you cannot compare, so the number was there to be typed and
mostly left alone.

**⌘4 is a page of them.** One row a take, every audio line at the same
seconds-per-point and the same amplitude scale, a slider under each. The longest
take fills the width and the rest end where they end — a row stretched to fit
would be a lie about which take is longer. The drawn amplitude is multiplied by
the take's own gain and clipped against its lane, the same conversion the mix
uses, so pushing one up until it flattens is the row saying so.

A row is what the take *contributes*, not the whole recording: the spans this
project uses, merged, which is also what the play button plays and what the
meter measures. Five minutes of tape of which twenty seconds is used would
otherwise be levelled against four minutes and forty of room tone.

**Measure** listens to every take at once, over those same spans, and matches to
the median.

## A shot can be duplicated with everything hung on it

The only way to reuse a treatment was to write it out again: a film look, a
bubble, a caption and a sting, re-hung by hand on the next shot.

Everything written *inside* an entry now comes with it — the overlays, the
sounds, and for a section everything inside it, all the way down. What does not
come is the project's own `overlays:` list: one that names this entry is not
written inside it, so it stays where it is and goes on covering the original.

Every name in the copy is freed against the ones the timeline already uses, so
`as: shot` becomes `shot-2` and `@build` becomes `@build-2`. That is not
tidiness — the resolver merges two entries answering to one name into a single
stretch of programme, so a duplicate that kept its name would take the caption
hung on it and quietly stretch it over both copies and everything between.
References within the copy follow it.

Three ways to ask: **⌥ while dragging**, **⌘C/⌘V**, and **Duplicate** on a row's
own menu. The pasteboard carries the entry as the file writes it, so ⌘C in the
tree and ⌘V in the project file's editor puts the lines in by hand.

## An overlay inside a clip stays with the clip

A real project lost the placement of three spinners with nothing to see: the
file was intact, it round-tripped byte for byte, and every version git had
recorded said the same. They had been written inside a clip but pinned to the
*programme's* clock, so the first change upstream moved the shot and left them
behind — five seconds early, over the shot before the one they were written on.

Dragging the bar of an overlay written inside an entry used to convert "covers
this clip" into `from:`/`to:` on the programme, which undoes the thing putting it
inside a clip was for. The same drag is now written relative to the clip. A
range that already says how it wants to be written keeps its spelling; only
programme times are turned into something relative.

And the resolver **says so** when it finds one that has already drifted. It does
not correct the file — the times are what somebody wrote, and this cannot know
which they meant — but it refuses to let it pass in silence, and it names
`within:` as the spelling that would have held.

**`within:` a clip means every use of it.** A clip the programme uses twice has
two placements and one slug, so `within: <slug>` put the overlay on at *both*.
A drag inside an unnamed clip used more than once now gives the entry a name,
once, and the range names that — `as:` names one use, and `within: @name` is the
only range that means this placement and no other.

## The programme's zoom, where somebody would look for it

Three reports of the zoom not working, and the last was not about a key at all:
there was no way to find it. There are now three buttons at the right of the
ruler — out, in, and the whole thing — sitting over the ruler, so a click
presses one rather than moving the playhead.

⌘+, ⌘− and ⌘0 work here too. They had been in the View menu all along and only
the cutting window answered them. ⌘9 frames the selected overlay. `i` and `o`
set the selected range's ends from the playhead.

**And the zoom keys no longer beep.** The guard asked for no modifier flags at
all, and there is no keyboard layout on which every one of `+ = - _` is a bare
key: on a German one `=` is Shift+0, and the keypad's plus and minus arrive
carrying `.numericPad`. Shift, the keypad and the function bit are not decisions
anybody made about which key this is, so they are ignored.

**The keys sheet is a panel**, in the fixed-width face its list was written for.
As an alert, a proportional font tore every space-aligned column apart, two
thirds of it was off the bottom of the screen, and it was modal — the wrong
shape for a reference, since the point of looking a key up is to use it.

## Fixes

- **A baked component came out at twice its size on a Retina display.**
  `snapshotWidth` is a width in *points*, and WebKit satisfies it with twice as
  many pixels on a Retina screen: a project asking for 1920×1080 baked to
  3840×2160 on a laptop and to 1920×1080 on a machine plugged into a projector.
  The frames are the artefact, so which Mac drew them is not allowed to decide
  what they are. They are resampled to one pixel per point — in premultiplied
  alpha, the only space a soft edge averages correctly in.
- **A spinner's row in the programme list could have a blank first line.** The
  properties panel adds a word *empty* and waits to be typed into, so `words`
  was not empty while the one text in it was — and the join produced nothing on
  the line the eye goes to first. Blank words are dropped, and a spinner with
  nothing to say is named by its style again.
- **Preview is ⌘5 again.** The Levels page was put on the end of the rail, which
  pushed it up a place. The rail reads Project, Edit, Text, Levels, Play, and
  Preview belongs last: it is the page somebody watches rather than works in.
- **A note above a duplicated entry stays on the original.** A comment is
  addressed by what its line says, so two entries reading the same is exactly
  the case that addressing has to answer for.
- **A suite that builds windows runs one test at a time.** Every test passed and
  the process never exited, which reads as a hang in the build rather than a
  fault in a test.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
