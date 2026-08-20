# Where the silence is

How a run of words becomes a cut, why a clip takes air with it, and how two
clips share one pause without either of them knowing the other exists.

## Two things a transcript cannot tell you

**A word time is not a cut point.** It comes from the recogniser, and it is a
claim about which sound was which word rather than about the instant the sound
began. It arrives rounded to a twentieth of a second besides. On the take this
was built against — five minutes of German, a separate recorder, 430 words — the
marks that had a moment of sound to be put on were off by a median of 70 ms at
the head and 100 ms at the tail, and by as much as 200 ms. A fifth of a second
is plainly audible: a clip that opens there begins mid-syllable or begins on
silence, and either one reads as a mistake.

**Nothing knew where the pauses were.** `Transcript.silence(after:)` classifies
the gap between two words as none / beat / rest / sentence, which is enough to
lay a transcript out in paragraphs and is not a measurement of anything. It is
derived from the same word times. So every clip was trimmed hard against the
words, and a row of them assembled later was glued end to end with no air
between them.

Both answers have to come from the audio. They now do.

## The shape of the answer

`SpeechEdges` already found the moments the talking starts and stops, from the
envelope the timeline is drawing — 242 of them over five minutes, in 50 ms.
`SpeechMap` pairs those moments up into *runs* of speech, and therefore into
*stretches of quiet*, which is the shape almost every question wants:

```
cuttr-render --silence take.cuttr
```

prints every stretch of quiet in a take, how long it is, and the words on either
side of it. `--clips` says how each existing clip's marks sit against the
speech — whether the clip has air or is cutting through a word. `--from/--to`
says what a proposed span would become.

**There is no sidecar, and that is deliberate.** A take already carries a
transcript file and a path per anchor, and each of those is a file that can fall
out of step with the media. What earns a sidecar is being expensive: recognising
five minutes of German is a minute of somebody's afternoon. This is a decode and
48 ms of arithmetic. When re-asking is free, a file that can go stale is a worse
answer than no file at all.

## Refinement

The in mark goes to the nearest moment the sound *starts*; the out mark to the
nearest moment it *stops*. Starts for one end and stops for the other, never
both, so a mark cannot be pulled onto the wrong kind of edge — an in mark beside
the end of a sentence would otherwise open the clip after the sentence it was
cut from.

Within `SpeechMap.reach`, a fifth of a second. That is several times the
recogniser's quantum, so it is worth doing, and strictly less than
`SpeechEdges.restingFor` — the quarter-second of quiet that makes a stop a stop
— so a mark inside one run can never reach the start of the next.

Between the runs, the transcript is what stops it. `Transcript.neighbours(of:)`
says where the previous word ended and where the next one starts, and the marks
are clamped to them. Two words with no silence between them clamp each other,
refinement does nothing, and that is the right answer: there is no moment the
sound started in the middle of a word.

**Measured.** Of the 46 lines whose marks landed in the quiet, the word times
left audible speech outside the mark on 9 of them — 19.6%, one clipped clip in
five. After refinement, 2 — 4.3%, and the worst of those is 8.5 dB over the
talking threshold, which is a breath.

## Handles, and the midpoint rule

A clip takes air at each end: up to `SpeechMap.handle`, a quarter of a second,
**and never past the middle of the silence it is sitting in**.

The midpoint is the whole rule. A pause belongs half to the sentence in front of
it and half to the one behind. Two clips cut from either side of one pause
therefore stop at the same line: they meet exactly, and they never overlap —
without either of them knowing that the other exists.

That last part is what the rule is for. A clip has to be a function of the take
and the recording alone. Any rule that shared a gap by looking at the clips
already in the file would mean that making the second clip went back and
re-trimmed the first, and a file somebody is reading as text would move under
them.

**What the guarantee is worth, exactly.** It holds whenever each mark is in its
own half of the pause they share — which is where a word time is, and where a
refined mark sits precisely, on the boundary of its own run. It cannot be made
to hold for arbitrary marks by any rule of this shape, and the proof is one
line: two marks a millisecond apart in the middle of a long pause would need the
earlier one to take no air at all, and it has no way of knowing the other is
there. What *is* unconditional is the part worth having — a mark only ever moves
within the pause it was already in, so anything two clips end up sharing is
silence. No word is ever in two clips. On the real take, 28 of 67 adjacent pairs
share some silence and none of them share a syllable.

**Measured.** Air heard at the join of two clips made from adjacent lines, from
the last sound of one to the first sound of the next: median 500 ms at the word
times, 890 ms once cut. Joins with under 40 ms of air — the glued ones, the
complaint itself — 13 before, 10 after.

## The case that decides whether to trust it

The ten joins that are still glued shut are joins where **nobody stopped
talking**. The longest unbroken run in that take is 9.36 seconds and 26 words. A
clip cut out of the middle of it:

```
asked   02:17.467 → 02:24.427
refined 02:17.467 → 02:24.427   in +0.000 s, out +0.000 s
cut     02:17.467 → 02:24.427   air 0.000 s and 0.000 s
```

Nothing moved and nothing was added. There is no moment the sound started to
refine to, the stretch of quiet at each mark is empty, the midpoint is the mark
itself, and the handle is nothing. The clip is a hard cut against the words,
exactly as it was before any of this.

That is the answer that matters. Where there is no air, you get no air — not a
quarter of a second bitten out of somebody's sentence to make the number come
out right.

## The defaults, and asking for none

| | | |
|---|---|---|
| `SpeechMap.handle` | 0.25 s | air at each end of a clip, when there is that much to be had |
| `SpeechMap.reach` | 0.2 s | how far a mark may move to land on the sound |
| `SpeechEdges.restingFor` | 0.25 s | quiet before the talking counts as stopped |

The handle is a quarter of a second because below about a tenth the air is not
audible as air and above about a third it sounds like a clip that begins by
waiting. It is also exactly `restingFor`, which means the shortest gap this
program will call a stop gives each of its two neighbours half of itself, and
every longer gap gives both of them the whole amount.

Ask for none with `--handle 0` on the command line, or Clip ▸ Air Around Word
Clips in the app. Somebody whose programme puts its own handles on wants one set
of them, not two.

## What this does not change

**Not the file format.** A clip is written as the two times it is, and a take
with no clips cut this way writes byte for byte what it always wrote. The handle
is a decision made at the moment of cutting, not a property of the clip; a
`handle:` key in the file would mean the times in a take no longer meant what
they say, which is the one thing this format is for.

**Not the clock.** Everything here is on the video's clock, like every other time
in a take. `SpeechMap` is built with the shift the waveform lane is drawn with —
the take's `audio.offset` for a separate recorder — so re-aligning the recorder
moves the speech map and not a single cut mark.

**Not what ⌥ snaps to.** The timeline's ⌥-drag and the refinement now read one
array: `TakeDocument.speechMap`. Two copies of one measurement would be two
chances for the mark you can see and the mark you get to disagree by a hair, and
nobody would ever catch it happening.

## Running the numbers again

Every figure on this page comes out of a footage test, gated the way the others
are, on a take that is not and cannot be in this repository:

```
CUTTR_FOOTAGE=/path/to/mia-take-1.cuttr \
    xcrun swift test --filter SpeechMapFootageTests
```

The arithmetic itself — refinement, the midpoint, the case with no silence in it
— is proved on envelopes made up for the purpose in `SpeechMapTests`, which
needs no footage and runs with the suite.
