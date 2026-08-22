## ADDED Requirements

### Requirement: A project can gather its takes into folders

A project SHALL be able to hold named folders, each referring to takes the
project lists. A folder SHALL have a name and a list of take paths, and the
order of the folders SHALL be the order the file has them in.

`takes:` SHALL be unchanged: the flat list of every take the project draws on.
A folder refers to takes; it does not contain them.

#### Scenario: A project with two folders
- **WHEN** a project lists three takes and gathers two of them under
  `Interviews` and none under `B-roll`
- **THEN** it SHALL hold two folders in that order
- **AND** `takes:` SHALL still list all three

#### Scenario: A take in no folder
- **WHEN** a take is in the project and named by no folder
- **THEN** it SHALL be loose, and SHALL still be in `takes:`

### Requirement: An empty folder survives a save

A folder with no takes SHALL be written to the file and SHALL be read back. It
MUST NOT be dropped for being empty.

Making a folder before there is anything to put in it is the reason to be able
to make one at all.

#### Scenario: A folder made and not yet filled
- **WHEN** a folder with no takes is written and the file is read again
- **THEN** that folder SHALL still be there, still empty

### Requirement: `takes:` is the authority

A folder naming a take the project does not list SHALL be ignored for that take.
A take listed in more than one folder SHALL belong to the first folder that
names it, in file order.

Neither SHALL be an error: both are what a hand-edited file or a half-finished
merge looks like, and a project must open.

#### Scenario: A folder names a take that is not in the project
- **WHEN** a folder names `takes/gone.cuttr` and `takes:` does not
- **THEN** the project SHALL still read
- **AND** nothing SHALL be shown for that path

#### Scenario: A take named by two folders
- **WHEN** two folders both name `takes/mia-1.cuttr`
- **THEN** that take SHALL appear under the first of them only

### Requirement: Folders round-trip without churn

Reading a project and writing it again SHALL produce an identical file, folders
included — the guarantee the emitter makes for everything else.

A project with no folders SHALL write no `folders:` block.

#### Scenario: Re-saving a project with folders
- **WHEN** a project with folders is read and written again untouched
- **THEN** the two files SHALL be byte-identical

#### Scenario: A project that has never made one
- **WHEN** a project with no folders is written
- **THEN** the text SHALL contain no `folders:` block

### Requirement: Making, renaming and removing a folder

The system SHALL offer making a folder, renaming one, and removing one.

Removing a folder SHALL leave its takes in the project, loose. Removing a *take*
from the project SHALL also take it out of whichever folder named it.

#### Scenario: A folder is removed
- **WHEN** a folder holding two takes is removed
- **THEN** the folder SHALL be gone
- **AND** both takes SHALL still be in `takes:`, and loose

#### Scenario: A take is removed from the project
- **WHEN** a take that is in a folder is removed from the project
- **THEN** it SHALL be out of `takes:` and out of that folder

#### Scenario: A folder is renamed
- **WHEN** a folder is renamed
- **THEN** it SHALL keep its takes and its place in the order

### Requirement: A take is moved into a folder, or out of one

Moving a take into a folder SHALL take it out of any folder it was in. Moving it
out SHALL leave it loose.

#### Scenario: Moving a take between folders
- **WHEN** a take in `Interviews` is moved to `B-roll`
- **THEN** it SHALL be in `B-roll` and not in `Interviews`

#### Scenario: Moving a take out
- **WHEN** a take in a folder is moved out of it
- **THEN** it SHALL be loose, and still in the project
