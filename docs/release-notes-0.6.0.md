# cuttr 0.6.0

Somebody in the picture can say something, the app is one window with documents
taking turns in it, and the film is the colour the footage was.

## Somebody saying something

A **bubble** is a new kind of overlay: a speech bubble, a thought bubble with
its trail of circles, or a hand-drawn box with an arrow — drawn rather than
typeset, so it belongs to a home film rather than to a slide deck.

It has **two positions, not one**, and that is the point of it. The paper goes
where there is room; the tail points at a head, or a hand, or a cake. Aiming
one arrow with one number could only ever hit the middle of the thing it named,
which is never where you want to point.

**It travels.** Given an `anchor:` — a face the take is already following — the
whole bubble goes along beside her, paper and tail together, so a bubble stays
pointed at somebody who walks across the frame.

**It breathes.** The line wobbles and the paper drifts a little, from a `seed:`
you can change and a `breath:` you can turn off. Reproducible, because a render
that comes out different every time is not a render you can check: the same
seed is the same wobble, on every machine and in a year.

**And it is placed by dragging it.** There is a picture of the frame in the
properties column with both handles on it, and a `⤢` that opens the same
picture large enough to aim properly. Placing a bubble with numbers is work
nobody should be asked to do twice.

## One window, and the documents take turns

Double-clicking a take opens it **in the window you are looking at**. Before
this it sometimes opened a second window and sometimes did nothing, which meant
the answer to "where is my take" depended on how you got there.

- The document's name at the head of the bar lists **every scene and take**,
  under the project they belong to, and choosing one opens it here.
- The palette (`⇧⌘P`) finds them by **path as well as by name**, and prints the
  path right-aligned beside the name in fixed-width text, so a column of them
  can be read down.
- The tab bar is gone for good — it used to come back after a restored session
  and overlap the new title bar.

## The title band

One band where there were two, with a **capsule** at the head of it: which
project, which branch, and a way into both.

The branch menu offers the other branches and **Open in Fork, on GitHub, or in
Abydos** when they are installed. The traffic lights are vertically centred the
way a unified toolbar centres them, rather than by a number that goes stale the
moment somebody changes their furniture — and the capsule measures where the
buttons actually end instead of guessing, so it never sits under them again.

## The film is the colour the footage was

**Renders came out washed out**, and had done more than once.

Nothing chose that. Only one of the three render paths said what colour the film
was, so the other two left the answer to AVFoundation — which infers it from the
footage, and infers the widest thing it can find. One iPhone clip in a project
of twenty exported the whole programme as HLG BT.2020: every player that is not
HDR-aware showed all of it washed out, and the Rec. 709 shots in it were
flattened into HLG's range on the way in. A highlight the footage put at 247
came out at 185, the mean dropped from 136 to 115, and white stopped being white
at 210.

Worse, which path a project took depended on **which features it happened to
use** — so adding a single title card moved the render onto the compositor,
which *does* say 709, and the same footage came out a different colour again.

All three paths now declare Rec. 709, which is what this program writes: an SDR
film every player shows the same way, with a wider source converted into it
rather than reinterpreted. Measured against the footage afterwards, a Rec. 709
shot in a mixed programme is exact, and an HLG shot lands within eight levels of
what macOS itself makes of that frame — where before it was thirty-nine out. The
preview is built by the same code, so it says the same thing.

## Who is speaking

**A guess now shows what it would change.** The pass proposes a name for every
line it can measure, including lines you have already answered — and keeping it
overwrote those. The margin showed only the name that was already there, so
`Keep 12 guesses` was the entire notice that twelve names were about to go, and
*which* ones was unknowable until afterwards. A guess over a name is now drawn
as what it is — `Papa → Mia` — and a guess that agrees with the name already
there is not a change and is not counted as one.

**An answer is about the line you are on.** Naming a speaker used to carry
forward: a press meant "from here on, it is her", and painted every following
line that still agreed. One keystroke for a whole page is quick, and it is also
one keystroke for a mistake whose extent nobody can see. A run of lines is
answered by **selecting them** and saying who, which says exactly which lines it
is about; a caret on one line still walks on afterwards, so labelling a page is
one key per line.

**`U` is a voice nobody can name.** A line nobody has answered is a question
still open; somebody off camera, or in the next room, is not — and until now the
only way to say so was to leave it looking unfinished. It is not a member of the
cast: it stays out of the take's `speakers:` and takes no colour from the
palette, because a colour says "this person".

Labelling a long take also no longer throws you back to the top of the page on
every keystroke.

## When an overlay is on

The **when it is on** strip shows the stretch that can mean something. An
overlay tied to a four-second clip used to be offered the whole programme to aim
at, with the seconds that could matter a thumbnail at one end of it.

And a range written inside a clip is now **held inside that clip**. A `within:`
is "so many seconds into that shot", so a `to:` past the shot's own end is not a
long overlay — it is a number the programme has nowhere to put, and it could be
typed, dragged, and copied by `+ range`. A clip used twice is also two places
and not one long one: the panel and the drag used to answer with the first start
and the last end, which for a shot used in the opening and again at the end is
most of the film.

**A transition can sit before the mark, across it, or after it** — at either
end. `at: before` finishes as the clip starts, `across` is half way through when
it starts, `after` begins with it, and the same three going out. Film mode
arriving a beat before the shot it belongs to is the whole reason.

## Scenes, and a look at what you have

**A scene's gradient can be animated.** `from:`, `to:` and `angle:` can be
stated at a key point like anything else, so a background can turn as well as
fade. Stating one at a key is what animates it — the panel used to offer a
global colour that looked like it would.

**Space takes a look.** Pressing space in the timeline or the tree plays what is
selected in a small hovering window over the top, rather than taking the
playhead somewhere and leaving it there. The tree keeps the keyboard while it is
open, so space and the arrows go on working where you are looking, and there is
nothing on the panel to click: every gesture that is not moving about the tree
means *enough*, and `⎋` closes it.

## Every pause leaves a version

With a git repository attached, **saving a project writes a version of it** to a
branch of its own, using git's plumbing and a temporary index — so it never
touches your working tree, your index, or your branch. It is there for the
morning when something is wrong and the answer is "what did this look like an
hour ago".

## Fixed

- **An unfilled section is no longer a problem**, and a problem is no longer a
  window: opening a project with empty sections produced a warning per section
  and a window five thousand points tall. The message is one line that gets out
  of the way.
- **The exported tree carries the words with the paper** — a project exported to
  one folder used to leave its transcripts behind.
- **A clip's colour tag goes beside its name**, not beside its icon, in both the
  library and the tree, so a column of them lines up.
- **A clip's context menu says what it does** rather than repeating the clip's
  name back at you.
- The reproducibility test measures the drawing rather than the encoder: H.264
  is not bit-identical under load, and a test that said otherwise failed at
  random. Two renders of the same project now have to agree to within a
  hundredth of a level, and two seeds have to differ by ten times that.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
