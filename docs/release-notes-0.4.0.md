# cuttr 0.4.0

Two things about sections, both about being able to keep working.

## A section you have not filled yet is not a broken project

Making a section and filling it are two actions, and between them the whole
programme used to stop resolving: an empty `group:` was an error, so the preview
went blank and the Render button greyed while somebody was in the middle of
building one. A caption hung on that section before there was anything under it
did the same.

Both are skipped now, and said out loud rather than silently: what was left out
appears under the picture in the colour of something that is not an alarm — the
programme it describes is playing perfectly well beside it — and `cuttr-render`
writes the same lines to stderr before the description.

A missing *clip* is still refused. That is a reference to material that ought to
be there, which is a different kind of wrong from a shape somebody is still
drawing.

## Watch one section on its own

Right-click a section on the programme: **Preview “name” on its own** takes the
window to the preview, starts at its first frame and stops at its last. After
building a section, that is what somebody wants to see — not the four minutes
in front of it.

## Requirements

macOS 14 or newer, Apple silicon or Intel.
