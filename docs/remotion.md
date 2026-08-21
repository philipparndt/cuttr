# Remotion, and what it would cost

An assessment, not a plan. Nothing in this document is built. It exists because
"maybe Remotion would be a good fit, I plan to have much more custom content"
is a reasonable thought and a decision that is not a side effect of a credits
task — so here is what the decision actually involves.

## What Remotion is, in this program's terms

Remotion draws frames with React in a browser. You write a component, it is
handed a frame number, and it renders DOM and SVG and canvas; the renderer
drives a headless Chromium through the frames with Puppeteer and screenshots
each one. There is no video engine in it and it does not need one: the output is
a PNG sequence, which `ffmpeg` then encodes.

That is worth stating plainly, because it decides everything below. Remotion is
**a way of drawing frames**. cuttr already has two of those, and they are the
part of this program with the strictest rule attached:

- `OverlayPainter` draws into a `CGContext` and hands the compositor a
  `CIImage`. It is what the window's preview and everything that changes the
  picture go through.
- `OverlayLayers` builds a `CALayer` tree and hands it to
  `AVVideoCompositionCoreAnimationTool`. It is what the export goes through.

Every part kind is implemented in both, and the tests assert that the two agree
— see `theLayerPathFillsTheSameBar`, and the comments in `OverlayLayers` about
why a spinner is not implemented twice. A third drawing path is therefore not a
small addition. It is a third answer to "where is this at 12.4 seconds", and the
existing two only stay honest because they are checked against each other.

## How a component's frames would reach the compositor

There is exactly one shape that does not make things worse, and it is the one
worth being concrete about.

**Not** "call Remotion per frame". A headless browser screenshot is tens of
milliseconds at best and a cold start is seconds; the preview redraws while
somebody drags a playhead, and the export asks for frames in order from a
composition request. Either path calling out to Node per frame is a preview that
stutters and an export that takes hours.

**Instead**: render the component *once*, ahead of time, to a frame sequence on
disk, and composite that sequence like any other picture.

    resolve → for each component part, hash (component file, props, size, fps,
              duration) → is there a cache under .cuttr/components/<hash>/ ?
              no  → run `remotion render` into it, once
              yes → use it
    draw   → frame N of the sequence, as an image

The payoff is that both render paths then read *the same PNGs*. The painter
draws frame N into its context; the layer path puts the images on a
`CAKeyframeAnimation` over `contents` with discrete timing. There is no second
drawing implementation to keep in step, because the drawing happened elsewhere
and both paths are only compositing. That is strictly better than a part kind
implemented twice, and it is the one genuine argument in Remotion's favour here.

Everything the compositor already does keeps working on those pixels: opacity,
scale, rotation, the person mask (`behind: people`), an anchor's path, film
mode and the tape and the grade, in the order the file lists them. A component
can even be told where the face is — the anchor's position at that frame, passed
in as props at render time — though then the cache key includes the take, and
recutting the take invalidates every component frame that depended on it.

## What it costs

**Build.** Nothing at all in the Swift build; this is a runtime dependency and
not a link-time one. That is the good news and it is also the problem.

**Runtime.** Node 18 or later, an `npm install` that lands a few hundred
megabytes of `node_modules`, and a Chromium download of comparable size. cuttr
ships as a signed, notarised `.app` in a disk image (see `docs/releasing.md`).
Two options, both bad:

- *Bundle it.* The app goes from tens of megabytes to something like half a
  gigabyte, and a bundled Chromium needs its own hardened-runtime entitlements
  (JIT, unsigned executable memory) and its own helper executables signed
  correctly, all of which is notarisation surface for something that draws
  titles.
- *Require it.* "Open the app and render" becomes "install a JavaScript
  toolchain, then open the app". Every project that uses a component part is
  then a project that some machines cannot render, which is precisely the
  failure the format's design has been avoiding: a `.cuttrproj` is meant to be a
  file that renders next year on a different computer.

There is a third option worth naming because it is honest: **do not integrate it
at all**, and let Remotion produce a `.mov`, which becomes a take on the
timeline like any other footage. That costs zero lines of Swift, keeps the
dependency entirely outside this program, and loses only the ability to nudge a
title's position from the inspector. For "much more custom content" that is
often the right trade, and it is available today.

**Reproducibility.** This is where it hurts most. The house rule is that the
file is the product and no render should be irreproducible next year. A
component's output depends on:

- the Chromium build (Skia changes and text rasterisation changes between
  versions),
- the `node_modules` tree, which means a lockfile is now part of the project,
- the fonts the *browser* can see, which is a second typography system beside
  `styles:` — a `roll:` sets `Helvetica Neue Medium` by its macOS name; a
  component would load a webfont, and the two will drift,
- anything non-deterministic in the component itself. `Math.random()` and
  `Date.now()` are one keystroke away, and cuttr's own effects go to some
  trouble over this: a seed cannot be animated *because* the same number giving
  the same cloud on every render is the whole point of having one.

None of that makes a project unrenderable, but it changes what a project *is*.
Today a `.cuttrproj` plus its takes plus its media is the whole of it. With a
component part, it is that plus a TypeScript file plus a lockfile plus a browser
version — and the cached frame sequence becomes the artefact that actually has
to be kept, which makes it material rather than a scene. The honest way to model
it is as material: a component is closer to a take than to a title.

**The preview.** The window draws every frame with the painter, live. A
component part cannot be drawn in that budget, so the preview shows the cache —
and the moment the cache is stale, the preview is lying about what the export
will contain. The rule that follows is not optional: the preview shows cached
frames and **says out loud** when the hash no longer matches ("this component
has changed since it was rendered"), and it never renders on the fly to catch
up. A grey placeholder with the component's name on it is honest; a stale frame
presented as the picture is not. This is the same standard the resolver already
holds itself to when it puts warnings beside the picture rather than instead of
it.

## Where it is a bad fit

**For anything the scene vocabulary already says.** A second way to make a
title is two coordinate systems, two easing vocabularies, two typographies and
two places to look when a title is in the wrong place. `scenes:` exists so that
a title is reviewable text; a component moves the title into a language the
project file can only refer to.

**For the editor.** The scene editor drags parts on a stage, hit-tests them with
`SceneLayout.placements`, and writes the number back to the key. None of that
can work on a component: it is one rectangle of pixels with no parts inside it,
so it can be moved and scaled as a whole and nothing else. Every project that
uses one has a part of it that the editor cannot edit.

**For iteration speed.** The good thing about editing `keys:` in a text file is
that the preview updates as soon as the file is saved. A component render is
seconds to minutes before anything can be looked at, which is a different way of
working — closer to compiling than to editing.

**Where it is genuinely good**: one-off, information-dense, *layout-heavy*
content that no sane part kind would cover. A chart of the year's walks. A map
with a route drawn on it. A leaderboard. Anything where the answer is really "I
want a web page, on a frame". That is exactly the case where the frames-on-disk
model is fine, because such a thing is data-driven and rendered once.

## The smallest useful first step

If this is done at all, do it in this order, and stop at whichever step turns
out to be enough.

1. **An image-sequence part, with no Remotion anywhere near it.**

       - frames: overlays/chart/%04d.png
         fps:    25
         keys:
           - {t: 0, x: 0.5, y: 0.5, opacity: 0, width: 0.6, height: 0.4}
           - {t: 0.6, opacity: 1, ease: out}

   This is a day's work, it has no dependencies, it is implemented once in each
   render path with the drawing code that already exists for `image:`, and it
   composites through everything. It covers *every* case above — because
   whatever made the frames, Remotion or Blender or a Python script, they arrive
   as pixels. Most of the value of the whole idea is in this step, and it is
   worth having on its own merits.

2. **A separate command that renders a Remotion composition into that shape.**
   Not in the app: a script beside `Scripts/`, run by hand, writing the frames
   and a small sidecar recording the hash of what produced them. The project
   file refers only to the frames. Nothing in the app learns about Node, nothing
   in the bundle grows, and a machine without a toolchain still renders the
   project because the frames are on disk beside it.

3. **Only then, if step 2 is being run by hand often enough to be annoying**, a
   `component:` part that knows how to invoke step 2 for itself, with the cache
   key, the staleness warning in the preview, and the lockfile in the project
   folder. By that point the cost is known and the benefit has been measured
   rather than guessed at.

The order matters because step 1 is the part with the good ratio, and it is
tempting to skip it and land on step 3 — where the dependency, the
reproducibility hole and the honest-preview problem all arrive at once, for a
feature whose real users may have been happy with a PNG sequence.
