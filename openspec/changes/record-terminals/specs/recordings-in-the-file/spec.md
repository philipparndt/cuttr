## MODIFIED Requirements

### Requirement: A recording is written down

A project SHALL be able to state what to record in the project file, so that
making the recording again is reading a file rather than remembering what
somebody did.

What is recorded SHALL be either a page or a terminal, said by which keys are
present rather than by a kind:

```
recordings:
  - as:      install-demo
    url:     https://example.com/download
    size:    1280x720      # the recording, chrome and all
    browser: chrome
    chrome:  bar           # or `none` for a bare window

  - as:       the-build
    terminal: ghostty      # or terminal, abydos
    in:       ~/dev/cuttr  # where the shell starts
    run:      [make build]
    size:     1280x720
```

A recording that states both a `url:` and a `terminal:` SHALL be refused by
name rather than one of them being chosen.

#### Scenario: The same recording, a month later
- **WHEN** a project states a recording and somebody records it again after the
  page has changed
- **THEN** the same URL is opened at the same size in the same profile, and the
  only difference in the film is the page

#### Scenario: A terminal recording, written down
- **WHEN** a project states a terminal, a directory and a command
- **THEN** recording it opens that terminal in that directory and runs that
  command

#### Scenario: A recording that is two things at once
- **WHEN** a recording states both a `url:` and a `terminal:`
- **THEN** the file is refused with a sentence naming the recording, rather than
  one of the two being picked

#### Scenario: A project that records nothing
- **WHEN** a project has no `recordings:` block
- **THEN** it reads, writes and renders exactly as it did before this existed,
  byte for byte
