## ADDED Requirements

### Requirement: A recording is written down

A project SHALL be able to state what to record — the URL, the size, the browser
— in the project file, so that making the recording again is reading a file
rather than remembering what somebody did.

```
recordings:
  - as:      install-demo
    url:     https://example.com/download
    size:    1280x720      # the recording, chrome and all
    browser: chrome
    chrome:  bar           # or `none` for a bare window
```

#### Scenario: The same recording, a month later
- **WHEN** a project states a recording and somebody records it again after the
  page has changed
- **THEN** the same URL is opened at the same size in the same profile, and the
  only difference in the film is the page

#### Scenario: A project that records nothing
- **WHEN** a project has no `recordings:` block
- **THEN** it reads, writes and renders exactly as it did before this existed,
  byte for byte

### Requirement: Unknown keys are carried through

A `recordings:` block written by a later version SHALL survive being opened and
saved by an older one, on the same terms as every other block in the file.

#### Scenario: A key this version does not know
- **WHEN** a recording states a key this version has never heard of
- **THEN** the key is still there after the file is opened and saved

### Requirement: What comes out is a take

When a recording stops, cuttr SHALL write the media beside the project and a
take file for it, so that a recording arrives as material the rest of the program
already understands rather than as a file somebody has to import.

The take SHALL be named from the recording's `as:`, and SHALL NOT overwrite an
existing take of that name — a second recording of the same thing is a second
take, because comparing the two is the reason to make it again.

#### Scenario: A recording lands as material
- **WHEN** a recording of `install-demo` stops
- **THEN** `install-demo.mov` and `takes/install-demo.cuttr` are beside the
  project, and the take appears in the material tree without anybody importing
  anything

#### Scenario: Recording it a second time
- **WHEN** `install-demo` is recorded again
- **THEN** the first recording is still there, and the second is a take of its own

### Requirement: The clock starts when the picture does

The take SHALL be on the recording's own clock, starting at nought at the first
captured frame — so the time somebody reads off the window while recording is the
time they can cut to afterwards.

#### Scenario: Marking a moment while recording
- **WHEN** something worth cutting to happens twelve seconds into a recording
- **THEN** twelve seconds on the take's clock is that moment
