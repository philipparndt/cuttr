## Context

    ┌──────────────────────────────┐
    │  ⦿ ⦿ ⦿                       │   a browser cuttr started, with
    │ ┌──────────────────────────┐ │   its own profile and no bookmarks
    │ │                          │ │
    │ │   the page being shown   │ │   ← ScreenCaptureKit captures
    │ │                          │ │     this window, not the screen
    │ └──────────────────────────┘ │
    └──────────────────────────────┘
                  ↓
       install-demo.mov  +  takes/install-demo.cuttr

Every recording cuttr has ever seen arrived from somewhere else. The take file
is the boundary: `video:`, `audio:`, an offset, and a list of clips. Nothing in
the program knows how a recording was made, and nothing needs to.

What is new here is the other end — making one. The reason to put it in cuttr
rather than leaving it to a screen recorder is not convenience: it is that a
screencast is the one kind of footage where the *subject* can be controlled as
well as the camera. A browser opened by cuttr, at a size cuttr chose, showing a
URL the file names, is repeatable. A browser somebody opened is not.

## Goals / Non-Goals

**Goals:**

- Record one window, at an exact size, with nothing of the person's own browser
  in it.
- Land the result as a take, ready to cut.
- Write the recording down, so it can be made again.
- Say plainly what is missing when the permission or the browser is not there.

**Non-Goals:**

- Not a general screen recorder. No region select, no full-screen capture, no
  webcam, no picture-in-picture.
- Not browser automation. cuttr opens a URL and gets out of the way; it does not
  click, type or drive the page. Somebody is demonstrating something, and a
  demonstration that was scripted is a different feature with a different name.
- Not audio, in this change. A screencast's narration goes on the separate
  recorder, which is what `audio:` and the offset in a take are for, and mixing a
  microphone in here would make one file that cannot be re-aligned.
- Not other applications yet, though nothing here should make them hard.

## Decisions

### `ScreenCaptureKit`, filtered to one window

`SCContentFilter(desktopIndependentWindow:)` captures the window rather than a
rectangle of the display. That is the whole reason to use it over the older
`AVCaptureScreenInput`: what is in the film is what is in the window, so a
notification sliding in over it is not in the take, and a window nudged during a
recording does not walk out of frame.

It also means the pixels are the window's own, at the window's backing scale, so
type stays type instead of becoming a photograph of type.

### The browser is a subprocess with `--user-data-dir`

    Chrome --user-data-dir=<project>/.cuttr/browser/<profile>
           --window-size=1280,720 --app=<url>
           --no-first-run --no-default-browser-check

`--user-data-dir` is the whole of the isolation, and it is a supported flag
rather than a trick: a fresh directory is a fresh browser, with no bookmarks, no
extensions, no history and no account. `--app=` opens without tabs or an address
bar, which is what a screencast of a *page* wants; a recording that wants the
chrome can say so.

Kept inside the project's `.cuttr/` rather than in a shared place, so that a page
needing a cookie accepted or a login done keeps it for that project and does not
leak between them.

**Why not drive the person's browser.** It has their bookmarks in it, and closing
it afterwards would close their tabs. A tool that touches somebody's own browser
session to make a film is a tool nobody runs twice.

### `--window-size` is the content size, and it is checked

Chrome's `--window-size` sets the *content* size, which is the number somebody
means. It is checked rather than trusted: the captured frame's size is compared
against what was asked for, and a mismatch refuses before recording rather than
producing something that has to be cropped — and cropping a screen recording
throws away the resolution that made it readable.

### A recording writes a take, and never overwrites one

The `.mov` lands beside the project and a take file is written for it, so the
recording arrives as material rather than as a file to import. Never overwriting
matters more than it sounds: the reason to record something twice is nearly
always to compare the two, and a second take is how the rest of the program
already says that.

### `recordings:` is a list, not a setting

Written in the project file with the rest of it, so a recording is a thing that
was decided rather than something somebody did once. `as:` names it, which is
also what the take is called — one name, and the material tree already shows it.

### Permission is a first-class state, not an error

TCC screen-recording consent is granted outside the app, cannot be requested
inline, and an unconsented capture yields black frames rather than a failure.
So it is asked about *before* recording, said in one sentence, and the settings
pane is one button away. Black frames written to disk would be the worst possible
answer: a file that looks like a recording and is not.

## Risks / Trade-offs

- **The permission cannot be granted from inside the app**, and on some macOS
  versions it does not take effect until the app restarts. → Detected and said,
  including the restart, rather than discovered as a black film.
- **Chrome's flags are Chrome's**, and could change. → They are the documented,
  long-standing ones, and the size is *verified from the captured frame* rather
  than assumed — so a flag that stops working is caught by the check that already
  has to be there.
- **Recordings are large.** A minute at 1280×720 is tens of megabytes. → Beside
  the project like all footage, gitignored like all footage, and said in the
  panel before the first one is made.
- **`--app=` hides the address bar**, which some screencasts want to show. → A
  key for it, defaulting to the bare window, because the commoner case is a
  recording of a page rather than of a browser.
- **A browser left running** if cuttr dies mid-recording. → The subprocess is
  killed on the way out of every path including the crash handler, and a stray
  profile directory is harmless.
- **Window capture needs the window to be on screen.** A minimised or fully
  occluded window captures nothing useful. → Raised before recording starts, and
  the panel says the window must stay visible.
