# cuttr 0.9.0

Several people can work on one programme now, and none of them has to know git.
Plus the frame on the info page turns up when the project does, and a media file
in the project's own folder is written down as one.

## Share

**Press Share and everybody has everybody's work.** It is on the File menu, on
⌃⌘S, and on the branch half of the capsule at the top of the window. It keeps a
version of where you are, commits the project's own files, fetches, brings in
what arrived, and pushes — then says one line about what happened: *nothing to
send*, *sent your changes*, *brought in 3 changes and sent yours*.

No `ahead`, no `behind`, no `fast-forward`, no commit hashes. Somebody who reads
a diff for a living is using a git client; this is for everybody else.

**Two people cutting two different shots never see each other's changes as a
problem.** That is the part worth explaining. Git merges lines, so two clips
written next to each other in a file collide over nothing at all — and when it
gives up it writes conflict markers into the file, which a `.cuttr` reader
cannot parse, leaving somebody looking at a broken project having done nothing
wrong.

So the merge happens on *values*, keyed by the names the file already uses. A
clip is matched by its slug and a shot by its `as:` label, because those are
what `within:` and `from:` point at — they are already identities. Sections are
merged through, so one person adding a shot to the introduction and another
adding one to the wrap-up is two edits in two places. Take-level keys are merged
one at a time as well: re-aligning the recorder and re-cutting a clip are not
the same edit, and the offset is the only thing relating the two clocks.

**Only a real disagreement reaches anybody.** When two people did change the
same clip, a sheet lists just those — the clip by name, both versions as
timecode, and which to keep:

    ┌──────────────────────────────────────────────────────────┐
    │ One thing was changed on both sides                      │
    │                                                          │
    │ What              Yours                Theirs            │
    │ Intro           ✓ 00:00.000→00:12.000    00:00.000→…14   │
    │ one.cuttr                                                │
    └──────────────────────────────────────────────────────────┘

Nothing is written until every row is answered, and Cancel leaves the folder
exactly as it was — your own cut is what is on the disk. No conflict marker ever
reaches a take file, at any point, including halfway through.

**It shares the cut and not the footage.** A take is kilobytes of text; the
recording it names is gigabytes and is not in the repository. The people you
work with need the media themselves, at the same path relative to the take. When
a take arrives naming a file this Mac has not got, Share says which file rather
than leaving a programme that plays black.

**Your repository stays yours.** Sharing is the one thing in cuttr allowed to
move `HEAD`, and it only ever happens because somebody pressed a button — the
automatic per-pause versions on `refs/cuttr/saves` still touch nothing at all.
It commits exactly the project, its takes and their sidecars, on a temporary
index seeded from `HEAD`: anything else you have staged is still staged
afterwards, and anything dirty is still dirty. There is no force-push and no
argument that constructs one.

**It refuses rather than half-doing.** A merge or rebase already in progress, an
open take window whose in-memory cuts would land back on top of what arrived,
uncommitted work that abandoning a merge could take with it — each one stops and
says what has to happen first. And because cuttr never lets git stop to ask for
a password, an HTTPS remote you have not signed in to says *not signed in to
github.com*, not "could not read Username".

`docs/sharing.md` is the whole of it, written for somebody who has never used
git.

## The frame on the info page

Opening a project onto the info page left an empty rectangle where the picture
should be, and it stayed empty until you switched windows and came back.

The order was the whole of it. Reading a project resolves it and hands it round
every panel, and only *then* starts the task that builds the composition — so
the page asked for the frame at nought at the one moment there was nothing to
cut one out of, got nothing, and kept the blank. Nobody asked again: that form
is rebuilt when the selection or the project changes, and a build finishing is
neither.

Switching windows was never the cure it looked like. What it did was end editing
in whichever field had the keyboard, and a field that commits writes the
project, which resolves, which rebuilds the page — by which time there was a
composition. Which is why the picture appeared a moment later for an unrelated
reason, and why it was blank again next time.

The build now says when there is something to ask for, and the panel asks again
for whatever it went without — only for what is missing, because an edit
rebuilds every time and re-fetching a frame already on screen would decode two
for every one anybody looks at.

## Media files are written down relative

A sound in the project's own `media/` folder was going into the file as
`/Users/somebody/Desktop/…`. That is not untidy, it is broken: the project moves
to another disk or another person and the path names a file that is not there
any more on the only machine that ever had it.

The file panel had always written a relative path. The field beside it had not —
and dragging a file onto a text field puts its absolute path in, as does pasting
one out of the Finder. Two doors into one field wrote two different things and
only one of them travelled.

Anything under the project's folder is now written relative to it, whichever
door it came through. There were four copies of that arithmetic in the program,
identical but for how far each would climb; there is one now.

## Telling two projects apart

**In the switcher**, each path is drawn right-aligned and truncated at the
*head*, so the tail — the half that says which file this is — is the half you
keep. It was running off the side of the panel instead, so it read as a
left-aligned path with the end sliced off, and two projects called the same
thing in two different folders were two identical rows.

A table's default style is the inset source-list look: rows held sixteen points
in from each edge, and the table made thirty-two points wider than the pane to
hold them. Every cell was measuring itself against an edge that was off the side
of the panel. It also held every coloured rail off the leading edge it is
supposed to be flush against, which is now fixed by the same line.

**In the Dock**, press and hold the icon and there is a list of recent projects
with the folder on any name that needs one. macOS draws its own Recent Documents
section from the same list as bare file names, and that section is the Dock's to
draw rather than ours to relabel — so this is a section that is ours, above it.

## Fixes

- **A clip's level could be set and never saved.** `gain` was missing from the
  comparison that decides whether a document has changed, so a clip you had
  levelled compared equal to the one you levelled it from: not dirty, not
  written, and the number gone at the next open. Anything already in a file was
  always honoured — this was only ever the setting of it.

## Known limits

- Sharing moves text. Footage is not in the repository and has to reach the
  other person some other way.
- A key a later version of cuttr writes on a *clip* is still dropped when an
  older one opens and saves the take. At the take's own level they are carried
  through as they always were.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Sharing needs git, which comes with
the Xcode command line tools, and a repository with a remote you can already
push to. Transcription, sound detection and proposed names need macOS 26;
proposed names also need Apple Intelligence switched on. Everything they do
happens on this Mac.
