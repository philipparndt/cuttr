# Who is speaking

What was tried, what it scored, and why the automatic pass is an offer rather
than an answer.

## The ground truth

`Tests/Fixtures/mia-take-1.speakers` says who speaks each of the 68 lines of a
real five-minute take — a German interview with a child and at least two adults
— labelled by hand, by reading. An interview alternates question and answer and
the text says which is which: a question about what somebody looks like is the
interviewer, and the description that follows it is the child.

**The words are not in this repository and must not be.** This repository is
public and that take is a seven-year-old's family video. A label is a *time and
a name* — the shape of a conversation rather than its content — and the
transcript stays beside the take on the machine that recorded it. The labels are
matched to a take by time rather than by line number, so that changing how lines
are divided cannot silently shift every label by one.

Two labels, not three. There are certainly two adults in the room — the exchange
from 00:32 to 00:54 is one of them talking to the other about where to cut — but
which adult says which of those lines cannot be read off the text, only heard.
Reading is the method that was used, so reading is what the labels claim.
Anybody who listens can split `interviewer` in two by editing that one file.

Four lines are read but not certain, about 6% of the take. They are named in the
fixture's header and labelled as read.

**68 lines: 26 interviewer, 42 Mia. Always answering `mia` scores 61.8%.** That
is the number to beat, and it is the reason a method at 60% is not "slightly
worse than good" but *worthless*, because a constant is cheaper.

Recompute any of this, on a machine that has the footage:

```
cuttr-render --speakers take.cuttr \
             --truth Tests/Fixtures/mia-take-1.speakers \
             --method mouth
```

The tests that need the words are gated the same way and skip without them:

```
CUTTR_FOOTAGE=/path/to/mia-take-1.cuttr xcrun swift test --filter SpeakerFootageTests
```

Scored the way diarisation is always scored — see `SpeakerLabels.score(_:against:)`:
the clusters have no names of their own, so every way of matching them to the
labels is tried and the best one is the score. Anything else marks a method
wrong for having called the same two people A and B rather than B and A.

## What was tried

| method | of all 68 lines | of the lines it placed | separation | time |
|---|---|---|---|---|
| always answer `mia` | 61.8% | — | — | — |
| voice analytics | 30.9% | 52.5% (40 placed) | 0.49 | 14 s |
| timbre (mel cepstra) | 55.9% | 60.3% (63 placed) | 0.16 | 3 s |
| **whose mouth is moving** | **80.9%** | **84.6%** (65 placed) | 0.69 | 93 s |
| speaker embedding | not measured | | | |

### `SFVoiceAnalytics` — 52.5% of the lines it placed, which is a coin toss

Apple's recogniser does fill in `voiceAnalytics`, and it took some work to get
at: `SFSpeechRecognizer` treats a file as a run of utterances and starts again
at each one, so asking for final results only returns **five characters** for a
five-minute interview. Every callback has to be taken and later ones allowed to
supersede earlier ones for the same timestamps — that is what
`VoiceAnalytics.Gathered` is doing.

Done properly it yields 1883 frames of pitch, jitter, shimmer and voicing across
the take. (`voicing` is not the probability its name suggests: it came back
between 0.02 and 0.15 on plain speech, and gating on 0.5 threw away all but 51
of those frames.)

And it separates nothing. 52.5% on the lines it placed is chance on a two-class
problem, and the whole-take figure is *below* the constant because it declines
28 of 68 lines. This is the same finding as pitch, which was already known not
to work here, and it is not surprising: four numbers about the larynx are four
numbers about the larynx, and a close mic on a child and on an adult woman put
them in the same place.

`Speech.framework` has no diarisation in it. There is no speaker symbol anywhere
in the framework, and voice analytics is not one.

### Timbre — 60.3%, barely off the floor

Mel-frequency cepstral coefficients off the samples: 25 ms frames every 10 ms,
26 mel bands, 13 coefficients with the first dropped, mean and spread per line,
standardised, k-means. This is the front end of every speaker system there has
ever been and it needs no model, no permission and no network.

It does not work on this footage either. Things that were tried and did not
save it:

- frame-level clustering with a majority vote per line (63.2%) — more data, same
  answer;
- the video's own microphone instead of the recorder (61.8%, exactly the
  constant);
- means only, spreads only, various coefficient counts.

Picking the subset of coefficients that scored best *after* seeing the labels
reaches 81%, and that number is worthless: it is chosen by looking at the
answer, and there is one take to look at. The honest figure for the textbook
configuration is 55.9%.

The alignment was checked before any of this was believed. Running the same
pipeline with the recorder's offset deliberately negated leaves 16 lines too
quiet to measure instead of 5, which is what a wrong offset looks like and is
not what the real one does.

### Whose mouth is moving — 84.6% of the lines it placed

Not audio at all. `SpeakerDetector` was already in this program: it takes the
faces a take is already following — an ``Anchor`` is a person — and measures how
much each one moves its mouth, from the picture. For a take with one tracked
face that is a two-class answer to "is it her?", which is exactly the question
the ground truth asks.

Two flaws had to be fixed before it was worth anything:

- **The samples were spread across the span.** A twelve-second line was sampled
  every half second, and the difference between one sample and the next is then
  a fact about two unrelated moments rather than about a mouth opening and
  closing. Sampling at ten a second from the head of the line, and letting the
  cap shorten what is *watched*, took it from 69.1% to 79.4%.
- **The scale was linear.** A mouth is either moving or it is not, and the
  interesting difference between 0.004 and 0.02 is the factor of five, not the
  0.016. Clustered linearly, one very animated line stretches the range and
  drags the split point up with it, and the errors were all one-directional —
  Mia called `interviewer`, never the reverse. On a log scale they stopped
  being one-directional.

Watching six seconds of each line rather than 2.4 gives 80.9% / 84.6%, at 93
seconds for the take.

Where it is still wrong: mostly the adults' side conversation from 00:20 to
00:42, where Mia is on camera, listening and reacting — and one of those lines
is one of the four the ground truth is itself unsure about. It cannot see the
interviewer at all, so what it really reports is "her, or not her".

### A speaker embedding — implemented, not measured

`SpeakerEmbedding` runs a Core ML model over each line and clusters the vectors
by angle. **There is no model in this repository and nothing downloads one by
itself.** If the file is not on the disk the method is not offered, and
everything else works exactly as before.

It is unmeasured because converting one needs `coremltools` and, for the
PyTorch-only models, `torch` — two gigabytes of Python that nobody asked to have
installed. `Scripts/fetch-speaker-model.sh` does the whole thing, prints the
licence first, and asks. The number can then be recomputed with the same command
as everything above.

The choice, and the reasoning, is **WeSpeaker `voxceleb_resnet34_LM`, Apache
2.0**:

- It publishes a ready-made ONNX export, so the conversion is one
  `coremltools.convert` call and needs no PyTorch and no model-definition code
  vendored into this repository.
- SpeechBrain's `spkrec-ecapa-voxceleb` is the better-known ECAPA-TDNN and is
  also Apache-2.0, but ships PyTorch weights only.
- `pyannote/embedding` is MIT but gated behind a Hugging Face token, which is a
  poor fit for something that must work without it.
- NVIDIA NeMo TitaNet is CC-BY-4.0 — permissive, but attribution-bearing.

**Two things to weigh before shipping it**, and they are for a person rather
than a build script:

1. The weights are Apache-2.0 by their authors' declaration, but they are
   trained on **VoxCeleb**, whose own release terms are for non-commercial
   research. Whether that reaches downstream use of the weights is an open
   question about your work.
2. VoxCeleb is adult broadcast speech, largely English. **A seven-year-old is
   outside what it was trained on**, and the accuracy it advertises is not the
   accuracy to expect on this footage.

## What the program does with all this

The best method on real footage sits just under 85%, so:

- **Nothing runs by itself.** There is a `Guess` button beside the cast, and
  that is the only thing that starts a pass.
- **A guess is drawn as a guess**: the name in brackets, dimmed, and the words
  are left in the ordinary text colour. Only a confirmed speaker colours their
  own line. A colour that is wrong a third of the time is worse than no colour,
  because after the third wrong one nobody believes the right ones either.
- **A guess is not in the file.** It lives beside the transcript, next to
  `TakeDocument.manualSlugs` and for the same reason: it is a fact about this
  session. The file records what somebody confirmed.
- **Below `SpeakerProposal.leastSeparation` nothing is offered at all.** Every
  clustering produces labels; hand it one blob and it will draw a line through
  the middle of it and report two speakers with great confidence. The silhouette
  is what tells the difference, and saying nothing is the right answer when the
  voices did not separate.
- **Answering a line by hand retires the guesses that answer covers**, so the
  pane never goes on offering an answer to a question already settled.

And the fast path is still the keyboard. Sixty-eight lines is sixty-eight
keypresses with the carry-forward, which is a minute of somebody's time and is
right every time.
