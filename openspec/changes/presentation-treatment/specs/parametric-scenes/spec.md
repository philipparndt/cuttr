## ADDED Requirements

### Requirement: Built-in scenes that take snippets

The program SHALL provide scenes named `bullets` and `boxes`, each taking
between two and five text snippets under the names `one:` through `five:`.

Only the snippets given SHALL be drawn: a treatment that gives three SHALL show
three, laid out as though three were all there ever were.

#### Scenario: Three bullets
- **WHEN** a treatment gives `one:`, `two:` and `three:`
- **THEN** three bullets SHALL be drawn, spaced as three

#### Scenario: Five boxes
- **WHEN** a treatment names `boxes` and gives five snippets
- **THEN** five boxes SHALL be drawn

#### Scenario: One snippet
- **WHEN** only `one:` is given
- **THEN** it SHALL still be drawn rather than refused — a single point is a
  thing somebody means

#### Scenario: A gap in the names
- **WHEN** `one:` and `three:` are given and `two:` is not
- **THEN** two snippets SHALL be drawn, with no space left for the missing one

### Requirement: Snippets appear together or one after another

A parametric scene SHALL take `reveal:`, being `together` or `one-by-one`, and
SHALL default to `together`.

`one-by-one` SHALL divide the hold evenly: the first snippet at the start, and
the rest at equal intervals across it.

#### Scenario: Together
- **WHEN** `reveal:` is `together`
- **THEN** every snippet SHALL be on screen from the start of the hold

#### Scenario: One after another
- **WHEN** five snippets are revealed one-by-one over six seconds
- **THEN** they SHALL appear at nought, 1.2, 2.4, 3.6 and 4.8 seconds

#### Scenario: The hold is made longer
- **WHEN** the hold is lengthened
- **THEN** the snippets SHALL re-time themselves across it, with nothing to edit

#### Scenario: Nothing said about revealing
- **WHEN** `reveal:` is not given
- **THEN** the snippets SHALL appear together

### Requirement: They are scenes, not a special case

The built-in scenes SHALL be ordinary scenes: drawn by the compositor that draws
every other scene, and overridable by name.

#### Scenario: Drawn by the same compositor
- **WHEN** a built-in scene is rendered
- **THEN** it SHALL go through the path every named scene goes through
