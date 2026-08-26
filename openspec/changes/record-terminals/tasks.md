## 1. One way to open an application

- [x] 1.1 A `Sitter` protocol: find, open, resize, close, and what is still
      theirs.
- [x] 1.2 Move the browser onto `NSWorkspace.openApplication` and make it a
      sitter. Nothing about the recording it makes changes.
- [x] 1.3 `Screencast` asks a sitter rather than knowing what a browser is; the
      order things are refused in does not move.
- [x] 1.4 Test: the browser still builds the command line it built, still lands
      its profile in the project, and is still closed on every path out.

## 2. The terminal in the file

- [x] 2.1 A recording states either a `url:` or a `terminal:`, with `in:` and
      `run:`; both at once is refused by name.
- [x] 2.2 Round-trips byte for byte; a project with none writes no block; a key
      from a later version survives.

## 3. Ghostty

- [x] 3.1 Found, opened with `--window-width`/`--window-height` in cells and
      `-e` for the command, sized by the measure-and-correct loop.
- [x] 3.2 Test the arguments and the cell arithmetic without launching anything.

## 4. Abydos

- [x] 4.1 Found, opened with `--project`, `--open-terminal` and `--run`.
- [x] 4.2 Test the arguments.

## 5. Terminal

- [x] 5.1 Opened and driven by AppleScript: a window, a size in columns and
      rows, a directory, and the commands.
- [x] 5.2 The automation permission, asked for only when a recording names
      Terminal, and said in the panel the way screen recording already is.
- [x] 5.3 Test the script that is built, and the permission's states.

## 6. What is still theirs

- [x] 6.1 A clean start: the named directory, cuttr's own prompt, no scrollback.
- [x] 6.2 The panel says what cuttr cannot clean, per terminal, before the first
      recording rather than after it.
- [x] 6.3 Test that the sentence is there for a terminal and absent for a
      browser.

## 7. Where somebody does it

- [x] 7.1 The panel offers a terminal as well as a URL, and the fields follow
      which it is.
- [x] 7.2 A paragraph in `docs/screencasts.md`, including what is still theirs
      and the second permission.

## 8. Finishing

- [ ] 8.1 `make test`, clean, including the real-decode test.
