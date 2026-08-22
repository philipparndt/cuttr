## Context

Two panes, stacked, with a drag handle between them:

    ┌─ material ─────────────┐        ┌─ material ─────────────┐
    │ Take      Clips  Where │        │ ⌕ filter    Find a meme│
    │ Mia 1     19  takes/…  │        │ ▾ Takes                │
    │ Leni      8   takes/…  │        │   ▾ Mia 1              │
    ├──────────── drag ──────┤   →    │       intro            │
    │ ⌕ filter   Find a meme │        │       demo-install     │
    │ ▾ clips                │        │   ▸ Leni               │
    │   intro      Mia 1     │        │ ▸ Scenes               │
    │   demo…      Mia 1     │        │ ▸ Anchors              │
    │ ▾ tags                 │        │ ▸ Tags                 │
    └────────────────────────┘        │        [Add ⌄] [New ⌄] │
                                      └────────────────────────┘

`TakesTable` is takes and scenes; `LibraryView` is clips, tags, anchors and
scenes again. The clip count in the left pane is the number of rows the right
pane would show for that take, and neither pane can show you the other half.

**What already exists and is not being rebuilt.** `ComposeDocument.Vocabulary`
carries `items` (every clip with its take, start, length, tags), `takeNames` in
project order, `anchorTakes`, `scenes` and `tags`. `MenuOutline` — the class the
programme tree uses — already has the right-click hook, the click that puts the
keyboard in the list, the paging keys that move the selection, and `MarkedRow`'s
selection drawing. The tree is a new *view*, not a new model and not a new
outline.

## Goals / Non-Goals

**Goals:**

- One list that answers "what have I got to work with", including the join the
  two panes could not make: which clips came out of which take.
- Give the material column back the vertical space the divider and the two
  floors were spending.
- Keep every behaviour both panes have. Nothing that works today stops working.
- Roots that fold, so somebody who never uses anchors can put them away.

**Non-Goals:**

- No change to any file format, and no change to `Vocabulary`.
- Not a file browser. Takes are the ones the *project* lists; adding one is
  still `Add`, and the tree does not go looking on the disk.
- Not the programme. This is material to draw from; what is drawn is the tree in
  the other pane and stays there.
- No multi-level nesting beyond root → take → clip. A clip has no children.

## Decisions

### Four roots, not three

`Takes`, `Scenes`, `Anchors`, `Tags`.

Tags are a root rather than children of a take because a tag *spans* takes:
`#b-roll` means every clip tagged so, wherever it was cut, and that is what
dragging one puts on the programme. Under a take it would appear once per take
that has it, and dragging any one of them would do the same thing — which is a
list that lies about what its rows mean.

Scenes are a root rather than a peer of takes even though the old takes pane
listed them together. That grouping was right when the pane was "material the
project draws on" and there were two kinds; with four kinds, one kind per root
is the rule, and a scene is not a take.

### Root → take → clip, and no deeper

A clip has no children. Its tags are shown *on* the row, not under it, because a
row that folds to reveal two words is a triangle nobody will press twice.

The take rows are in project order — `Vocabulary.takeNames` — not alphabetical.
The order the project lists its takes in is somebody's arrangement and the file
already keeps it.

### Dragging a take lays down all its clips

In take order, as a single drop. A take is a container, and the argument against
was that dropping nineteen clips by accident is easy — but the same argument
applies to any multi-row drag, undo now exists on a project, and assembling a
first cut by dropping whole takes is the thing somebody actually does first.

The pasteboard carries the same references a multi-clip drag from the old
library carried, so nothing downstream needs to know a take was dragged.

### Search matches every kind, and keeps parents

One field over the whole tree. A take matches by name; a clip by name, slug or
tag; a scene and an anchor and a tag by name.

A match is shown *with its parents*, expanded — a clip found in a folded take
opens that take rather than appearing at the root — and a take that matches
shows all its clips. Anything else is a list that answers a search with rows
whose meaning depends on where they came from.

Alternative considered: filtering to a flat list of matches, as the old library
effectively did within one section. Rejected — in a tree, a row with no parent
visible cannot say which take it is from, which is the one thing the tree was
built to say.

### `Add` and `New` at the foot, and on the rows

Two buttons under the tree, as they are under the takes table now, and the same
two verbs in the context menu of the root or row they belong to: right-clicking
`Takes` offers `Add Take…` and `New Take…`; right-clicking `Scenes` offers the
scene pair. The buttons keep their menus, so nothing that is on them today
disappears.

Rows keep the verbs they have now: open in take, open aside (⌥), rename, remove.

### One view, `MaterialTree`, replacing both

Not a third view beside them, and not `LibraryView` grown a take level. Both
panes are read-only projections of `Vocabulary` plus a handful of callbacks; the
tree is the same, with the callbacks unioned. Keeping either one alive would
leave two things to update when the vocabulary changes shape, which is the fault
being fixed rather than a way to fix it.

## Risks / Trade-offs

- **This is the panel somebody assembles a programme from, and it is being
  replaced rather than edited.** → Every behaviour of both panes is enumerated
  as a requirement with a scenario, and the existing tests for those behaviours
  (`LibraryLookTests`, `TakesListGestureTests`, `OpenInTakeTests`) are ported
  rather than deleted. A behaviour with no test in either suite gets one.
- **A project with forty takes opens to a wall of rows.** → Roots start
  expanded, takes start *collapsed*: the first thing shown is the list of takes,
  which is what the old takes pane showed. Which rows are open is remembered per
  project for the session, the way the programme tree already remembers.
- **The clip count column goes.** It was the one thing the takes pane said that
  the disclosure triangle does not. → It stays on the take row, after the name,
  as it is now.
- **`Where` — the take's path — goes too.** It is the second column of the takes
  pane and there is no room for it on a tree row at this width. → On the row's
  tooltip and in its context menu, where the switcher already puts a path, and
  a take whose file has gone still says so on the row itself, which is the case
  the column was really there for.
- **Two panes could be sized independently; one cannot.** Somebody who wants a
  tall list of takes and a short list of clips loses that. → They fold what they
  are not using, which is the same amount of control in one gesture instead of a
  drag.
