## ADDED Requirements

### Requirement: Takes and projects merge by slug, not by line

The system SHALL merge `.cuttr` and `.cuttrproj` files three-way — base, mine,
theirs — by decoding all three through the existing readers and merging clip by
clip, keyed by slug. It MUST NOT rely on git's line merge for these files.

The merge SHALL produce a `Take` or `Project` value, never text. Only
`TakeWriter` and `ProjectWriter` write the result, so a merged file is
byte-identical to one somebody saved by hand.

#### Scenario: Two people change different clips
- **WHEN** one person changes the `intro` clip and another changes `wrap-up`
- **THEN** both changes SHALL be present in the merged take
- **AND** nobody SHALL be asked anything

#### Scenario: Two people change clips adjacent in the file
- **WHEN** two clips written on neighbouring lines are each changed by one person
- **THEN** the merge SHALL succeed, because adjacency is not a conflict

#### Scenario: One side adds a clip
- **WHEN** one person adds a clip and the other does not touch it
- **THEN** the added clip SHALL be in the result

#### Scenario: One side removes a clip
- **WHEN** one person removes a clip and the other does not change it
- **THEN** the clip SHALL be absent from the result

#### Scenario: Both sides make the same change
- **WHEN** both people change a clip's `end` to the same value
- **THEN** the merge SHALL succeed with that value and report no conflict

### Requirement: A conflict marker never reaches a take file

The system MUST NOT write git conflict markers into a `.cuttr` or `.cuttrproj`
file at any point, including transiently. A file carrying markers does not
parse, and a person opening one would see a broken project.

#### Scenario: A conflict is unresolved
- **WHEN** two people changed the same clip differently
- **AND** the person has not yet chosen between them
- **THEN** the file on disk SHALL remain the person's own version, unmarked
- **AND** the incoming version SHALL be held out of the file until chosen

### Requirement: Unknown keys are carried through from both sides

The merge SHALL preserve unknown keys from both sides, and an unknown key
present on one side only SHALL be kept. This is the file format's own rule: a
file written by a later version must survive being opened and saved by an older
one.

#### Scenario: A newer version's key is on one side
- **WHEN** their take carries a key this build does not know
- **AND** the person's take does not
- **THEN** the merged file SHALL still carry that key

#### Scenario: Unknown keys on both sides
- **WHEN** each side carries a different unknown key at the take level
- **THEN** both keys SHALL be present in the result

#### Scenario: A clip's unknown keys are outside what this can promise
- **WHEN** a clip carries a key this build does not know
- **THEN** the merge SHALL NOT be the thing that loses it

Note: `TakeReader` keeps leftover keys only at the take's root — a clip's
mapping is read key by key and the remainder discarded — so a clip-level key
from a later version is already lost on read, before any merge sees it. Closing
that is a change to the reader and the emitter, and belongs in its own proposal;
this requirement holds the merge to not making it worse.

### Requirement: Only a same-clip disagreement is a conflict

A conflict SHALL be raised only when both sides changed the same clip, or the
same take-level key, to different values. Everything else merges.

Take-level keys — `video:`, `audio:`, `offset:`, `words:` — SHALL each be merged
on their own rather than as one block.

#### Scenario: One side re-aligns and the other re-cuts
- **WHEN** one person changes `offset:` and another changes a clip's `start`
- **THEN** both SHALL be kept, because the offset is the only thing relating the
  two clocks and it is independent of any cut mark

#### Scenario: Both sides re-align differently
- **WHEN** both people set `offset:` to different values
- **THEN** that SHALL be a conflict and be put to the person

### Requirement: Conflicts are resolved clip by clip, in the app

WHEN a merge conflicts, the system SHALL present each conflicting clip with what
the person did, what the other person did, and a choice between them. The chosen
result SHALL be written through the emitter.

The chooser SHALL identify clips by name and slug, and times as timecode — not
as diff hunks or line numbers.

#### Scenario: One clip conflicts
- **WHEN** two people trimmed the `demo-install` clip differently
- **THEN** the person SHALL be shown both versions of that clip
- **AND** choosing one SHALL write a file containing that version and every
  non-conflicting change from both sides

#### Scenario: Several clips conflict
- **WHEN** three clips conflict
- **THEN** each SHALL be resolved on its own
- **AND** nothing SHALL be written until all three are answered

#### Scenario: The person dismisses the chooser
- **WHEN** the person closes the chooser without answering
- **THEN** no file SHALL be written
- **AND** the work tree SHALL be exactly as it was before Share was pressed

### Requirement: A merged file re-saves unchanged

Re-saving a merged take without editing it SHALL produce an identical file, the
same guarantee `writingIsStableForTheSameTake` makes for every other take. This
follows from the merge returning a value and only the emitter writing.

#### Scenario: Re-saving after a merge
- **WHEN** a merged take is written and then saved again untouched
- **THEN** the two files SHALL be byte-identical

### Requirement: Manual slugs are a fact about the session, not the take

`TakeDocument.manualSlugs` is not in the file and SHALL NOT take part in the
merge. A slug in a merged file SHALL be whatever the file says it is.

#### Scenario: A merge arrives while a slug was typed by hand
- **WHEN** the person has typed a slug for a clip in this session
- **AND** a merge brings in a change to that clip's name
- **THEN** the typed slug SHALL still not be derived from the new name
