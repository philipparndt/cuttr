# Remotion, beside cuttr rather than inside it

A small [Remotion](https://www.remotion.dev/) project whose compositions render
to folders of numbered PNGs — which is the shape a cuttr `frames:` overlay
reads.

**Nothing in cuttr runs any of this.** It is not in `make`, it is not in the
test suite, and it is not in the app bundle. A machine with no Node on it builds
cuttr, passes the whole suite, and renders every project whose frames are
already on disk. That separation is the point, and `docs/remotion.md` is the
argument for it: bundling Node and a headless Chromium into a signed, notarised
app is half a gigabyte and a set of JIT entitlements for something that draws
titles, and making "open and render" mean "install a JavaScript toolchain" is
worse.

So the interface between the two programs is **a folder of pictures**, and
running this is a step somebody takes.

## Running it

Needs Node 18 or later. Everything else installs itself the first time.

```
tools/remotion/render.sh chart
tools/remotion/render.sh route
```

Each one writes to `examples/frames/<composition>/`. Pass a second argument to
put them somewhere else:

```
tools/remotion/render.sh chart ~/films/spring/overlays/chart
```

Then reference the folder from a project, relative to the `.cuttrproj`:

```yaml
overlays:
  - frames: chart
    fps:    30
    size:   0.62
    from:   "@results"
    in:     {fade: true, over: 0.5}
    out:    {fade: true, over: 0.5}
```

`cuttr-render --describe` will tell you how many pictures it found and how long
they run for. `examples/frames/remotion.cuttrproj` is both of these on two
cards, with the reasoning in its comment.

To draw one rather than render it:

```
cd tools/remotion && npm run studio
```

## What it produces

| | |
|---|---|
| `chart` | 135 PNGs at 1200×680, 30 fps — 4.5s. An animated bar chart, laid out from a list of numbers. |
| `route` | 165 PNGs at 1200×680, 30 fps — 5.5s. A walk drawing itself across a coastline, with the distance counting up. |

Both are rendered with `--image-format=png` and **no background at all**, so
they composite over the programme. That is not optional: JPEG has no alpha
channel, and the chart would arrive as a white rectangle over the shot.

Both are also rendered at about the number of pixels the overlay will actually
occupy — 680 tall for something drawn at `size: 0.62` of a 1080-high frame —
rather than at the size of the programme. Scaling a picture down is free and
scaling one up is a soft picture, and 4K would be forty times the disk for a
sequence that is then reduced.

The frames are **not committed**: the two of them come to about twenty
megabytes, which is not a thing to put in a git history for an example.
`examples/frames/harmonograph.cuttrproj` is the self-contained one — its frames
are a few kilobytes each and are in the repository, and it needs none of this.

Each folder also gets a `rendered.json`, which cuttr never reads:

```json
{
  "composition": "chart",
  "frames": 135,
  "remotion": "4.0.515",
  "node": "v24.15.0",
  "command": "npx --no-install remotion render src/index.ts chart … --sequence --image-format=png",
  "lockfile-sha256": "…",
  "source-sha256": { "src/Chart.tsx": "…" },
  "rendered": "2026-08-21T16:19:04Z"
}
```

## The reproducibility problem, said plainly

cuttr's house rule is that the same project renders the same frames. A rendered
sequence keeps that rule — the pictures are on disk, and they do not change —
but it moves where the rule is *kept*. What a composition renders as depends on:

- the Chromium build, because Skia and text rasterisation change between
  versions;
- the `node_modules` tree, which makes the lockfile part of the film;
- the fonts the *browser* can see, which is a second typography system beside
  cuttr's `styles:` — a `roll:` asks macOS for `Helvetica Neue Medium` and a
  composition asks a browser for whatever it can find under that name;
- anything non-deterministic in the composition itself. `Math.random()` and
  `Date.now()` are one keystroke away, and neither of the two here uses them.

None of that makes a project unrenderable. It changes what a project *is*: a
`.cuttrproj` plus its takes plus its media, and now plus a TypeScript file and a
lockfile and a browser version. `rendered.json` is the least this can do about
it.

The practical consequence: **treat a rendered sequence as material, like a
take.** Something to keep beside the project, not something to regenerate on a
whim. Re-rendering it a year later on a newer Chromium is a new version of the
material, and should be looked at as one.

## What is deliberately not here

No `component:` overlay kind that would run Remotion from inside cuttr. That was
considered and written up as step three of `docs/remotion.md`, and the reasons to
stop before it are all in there: the bundle, the entitlements, and the honest-
preview problem — a preview that shows cached frames is lying the moment the
cache is stale, and a preview that renders on the fly to catch up is seconds per
frame.

If step two here turns out to be run by hand often enough to be annoying, that
is the moment to reopen it, with the cost known rather than guessed at.

## Files

| | |
|---|---|
| `src/index.ts` | `registerRoot` — the entry point |
| `src/Root.tsx` | the compositions, and why their sizes are what they are |
| `src/Chart.tsx` | the bar chart, and the argument for why a chart earns this |
| `src/Route.tsx` | the route, and the argument for why a measured path does |
| `remotion.config.ts` | PNG, and nothing else — the rest is on the command line |
| `render.sh` | one composition to one folder, plus the sidecar |
