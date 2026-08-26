## Context

    ┌──────────────────────────────┐
    │ ⦿ ⦿ ⦿  ┌────────────┐        │   a browser cuttr started, with
    │ ┌──────┴────────────┴──────┐ │   its own profile and no bookmarks
    │ │ ← → ⟳  example.com/…     │ │   ← the address bar is in the film,
    │ ├──────────────────────────┤ │     because a screencast that does
    │ │                          │ │     not say where it is is a
    │ │   the page being shown   │ │     screencast of an anonymous box
    │ │                          │ │
    │ └──────────────────────────┘ │   ScreenCaptureKit captures this
    └──────────────────────────────┘   window, not the screen
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
           --window-size=1280,720 --no-first-run
           --no-default-browser-check --hide-crash-restore-bubble
           <url>

`--user-data-dir` is the whole of the isolation, and it is a supported flag
rather than a trick: a fresh directory is a fresh browser, with no bookmarks, no
extensions, no history and no account.

Note what is *not* there: `--app=`. See below.

Kept inside the project's `.cuttr/` rather than in a shared place, so that a page
needing a cookie accepted or a login done keeps it for that project and does not
leak between them.

**Why not drive the person's browser.** It has their bookmarks in it, and closing
it afterwards would close their tabs. A tool that touches somebody's own browser
session to make a film is a tool nobody runs twice.

### The address bar is in the film

`--app=<url>` opens a window with no tab strip and no address bar, and it was the
obvious choice: fewest pixels that are not the page. It is the wrong one.

A screencast is somebody being shown how to do a thing, and *where you are* is
half of that. "Go to the downloads page" is a sentence about an address bar. A
recording that opens on an anonymous white box has to say in words what the
browser was already saying in the frame, and the viewer has no way to follow
along in their own browser. It is also the difference between a film of a web
application and a film of a rectangle: the chrome is what makes it legibly a
browser at all.

The fresh profile is what makes this affordable. An ordinary window here is not
the usual crowded one — no bookmarks bar, no extension buttons, no profile
avatar, no account, one tab — so what is left above the page is the back and
forward buttons, a reload, and the URL. That is the part worth having.

`chrome: none` hides it, for the recordings that are about the page and not
about the browser. The default is on, because the case that wants it is the
commoner one and the one somebody would not think to ask for.

**What is now in the frame that was not before**: the URL. A demonstration
against `localhost:3000`, or a staging host with somebody's name in it, is
readable in the finished film. Said in the panel, once, where the URL is typed.

### `size:` is the size of the recording

The picture that is captured, which is the window — chrome and all — and
therefore the picture that lands in the take and has to fit the output's frame.
Not the page's size, which with the address bar shown is that minus the chrome.

One number, and no ambiguity about which of two things it names. It is checked
rather than trusted: the captured frame's size is compared against what was asked
for, and a mismatch refuses before recording rather than producing something that
has to be cropped — and cropping a screen recording throws away the resolution
that made it readable.

A recording that needs the *page* at an exact size — a layout with breakpoints in
it — is a different number and can be a different key. It is not this one, and
guessing which was meant is how a feature grows a setting nobody can explain.

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
- **The address bar puts the URL in the film.** A localhost port or a staging
  host with somebody's name in it is readable in the finished screencast. → Said
  in the panel where the URL is typed, and `chrome: none` is one word away.
- **The chrome's height is Chrome's**, and it changes between versions — so the
  page gets a slightly different number of pixels on a different machine. That
  is fine for a screencast and fatal for a layout test, which is the second
  reason `size:` names the recording rather than the page.
- **A browser left running** if cuttr dies mid-recording. → The subprocess is
  killed on the way out of every path including the crash handler, and a stray
  profile directory is harmless.
- **Window capture needs the window to be on screen.** A minimised or fully
  occluded window captures nothing useful. → Raised before recording starts, and
  the panel says the window must stay visible.
