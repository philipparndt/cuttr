# cuttr 0.10.2

Sharing says what it is doing, where you will see it. A programme made only of
cards no longer takes the app down.

## The share button says what there is to do

Sharing worked and looked as though it did not. Everything it did, it said once
in the status line at the top of the window, and the line was gone by the time
anybody looked — so "it refused because a take window is open" and "the button
does nothing" were the same experience.

**There is a button in the bar now for as long as there is something to do.** It
says `Upload 3 changes`, or `Merge 2 changes` when somebody else got there
first. Its absence means everything is shared; its presence means there is
something to press. It is the same button that does the sharing.

Merging comes before uploading, because pushing on top of work you have not seen
is what the whole feature exists to avoid.

It never goes to the network on its own. Asking a remote how things stand every
half minute is a password prompt, or a stall, forever — so it reads what is
already on this machine: your uncommitted files, and how far your branch is from
the last fetch. `Merge` therefore appears after a share rather than the instant
somebody else pushes.

## Messages appear in the corner

Everything the program has to say now appears as a note in the corner of the
window and goes away by itself, instead of a line at the top that you had to be
looking at already.

A refusal — an open take window, not signed in, a merge half-finished — stays
more than twice as long as the rest, because it names something you have to do.
None of them waits for a click; a message that has to be dismissed is a dialog
wearing a different coat. Clicking one puts it away early.

## A programme of cards could take the app down

Cards and scenes are a whole project — an intro screen made of nothing but the
file it is written in — and such a programme has no footage anywhere in it.
Asking for a still frame of one made AVFoundation raise an error that could not
be caught, and the app stopped rather than failing.

The info page asks for exactly that frame on the way in. It asks whether there
is a picture first now.

## Fixes

- **The lane colours appeared twice, and on the project window.** They were
  added to a part of the bar that was never emptied when a document left it, so
  they accumulated a set per switch and stayed behind for whatever came next.
- **Two lists could stop the program between them.** Opening a row in a list is
  animated, and an animation holds a worker thread while it runs; both the
  programme tree and the material tree reopen their rows every time they are
  rebuilt. Enough of that and every thread the system will give is holding an
  animation. Those rows open without one now.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Sharing needs git and a repository
with a remote you can already push to. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
