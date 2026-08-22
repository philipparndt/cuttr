# cuttr 0.10.0

The project window lists what a project is made of once, in one tree, instead of
twice in two panes.

## One tree

There were two lists, stacked, with a drag handle between them. A takes table
knew there were fifteen clips in `Mia 1` and could not show you one; a library
knew every clip and listed `Mia 1` fifteen times in a column. Between them they
answered one question — what have I got to work with — and answered half of it
each, while spending a third of the column on chrome and repetition.

    ▾ TAKES              ▾ SCENES        ▾ ANCHORS      ▾ TAGS
      ▾ Mia 1     19         title-card      mia-eye        b-roll  12
          intro                                             keep     4
          demo-install
      ▸ Leni       8
      ▸ memes      4

**A take's clips are its children**, which is the join neither list could make.
The clip count stopped being a column and became a disclosure triangle.

**Tags are a root of their own.** A tag spans takes — `#b-roll` means every clip
tagged so, wherever it was cut — so filing it under one take would be filing it
under an arbitrary one of several, and every copy would drag the same thing.

**Memes are one row**, as they were one heading before: a meme is a take with a
single clip in it, and a row each is a page of rows with one child under every
one.

**Dragging a take lays down every clip it holds**, in order. Dragging a clip, a
tag, an anchor or a scene does what it did.

**Search covers everything** — takes by name, clips by name, slug or tag, and
scenes, anchors and tags by name — and shows a match *with its parents*: a clip
found inside a folded take opens that take rather than appearing loose. A row
with no parent visible cannot say which take it came from, which is the one
thing the tree exists to say.

**Takes start folded**, so a project with forty of them opens showing the list of
takes rather than a wall of clips. What you open is remembered.

Everything both panes could do, the tree does: open a take, open one beside the
project with ⌥, rename in place, remove, add and make takes and scenes, open a
scene in its editor, put a reference on the programme, open a clip in the take it
was cut from, and space for a look at a clip before you place it.

**Add and New are under the tree** and in the context menu of the root they
belong to. A take's own menu now reveals its file in the Finder — which is where
the `Where` column went, since there is no room for a path on a tree row.

## The material folds away

A chevron in the bar folds the whole panel to the side and brings it back the
width it was. The control is in the bar rather than in the panel on purpose: one
inside it would go away with it, and then nothing on screen brings it back.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
