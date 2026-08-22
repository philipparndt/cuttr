# cuttr 0.9.1

Playing a clip no longer stutters, full screen keeps the bar at the top, and a
click in the clip list picks a clip instead of typing into it.

## Playing a clip is smooth again

The window stuck while a clip was playing, and the cause was worse than it
sounds: the playhead tick called `showDocument`, which asked git which branch
the take's folder was on. `branch(in:)` runs `git rev-parse` and waits for it —
so playing a clip spawned a process **per frame**, thirty times a second, on the
thread drawing the picture. Scrubbing did it once per mouse event.

Nothing that was on that tick belonged there. The name of the document, the
branch it is on, whether it has a separate recorder: all facts about the
document, and none of them changes because the tape moved a frame. The tick sets
the clock and that is all.

The branch is read once per document now, which needed a listener that was never
there — nothing watched for a checkout, and the capsule was right afterwards
only by accident, because the tick re-asked git within a frame of the next play.
Asking properly, once, is what makes it safe to stop asking thirty times a
second.

**And a resolve no longer re-reads the disk.** Not the reported fault, but found
looking for it, and the same shape. A project resolves on every change, and
every resolve re-read and re-parsed every take file and every tracked face's
solved path — a line per frame, twenty-five a second for as long as the shot
runs. Dragging an overlay along the programme is dozens of changes a second.
Files are now parsed once per version of themselves, checked by modification
date and size.

## Full screen keeps the bar

The green button took the project capsule and the clock with it. The bar was
still there — it is a view in the content view rather than anything in the
titlebar, which is the whole of why full screen does not take it — but an empty
toolbar was being drawn across the top of it.

That toolbar holds no items and never has. It exists so that macOS gives the
window a 52-point title band with the traffic lights centred in it, which is
exactly the band the bar wants. Windowed it is transparent and the bar shows
through; in full screen there is no band to size and no buttons to centre, and
what was left was an empty strip over the two things the bar had to say.

It now hides *with* the titlebar rather than on its own, so the band and the
centred traffic lights are intact every time the titlebar is on screen, and the
bar is visible the rest of the time.

**And the room kept for the traffic lights is measured again** when they move.
It was worked out once, when the bar arrived in its window, so the eighty-two
points held clear for three buttons stayed held in full screen, where there are
no buttons — a hole at the leading edge with nothing in it.

## The project window's playhead moves again

While a programme played, the picture ran but the playhead line stood still, the
clock in the bar did not count, and the full-screen preview's own controls
showed nothing. The two handlers that move them were written at the bottom of a
function after a `switch` in which every case returns, so nothing ever reached
them — the compiler has been saying "will never be executed" about that line
since the first commit.

The picture played anyway, which is why it went unnoticed for so long: that part
is `AVPlayer`'s doing and needs nobody's help. Everything that has to be told
the time was never being told.

## A click in the clip list picks a clip

Single-clicking a clip in the take editor put a caret in it. Choosing a clip and
typing into a clip are different intentions, and the second arrived every time
you tried the first, which made a clip hard to select at all.

A click now means what a click in a list means. Editing stays a deliberate act
and every route to it is unchanged: the rename that follows making a clip, and
the menu items for the slug and the tags.

## Double-click a clip in the programme

**Double-clicking a clip in the programme tree opens it in its take**, at the
moment it was cut. The same journey the row's own menu offers under "Open in
Take", and the same one double-clicking the programme strip already made.

Only a clip. A card and a section were never cut out of a take, and on a section
a double-click already means open and close it.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
