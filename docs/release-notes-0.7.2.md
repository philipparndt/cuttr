# cuttr 0.7.2

The take level does something you can hear. The quick look draws what is over
the picture. Comments in a file survive being saved.

## The take level works

It went into the file and was honoured by the renderer, and nowhere else. The
cutting room's own monitor played the audio at full level and the timeline drew
the waveform at full height — so typing a number did nothing anybody could hear
or see, which is indistinguishable from a field that does not work.

The monitor takes it as a mix on the player item rather than a rebuild of the
composition: the cuts do not change when a level does, and rebuilding would seek
and stutter on every keystroke, which is exactly what stops somebody hearing the
number they are setting. The waveform is drawn through it too — on top of the
display zoom, which stays a separate thing, because the zoom is a magnifying
glass that changes nothing and the level is what will be heard. It clips against
the lane like any overdriven peak, so pushing a take up until it flattens is the
lane saying so.

## The quick look shows the whole frame

Space over the programme played the cut, the grade and the effects and nothing
that is drawn *over* the finished frame — no spinners, no captions, no scenes, no
bubbles. The look built a player of its own, and the overlay tree belonged to the
window.

It now hosts the same `OverlayLayers` tree — a third caller, not a third
implementation — in an `AVSynchronizedLayer` bound to the look's own player. That
is the difference that matters for a four-second look: the window's tree is held
still and stepped by hand, which is right for scrubbing and wrong for playback,
where two clocks make a spinner stutter.

Proved by rendering rather than by reading: the tree is taken off a real look,
handed to an animation tool, encoded and decoded, and the bright pixels of a
spinner counted inside its span and outside it.

**And the panel moves.** The caption strip is the handle and its corner resizes,
keeping the programme's shape. Everywhere else on it still passes the click
through, so "any gesture that is not moving about the list means enough" is
intact — and the list keeps the keyboard, so space and the arrows go on working.

**Space works in the clip library too**, playing the take's own media at the
take's offset. Nothing is drawn over it, because overlays belong to a project and
a library clip is a piece of a recording.

## Comments survive a save

Opening a project you had annotated and saving it destroyed every comment in it:
`crawl.cuttrproj` went in with 29 comment lines and came out with one.

They now ride on the model beside the unknown keys — the existing answer to "the
file carried this and a decode would delete it" — addressed by path, and a list
item is addressed by **what it says rather than its index**, so a note about one
overlay cannot be handed to whichever one lands in its slot after a drag. A note
on a key that has gone is dropped rather than moved; there is nowhere honest to
put it, and inventing one is the migration this addressing exists to prevent.

The emitter is untouched: it still writes the same bytes, and the comments are
spliced into its output by re-reading it with the same addressing, so the reader
and the writer agree by construction instead of by being kept in step. Styles,
scenes and profiles also come back in the order the file had them.

Measured: 35 comment lines in, 35 out, and the file now round-trips line for
line.

## ⌘S saves everything

`⌘S` writes every open document that has changed — takes before projects, since a
project window re-resolves when a take lands. `⌥⌘S` saves just the one in front.

Only what is dirty is written. That is not tidiness: the emitters exist to keep
diffs still, and a save-everything that touched every file would fill the version
branch with empty commits. Untitled documents are named in the status line rather
than putting up a row of sheets, and one that cannot be written is named while the
rest still go down.

## The "when it is on" strip zooms

⌥- or ⌘-scroll and pinch zoom about the pointer; `−` and `+` about the selected
range; `Z` frames it, `F` fits. The same vocabulary the cutting timeline uses, so
there is nothing new to learn. The bare wheel is deliberately not claimed — the
strip sits inside a scrolling form, and a view that swallows the wheel is a trap.

**`i` and `o` set the selected range's ends from the playhead**, written through
the same door a drag uses, so a `within:` stays a `within:` and a mark still
snaps. They refuse with a reason rather than doing nothing: a range hung on a
section says the programme decides when that is, and a playhead outside what the
range is over says so.

## Under the picture

The three Core Image contexts are one function now, with the measurements written
beside it. The "seven or eight levels" the old comments blamed on colour
management was really the *destination*: `CGColorSpace(name: .itur_709)` is a
different profile from the one a 709 frame actually arrives in, and naming it cost
nineteen levels where landing where the frame came from costs nought. Management
is still off, and the reason is now recorded — a managed pass would convert a
painted `#808080` and the Core Animation pass would not, so one hex would be two
colours in one film. No pixel moved: the renders are byte-identical.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
