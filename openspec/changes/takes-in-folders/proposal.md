## Why

A project with forty takes lists forty takes. The tree gave them somewhere to
live — a `Takes` root with each take's clips under it — but nothing to be
arranged *into*: a shoot with four interviews, a day of b-roll and a pile of
outtakes is one flat run of names, sorted by the order somebody happened to add
them in.

Sorting is not the answer, because the grouping somebody wants is not a property
of the file. Interviews are interviews because the person cutting says so.

## What Changes

- **A project can put its takes in folders.** A folder has a name, holds takes,
  and appears under `Takes` in the material tree with its takes under it.
- **Folders are in the file**, so the arrangement travels with the project and
  is shared like everything else. A new `folders:` block, beside `takes:`.
- **`takes:` does not change.** It stays the flat list of every take the project
  draws on, in project order. A folder *refers* to takes; it does not contain
  them. Nothing that reads `project.takes` — the resolver, the library, the
  vocabulary, sharing — needs to know folders exist.
- **An empty folder is a folder.** Made now, filled later, and it survives a
  save with nothing in it. That is the whole point of being able to make one
  before there is anything to put in it.
- **Made from the context menu**: `New Folder…` on the `Takes` root, and
  `Move to Folder ▸` on a take, with the folders that exist and a `New Folder…`
  at the end of that submenu. Renaming and removing a folder are on the folder's
  own menu; removing one leaves its takes in the project, loose.
- **A take in no folder sits at the top level of `Takes`**, exactly as every take
  does now, so a project that never makes a folder looks and behaves as it does
  today.

## Capabilities

### New Capabilities

- `take-folders`: what a folder is, how it is written in the file, what happens
  to takes when folders are made, renamed and removed, and where it appears in
  the material tree.

### Modified Capabilities

- `material-tree`: the `Takes` root gains a level. Its children are folders and
  loose takes; a folder's children are takes; a take's children are still its
  clips.

## Impact

- **Changed**: `Project` gains `folders`; `ProjectFile` reads a `folders:` block
  and `ProjectWriter` writes one. `Material` grows a `folder` row and a level
  under `Takes`. `MaterialTree` grows the menu items and the moves.
- **Unchanged**: `project.takes`, and therefore every reader of it. The
  resolver, the vocabulary, the library's items, the exporter and sharing all
  see exactly what they see now.
- **File format**: additive. A `folders:` block is a new key; a version without
  it carries it through as an unknown key, which is the rule the format already
  has. A project with no folders writes no block.
- **Risk**: a folder naming a take the project does not list, or a take in two
  folders — both are files somebody can hand-edit into existence. The spec says
  what happens rather than leaving it to whichever loop runs first.
