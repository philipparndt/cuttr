# cuttr 0.5.0

A take can be cut by reading it, and the two windows agree with each other for
the first time.

## Cut by reading

A take can now be transcribed on this Mac — nothing is uploaded — and what was
said appears beside the picture as a **words** pane in fixed-width text, laid
out the way somebody would write it down: a new line where the talking stops
for half a second, a paragraph where it stops for two and a half, and an
ellipsis so the pause is on the page rather than implied by the white space.
Those numbers were measured on real footage rather than chosen.

Drag across a sentence to set in and out; `⏎` makes a clip of it. Click a word
to take the playhead there. Space plays what is selected and stops at the end
of it. Right-click gives you the two things this pane is for — play exactly
these words, or make a clip of them — and it is about the line under the
pointer when nothing is selected.

**Say what language it is.** The recogniser used to take the language from the
Mac, which meant German footage on an English Mac came back as four hundred
words of confident nonsense — the same take reads as 13 words in English and
421 in German. The pane now lists the languages this Mac actually has, marks
the ones that would have to be fetched, remembers the choice between takes, and
shows a take's own language when it already has words, because that is a fact
about the file rather than a preference.

**The pauses are part of the take.** Select an ellipsis and you have selected
the silence itself, which can be played or cut like anything else — the beat
before an answer is often exactly the thing that has to go, or exactly the
thing that has to stay.

**The sounds that are not words.** `[laughter]`, `[applause]`, `[singing]` and
four more are found on this Mac and sit inline in their own colour, selectable
exactly like a word. Seven kinds, not the classifier's three hundred, and one
of them was dropped after it fired eight times on a real take and was wrong
every time: a class that is never right is worse than one that is missing.

**Who is speaking.** Press a number to name the line under the caret and every
following line that agreed with it, so an interview is a couple of dozen
keystrokes and no mouse. Each speaker gets a colour derived from their name, and
the name itself begins every line, because hue is never the only marker.

Automatic assignment is offered and not trusted. Four methods were measured
against sixty-eight hand-read labels: always answering the commonest speaker
scores 61.8%, Apple's voice analytics 52.5%, timbre 60.3%, and whose mouth is
moving 80.9%. All are below the bar, so nothing runs by itself — a guess arrives
dimmed and in brackets, and keeping it is a separate press.

**A name for the clip.** With Apple Intelligence available, a clip made from a
selection arrives with a name proposed from what is said in it, in the language
it was said in. It is a proposal: it lands in the rename field, selected, and
nothing reaches the take until Return. Every proposal is checked against the
words actually spoken, because a model asked to label *"everything from A to Z"*
once answered with a soup nobody had mentioned.

## Cuts that land on the sound

A word time is not a cut point. It comes from a recogniser, it is quantised to a
twentieth of a second, and it is loose against the audio — so a clip made from a
selection used to start a little before or after the sound did, and to be
trimmed hard against the words, which glued every clip to the next.

Both are answered from the recording now. The in mark goes to the nearest moment
the sound starts and the out mark to where it stops, within a reach short enough
that a mark can never leave the run it was in. Then each mark takes air — up to a
quarter of a second, and **never past the middle of the pause it sits in**. That
midpoint is the whole rule: a pause belongs half to each side, so two clips cut
either side of one gap meet exactly, without either knowing the other exists.

On a five-minute take: in marks were adrift by a median of 70 ms and out marks by
100 ms; lines with speech left outside the mark fell from 19.6% to 4.3%; and the
air at a join went from a median of 500 ms to 890 ms. Where nobody stops talking,
nothing is invented and nothing is taken from a neighbour's voice.

Hold **⌥** while dragging a clip's edge and the mark goes to the nearest place
the talking starts or stops — read from the waveform the timeline is drawing,
so what you see is what you snap to.

And it reads from a terminal, which is the point:

    cuttr-render --silence take.cuttr           # every quiet stretch, and the words either side
    cuttr-render --silence take.cuttr --clips   # per clip: "air 0.240 s" or "cuts 1.278 s into speech"

## A window that says one thing at a time

Both windows have been rebuilt to one grammar: **the left edge says what you are
doing, the middle is the thing, and the bar says which document and what just
happened.**

- A **rail** down the left edge. In a take: clips, faces, words, look — one open
  at a time, because only one is ever being worked on. In a project: Project,
  Edit, Text, Play, which is what those modes always were.
- **One bar**, and the play time is always in it, at a fixed width so the digits
  do not dance. The bar *is* the title bar now — one band where there were two.
- The **overlays and sounds panes are gone**. The tree beside them already said
  it, and saying it twice was most of why that window read as chaotic.
- The **properties column says what it is looking at** — `clip-4 · from
  mia-take-1 · in @question1` — and each of those selects the thing it names.
  Its explanations wait behind a **?** instead of being printed for ever.
- **Hue means one kind of thing**, program-wide, and selection has no hue at all.
- Clicking the **document's name** lists every open document, projects with their
  takes indented under them. `⇧⌘P` is the keyboard path. Window tabbing is off
  with it: there is no tab bar and no dragging a tab out, and macOS's own `⌘\``
  and Window menu do that work.

## Written where it plays

An overlay or a sound can be written **inside** the timeline entry it belongs to,
where it covers exactly that placement and needs no name invented to say so. The
tree makes and moves them there, and dragging one between entries keeps it on
screen at the same moments.

Effects can also **move while they are on**. `keys:` gives an overlay keyframes
in the same vocabulary scenes already use, so an aberration can grow and settle
and a shower can come on hard. What cannot honestly be animated is refused by
name rather than ignored — a seed that changed half way through would be two
clouds cut together rather than one cloud moving.

## Fixed

- **Collapsing a pane could kill the app.** A folded pane went on laying its
  table out inside a rectangle that is entirely heading, and a table given a
  rectangle it cannot arrange never settles: it laid out 1,760 times in one pass
  until AppKit gave up. Eight more conflicting pairs went with it, and a test now
  fails if any window causes even one.
- **An overlay with `in: cut, out: cut` was on screen for the whole film.** The
  span was right and the export ignored it. `{fade: false}` also read as a fade
  of the default length, for overlays and for sounds.
- **Save As did nothing in a project window** — it offered to write a take. It
  also re-points every path in the project now, so a project saved into another
  folder still finds its takes.
- **A clip's length comment could contradict the times above it** by a
  millisecond. It is the difference of the two times as written now.
- Person masks are cut at a higher resolution, rain and snow arrive and leave
  when they are told to, and a build says which commit it came from.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
