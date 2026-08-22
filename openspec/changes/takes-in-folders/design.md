## Context

`Takes` in the material tree is a flat run of every take the project lists, in
project order. For a shoot of four interviews, a day of b-roll and a pile of
outtakes, that is forty names with nothing to tell them apart but the order
somebody added them in.

The grouping wanted here is not derivable. Interviews are interviews because the
person cutting says so, which means it has to be written down, which means it
has to be in the file — the file is the product, and an arrangement kept only in
a window is an arrangement the next person does not get.

## Goals / Non-Goals

**Goals:**

- Folders that hold takes, named by the person, written in the project file.
- Empty folders: made before there is anything to put in them, and still there
  after a save.
- Made and managed from the context menu, where the pointer already is.
- A project that never makes one looks and behaves exactly as it does now.

**Non-Goals:**

- Not folders on disk. A take's file stays where it is; this is an arrangement
  of the project's own list, not a file manager.
- Not nested folders. One level. A folder of folders is a thing to ask for once
  somebody has wanted it.
- Not a change to `takes:`. Everything downstream reads that list and none of it
  should have to learn about this.
- Not sorting. The order inside a folder is the project's order, as it is now.

## Decisions

### A folder refers to takes; it does not contain them

`takes:` stays exactly what it is — every take the project draws on, flat, in
order. A new block says which of them are gathered where:

    takes:
      - takes/mia-1.cuttr
      - takes/leni.cuttr
      - takes/b-roll-1.cuttr

    folders:
      - name:  Interviews
        takes: [takes/mia-1.cuttr, takes/leni.cuttr]
      - name:  B-roll
        takes: []

The alternative was to nest: make `takes:` a list whose entries are either a
path or a folder holding paths. That reads better in the file and is much worse
everywhere else — `project.takes` is `[String]` and is read by the resolver, the
vocabulary, the exporter, the library and sharing, none of which has any
business knowing about an arrangement in a window. Additive beats tidy here.

The cost is that a path appears twice, and the two can disagree. That is
answered by making `takes:` the authority and `folders:` a view of it: a path in
a folder that the project does not list is ignored, and a take listed in no
folder is loose. Neither is an error, because both are what a hand-edited file
or a half-finished merge looks like.

### A take is in at most one folder

The first folder that names it, in file order. A take named by two folders is
not a state the program can produce; it is a state a text editor can, and the
answer has to be one of them rather than the take appearing twice.

### Empty folders are the point, so they are written

A folder with no takes is written as `takes: []` rather than omitted. It has to
survive a save, or `New Folder…` makes something that is gone as soon as
anything else is written — and the whole reason to make one before filling it is
that you know what is coming.

### Removing a folder does not remove its takes

They go loose, back to the top level of `Takes`. A folder is an arrangement, and
throwing away an arrangement should not throw away the material — especially
when `takes:` is the authority and the folder was only ever a view of it.

Removing a *take* from the project takes it out of `takes:` and out of whichever
folder named it, which is the same act it is now.

### One level

A folder holds takes. A take holds its clips. A folder does not hold a folder.

The tree is already root → take → clip; this makes it root → folder → take →
clip, which is three levels of disclosure and about as much as a panel 260
points wide can carry. Nested folders would be a fourth, and the indentation
alone would eat the names.

## Risks / Trade-offs

- **Two places name the same path.** → `takes:` is the authority; a folder is a
  view of it. Both directions of disagreement are specified rather than left to
  whichever loop runs first, and both are tested.
- **A merge could put a take in two folders**, since `ProjectMerge` merges named
  blocks key by key. → The first folder in file order wins, deterministically,
  so two people merging get the same tree rather than two different ones.
- **The panel gains a level of indentation.** → Only when there are folders. A
  project with none is drawn exactly as it is now, and a loose take sits where
  every take sits today.
- **`ProjectWriter` is hand-written and must stay diff-stable.** → The block is
  written in the order the file had it, like every other named block, and
  `writingIsStableForTheSameProject` covers it.
