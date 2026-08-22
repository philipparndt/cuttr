## 1. The rows, before any view

- [ ] 1.1 Add `MaterialTree.Row` in `CuttrUI`: the four roots, a take, a clip, a
      scene, an anchor, a tag. Each says what it drags as, and a root drags as
      nothing.
- [ ] 1.2 Build the rows from `ComposeDocument.Vocabulary` — takes in
      `takeNames` order, clips from `items` grouped by take, anchors from
      `anchorTakes`, scenes and tags from their lists. A pure function from a
      vocabulary to a tree, so it can be checked without a view.
- [ ] 1.3 Test the shape: four roots always, empty roots kept, takes in project
      order, a tag counted once across takes, a clip with no children.

## 2. Searching

- [ ] 2.1 Match a take by name; a clip by name, slug or tag; a scene, anchor and
      tag by name. Reuse `LibraryView`'s existing letters-in-order rule for
      names and its plain-text rule for anything path-like.
- [ ] 2.2 A match keeps its parents and expands them; a matching take shows all
      its clips.
- [ ] 2.3 Test: a clip found inside a folded take opens it; a take that matches
      shows its clips; nothing matching leaves the roots; clearing the field
      puts back what was folded.

## 3. The view

- [ ] 3.1 Add `MaterialTree` on `MenuOutline`, which already carries the
      right-click hook, the click that puts the keyboard in the list, the paging
      keys and `MarkedRow`'s selection.
- [ ] 3.2 Draw the rows: the kind's colour, the name, the clip count on a take,
      a clip's tags on the row, and what went wrong when a take's file has gone.
- [ ] 3.3 The search field and `Find a meme` above; `Add` and `New` below,
      keeping the menus they have.
- [ ] 3.4 Roots expanded, takes collapsed, and what is open remembered for the
      session.

## 4. Dragging

- [ ] 4.1 A clip, tag, anchor and scene drag as the reference a project file
      uses for them.
- [ ] 4.2 A take drags as every clip it holds, in take order, on the same
      pasteboard shape a multi-clip drag already uses.
- [ ] 4.3 A root drags as nothing.
- [ ] 4.4 Test all four, including that dropping a take of three puts three down
      in order.

## 5. The verbs

- [ ] 5.1 Row actions: open a take, open it aside with ⌥, rename in place,
      remove, open a scene, remove a scene, insert a reference, open a clip in
      its take.
- [ ] 5.2 `Add` and `New` in the context menu of the root they belong to, the
      same verbs the buttons carry.
- [ ] 5.3 A take's path on the row's tooltip and in its menu, since the `Where`
      column goes.

## 6. Putting it in the window

- [ ] 6.1 Replace `takesTable` and `library` in `ComposeWindowController` with
      one `MaterialTree`, and union their callbacks.
- [ ] 6.2 Remove the `material` split stack, its divider and both height floors,
      and give the space to the tree.
- [ ] 6.3 Delete `TakesTable.swift` and `LibraryView.swift`.

## 7. Not losing what was tested

- [ ] 7.1 Port `LibraryLookTests`, `TakesListGestureTests` and the library half
      of `OpenInTakeTests` onto the tree rather than deleting them.
- [ ] 7.2 Any behaviour listed in the spec with no test in either old suite gets
      one.
- [ ] 7.3 `make test` clean, including the real-decode test.
