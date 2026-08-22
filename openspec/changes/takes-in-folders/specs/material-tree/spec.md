## ADDED Requirements

### Requirement: Folders are a level under Takes

The `Takes` root SHALL show the project's folders and its loose takes. A
folder's children SHALL be the takes it holds; a take's children SHALL still be
its clips.

Folders SHALL come before loose takes, so the arrangement reads as an
arrangement rather than as names scattered among names.

#### Scenario: A project with a folder and a loose take
- **WHEN** the project has one folder holding one take, and one take in no
  folder
- **THEN** `Takes` SHALL show the folder first and the loose take after it
- **AND** the folder SHALL hold that take, which SHALL hold its clips

#### Scenario: A project with no folders
- **WHEN** the project has no folders
- **THEN** `Takes` SHALL show its takes exactly as it does now, with no extra
  level

#### Scenario: An empty folder
- **WHEN** a folder holds no takes
- **THEN** it SHALL still be shown, holding nothing

### Requirement: Folders are made and managed from the menu

The context menu of the `Takes` root SHALL offer making a folder. A take's menu
SHALL offer moving it into any folder that exists, out of the one it is in, and
into a new one. A folder's menu SHALL offer renaming and removing it, and making
a folder.

#### Scenario: Making one from the root
- **WHEN** the `Takes` root is right-clicked
- **THEN** the menu SHALL offer making a new folder

#### Scenario: Moving a take
- **WHEN** a take is right-clicked and the project has a folder
- **THEN** the menu SHALL offer moving it into that folder
- **AND** SHALL offer moving it into a new one

#### Scenario: A take already in a folder
- **WHEN** a take that is in a folder is right-clicked
- **THEN** the menu SHALL offer taking it out

#### Scenario: A folder's own menu
- **WHEN** a folder is right-clicked
- **THEN** the menu SHALL offer renaming it and removing it

### Requirement: Searching reaches into folders

A take or clip that matches a search SHALL be shown with its parents, folder
included, so that a match is never shown without the folder it is arranged into.

#### Scenario: A clip found inside a folded folder
- **WHEN** a clip matches, and its take is in a folder, and both are folded
- **THEN** the folder and the take SHALL be shown, expanded, with the clip under
  them
