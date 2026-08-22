# Sharing a project

Several people, one programme, and nobody has to know git.

Press **Share** — in the File menu, on ⌃⌘S, or from the branch half of the
capsule at the top of the window. It sends what you have done and brings back
what everybody else has. That is the whole of it.

    ┌─ film.cuttrproj ──────────────────── main ─┐
    │                              Share…        │
    │                              ────────────  │
    │                              Open in Fork  │
    └────────────────────────────────────────────┘

## What it does, in order

1. **Keeps a version** of where you are, on `refs/cuttr/saves`. Whatever happens
   next, the state before it is one ⇧⌘Y away.
2. **Commits the project's own files** — the project, the takes it names, and
   their transcripts and tracked anchors. Nothing else in the folder is touched.
3. **Fetches**, and brings in anything that arrived.
4. **Pushes.**

Then it says one line: *nothing to send*, *sent your changes*, *brought in 3
changes and sent yours*.

## What it will not do

**It does not share footage.** A take is a few kilobytes of text. The recording
it points at is gigabytes and is not in the repository, and putting it there
would be the wrong thing for everybody. So the people you are working with need
the media themselves — on a shared volume, an external disk, wherever, as long
as it is at the same path relative to the take. If a take arrives naming a file
this Mac has not got, Share says which file, rather than leaving you with a
programme that plays black.

**It does not touch anything that is not the project's.** If you have other
files in that folder — notes, a script, a half-finished anything — they are not
committed, not staged and not reverted. If you had something staged, it is
still staged afterwards.

**It never force-pushes.** There is no setting for it and no code path that
could construct one.

## When two people change the same thing

Most of the time they do not, and nothing is asked. Two people cutting two
different shots merge silently, even when those shots are next to each other in
the file. Two people working in two different *sections* of the programme merge
silently. That is what the whole thing is built around: a clip is matched by its
slug and a shot by its `as:` name, so cuttr can tell two edits to two different
things from two edits to one thing.

When you really have both changed the same clip, a sheet opens listing just
those — what you did, what they did, and which to keep:

    ┌──────────────────────────────────────────────────────────┐
    │ One thing was changed on both sides                      │
    │                                                          │
    │ What              Yours                Theirs            │
    │ Intro           ✓ 00:00.000→00:12.000    00:00.000→…14    │
    │ one.cuttr                                                │
    └──────────────────────────────────────────────────────────┘

Nothing is written until every row is answered. **Cancel leaves everything
exactly as it is** — your own cut is what stays on the disk.

No conflict markers ever go into a `.cuttr` or `.cuttrproj` file. They would
stop it parsing, and you would be looking at a broken project having done
nothing wrong.

## When it refuses

It refuses rather than half-doing something, and says what has to happen first.

**"a merge is in progress — finish it first."** Something in that folder is
half-done, probably from a git client. Finish or abandon it there.

**"close take-01 first — a take window holds its cuts in memory."** A take
window does not re-read its file, so anything arriving underneath it would be
written straight back over on the next save. Close the take windows and share
again.

**"there are uncommitted changes in this folder."** Bringing changes in may need
a real merge, and abandoning a merge can take uncommitted work with it. Your
files are not ours to risk, so commit them or put them aside first.

**"not signed in to github.com."** cuttr never lets git stop and ask for a
password — a prompt nobody can see is a program that has hung. So the sign-in
has to already work. Open the folder in a git client once (Fork is in the same
menu), let it sign you in, and Share will work from then on.

**"no permission to push to this repository."** You are signed in and this is
somebody else's repository. Ask them for access.

**"somebody else pushed at the same moment."** Rare, and Share already tried
again three times. Press it once more.

## Getting set up

One person makes the repository and pushes the project to it. Everybody else
clones it, opens the `.cuttrproj` from their clone, and puts the footage where
the takes expect it. After that it is Share and nothing else.

If a folder is not a git repository at all, or has no `origin`, there is no
Share item — that is not an error, it is most projects.

## For anybody who does know git

Share commits on the branch you are on, through plumbing, against a temporary
index seeded from `HEAD`, adding only the paths the project owns. It then
refreshes your real index for exactly those paths so they do not read as
modified afterwards. Fetch, integrate, push; a fast-forward where one is
possible, otherwise a merge with `.cuttr` and `.cuttrproj` conflicts resolved by
value rather than by line. The automatic per-pause snapshots are a different
thing and still never move `HEAD` — see `ProjectHistory.swift`.
