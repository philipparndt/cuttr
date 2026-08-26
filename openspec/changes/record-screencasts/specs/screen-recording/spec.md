## ADDED Requirements

### Requirement: One window, not a region of the screen

cuttr SHALL capture the browser window itself rather than a rectangle of the
display, so that a window moved during a recording is still fully in frame and
anything passing in front of it — a notification, another window, the cursor
leaving — is not.

#### Scenario: Something passes in front
- **WHEN** a notification appears over the window being recorded
- **THEN** it is not in the recording

#### Scenario: The window is moved
- **WHEN** the window is dragged to another part of the screen mid-recording
- **THEN** the recording is unbroken and the frame is still the window

### Requirement: Consent is asked for once and explained

cuttr SHALL ask whether it has the person's consent to record the screen before
it opens anything, because macOS grants that consent outside the app and an
unconsented capture yields black frames rather than a failure. cuttr SHALL
say what is missing in one sentence with a way to the settings pane, and SHALL
NOT record silently to a file that is black.

#### Scenario: The first recording on a machine
- **WHEN** somebody presses record and cuttr has never been granted the
  permission
- **THEN** it says what is missing and where to grant it, and no file is written

#### Scenario: Permission granted while the app is open
- **WHEN** the permission is granted in System Settings and the person comes back
- **THEN** recording works without the app being restarted, or cuttr says
  plainly that a restart is needed

### Requirement: The recording is the window's own pixels

Frames SHALL be captured at the window's backing scale and written at the size
that was asked for, without upscaling. A screencast that has been scaled up is a
screencast that reads as blurred type.

#### Scenario: A Retina display
- **WHEN** a 1280×720 recording is made on a 2× display
- **THEN** the file is 2560×1440, or 1280×720 downscaled from it — never 1280×720
  captured at 1× and enlarged

### Requirement: Stopping writes a whole file

A recording SHALL be a complete, playable file the moment it is stopped, and a
recording interrupted by a crash or a quit SHALL leave either a whole file or no
file — never one that opens and fails part way through.

#### Scenario: Stopped by hand
- **WHEN** the person presses stop
- **THEN** the file plays to the end and its duration is what the clock showed

#### Scenario: The app quits mid-recording
- **WHEN** cuttr is quit while recording
- **THEN** what is on disk is either a whole recording of what happened so far or
  nothing at all
