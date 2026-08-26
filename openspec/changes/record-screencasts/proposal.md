## Why

Everything cuttr does begins with a recording it did not make. For a screencast
that is a poor place to begin: somebody records a browser with a third-party
tool, and what lands in the take is their bookmarks bar, their extensions, a
notification, a window that is 1487 points wide because that is what it happened
to be, and a mouse that spent the first four seconds finding the address bar.
Then it is cropped, and cropping a screen recording throws away the resolution
that made it readable.

The fix is to record it deliberately: a browser that is cuttr's, not theirs, at a
size somebody chose, showing a URL somebody named. Nothing else is in the frame
because nothing else was ever in the window.

`examples/presentation/screencast.cuttrproj` is the evidence. To demonstrate the
presentation treatment — a feature *about* screen recordings — this repository
draws a fake browser out of scene parts, because there was no way to make a real
one that would look the same twice.

## What Changes

- **A recording lives in the project**, as a block that says what to record:
  the URL, the size, whether the browser's own chrome is shown, and which
  profile. It is written down, so the same recording can be made again next
  month with one number changed.
- **cuttr launches its own browser.** A Chrome (or Chromium/Edge) started with
  `--user-data-dir` pointing inside the project's own folder: no bookmarks, no
  extensions, no signed-in account, no notifications, and a window opened at
  exactly the size asked for rather than resized afterwards.
- **The address bar is in the film.** A screencast is somebody being shown how to
  do a thing, and where you are is half of that — "go to the downloads page" is a
  sentence about an address bar. The fresh profile is what makes that affordable:
  what is left above the page is back, forward, reload and the URL, with no
  bookmarks bar, extension buttons or account avatar. `chrome: none` hides it for
  the recordings that are about the page rather than the browser.
- **cuttr records that window**, through `ScreenCaptureKit`, which captures one
  window rather than a region of the screen — so nothing that passes in front of
  it is in the film and the pixels are the window's own.
- **What comes out is a take.** The `.mov` lands beside the project and a
  `.cuttr` take file is written for it, so the recording arrives already cut into
  the format the rest of the program works on.
- **A panel to drive it**: type a URL, choose a size, press record, watch the
  window, press stop. The waiting-for-permission case is part of the feature and
  not an afterthought — screen recording needs consent from System Settings and
  the first run must say so plainly.
- Other applications come later. The browser is first because it is the one
  case where cuttr can also control *what is on screen*, which is what makes a
  screencast repeatable rather than merely recorded.

## Capabilities

### New Capabilities
- `screen-recording`: capturing one window to a file, the permission it needs,
  and what is written when it stops.
- `browser-sessions`: a browser instance that is cuttr's rather than the
  person's — its own profile, its own window, opened at a named size and URL.
- `recordings-in-the-file`: how a recording is written down in the project, so
  that making it again is reading a file rather than remembering what was done.

### Modified Capabilities
<!-- None. A recording produces a take and a take is unchanged; nothing about
     cutting, composing or rendering has a new requirement. -->

## Impact

- **New**: a `CuttrRecord` area for the capture and the browser, a recording
  panel in the app, and a `recordings:` block in the project format.
- **Entitlements and consent**: screen recording is gated by TCC, so the app
  needs the permission and a first-run explanation. The notarised build's
  entitlements change.
- **A dependency on a browser being installed**, discovered rather than bundled:
  Chrome, Chromium and Edge in that order, and a clear refusal naming what to
  install when none is there.
- **Disk**: screen recordings are large. They land beside the project like any
  other footage and are gitignored like any other footage.
- **macOS floor**: `ScreenCaptureKit`'s window capture is macOS 12.3+, and the
  app already requires 14.
