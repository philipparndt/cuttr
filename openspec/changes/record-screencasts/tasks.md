## 1. The recording in the file

- [x] 1.1 Add `Recording` — `as`, `url`, `size`, `browser`, `chrome` — and
      `Project.recordings`. `size` is the recording's own size, chrome and all.
- [x] 1.2 `ProjectFile` reads a `recordings:` block and carries unknown keys
      through; `ProjectWriter` writes it, and writes nothing when there are none.
- [x] 1.3 Test: round-trips byte for byte, a project with none writes no block,
      and a key from a later version survives.

## 2. Capturing one window

- [x] 2.1 A capture over `SCContentFilter(desktopIndependentWindow:)` that writes
      a `.mov`, starting and stopping cleanly.
- [x] 2.2 The frame size is the window's own at its backing scale, and never
      upscaled.
- [x] 2.3 Stopping finishes the file; quitting mid-recording leaves a whole file
      or none.
- [x] 2.4 Test what can be tested without a screen: the writer's settings, the
      size arithmetic, and that an interrupted write leaves nothing half-made.

## 3. Consent

- [x] 3.1 Ask whether the permission is there *before* opening anything, because
      an unconsented capture writes black frames rather than failing.
- [x] 3.2 Say what is missing in one sentence, with a button to the settings
      pane, and handle the case where it does not take effect until a restart.
- [x] 3.3 Test the states apart from the system: granted, refused, and granted
      but not yet in effect.

## 4. A browser of cuttr's own

- [x] 4.1 Find Chrome, then Chromium, then Edge; refuse by name when there is
      none.
- [x] 4.2 Launch with `--user-data-dir` inside the project, at the URL, with the
      first-run and default-browser prompts off, and with the address bar shown —
      `--app=` only when the recording asks for a bare window.
- [x] 4.3 Size the window so that the *captured picture* is what was asked for,
      whatever the chrome costs, and refuse when it cannot be had.
- [x] 4.4 Wait for the window to exist and be on screen before capture starts,
      and raise it.
- [x] 4.5 Close it on the way out of every path — stopped, failed, or quit.
- [x] 4.6 Test the command line that is built for both kinds of window, the
      browser search order, and that the profile lands inside the project.

## 5. What comes out

- [x] 5.1 The `.mov` lands beside the project; a take is written for it, named
      from `as:`, never overwriting an existing one.
- [x] 5.2 The take's clock starts at nought at the first captured frame.
- [x] 5.3 The new take appears in the material tree without anybody importing it.
- [x] 5.4 Test: a second recording of the same name is a second take, and both
      are still there.

## 6. Where somebody does it

- [x] 6.1 A panel: the URL, the size, the browser, record and stop, and the clock
      while it runs.
- [x] 6.2 The recordings the project already states are listed and can be made
      again with one press.
- [x] 6.3 Say the three things that go wrong before they go wrong: the
      permission, how much disk a minute costs, and that the URL is readable in
      the film.
- [x] 6.4 Test the panel's states without a screen: idle, waiting for consent,
      recording, and stopped.

## 7. Proving it

- [x] 7.1 The example states its recording. **Not** what this task said: the
      fake browser stays. An example in this repository has to render on a
      machine with nothing installed and no permission granted, and a real
      recording needs Chrome, a URL that still exists and somebody at the
      keyboard — so `explainer.cuttrproj` now carries the `recordings:` block
      that would make the footage, and `screencast.cuttrproj` remains the
      stand-in that renders anywhere.
- [x] 7.2 A paragraph in `docs/`: what is recorded, what is not, where the
      profile lives, and that narration goes on the separate recorder.
- [x] 7.3 Entitlements and the notarised build: screen recording, and a first-run
      explanation that survives the sandbox.

## 8. Finishing

- [x] 8.1 `make test`, clean, including the real-decode test.
