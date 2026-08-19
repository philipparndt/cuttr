# cuttr 0.2.0

One new thing, and the paperwork around the first release.

## Film mode

An overlay that is not laid over the picture but *is* the picture, for as long
as it lasts: the bars close in to a wider shape, the colour goes to a stock, and
the grain arrives. All three are scaled by one number — how far into the mode
the programme is — so `in:` and `out:` are what make it a move rather than a
switch, and a shot can go to film and come back inside its own length without
anything else in the project knowing.

```yaml
overlays:
  - film:     warm       # none · warm · cool · sepia · noir · bleach
    ratio:    "2.39:1"
    grain:    0.5
    vignette: 0.35
    from:     the-build
    to:       the-build
    in:       {fade: true, over: 1}
    out:      {fade: true, over: 1}
```

- **Six stocks**, named for what somebody wants rather than for the arithmetic.
  Each is a `Look` — the same type the take's own grade and the renderer use — so
  there is one place that decides what warm means.
- **`ratio` keeps the two numbers you wrote.** `2.39:1` comes back as `2.39:1`,
  not as `2.39`. Which way the bars go follows from the two shapes: black above
  and below a programme taller than what is asked for, columns beside one that is
  wider. A shape the programme already is costs nothing and shows nothing, which
  is why a new film overlay picks 2.39:1 for a widescreen programme and 16:9 for
  one cut for a phone.
- **`strength` mixes the stock in** rather than switching it on, so a half is
  half way there.
- **The grain moves** from frame to frame. Grain that sits still is dirt on the
  lens, and the eye finds a fixed pattern in about two seconds.
- **At nought it does nothing at all**, and the renderer's "is there anything to
  do to this frame" test knows about film — so the frames either side of a film
  sequence go through no filter, and the rest of the cut stays exact.

All of it is in the properties panel: ratio, stock, strength, grain, vignette,
with the fade at each end where every other overlay's is.

Measured on a rendered file rather than described: the source values before it
starts, black bars and a warmed middle half a second in, and the source values
again once it has gone.

## Fixed

- **The Homebrew tap was not updated by the 0.1.0 release.** The script asked
  `git diff` whether the cask had changed, and in a repository that has never had
  a commit the new file is untracked — so it answered "nothing has changed",
  truthfully and uselessly, and pushed nothing. It asks `git status` now. (The
  0.1.0 cask was published by hand at the time; nobody was affected.)

## Also

- The README says how to install and how to update, at the top, before it says
  what the program is.
