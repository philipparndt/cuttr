## Why

cuttr can record a browser. Half of what anybody demonstrates on a Mac happens
in a terminal — a build, a deploy, an agent working, a tool being installed — and
none of it can be recorded yet.

A terminal is also the case where recording somebody's own application is
*worst*. A browser's bookmarks bar is embarrassing; a terminal's prompt has your
username, your hostname and the path to whatever you were doing before in it,
and your scrollback above that. The isolation `--user-data-dir` buys for a
browser has no exact equivalent, which is the whole difficulty of this change and
the reason it is worth writing down before it is built.

## What Changes

- **A recording can name a terminal** instead of a URL: `terminal: ghostty`, a
  directory to start in, and the commands to run.
- **Three of them**: macOS Terminal, Ghostty, and Abydos.
- **Applications are opened through `NSWorkspace`, not `Process`.** Ghostty
  refuses to be launched from the command line on macOS and says so; Terminal is
  driven by AppleScript; Abydos takes arguments. `openApplication` hands back an
  `NSRunningApplication`, which is a thing cuttr can size, find the window of,
  and close — which `open` is not. **BREAKING** to nothing outside this: the
  browser moves to the same mechanism, because one way of starting an
  application is better than two.
- **Sizes are said in pixels and asked for in cells.** A terminal is sized in
  columns and rows, and what a recording needs is a picture of a given size. The
  ask-measure-correct loop the browser already uses does the conversion, so
  nothing has to know how wide a character is.
- **Cleanliness is offered, not promised.** cuttr starts the shell in a named
  directory with a prompt of its own and no scrollback. It cannot rewrite
  somebody's `.zshrc`, and the proposal says which parts of the frame are still
  theirs.

## Capabilities

### New Capabilities
- `terminal-sessions`: a terminal cuttr opens — which one, where it starts, what
  it runs, and what of the person's own setup is still in the frame.

### Modified Capabilities
- `browser-sessions`: the browser is started through the same application
  launcher as the terminals rather than as a subprocess.
- `recordings-in-the-file`: a recording says what it records — a URL or a
  terminal — rather than always a URL.

## Impact

- **New**: a `Sitter` protocol in `CuttrRecord` with four implementations, and a
  `terminal:` block in the project format.
- **Changed**: `Browser` becomes one sitter among four; `Screencast` asks a
  sitter to open, size and close rather than doing it itself.
- **AppleScript**: driving Terminal needs `NSAppleScript` and, on a hardened
  runtime, the automation entitlement plus consent — a *second* permission, of a
  different kind, which is the main cost of supporting Terminal at all.
- **No new dependency.** Ghostty and Abydos are found where they are installed
  or not supported, exactly as the browsers are.
