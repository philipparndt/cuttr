# Who is speaking

What was tried, what it scored, and why the automatic pass is an offer rather
than an answer.

## The ground truth

Two kinds, and the second one arrived by somebody doing the work.

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

Then somebody sat down and labelled two takes properly, by ear, in the app —
which puts the labels in the sidecar as `# speaker:` markers, where they are
worth far more than a fixture, because they are what the pass is going to be
taught from in real use. **A sidecar somebody has finished labelling is a ground
truth.** So `--speakers` reads it as one when no `--truth` file is named:

```
cuttr-render --speakers take.cuttr --taught 2 --trials 25
```

Two takes on this machine have been labelled that way, and every figure below is
measured over both:

| | lines | voices | commonest |
|---|---|---|---|
| take A | 70 | 3 — one child, two adults | 67.1% |
| take B | 51 | 3 — two children of similar age, one adult | 45.1% |

Take B is the harder problem and the more honest one: two siblings a year or two
apart, on the same microphone, in the same room.

Scored the way diarisation is always scored — see `SpeakerLabels.score(_:against:)`:
where the clusters have no names of their own, every way of matching them to the
labels is tried and the best one is the score. **Except when the pass was
taught.** A pass that was handed two answered lines per person has no
permutation to hide behind: it chose those names, and calling one person by the
other's name throughout is exactly as wrong as it sounds. That figure is
`Score.agreement`, and it is the one quoted for the taught pass.

## The pass is taught, not blind

The old pass clustered the lines and then went looking for a name for each
cluster. That is the wrong way round, and on take A it was worse than useless:
**29–37% of the lines, against 67% for answering `mia` every time.**

It failed in a way worth writing down, because it is not obvious from the
accuracy alone. The clustering was *fine*. On the mouth-movement features, take
A's two clumps were 0.66 separated and 90% of lines fell in the right one. Then
the naming looked at each cluster in turn and took whoever was commonest in it —
and with six answered lines to go on, one stray answer was the only label in the
cluster holding forty of the child's lines, so that cluster took the stray's
name and the child's name went to the other one. Ninety per cent right became
eight per cent right, at the last step, silently.

The answer is not a better naming step. It is to stop clustering. With two people
already named anywhere in the transcript, those lines are examples of what each
person sounds like, and every other line can simply be asked which of them it
resembles — see `SpeakerClustering.place(_:as:rounds:prior:shrink:trust:)`. The
question changes from "how many voices are there and where are they" to "which
of these two", which is a far easier question and has a right answer to aim at.

A voice is a mean and a variance per dimension, and no covariance between them —
a diagonal Gaussian, which is what a handful of lines can honestly support. Two
answered lines know a little about where a voice sits and nothing at all about
how much it moves, so the variance is mostly borrowed from the take as a whole
and the mean is pulled towards it by a fifth of a line's worth of weight. That
is the relevance factor every speaker system since the nineties has had in it.

Then one round of self-training: the lines that were sure of themselves join
their voice, and everything is asked again. A voice whose one answered line was
atypical gets corrected by its crowd.

**What it is worth**, as the mean of 25 draws of which lines somebody happened to
answer — because that choice moves the figure by twenty points and one draw is an
anecdote:

| take | answered by hand | blind, as it was | taught | separation |
|---|---|---|---|---|
| A | 1 per voice | 37% | **45%** | 0.11 |
| A | 2 per voice | 37% | **59%** | 0.11 |
| A | 3 per voice | 30% | **63%** | 0.12 |
| B | 1 per voice | 48% | 47% | 0.08 |
| B | 2 per voice | 50% | **58%** | 0.07 |
| B | 3 per voice | 50% | **63%** | 0.07 |

Averaged over the six, 42% becomes 56%. Answer one line each and it is roughly a
wash; answer two and it is worth twenty points; answer three and it is worth
twenty-five. That is the workflow the pane was always described as having and
now it is the workflow it rewards: answer a couple, ask, correct a few, ask
again.

Reproduce any row:

```
cuttr-render --speakers take.cuttr --taught 2 --trials 25          # taught
cuttr-render --speakers take.cuttr --taught 2 --trials 25 --blind  # as it was
```

**To the nearest whole per cent, and that is not modesty.** The same command on
the same file twice does not give the same number: `AVAssetReader` does not hand
back byte-identical samples from a compressed file every time — measured, on one
four-second span, two decodes agreeing to nine figures and a third differing in
the fourth — and a line sitting between two voices can change its mind on that.
Half a point of movement is the decoder. Anything smaller than a point is not a
finding, which is also why every figure here is the mean of twenty-five draws
rather than one run of anything.

**The separation gate is gone from this path**, and that matters. Blind, the
silhouette is the only thing standing between a real split and a line drawn
through one blob, so nothing is offered below `SpeakerProposal.leastSeparation`.
Taught, the voices are not a guess — somebody named them — and take B's two
children genuinely sound alike: 0.07 separated, and the answer is still worth
having. Gating it would have suppressed the whole thing.

`Speaker.unknown` is not a voice and is never taken as an example. It is an
answer meaning nobody knows, and two lines answered that way are quite possibly
two different people.

## What was measured and thrown away

All of it against the same two takes and six sizes of answered-line budget. None
of it is in the code, so none of it can be re-measured from the code — the point
of writing the numbers down is that nobody has to do the work twice.

- **Smoothing a lone line between two of the same speaker.** Turns really do
  come in runs, and this really does not help: **−2 to −5 points**, on both
  takes, at every budget. A lone line surrounded by somebody else is usually
  wrong, but the arithmetic is wrong about *which* lone lines, and it moves the
  ones it was right about.
- **Refusing where the margin is thin.** It works, and it is not worth it: a
  floor that leaves 7% of lines alone buys 2 points of precision on the rest, and
  one that leaves 13% alone buys 4. Both end up with *fewer lines correct* than
  offering everything, and the reviewer still has to read every line either way.
  The margin is computed and returned — `Placing.margin` — because it is the
  right thing to hold a threshold against if a use for one ever appears.
- **Length-weighting the examples**, so a twelve-second answered line counts for
  more than a one-second one: **+1 on A, −1 on B**. Nothing.
- **A frame-level Gaussian** over the cepstra of every 25 ms frame, rather than
  one summary vector per line: **+0.5**, and it needs frames plumbed through
  every method, which the mouth and embedding methods do not have. The summary
  vector is the same idea at a hundredth of the machinery.
- **Concatenating mouth movement with timbre**: **+2**, and ninety seconds of
  video decoding for it. Left as two separate methods.
- **Agglomerative clustering** with the answered lines as must-link and
  cannot-link constraints, which is the textbook shape for this size of problem:
  **−4 on average**, and it swings by seventy points on one take depending on
  which lines happened to be answered. A method that good on Tuesday and that
  bad on Wednesday is not a method.
- **More mel filters and more cepstral coefficients** — 40/20, 30/20, 40/14,
  26/20 against the 26/13 in the code: **±3 with no direction to it.** The front
  end is not the bottleneck.
- **Dropping the spreads** and keeping only the cepstral means: **+6 on A, −7 on
  B.** Kept both, as before.
- **Taking the number of voices from the cast** rather than the hardcoded two, on
  the blind path: **+9 on A, −17 on B**, scored the way a blind pass has to be.
  Take B has three speakers and one of them says seven lines; asking for three
  clusters splits one of the two who actually talk. Left at two, and it matters
  much less now that the blind path is the fallback rather than the method.

And the ceiling, which says where the remaining error lives: given **half the
lines** answered by hand, the same arithmetic reaches **88% on take A and 68% on
take B**. On A the features are fine and the labels were the constraint; on B the
features are the wall, and no amount of arithmetic over mel cepstra is going to
tell two siblings apart on one microphone.

## What was tried before: listening against looking

These are the older figures, against the two-label fixture and the blind pass, on
take A only. They are what chose the default method and they still do.

| method | of all 68 lines | of the lines it placed | separation | time |
|---|---|---|---|---|
| always answer `mia` | 61.8% | — | — | — |
| voice analytics | 30.9% | 52.5% (40 placed) | 0.49 | 14 s |
| timbre (mel cepstra) | 55.9% | 60.3% (63 placed) | 0.16 | 3 s |
| **whose mouth is moving** | **80.9%** | **84.6%** (65 placed) | 0.69 | 93 s |
| speaker embedding | not measured | | | |

The tests that need the words are gated on the footage being present and skip
without it:

```
CUTTR_FOOTAGE=/path/to/mia-take-1.cuttr xcrun swift test --filter SpeakerFootageTests
```

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

### Timbre — 60.3% blind, and it is what the taught pass is built on

Mel-frequency cepstral coefficients off the samples: 25 ms frames every 10 ms,
26 mel bands, 13 coefficients with the first dropped, mean and spread per line,
standardised. This is the front end of every speaker system there has ever been
and it needs no model, no permission and no network.

Blind it barely clears the floor. Things that were tried and did not save it:

- frame-level clustering with a majority vote per line (63.2%) — more data, same
  answer;
- the video's own microphone instead of the recorder (61.8%, exactly the
  constant);
- means only, spreads only, various coefficient counts.

Picking the subset of coefficients that scored best *after* seeing the labels
reaches 81%, and that number is worthless: it is chosen by looking at the
answer, and there is one take to look at. The honest figure for the textbook
configuration, clustered blind, is 55.9%.

The alignment was checked before any of this was believed. Running the same
pipeline with the recorder's offset deliberately negated leaves 16 lines too
quiet to measure instead of 5, which is what a wrong offset looks like and is
not what the real one does.

What the taught pass shows is that the *features were never the whole problem*.
The same twenty-four numbers per line, asked "which of these two people" instead
of "how many people are there", reach 63% on both takes from three answered
lines each and 88% on take A given half of them.

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

**And that is why it is not always the better method.** On take B, which follows
two faces, it scores in the thirties — one of the two anchors is solved for
twenty seconds of a four-minute take, so its column is zero throughout, and what
looks like a beautifully separated split (0.83) is one child's mouth against
nothing. A high separation is not a promise. The window still prefers the mouth
when a take has faces, because on a take that has *solved* faces it is the best
thing here; a take whose anchors are half solved is better served by not solving
them at all.

### A speaker embedding — implemented, not measured

`SpeakerEmbedding` runs a Core ML model over each line and clusters the vectors
by angle. **There is no model in this repository and nothing downloads one by
itself.** If the file is not on the disk the method is not offered, and
everything else works exactly as before.

It is unmeasured because converting one needs `coremltools` and, for the
PyTorch-only models, `torch` — two gigabytes of Python that nobody asked to have
installed. `Scripts/fetch-speaker-model.sh` does the whole thing, prints the
licence first, and asks. The number can then be recomputed with the same command
as everything above — and it will benefit from the taught pass without a line of
new code, because a line is a vector and `place` does not care where the vector
came from.

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

The best it does on real footage is around 63% from three answered lines a
person, and 88% at the ceiling. So:

- **Nothing runs by itself.** There is a `Guess` button beside the cast, and
  that is the only thing that starts a pass.
- **Answer two lines first, and press it twice.** The pass is only as good as
  what it was taught, and correcting three of its answers and asking again is
  the cheapest accuracy in the program.
- **A guess is drawn as a guess**: the name in brackets, dimmed, and the words
  are left in the ordinary text colour. Only a confirmed speaker colours their
  own line. A colour that is wrong a third of the time is worse than no colour,
  because after the third wrong one nobody believes the right ones either.
- **A guess is not in the file.** It lives beside the transcript, next to
  `TakeDocument.manualSlugs` and for the same reason: it is a fact about this
  session. The file records what somebody confirmed.
- **A line somebody answered is never guessed at.** It is the example the rest
  were placed from, and offering it back — or worse, offering something else —
  would be the program contradicting the person it is helping.
- **Blind, below `SpeakerProposal.leastSeparation` nothing is offered at all.**
  Every clustering produces labels; hand it one blob and it will draw a line
  through the middle of it and report two speakers with great confidence. The
  silhouette is what tells the difference, and saying nothing is the right answer
  when the voices did not separate. Taught, the voices are given and there is no
  gate.

And the fast path is still the keyboard. Seventy lines is seventy keypresses,
which is a minute of somebody's time and is right every time.
