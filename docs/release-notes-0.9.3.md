# cuttr 0.9.3

Undo on a programme, which there has never been. Selecting an overlay stops
editing it. Lists say which one the keyboard is in, and the paging keys move the
selection rather than scrolling past it.

## Undo, on a project

There was none. The take editor and the scene editor have both had undo since
they were written; the project window had nothing at all, so ⌘Z on a programme
did nothing and the way back from a mistake was git.

Two things were missing and both are fixed. The document did not remember — it
does now, at the one door every change goes through, skipped when nothing
actually changed and cleared when the file is re-read underneath. And ⌘Z could
not have reached it anyway: the Edit menu named the *take* window's undo, so
takes and scenes answered and projects did not. It is on the shared window base
now, so every kind of document gets ⌘Z, ⇧⌘Z, and a menu item that says what it
is about to take back — "Undo Move Overlay" rather than "Undo".

An undo writes the file, which the forward direction leaves to whoever asked for
it. The file is the product; an undo that put the model back and left the file
saying the other thing would be a window disagreeing with its own document.

## Selecting an overlay is not editing it

Clicking an overlay's bar on the preview strip wrote the project file. Clicking
a bar is how an overlay gets *selected*, and letting go handed its two ends
straight to the code that moves one — whether or not the pointer had moved.

That is not the nothing it looks like. The range is re-spelled on the way
through, so selecting an overlay written `within:` a clip could rewrite it as
programme times — the very drift that spelling exists to prevent — and one with
no range at all could be given one. Together with there being no undo, a click
meant to look at something was permanent.

The bar now remembers where it was taken hold of, and lets go quietly when it
has not moved.

## Lists say where the keyboard is

**A selected row now says whether its list has the keyboard.** It did not: every
list drew its selection the same, so none of them said which one the arrow keys
would move.

The reason it was that way is a good one and is kept. Every list here is a list
of *named things* whose colour carries the meaning — green a clip, amber a tag,
violet a section — and AppKit's own focus highlight is a bar of saturated blue
painted over exactly that. So the lit row is the same steel as the selection
mark, a shade up in value: focus you can see across the desk, hues still
readable through it.

**And the takes list never had the keyboard to say it with.** The row selected,
so the click was arriving — but the keyboard stayed wherever it had been, so the
arrow keys went on moving something else while the row that looked chosen was
not the one they moved.

## Page Up, Page Down, Home and End

They only scrolled. That is right for a document — move the paper, leave the
caret — and wrong for a list somebody is choosing from: the chosen row goes off
screen and the arrow keys carry on from where it still is.

They move the selection now, in all three lists. A page is one row short of a
screenful, so the row that was at the bottom is at the top afterwards and you
keep your place.

## The lane colours moved again

To the right edge rather than just past the clock. Put straight after it they
crowded the number they were meant to be giving room to — the clock is the one
thing in the bar that must not move, and a row of swatches pressed against it
reads as part of it. Out at the edge they are their own thing and the middle is
the time.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
