## ADDED Requirements

### Requirement: One tree with four roots

The material panel SHALL be a single outline with four root rows — `Takes`,
`Scenes`, `Anchors` and `Tags` — each of which folds. It SHALL replace both the
takes table and the library, and the split between them SHALL be removed.

A root with nothing under it SHALL still be shown, so that the shape of the
panel does not change with the contents of the project.

#### Scenario: The four roots are there
- **WHEN** a project is open
- **THEN** the tree SHALL show exactly the roots `Takes`, `Scenes`, `Anchors`
  and `Tags`, in that order

#### Scenario: A project with no scenes
- **WHEN** the project defines no scenes
- **THEN** the `Scenes` root SHALL still be shown, with nothing under it

#### Scenario: A root folds
- **WHEN** the `Anchors` root is collapsed
- **THEN** its rows SHALL not be shown
- **AND** the other roots SHALL be unaffected

### Requirement: A take's clips are its children

Each take the project lists SHALL appear under `Takes`, in the order the project
lists them, with the clips cut from it as its children. A clip SHALL have no
children of its own.

A take row SHALL say how many clips it holds and, when its file cannot be read,
SHALL say so on the row.

#### Scenario: Opening a take shows its clips
- **WHEN** the take `Mia 1` holds the clips `intro` and `demo-install`
- **AND** its row is expanded
- **THEN** those two clips SHALL be its children

#### Scenario: Takes are in the project's order
- **WHEN** the project lists `Leni` before `Mia 1`
- **THEN** the tree SHALL show `Leni` before `Mia 1`, whatever their names sort as

#### Scenario: A take whose file has gone
- **WHEN** a take's file is not where the project says it is
- **THEN** its row SHALL say so
- **AND** the row SHALL still be listed rather than dropped

#### Scenario: A clip has nothing under it
- **WHEN** a clip row is shown
- **THEN** it SHALL not be expandable, and its tags SHALL be shown on the row

### Requirement: Tags are a root, not children of a take

Tags SHALL be listed under the `Tags` root, each once, with the number of clips
carrying it. A tag SHALL NOT be listed under any take.

A tag names clips across every take that has one, so filing it under a single
take would be filing it under an arbitrary one of several.

#### Scenario: A tag carried by clips in two takes
- **WHEN** `#b-roll` is on two clips in `Mia 1` and one in `Leni`
- **THEN** the `Tags` root SHALL list `b-roll` exactly once, counting 3
- **AND** neither take SHALL list it among its children

### Requirement: Dragging material onto the programme

A clip row SHALL drag as the reference it is. A tag, an anchor and a scene row
SHALL each drag as the reference a project file uses to mean it.

A take row SHALL drag as every clip it holds, in take order, as one drop.

#### Scenario: A clip is dragged
- **WHEN** a clip row is dragged onto the programme
- **THEN** the reference put down SHALL be the one a project file uses for that
  clip

#### Scenario: A take is dragged
- **WHEN** a take holding three clips is dragged onto the programme
- **THEN** all three SHALL be put down, in the order the take holds them

#### Scenario: A root is dragged
- **WHEN** a root row is dragged
- **THEN** nothing SHALL be put down — a heading is not material

### Requirement: One search over the whole tree

A search field SHALL sit above the tree and match every kind of row: a take by
name, a clip by name or slug or tag, and a scene, an anchor and a tag by name.

A row that matches SHALL be shown with its parents, expanded, so that a clip is
never shown without the take it came from. A take that matches SHALL show all
its clips.

#### Scenario: A clip is found inside a folded take
- **WHEN** the take holding `demo-install` is collapsed
- **AND** the search matches `demo-install`
- **THEN** that take SHALL be shown, expanded, with the matching clip under it

#### Scenario: A take is found
- **WHEN** the search matches a take's name
- **THEN** that take SHALL be shown with all of its clips

#### Scenario: Nothing matches
- **WHEN** the search matches nothing
- **THEN** the roots SHALL still be shown, holding nothing

#### Scenario: The search is cleared
- **WHEN** the search field is emptied
- **THEN** the tree SHALL return to what was folded before the search

### Requirement: Find a meme stays above the tree

The `Find a meme` control SHALL remain above the tree, beside the search field,
and SHALL keep the behaviour it has now.

#### Scenario: It is where it was
- **WHEN** the material panel is shown
- **THEN** `Find a meme` SHALL be above the tree, beside the search

### Requirement: Add and New at the foot and on the rows

`Add` and `New` SHALL be buttons at the foot of the tree, keeping the menus they
have now. The same verbs SHALL also be in the context menu of the root or row
they belong to.

#### Scenario: The buttons are under the tree
- **WHEN** the material panel is shown
- **THEN** `Add` and `New` SHALL be below the tree

#### Scenario: Right-clicking the Takes root
- **WHEN** the `Takes` root is right-clicked
- **THEN** the menu SHALL offer adding an existing take and making a new one

#### Scenario: Right-clicking the Scenes root
- **WHEN** the `Scenes` root is right-clicked
- **THEN** the menu SHALL offer bringing in a scene and making a new one

### Requirement: Every behaviour of both panes is kept

The tree SHALL keep every action the takes table and the library have: opening a
take, opening one in a window of its own with ⌥, renaming a take in place,
removing a take, opening a scene, removing a scene, inserting a reference onto
the programme, and opening a clip in the take it was cut from.

#### Scenario: Opening a take
- **WHEN** a take row is double-clicked
- **THEN** that take SHALL open where the project was

#### Scenario: Opening a take beside the project
- **WHEN** a take row is double-clicked with ⌥ held
- **THEN** that take SHALL open in a window of its own

#### Scenario: Renaming a take
- **WHEN** a take row's name is edited
- **THEN** the take's file SHALL be renamed to match, as it is now

#### Scenario: Opening a clip in its take
- **WHEN** a clip row is asked to be opened in its take
- **THEN** the take SHALL open at the moment that clip starts

#### Scenario: A scene is not material
- **WHEN** a scene row is double-clicked
- **THEN** it SHALL open in the scene editor rather than being put on the
  programme

### Requirement: What is open is remembered, and takes start closed

Roots SHALL start expanded and takes SHALL start collapsed, so that the first
thing shown is the list of takes. Which rows are open SHALL be remembered for
the session.

#### Scenario: A project with forty takes
- **WHEN** a project with forty takes is opened
- **THEN** the `Takes` root SHALL be expanded
- **AND** each take SHALL be collapsed

#### Scenario: Coming back to the panel
- **WHEN** a take is expanded, and the panel is left and returned to
- **THEN** that take SHALL still be expanded
