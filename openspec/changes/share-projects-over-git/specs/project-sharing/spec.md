## ADDED Requirements

### Requirement: A single Share action

The system SHALL offer one action, **Share**, that sends the person's work to
the remote and brings back everyone else's. It SHALL be available from the File
menu and from the document capsule, and SHALL be present only when the project
sits in a git work tree that has a remote named `origin`.

Share SHALL never run by itself. It runs because a person asked for it, and for
no other reason.

#### Scenario: The project is not in a work tree
- **WHEN** the project sits on a footage volume that is not a git work tree
- **THEN** the Share action SHALL be absent rather than present-and-disabled

#### Scenario: The work tree has no remote
- **WHEN** the project is in a work tree with no `origin`
- **THEN** Share SHALL be absent, and the branch menu SHALL be unaffected

#### Scenario: Nothing runs on a timer
- **WHEN** the project is saved, or the editing goes quiet, or the window closes
- **THEN** no fetch, commit to a branch, or push SHALL occur

### Requirement: Only the project's own files are committed

Share SHALL commit exactly the files `ProjectVersions.files()` reports — the
project, every take it names, and those takes' `words:` transcripts and solved
anchor paths. It SHALL build the commit through git plumbing against a temporary
index.

Share MUST NOT stage, commit, revert or otherwise alter any other path, and MUST
NOT disturb anything the person has already staged.

#### Scenario: An unrelated file is dirty
- **WHEN** the person has an unrelated modified file in the work tree
- **AND** Share is pressed
- **THEN** the commit SHALL NOT contain that file
- **AND** the file SHALL still be modified and unstaged afterwards

#### Scenario: The person has staged something
- **WHEN** the person has staged an unrelated change in the index
- **AND** Share is pressed
- **THEN** that change SHALL remain staged and uncommitted afterwards

#### Scenario: The committed files read as clean
- **WHEN** Share has committed the project's files
- **THEN** `git status` SHALL NOT afterwards report those files as modified

### Requirement: Share refuses rather than half-acting

Share SHALL refuse, changing nothing, when the repository is mid-merge, rebase,
cherry-pick or bisect; when a take window is open that holds cuts which would be
written back over incoming changes; or when the remote cannot be reached.

A refusal SHALL name what has to happen before it can be tried again.

#### Scenario: The repository is busy
- **WHEN** a rebase is in progress
- **AND** Share is pressed
- **THEN** nothing SHALL be committed, fetched or pushed
- **AND** the outcome SHALL say a rebase is in progress

#### Scenario: A take window is in the way
- **WHEN** a `TakeDocument` for a take in this project is open
- **AND** incoming changes would rewrite that take's file
- **THEN** Share SHALL refuse and name the windows to close first

#### Scenario: A push is rejected by a race
- **WHEN** another person pushes between this Share's fetch and its push
- **THEN** Share SHALL fetch, integrate and push again, at most three times
- **AND** it MUST NOT use `--force` under any circumstance

### Requirement: A version is kept before anything moves

Share SHALL flush any pending `refs/cuttr/saves` version before it commits, so
the state on disk before the share is always recoverable.

#### Scenario: An edit is still owed a version
- **WHEN** the editing has not yet gone quiet
- **AND** Share is pressed
- **THEN** a version SHALL be kept first
- **AND** that version SHALL contain what was on screen when Share was pressed

### Requirement: The outcome is said in plain words

Share SHALL report what happened in one line, in the words the program uses
elsewhere, naming counts and people rather than git terms. It MUST NOT report
`ahead`, `behind`, `fast-forward`, `rebase`, or a commit hash as its primary
wording.

#### Scenario: There was nothing to send and nothing to get
- **WHEN** the branch and its upstream are identical and nothing local changed
- **THEN** the outcome SHALL say there is nothing to send

#### Scenario: Work went out and came in
- **WHEN** the person's changes are pushed and three of another person's arrive
- **THEN** the outcome SHALL say both, and how many came in

### Requirement: Credentials are diagnosed

Because git runs with `GIT_TERMINAL_PROMPT=0` and can never prompt, Share SHALL
read git's standard error and distinguish an unreachable network, an
unauthenticated remote, and a remote the person cannot push to. Each SHALL be
reported with the one next step, without assuming the reader knows what a
credential helper is.

#### Scenario: An HTTPS remote with no credential helper
- **WHEN** the push fails because git could not authenticate
- **THEN** the outcome SHALL say the person is not signed in to that host
- **AND** it SHALL NOT report the failure as a network problem

#### Scenario: No push rights
- **WHEN** the remote refuses the push for permissions
- **THEN** the outcome SHALL say the person cannot push to that repository
- **AND** the work SHALL remain committed locally

### Requirement: Missing footage is said, not hidden

Share SHALL say when an incoming take names media that is not on this machine,
rather than leaving a project that opens to black. Sharing moves text and not
recordings: the takes are kilobytes and the footage is gigabytes and is not in
the repository.

#### Scenario: A take arrives naming footage this machine has not got
- **WHEN** an incoming take names a video file not present at its path
- **THEN** the outcome SHALL name the missing media
- **AND** the take SHALL still be written to disk
