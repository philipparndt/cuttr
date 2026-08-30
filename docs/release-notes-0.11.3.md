# cuttr 0.11.3

A caption that falls in and lands, an overlay over part of a shot, a typewriter
you can hear, and messages that would not go away.

## `in: {drop: …}` lands a caption

It falls in from above under gravity — accelerating rather than easing, which is
the difference between a drop and something being lowered on a wire — hits part
way through the movement, rattles to a stop, and knocks up a cloud of dust along
the foot of the words:

```yaml
  - text:  Wie sieht Oma aus?
    style: lower-third-centre
    in:    {drop: true, over: 0.7, dust: 1}
    out:   {slide: right, over: 1}
```

`dust:` is how much of it, against the usual: `0` for a landing with no cloud,
`2` for twice as much. The cloud is thrown from where the words *land*, so it
stays on the floor while they are still rattling above it, and it is worked out
from the words themselves — a long caption throws a long cloud without being told
to, and the same caption throws the same cloud in every render.

The impact shakes the caption and nothing else. The picture underneath is not
touched, which is what lets a drop go over any shot without disturbing whatever
else is on screen at that moment. `out: {drop: …}` is refused rather than quietly
read as a slide off the top: a caption cannot leave by falling in.

## `within:` puts an overlay on part of a clip

An overlay bound to a clip is on for the whole of it. `within:` names the clip
and two times *measured from where that clip starts*, so it is on for a stretch
of it:

```yaml
  - clip: liam-alt-zerbrechlich
    overlays:
      - effect:  confetti
        within:  liam-alt-zerbrechlich
        from:    00:01.200
        to:      00:04.400
```

Reach for this rather than plain `from:`/`to:` whenever the range belongs to a
shot. Programme times are on the programme's own clock and do not survive
anything upstream changing length — the clip moves and the range does not, so
what was over one shot ends up over the shot before it. In the window, "when it
is on" now offers **the whole clip**, **a stretch of it**, and **programme
times**, in that order of preference.

## The typewriter can be heard

`click:` gives each character of a typed line a short mechanical click — `true`
for the usual level, a number for more or less of it. The clicks are synthesised,
so there is no sound file to find and lose, and they are mixed at the same
moments the characters land: an uneven `steady:` is heard as well as seen,
because there is one list of moments and not two. They arrive on the sound lanes
as an ordinary sound, so the mix treats them like anything else.

## Messages in the corner would not go away

A toast is meant to be gone in a few seconds. Some of them stayed in the corner
of the window for good, over whatever you did next, until the program was quit.

Its few seconds belonged to the thing that drew it rather than to the toast
itself, and that thing is replaced whenever a document speaks from off screen —
a take that finishes transcribing while you are looking at the project, a render
that lands in a window you have since moved on from. The one being replaced was
released with the message still on the glass and nothing left to take it off
again. A toast now goes by itself whoever is or is not still holding it, and what
a document drew goes with it when it leaves the screen. It also goes while a menu
is down or a divider is being dragged, rather than waiting for the mouse to be
let go.
