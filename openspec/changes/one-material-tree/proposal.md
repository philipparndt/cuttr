## Why

The project window lists what a project is made of twice, in two panes, one
above the other with a divider between them.

`TakesTable` shows the takes and the scenes: a name, how many clips are in it,
and where the file is. `LibraryView` shows the clips, the tags, the anchors —
and the scenes again — grouped under collapsible headings, with a search field
and `Find a meme` above them. Between them they answer one question, "what have
I got to work with", and they answer half of it each: the takes pane knows there
are fifteen clips in `Mia 1` and cannot show you one; the library knows every
clip and lists `Mia 1` fifteen times in a column.

It is also expensive in the one direction the window has least of. The two panes
are stacked vertically with a drag handle between them, one held at 180 points
and floored at 90, the other floored at 120 — so a third of the material column
is spent on chrome and on saying the same names twice.

## What Changes

- **One outline replaces the two panes.** Four roots, each a heading that folds:
  `Takes`, `Scenes`, `Anchors`, `Tags`.
- **A take's clips are its children.** The clip count stops being a column and
  becomes a disclosure triangle. `Mia 1` opens to the fifteen clips cut from it,
  which is the join the two panes could not make.
- **Tags stay a root of their own** rather than moving under the takes. A tag
  spans takes — `#b-roll` means every clip tagged so, wherever it was cut — so
  filing it under one take would be filing it under an arbitrary one of several.
- **Dragging a take lays down every clip it holds**, in take order. Dragging a
  clip does what it does now.
- **Search and `Find a meme` stay at the top**, over the whole tree rather than
  over the clips alone: one field that finds a take, a clip, a scene, an anchor
  or a tag.
- **`Add` and `New` move to the bottom** of the tree, and into the context menu
  on the rows they belong to, so a right-click on `Takes` offers them where the
  pointer already is.
- **`TakesTable` and `LibraryView` are replaced by one view**, and the split
  stack that held them, its divider and its two height floors go with them.
- **BREAKING for the window's layout only.** No file format changes. A project
  written by this version is a project written by the last one.

## Capabilities

### New Capabilities

- `material-tree`: the one outline — what its four roots hold, what opens, what
  drags, what the search matches, and where `Add` and `New` are.

### Modified Capabilities

None. `openspec/specs/` is empty; `share-projects-over-git` is implemented but
not archived, so nothing has been promoted yet.

## Impact

- **Removed**: `Sources/CuttrUI/TakesTable.swift` and
  `Sources/CuttrUI/LibraryView.swift`, and the `material` split stack in
  `ComposeWindowController` with its divider and floors.
- **New**: `Sources/CuttrUI/MaterialTree.swift`, an outline on `MenuOutline` —
  which already carries the click that focuses a list, the paging keys that move
  the selection, and `MarkedRow`'s selection.
- **Changed**: `ComposeWindowController` loses two sets of callbacks and gains
  one. Every behaviour both panes have keeps working: open a take (⌥ for a
  window of its own), rename a take in place, remove one, add and make takes and
  scenes, open a scene, insert a reference, open a clip in its take, and drag
  anything onto the programme.
- **Unchanged**: `ComposeDocument.Vocabulary` already carries everything the
  tree needs — `items` with their take, `takeNames` in project order,
  `anchorTakes`, `scenes`, `tags`. No new model.
- **Risk**: this is the panel somebody assembles a programme from, and it is
  being replaced rather than edited. The mitigation is that the *behaviours* are
  enumerated in the spec and each keeps its test; what changes is where the rows
  are, not what pressing them does.
