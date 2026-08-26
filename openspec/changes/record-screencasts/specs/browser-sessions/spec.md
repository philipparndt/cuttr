## ADDED Requirements

### Requirement: A browser that is cuttr's, not the person's

cuttr SHALL start the browser with a user-data directory of its own, inside the
project's working folder, so that the recorded window carries none of the
person's bookmarks, extensions, history, signed-in accounts or notifications.

The person's own browser SHALL NOT be reused, restarted or otherwise disturbed,
whether or not it is running at the time.

#### Scenario: Nothing of the person's browser is in the frame
- **WHEN** a recording is started and the person's Chrome is open with a
  bookmarks bar, extensions and a signed-in account
- **THEN** the window cuttr records shows none of them, and the person's own
  windows are left where they were

#### Scenario: The profile is kept, so a second take matches the first
- **WHEN** a recording is made, and another is made from the same project a week
  later
- **THEN** the same profile directory is used, so a page that needed a cookie
  accepted or a login done once does not need it again

### Requirement: A named window at a named size

cuttr SHALL open the browser at a stated URL with the window's *content* at a
stated size, and SHALL refuse rather than approximate when the size cannot be
had — a recording that is 8 points off is a recording that has to be cropped.

#### Scenario: The frame is the size that was asked for
- **WHEN** a recording asks for 1280×720
- **THEN** the captured frames are 1280×720, and not the window's outer size or
  the nearest the window manager felt like

#### Scenario: A size the screen cannot hold
- **WHEN** a recording asks for a window larger than the display
- **THEN** cuttr says so by name before recording, rather than recording a
  window that has been silently shrunk

### Requirement: A browser is found, not bundled

cuttr SHALL look for Chrome, then Chromium, then Edge, and SHALL name what to
install when it finds none. A browser SHALL NOT be downloaded or bundled.

#### Scenario: Nothing to drive
- **WHEN** no supported browser is installed
- **THEN** recording refuses with a sentence naming the browsers it looks for,
  and nothing is written

### Requirement: The browser goes away with the recording

The browser cuttr started SHALL be closed when the recording stops, including
when the recording fails or the app quits mid-recording. A browser left running
with cuttr's profile is a window nobody owns.

#### Scenario: A recording that fails
- **WHEN** capture cannot start, after the browser has been opened
- **THEN** the browser is closed before the refusal is reported
