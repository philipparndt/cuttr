# Screencasts — recording the browser

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

**No browser.** cuttr drives Google Chrome, Chromium or Microsoft Edge, in that
order, and installs none of them. A browser is a thing the machine has or has not
got.

## What it costs

About 40 MB a minute at 1280×720. Recordings land beside the project like all
footage and are gitignored like all footage.
