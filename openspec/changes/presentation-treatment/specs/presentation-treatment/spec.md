## ADDED Requirements

### Requirement: A placement can carry presentation treatments

A timeline entry SHALL be able to carry treatments, each written inside the
entry. A treatment SHALL say when in the clip it happens, the rectangle the
picture goes into, how long the picture is held, how long the travel takes, and
which scene plays.

`at:` SHALL be on the clip's own clock, not the programme's, so that the same
recording placed twice is treated only where it was asked for.

#### Scenario: A treatment is read and written back
- **WHEN** an entry carries a treatment and the project is written and read again
- **THEN** the treatment SHALL be unchanged
- **AND** the two files SHALL be byte-identical

#### Scenario: A project with no treatments
- **WHEN** no entry carries one
- **THEN** the written file SHALL contain no `presentations:` block
- **AND** the project SHALL resolve exactly as it does without this feature

#### Scenario: The same clip placed twice
- **WHEN** a clip is placed twice and only one placement carries a treatment
- **THEN** only that placement SHALL be treated

### Requirement: The hold stretches the programme

A held picture SHALL stop where it stopped and resume from the same frame.
Nothing of the recording SHALL be skipped, and everything after the hold SHALL
move later by the length of the hold.

A resolved clip's duration SHALL therefore be its own length plus its holds.

#### Scenario: A clip with one hold
- **WHEN** a clip ten seconds long carries a six-second hold
- **THEN** it SHALL occupy sixteen seconds of programme
- **AND** the clip after it SHALL begin six seconds later than it would have

#### Scenario: Nothing is lost
- **WHEN** the hold ends
- **THEN** the picture SHALL continue from the frame it stopped on

#### Scenario: A clip with no holds
- **WHEN** a clip carries no treatment
- **THEN** its duration SHALL be exactly its own length

### Requirement: Programme time and take time are converted in one place

`takeTime(forProgramme:)` and `programmeTime(forTake:)` SHALL account for holds,
and SHALL remain inverse to one another everywhere outside a hold. Within a
hold, take time SHALL stand still.

No other code SHALL do this arithmetic itself.

#### Scenario: Converting across a hold
- **WHEN** a programme time after a hold is converted to take time and back
- **THEN** the result SHALL be the programme time it started from

#### Scenario: Inside a hold
- **WHEN** two different programme times inside one hold are converted
- **THEN** both SHALL give the take time the hold began at

#### Scenario: A tracked face during a hold
- **WHEN** an anchor is solved over a clip that is held
- **THEN** its position during the hold SHALL be the position at the moment the
  picture stopped, and SHALL not advance

### Requirement: The picture travels into a rectangle and back

The picture SHALL move from the whole frame into the rectangle over the ramp,
stay there for the hold, and travel back over the ramp. The travel SHALL be
eased at both ends.

The picture SHALL keep its shape: a rectangle of a different aspect SHALL fit
the picture inside it rather than stretch it.

#### Scenario: Into a small rectangle on the left
- **WHEN** the rectangle is the left of the frame at four tenths
- **THEN** at the end of the ramp the picture SHALL be drawn inside it

#### Scenario: Coming back
- **WHEN** the hold ends
- **THEN** the picture SHALL return to the whole frame over the ramp

#### Scenario: A rectangle of the wrong shape
- **WHEN** a 16:9 picture is given a square rectangle
- **THEN** the picture SHALL be fitted inside it, unstretched

#### Scenario: No ramp
- **WHEN** the ramp is nought
- **THEN** the picture SHALL be in the rectangle for the whole of the hold

### Requirement: The scene plays while the picture is held

The named scene SHALL play over the whole frame for the length of the hold, and
SHALL be resolved the way every other named scene is — a scene the project
defines under that name SHALL win over a built-in one.

#### Scenario: A scene runs for the hold
- **WHEN** a treatment holds for six seconds
- **THEN** its scene SHALL be on screen for those six seconds

#### Scenario: A project defines its own
- **WHEN** the project defines a scene named `bullets`
- **THEN** that scene SHALL be used rather than the built-in one

#### Scenario: A scene that does not exist
- **WHEN** a treatment names a scene nothing defines
- **THEN** the project SHALL say so rather than rendering an empty hold
