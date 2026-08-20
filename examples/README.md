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
| `effects/celebrate.cuttrproj` | metallic confetti over a title card, then snow |
| `effects/weather.cuttrproj` | rain, snow and sparks — the same machinery with different numbers |
| `effects/looks.cuttrproj` | film mode, the tape and chromatic aberration, working on confetti and rain |
| `overlays/placements.cuttrproj` | captions written inside the entries they cover, and one on the programme's own clock |

Two things these are meant to teach, both of which cost a render to learn:

**The ground belongs to the card, not to the scene.** Effects are drawn *into*
the picture; a scene is drawn *over* it, as a Core Animation layer, in a second
pass. A scene with a full-frame background therefore hides every effect under
it — the confetti is there and cannot be seen. Put the colour on the card's
`fill:` and leave the scene its words.

**Cut between scenes.** For the same reason a scene does not travel with a
dissolve or a push: during an overlap both scenes are on at once and the later
one simply covers the earlier. Between two shots a push reads beautifully;
between two cards with scenes on them it reads as the second arriving early.
