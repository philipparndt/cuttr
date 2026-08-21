# Examples

Programmes made of nothing but the file they are written in — cards, scenes and
effects, no footage — so every one of them renders on any machine:

    cuttr-render examples/scenes/scenes.cuttrproj

| | |
|---|---|
| `scenes/scenes.cuttrproj` | `{{title}}`: one scene used three times with different words in it |
| `scenes/shapes.cuttrproj` | bars that draw themselves, a rule sweeping, a square turning through two colours |
| `scenes/kinetic.cuttrproj` | one word at a time, each under a block that wipes off it |
| `scenes/morph.cuttrproj` | a square becoming a circle, a triangle becoming a star, and parts that fill themselves |
| `scenes/gradient.cuttrproj` | a ground ramping out of one gradient and into another, and an angle turning a whole circle |
| `scenes/credits.cuttrproj` | `roll:` — end credits three ways: a roll up the frame, one block at a time, and a warm centred one |
| `scenes/crawl.cuttrproj` | the same `roll:` part as an opening crawl, receding and fading as it goes |
| `scenes/typing.cuttrproj` | a word typed one letter at a time and then moved in — and what hand-placing text costs |
| `effects/celebrate.cuttrproj` | metallic confetti over a title card, then snow |
| `effects/weather.cuttrproj` | rain, snow and sparks — the same machinery with different numbers |
| `effects/looks.cuttrproj` | film mode, the tape and chromatic aberration, working on confetti and rain |
| `effects/coming-on.cuttrproj` | `keys:` — a drizzle becoming a downpour, bars closing in, a lens giving up and recovering |
| `overlays/placements.cuttrproj` | captions written inside the entries they cover, and one on the programme's own clock |
| `overlays/at-the-mark.cuttrproj` | `at:` — the same fade placed before, across and after the mark, at both ends of a span |
| `overlays/bubbles.cuttrproj` | speech, thought and a box with an arrow — drawn by hand, redrawn eight times a second, aimed by two points, and the same hand on every render |
| `components/chart.cuttrproj` | `component:` — a React chart, baked to frames in the browser macOS already has, with nothing installed |

One of them bakes before it renders. `components/chart.cuttrproj` draws its
component into `.cuttr/components/walks/` the first time — a few seconds — and
reuses the frames after that. Nothing is installed and nothing is fetched; React
is in the app bundle. Those frames are gitignored, because in a repository the
component is the thing worth keeping and re-baking it is the demonstration. In a
real project they are the opposite: the artefact, kept and exported, for the
reason `docs/remotion.md` gives at length.

Five things these are meant to teach, all of which cost a render to learn:

**The ground belongs to the card, not to the scene.** Effects are drawn *into*
the picture; a scene is drawn *over* it, as a Core Animation layer, in a second
pass. A scene with a full-frame background therefore hides every effect under
it — the confetti is there and cannot be seen. Put the colour on the card's
`fill:` and leave the scene its words.

**Cut between scenes.** For the same reason a scene does not travel with a
dissolve or a push: during an overlap both scenes are on at once and the later
one simply covers the earlier. Between two shots a push reads beautifully;
between two cards with scenes on them it reads as the second arriving early.

**`in:` and `out:` are not `keys:`.** The envelope scales the whole of an effect
on its way in and out — everything at once, from nothing to everything, which is
one shape and the shape of *arriving*. Keys move the parameters themselves, so
the rain can start as a drizzle and turn into a downpour while it is fully on.
Not everything can move: a seed cannot, because the same number giving the same
cloud on every render is the whole of what a seed is for, and a stock or a
condition or a finish cannot, because there is nothing half way between two
names. Ask for one of those on a key and the file will not open, with a sentence
saying which and why — an animation that silently does nothing looks exactly
like an animation nobody wrote.

**A `roll:` is a column, not a scroll.** It knows how a credit column is set —
roles against names, gaps between blocks, a title over the top, every line
spaced in proportion to its own type size — and it knows nothing at all about
moving. What makes `credits.cuttrproj` scroll is two keys on `y`; what makes the
middle of that same file a sequence of cards is keys that hold `y` still and
move `opacity` instead; what makes `crawl.cuttrproj` an opening crawl is the
same two keys with `scale` beside them. Compare it with `typing.cuttrproj`,
where every line is a text part placed by hand: nine parts and twenty-eight keys
to type seven letters, which is fine when the placement *is* the animation and
becomes a file holding the result of a layout the moment there are thirty names
in it.

**A component is for when the position is a fact about the data.** That is the
whole test, and `components/chart.cuttrproj` argues it in its own header.
`scenes:` puts a title where somebody decided it looks right, in text that
diffs — which is exactly right for a title and exactly wrong for twelve bars
whose heights, widths and gaps all fall out of the numbers. Written as parts and
keys, a chart is a file holding the *result* of a layout: change one month and
every bar after it has to be re-typed. Compare it with `scenes/typing.cuttrproj`,
which makes the same complaint at nine parts. The price is that the scene editor
cannot touch it, it takes seconds to bake rather than being instant, and its
pixels came out of WebKit rather than out of this program — so a component is the
answer for a chart, a table or a leaderboard, and the wrong answer for a title.

**Watch the bubbles rather than looking at them.** `overlays/bubbles.cuttrproj`
is the one example whose point is invisible in a still: every bubble in it is
redrawn eight times a second and each drawing is held, the way a cartoon holds a
drawing for two or three frames instead of redrawing on every one. The last card
is the same bubble three times — `breath: 0`, the default, and `breath: 4` —
which is the comparison worth pausing on. Frozen, the three differ by about a
pixel. Running, the first is a sticker, the second is drawn, and the third is
having a seizure. Twenty-five drawings a second looks like the third one; that is
why the rate is eight and not the frame rate.

The card before it is the other thing a still cannot show you, and this one it
almost can: **a bubble has two positions, and they are two words.** Three bubbles
standing off from one spot by the same `offset:`, with `tail:` sending the tip to
three different places. The papers are level with each other and the tails are
not, which is the whole claim — on a real shot the spot is the eye a tracker can
follow and the tip is her mouth, and moving one must not move the other.
