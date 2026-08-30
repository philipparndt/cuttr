# cuttr 0.11.2

A crash, two things the window would not say out loud, a timeline that would not
move, and a take whose name has a space in it.

## Ducking a dissolve took the window with it

If cuttr quit while you were setting `ducks:` on a piece of music, or while
cutting a take that carries a gain curve, this is why.

Every level in a programme is written to the mix as a ramp — a flat one where a
level holds, a sloped one where a dissolve or a curve moves it. They were written
straight out, in whatever order a sort left them in, and AVFoundation has two
opinions about that. Two ramps that overlap raise an Objective-C exception, which
is not an error a build can catch: it is the process going, with the take
somebody was in the middle of. Two that merely *begin* together are taken
silently, one replacing the other, so which of a dissolve and the level it
dissolves from was heard came down to the sort.

Overlapping is not exotic. A duck fades the programme back up over a second and a
half; a dissolve inside that second and a half is a Tuesday. A gain curve covers
its clip end to end, and a dissolve *is* the two clips overlapping, so the curve
is still running when the crossfade starts.

The lane is swept now rather than written straight out: at every moment the
instruction that started last is heard, for as long as it runs, and what it
interrupted is heard again afterwards from where it had got to. A dissolve laid
over a level does the dissolve and then holds, which is what both of them were
asking for — and the incoming shot comes up from nothing instead of arriving at
full, which it did whenever the sort went the other way.

## A recording that is not there says so, in pink

A project cloned without its media, or with one card still unread, resolved
perfectly and then died in the build:

    preview: The operation could not be completed

No preview, no play button, no quick look, and nothing to say it was about a
file — for a programme of a hundred and twenty clips of which one was missing.

The same fact is now told three times, each to the person who can act on it:

- **The resolver names the file** beside the picture, once however many
  placements play it.
- **A preview plays that stretch as a pink card** with `missing media` and the
  file's name on it. Pink because nothing in a programme is this colour by
  accident — black is a shot of a dark room, a dropped frame or a fade, and
  anybody would look for a fault in all three before thinking of the drive they
  never plugged in.
- **An export refuses, and says which file.** A render is minutes of encoding and
  then a file to hand somebody; a hole in it is not something to find out about
  afterwards. A file that is there and will not decode says *that* instead, which
  is a different thing to go and look into.

## The programme strip zooms where you are looking

`+` and `−` — and the buttons beside them — zoomed about the middle of the view,
which is nothing. What somebody is looking at is the frame they are on, so two
presses walked the playhead off the edge and left the strip showing a part of the
programme nobody had asked for. It anchors on the playhead now, and falls back to
the middle when the playhead is not on screen.

And then the strip could not be moved. Panning was a sideways swipe and nothing
else — no thumb, no rail, nothing to say the programme continued past either
edge — so on a mouse without a sideways wheel a zoom was a one-way door. There is
a scrollbar under the ruler now: drag it, or click anywhere on the rail to take
it there. Shift with a plain wheel pans too. The swipe itself also went the wrong
way, against every scroll view on the platform and against this program's own
other strip, which is fixed.

## What the window says can be copied

The line under the title bar and the toasts in the corner are where this program
says what went wrong, and what is in them is exactly what a bug report should
quote: a path, a slug, a decoder's own words. Neither could be copied.

The line is selectable, right-clicks to **Copy Message**, and hovers to show the
whole of it — warnings are joined into one line to fit a strip of window fourteen
points high, and the tooltip puts them back one to a line. A toast right-clicks
to **Copy** and stays where it is.

## A take whose name has a space in it

Dragging a clip out of a take called `Mia 1` wrote `query: Mia 1/that-clip`, and
the query language separates terms with spaces — so that asked for the clip `mia`
*and* the clip `that-clip` in a take called `1`. Nothing, in every project. The
file was saved that way, so the mistake outlived the drag.

A reference is now recognised by *being* one rather than a query by looking like
one: a slug, optionally with a take in front of it. A drag produces a clip entry
and needs no quoting at all. Where a query is what was meant, the language takes
quotes:

    - query: "\"Mia 1\"/#interview"

And a query that matches nothing now says which of the two is wrong, with the
repair written out in the project's own words, instead of "check the tag"
whatever the query was.
