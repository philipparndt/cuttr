## Context

cuttr records a browser: found on disk, started as a subprocess with
`--user-data-dir`, sized by asking and measuring, captured as a window, closed
when the recording stops. All of that generalises except the first two steps.

    what cuttr does          browser              terminal
    ─────────────────────────────────────────────────────────────
    find it                  /Applications/…      /Applications/…
    open it                  Process()            ✗ Ghostty refuses
    make it clean            --user-data-dir      ✗ no equivalent
    size it                  --window-size        columns and rows
    find its window          by process id        by process id
    close it                 terminate()          terminate()

Two of those rows are the whole of this change.

## Goals / Non-Goals

**Goals:**

- Record a terminal: Terminal, Ghostty, Abydos.
- Start it somewhere, run something in it, and record what happened.
- One mechanism for opening an application, whichever it is.
- Say plainly which parts of the frame cuttr cannot clean.

**Non-Goals:**

- Not a terminal emulator. cuttr does not draw a shell; it records one.
- Not typing. Commands are run when the terminal opens; a screencast where
  cuttr types is a different feature, and the reason to record a terminal is
  usually to show somebody doing it.
- Not tmux, panes or tabs. One window.
- Not every terminal. Three, named, with a refusal for the rest — iTerm,
  Warp, Alacritty and Kitty each drive differently and each would be a decision
  taken without a reason to take it.

## Decisions

### `NSWorkspace.openApplication`, for all four

Ghostty says it plainly: *"On macOS, launching the terminal emulator from the CLI
is not supported."* An app started by running its binary is not the same thing as
an app launched by the system, and terminals are the case where the difference
shows.

`NSWorkspace.openApplication(at:configuration:)` takes arguments, takes
`createsNewApplicationInstance`, and — the part that matters — hands back an
`NSRunningApplication`. That is a process id to find the window by and a
`terminate()` to close it with, which is what the browser already needs and what
`open` cannot give.

So the browser moves to it too. Two ways of starting an application, one of which
only works for some of them, is one more than is worth keeping.

### A `Sitter` is the thing being recorded

    protocol Sitter {
        static func find(_ named: …) -> Self?
        func open(_ recording: Recording, in project: URL) async throws -> NSRunningApplication
        func resize(to: CGSize, of: NSRunningApplication) async throws
        var whatIsStillTheirs: String? { get }
    }

Four of them: `Chromium` (all three browsers), `Terminal`, `Ghostty`, `Abydos`.
`Screencast` keeps the order things are refused in — consent, then the
application, then the size — and stops knowing what a browser is.

`whatIsStillTheirs` is the honest one, and the reason it is on the protocol
rather than in the panel: only the sitter knows. A browser with a fresh profile
answers nothing; a terminal answers *"your shell's startup files still run"*.

### Cleanliness is offered, not promised

A browser gets `--user-data-dir` and the frame is genuinely cuttr's. A terminal
has no such flag, and the prompt carries the person's username, hostname and
working directory — which is the same problem as the bookmarks bar and worse,
because it is in every frame rather than at the top of the first one.

What cuttr can do, and will:

- **Start in a named directory**, so the prompt does not open on wherever they
  were.
- **Set the prompt** by running the shell with `PS1`/`PROMPT` of its own, which
  works for `sh`, `bash` and `zsh` started non-interactively-then-interactive.
- **No scrollback**, because the window is new.

What it cannot, and says: a login shell reads the person's own startup files, and
an alias, a version manager's banner or a prompt that draws itself will be in the
film. Refusing to run those would mean starting a shell that is not the one they
use, which would make the screencast a lie in the other direction.

### Sizing goes through the loop that already exists

Terminals are sized in columns and rows and cuttr wants pixels, and how wide a
column is depends on a font this program has no business knowing about. The
browser already asks, measures what it got and asks again with the difference
applied — so the terminal sitters express a size in cells, measure the window,
and correct. Two rounds instead of one, and no arithmetic about fonts anywhere.

Ghostty takes `--window-width` and `--window-height` in cells. Terminal takes
`set number of columns` over AppleScript. Abydos takes a window size directly,
which makes it the one that converges in a single round.

### Terminal.app costs a second permission

Driving Terminal means AppleScript, which on a hardened runtime means the
automation entitlement *and* a consent prompt of a different kind from the screen
recording one — a second dialogue, about a different thing, at a different
moment.

Supported anyway, because it is the terminal every Mac has and the one a viewer
is most likely to recognise. But it is asked for only when a recording actually
names Terminal, so somebody who uses Ghostty is never asked at all.

## Risks / Trade-offs

- **A terminal cannot be made as clean as a browser.** → Said, on the panel, per
  sitter, rather than discovered in the finished film.
- **Two permissions for one feature**, if Terminal is chosen. → Only asked for
  when it is chosen, and the other two terminals need nothing.
- **`NSRunningApplication.terminate()` is a request**, and an application with
  unsaved work can refuse it. → A terminal cuttr opened has nothing to save;
  `forceTerminate()` after a grace period for the one that argues.
- **Abydos is one person's application** and its command line may change. → It is
  found or it is not, exactly like the others, and its flags are checked by the
  same measure-and-correct loop that catches a browser's changing.
- **The prompt is set by running a shell with an environment**, which a `.zshrc`
  that sets `PROMPT` unconditionally will overwrite. → That is the case
  `whatIsStillTheirs` exists to say out loud.
