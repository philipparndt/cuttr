# cuttr 0.4.1

Fixes.

## Rain that stopped a quarter of the way in

Reported: rain asked for from 7.1 to 33.1 seconds stopped at about fifteen.

`out: {fall: …}` means a shower runs out rather than being switched off, so the
renderer stops letting pieces go shortly before the end and lets what is in the
air leave on its own. That moment is on the programme's clock — and everything
inside the renderer is on the effect's own, which is the real time multiplied by
`speed`. The two were compared directly, so pieces stopped spawning at
`spawningUntil ÷ speed`: at `speed: 4`, a quarter of the way in. At `speed: 1`
nobody would ever have seen it.

## Snow that arrived four seconds late

Also reported: no snow in the weather example. It was there — four seconds
later, and the card is three seconds long. Each piece starts above the frame so
that the first arrive within a moment, but the head-room and the spread were
fixed *distances*, so a slow style paid proportionally: rain was in shot at
0.4 s, confetti at 1.5, snow not until four and not full until eight.

Both are measured in time now — a quarter of a second of head-room, a second and
a half of spread — so every style fills at the same rate. Confetti and rain
arrive sooner than they did, which is visible in any project with one in them.

## The meme panel

- **No scrollbar and no clicking.** The grid is meant to be as wide as the pane
  and as tall as its contents, but it was still on its autoresizing mask, so the
  width constraint lost: it stayed the width it was born with, found room for one
  column, and left the scroll view with nothing to scroll and the tiles nowhere
  near where they were clicked.
- **No sound.** A meme from a GIF search has none, and cannot: both services
  serve them as silent mp4s because they are GIFs underneath, and Giphy's Clips
  are behind an endpoint that answers 403 to an ordinary key. The panel says so
  before you add one.
- A downloaded meme is now kept exactly as the service served it. The track of
  silence it used to get was a workaround for an exporter that refused a
  composition whose audio track never had anything in it, and that was fixed in
  0.3.0.

## Requirements

macOS 14 or newer, Apple silicon or Intel.
