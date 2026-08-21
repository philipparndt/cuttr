# cuttr 0.7.0

Clips of one take can be levelled against each other, a film can have end
credits, and the speaker pass is taught by the lines you answered rather than
guessing from nothing.

## Levels, in the cutting room

**Two children at one microphone are ten decibels apart, and nothing could fix
it where you could hear it.** Loudness was only ever measured *per recording* —
right for a take somebody speaks through at one level, useless for one where
people take turns. Matching the take to a target moved all of it and left them
exactly as far apart as they were.

A clip now carries its own `gain:`, in decibels, and the cutting window is
where it is set: a **Level** column in the clip list, and **Match Levels Across
the Take**, which measures each clip's own span and works the trims out.

Matched to the *middle* of what it heard, not to the loudest and not to a
target. The median is the level most of the take already is, so most clips
barely move and the ones that were out come to meet them; matching to the
loudest turns everything else up and brings the room with it. Bounded at twelve
decibels, because past that what comes up is the room, and a clip needing more
than that needs re-recording. A clip with nothing to measure keeps the trim it
had rather than being amplified to meet a conversation.

On the programme the trim is *added* to whatever the take-wide match worked out,
so a project matching to a target still does.

## End credits

`roll:` is a new kind of scene part: **the arithmetic of a column.** Roles set
against names, gaps between blocks, a title over the top, lines spaced in
proportion to their own type size. It scrolls because two keys move `y` — held
still with `opacity` keys the same part is a card sequence, and with `scale`
beside them it is an opening crawl.

It exists because a text part is a single line, so thirty names were thirty
parts with two keys each whose `y` values had to stay a fixed distance apart.
The file held the *result* of a layout instead of the layout.

**Generated from the cast, and re-generated later.** A block marked `from: cast`
takes its names from everybody who speaks in the takes the film actually uses.
Ask again after adding three takes and only the derived names are replaced — a
role you rewrote survives, and a block you typed yourself is never touched. The
marker is on the *derived* block rather than on the typed one, so a line added
by hand in a text editor by somebody who never knew the key exists cannot be
silently lost.

Four presets — `broadcast`, `cards`, `family` — each bringing styles under its
own names, so two outros in one project never restyle each other and a style you
tuned is not overwritten.

**And a crawl converges.** The opening crawl faked its distance with a key on
`scale`, and it did not read as distance: a scale shrinks every line and every
gap by the same factor, so the column recedes without ever converging. `tilt:`
lays it on a plane tilted away from the viewer — the lines nearer the horizon
are smaller *and closer together than the ones below them*, which is the effect.
The near edge keeps its size and its leading, so the newest line reads at full
size. Nought is flat, which is what a credit roll wants.

## Who is speaking, taught

**The pass was worse than useless on one take and nobody could see why.** The
clustering was fine; the *naming* destroyed it. On one take the two clumps were
0.66 separated with 90% of lines in the right one — then a per-cluster majority
vote handed the cluster holding forty of one person's lines the name of the one
stray answer that had landed in it. 90% right became 8% right at the last step,
silently.

So it stops clustering once there are names. Two or more speakers you have
answered become exemplars, and every other line is asked which of them it
resembles. Averaged over two hand-labelled takes, **42% becomes 56%** — answer
one line each and it is a wash, two and it is worth twenty points, three and it
is worth twenty-five.

**Where it earns its place, and where it does not.** On a take where three
people share the talking it turns 45% into 63%. On one where a single child
holds two thirds of the lines it reaches 63% against a constant of 67% — so
answering that person everywhere and correcting by hand still wins. What decides
it is how lopsided the speaking time is, not how alike the voices are. It is why
nothing runs by itself and a guess is still only a guess. `docs/speakers.md` has
the numbers, including eight approaches that were measured and thrown away.

**A guess also shows what it would change.** A guess over a name you already
typed is drawn as `Papa → Mia`; one that agrees with what is there is not a
change and is not counted as one. Before, `Keep 12 guesses` was the entire
notice that twelve names were about to go.

**An answer is about the line you are on.** Naming a speaker no longer carries
forward to every following line — one keystroke for a whole page was also one
keystroke for a mistake whose extent nobody could see. Select a passage and name
it to answer a run at once. `U` is a voice nobody can name: an answer, not a
blank, and not a member of the cast.

## End a line yourself

The words pane breaks its lines where the recording stops. **`B`** ends one
where you say instead, and the same key takes it back.

Stored in the sidecar as a comment, which is the one thing every version of the
reader has always discarded — so a build that has never heard of breaks reads
exactly the words it read before. Anchored to a *time* rather than a word index:
re-transcribe and a break stays between the same two words instead of sliding
down the take. A break more than half a second from any boundary is dropped
rather than moved, because a take re-timed by that much has been re-aligned.

Both halves of a broken line keep who was speaking, and each can be answered
separately.

## The cutting window

- **The lane colours are in the bar.** Which lane the next cut goes on is true
  of the whole window, and on the clips pane's heading it disappeared whenever
  that pane was folded away.
- **Space is a look at the selected clip**, playing the take with its recorder
  track already at the offset. The same key puts it away.
- **A section says how long it runs** in the programme tree — `5 entries
  00:24.320` — measured on the programme, so two shots that dissolve are counted
  once.

## Fixed

- **Renaming a take that is open** no longer refuses. It used to have a real
  reason — the open document held the old URL and its next save wrote the old
  file back — which stopped being a reason when every document moved into one
  window. The document is told instead.
- **A range written inside a clip stays inside it.** A `within:` is "so many
  seconds into that shot", and a `to:` past the shot's own end could be typed,
  dragged, and copied by `+ range`. A clip used twice is also two places and not
  one long one: the panel and the drag answered with the first start and the last
  end, which for a shot used at the top and again near the finish is most of the
  film.
- **A bubble stays where it is put down.** Releasing the drag showed the old
  position for as long as it took the file to catch up, because the view gave up
  its in-flight value before the document had the new one. The placement picture
  can also be opened large enough to aim properly.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
