## 1. The model

- [x] 1.1 Add `Project.Folder` — a name and a list of take paths — and
      `Project.folders`, in file order.
- [x] 1.2 `ProjectFile` reads a `folders:` block; a folder with no takes reads
      as an empty one rather than being dropped.
- [x] 1.3 `ProjectWriter` writes it, in the order the file had it, and writes
      nothing when there are none.
- [x] 1.4 Test: round-trips byte for byte; an empty folder survives; a project
      with none writes no block; a folder naming a take the project does not
      list is ignored; a take named twice belongs to the first folder.

## 2. Editing the arrangement

- [x] 2.1 `Project.addFolder(_:)`, `renameFolder(_:to:)`, `removeFolder(_:)` —
      removing leaves the takes in `takes:`, loose.
- [x] 2.2 `Project.move(take:toFolder:)`, with `nil` meaning out of any folder,
      taking it out of whichever folder had it.
- [x] 2.3 Removing a take from the project takes it out of its folder too.
- [x] 2.4 Test each, including moving between folders and out.

## 3. The tree

- [x] 3.1 `Material.Row.folder(name:takes:)`, and a level under `Takes`:
      folders first, then loose takes.
- [x] 3.2 A folder's children are its takes; a take's children are still its
      clips; an empty folder is still shown.
- [x] 3.3 Search reaches through a folder, and a match opens its folder as well
      as its take.
- [x] 3.4 Test the shape: with folders, without, empty ones, and a search that
      has to open two levels.

## 4. The menus

- [x] 4.1 `New Folder…` on the `Takes` root and on a folder.
- [x] 4.2 `Move to Folder ▸` on a take: every folder, `Out of the Folder` when
      it is in one, and `New Folder…` at the end.
- [x] 4.3 `Rename…` and `Remove Folder` on a folder.
- [x] 4.4 A sheet or field for the name — a folder made from a menu has to be
      called something.
- [ ] 4.5 Test that each menu offers what it should on each kind of row.

## 5. Finishing

- [x] 5.1 Dragging a folder lays down every clip of every take it holds, in
      order — the same rule a take already follows.
- [ ] 5.2 `make test` clean, including the real-decode test.
