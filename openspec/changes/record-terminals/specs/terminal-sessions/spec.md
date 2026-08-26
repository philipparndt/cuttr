## ADDED Requirements

### Requirement: A terminal cuttr opened

cuttr SHALL open a terminal of its own for a recording rather than record one the
person is already using, and SHALL close it when the recording stops — including
when the recording fails or the app quits mid-recording.

The terminals cuttr drives SHALL be macOS Terminal, Ghostty and Abydos. cuttr
SHALL name what to install when the one a recording asks for is not there, and
SHALL NOT download or bundle one.

#### Scenario: The person's own terminal is left alone
- **WHEN** a terminal recording is made while the person has Ghostty open with
  their own work in it
- **THEN** a separate window is opened and recorded, and their windows are
  untouched

#### Scenario: A terminal that is not installed
- **WHEN** a recording asks for a terminal this machine does not have
- **THEN** cuttr says which one by name, and nothing is opened or written

### Requirement: What is still the person's

cuttr SHALL start the shell in a named directory, with a prompt of its own and
no scrollback, so that the frame does not open on the last thing the person was
doing.

cuttr SHALL NOT claim more than that. A shell reads the person's own startup
files, and what those put on screen — an alias, a version manager's banner, a
prompt that draws itself — is theirs and stays. The panel SHALL say so once,
rather than letting somebody find out in the finished film.

#### Scenario: The frame opens on nothing
- **WHEN** a terminal recording starts
- **THEN** the window shows one prompt in the directory the recording named, with
  nothing above it

#### Scenario: What cuttr cannot promise is said
- **WHEN** somebody is about to make their first terminal recording
- **THEN** cuttr says that the shell's own startup files still run, so a banner
  or a custom prompt will be in the film

### Requirement: Commands are run, not typed

A recording SHALL be able to state commands to run when the terminal opens, so
that a screencast can begin with the state it is about rather than with somebody
typing their way to it.

Commands stated in the file SHALL run in the order they are written.

#### Scenario: Starting where the demonstration starts
- **WHEN** a recording states `run: [make build]`
- **THEN** the terminal opens and runs it, and the recording is of what happened
  next

#### Scenario: Nothing to run
- **WHEN** a recording states no commands
- **THEN** the terminal opens at a prompt and waits

### Requirement: A terminal is sized in pixels

A recording SHALL produce a picture of the size it asks for, whatever the
terminal's own idea of a size is — a terminal is sized in columns and rows, and
how wide a column is depends on the font.

cuttr SHALL ask, measure what it got, and ask again with the difference applied,
and SHALL refuse rather than approximate when the size cannot be had.

#### Scenario: The frame is the size that was asked for
- **WHEN** a terminal recording asks for 1280×720
- **THEN** the recording is 1280×720, whatever font the terminal is set to

#### Scenario: A size no whole number of cells can make
- **WHEN** the asked-for size cannot be reached because a column is 8 points wide
  and the difference is 3
- **THEN** cuttr says both sizes rather than recording something that has to be
  cropped
