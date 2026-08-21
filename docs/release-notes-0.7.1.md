# cuttr 0.7.1

Four things from 0.7.0 that did not work, and a level you can type.

## Fixed

**Space in the clip list did nothing.** Every key press in the cutting window
goes through the window's own monitor, which catches it before any view sees one
and claims space for the transport — so the clip list, which answered space for
itself, was never asked. The tape rolled instead. It now gets first refusal
while it has the keyboard, on the same terms the words pane already had.

**Recent Documents in the palette did nothing.** There are three openers —
project, take, footage — and the rule for choosing between them had been written
out separately at each place that needed one, so the palette sent its rows to
the take opener. That one treats anything which is not a `.cuttr` as footage to
make a take out of: it looked inside the project for a video, found none, and
returned without a word. Every row in that list is a project, so every row was
dead.

**Match Levels looked like it did nothing.** It measured its clips one at a
time, and a decode per clip in series on a take of three dozen is minutes of a
window showing no sign of life. They are measured together now, and the bar
fills as the answers come in.

## A level you can type

Measuring every clip takes as long as it takes to decode them, and somebody who
can hear that a take is four decibels under the others does not need it
measured. So a take carries its own `gain:` in decibels, in the set-up popover
beside the offset.

It balances one recording against another, where a clip's own **Level** balances
the clips inside a recording. Both add, and both are separate from the automatic
match a project makes toward `output.audio.target` — that one is a measurement,
these are decisions, and a decision is allowed to overrule it.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
