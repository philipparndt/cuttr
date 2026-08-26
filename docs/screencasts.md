# Screencasts — recording a browser or a terminal

Everything else cuttr does begins with a recording it did not make. A screencast
is the exception, and the reason to make it here rather than with a screen
recorder is not convenience: it is that a screencast is the one kind of footage
where the *subject* can be controlled as well as the camera. A browser cuttr
opened, at a size you chose, showing a URL the file names, is repeatable. A
browser you opened is not.

**File → Record Screencast…** (⇧⌘R). Type a URL, press Record, do the thing,
press Stop. What lands beside the project is a `.mov` and a take file for it, so
the recording is in the material tree without importing anything.

## What is in the frame

A browser cuttr started, with a profile of its own inside the project's
`.cuttr/browser/`. That directory is the whole of the isolation, and it is why
the recording has none of your bookmarks, extensions, history, signed-in accounts
or notifications in it. Your own browser is not touched, restarted or closed —
whether or not it is running.

The profile is kept between recordings of the same project, so a page that needed
a cookie accepted or a login done once does not need it again next month.

**The address bar is in the film.** A screencast is somebody being shown how to
do a thing, and where you are is half of that — "go to the downloads page" is a
sentence about an address bar. The fresh profile is what makes that affordable:
what is above the page is back, forward, reload and the URL, with no bookmarks
bar, extension buttons or account avatar. Set `chrome: none` for a bare window,
for the films that are about the page rather than the browser.

Which also means **the URL is readable in the finished piece**. A demonstration
against `localhost:3000`, or a staging host with somebody's name in it, is in the
film. The panel says so where the URL is typed.

## What is not in the frame

The window is captured, not a rectangle of the screen. So a notification sliding
over it is not in the recording, and a window nudged half way through does not
walk out of frame. It does have to stay *visible* — a window that is minimised or
entirely behind another one has nothing to capture.

Nothing else on your screen is recorded. That is worth saying twice, because the
permission macOS asks for is called Screen Recording and sounds much broader than
what happens.

## Terminals

Half of what anybody demonstrates on a Mac happens in a terminal. cuttr drives
three: **Terminal**, **Ghostty** and **Abydos**. It opens one of its own, starts
the shell where you tell it to, runs what you ask, and closes it afterwards.

```
recordings:
  - as:       the-build
    terminal: ghostty      # or terminal, abydos
    in:       ~/dev/cuttr  # where the shell starts
    run:      [make build, make test]
    theme:    midnight     # the palette to record in
    size:     1280x720
```

`run:` runs when the window opens, in the order written, and the shell stays
afterwards — a terminal that exits the moment the command finishes is a recording
that ends before anybody has read the output.

`theme:` is worth setting for the same reason the browser gets a fresh profile: a
screencast made on a laptop set to a light theme and one made on a desktop set to
a dark one are two different films of the same thing. Ghostty and Abydos take a
theme name; Terminal takes one of its settings sets.

### What is still yours

This is the one place cuttr cannot do for a terminal what it does for a browser.
A browser gets a profile directory of its own and the frame is genuinely cuttr's.
A shell has no such thing: **your own startup files still run**, so an alias, a
version manager's banner or a prompt that draws itself will be in the film.

What cuttr does do: starts in the directory you name, sets a plain `$ ` prompt,
and opens a window with no scrollback — so the frame does not open on the last
thing you were doing. What it will not do is start a shell without your setup,
because that is not the shell you use, and a screencast of a shell nobody has is
a lie in the other direction.

The panel says this before the first recording rather than leaving you to find it
in the finished piece.

### Terminal costs a second permission

Driving Terminal means AppleScript, which macOS gates behind its own consent — a
different dialogue, about a different application, at a different moment from the
screen recording one. It is asked for only when a recording actually names
Terminal; if you record in Ghostty or Abydos you are never asked.

Terminal is supported anyway, because it is the one every Mac has and the one a
viewer is most likely to recognise.

### Sizes

A terminal is sized in columns and rows, and how wide a column is depends on the
font it is set to. You still say pixels: cuttr asks for a number of cells,
measures the window it got, and asks again with the difference — so nothing you
type has to know anything about fonts. It refuses rather than approximating if it
cannot land on the size.

## No sound

A screencast records no audio, and that is deliberate. Narration goes on the
separate recorder — which is what `audio:` and the offset in a take are for — so
that the two can be re-aligned afterwards. One mixed file cannot be.

## Writing it down

```
recordings:
  - as:      install-demo
    url:     https://example.com/download
    size:    1280x720      # the recording, chrome and all
    browser: chrome        # or chromium, edge — omit for whichever is installed
    chrome:  bar           # or `none` for a bare window
```

`size:` is the size of the **recording**: the window as captured, chrome and all,
which is what lands in the take and has to fit the output's frame. Not the page's
size, which is that minus whatever the chrome costs. The file that comes out is
that size at the display's resolution, so a 1280×720 recording on a Retina screen
is a 2560×1440 file — the window's own pixels, not an enlargement of them.

`as:` names the recording *and* the take it writes. Recording the same thing
twice never overwrites the first: the second is `install-demo-2`, because the
reason to record something again is nearly always to compare the two.

## The two things that go wrong

**The permission.** Screen recording is granted in System Settings → Privacy &
Security → Screen Recording, outside the app, and cuttr cannot ask for it inline.
An app that does not have it is not refused — it is handed a picture of an empty
desktop and writes a film of nothing — so cuttr checks before opening anything
and says what is missing. If you grant it while cuttr is running, quit and open
it again: macOS decides what a process may do when it launches.

**Nothing to record with.** cuttr drives Google Chrome, Chromium or Microsoft Edge, in that
order, and installs none of them — nor any of the three terminals. A browser is a
thing the machine has or has not got.

## What it costs

Under 15 MB a minute at 1280×720, and usually far less. Recordings land beside
the project like all footage and are gitignored like all footage.

A screen recording is not footage and compresses nothing like it: flat colour,
hard edges, and long stretches where nothing moves at all. Three things follow
from that, and together they matter more than any single setting.

**HEVC, always.** h.264 spends its bit-rate worst on exactly what a screencast is
made of, and shows it as rings around type.

**Frames that are the same are not written.** A capture hands out a frame whether
or not anything changed and marks the ones that are not new; those are dropped
where they arrive. A page somebody is reading costs nothing per second.

**Keyframes every four seconds, not every one.** A keyframe is a whole picture
and a screencast is mostly one picture, so they are the largest single thing in
the file — and four seconds is still close enough to scrub without decoding half
the recording.

The bit-rate itself is a twelfth of a bit per pixel per frame, which is what text
at rest costs, and it is a ceiling rather than a target.
