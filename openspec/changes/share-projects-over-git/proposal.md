## Why

Everything cuttr knows about git today is single-machine. `ProjectVersions`
keeps a snapshot on `refs/cuttr/saves` every time the editing goes quiet,
`BranchMenu` switches branches and hands the folder to Fork, and
`GitRepository.forge` reads `origin` — but only to build a web address. Nothing
ever fetches and nothing ever pushes, so two people editing the same programme
on two machines never see each other's work.

The files are already the right shape for this. A take is line-oriented text
with a hand-written emitter that guarantees an unchanged take re-saves to an
unchanged file, and every clip in it carries a stable slug. That is a better
starting point for merging two people's edits than most editors ever get, and it
is currently going unused.

## What Changes

- A **Share** action, on the File menu and on the capsule, that a person presses
  when they want to send their work and see everyone else's. It flushes the
  pending version, commits **only this project's own files** — the set
  `ProjectVersions.files()` already computes — fetches, integrates what came in,
  and pushes. It says one plain line about what happened: "nothing to send",
  "sent your changes", "brought in 3 of Anna's changes and sent yours".
- **Share moves HEAD, and is therefore never automatic.** `ProjectVersions`
  documents at length that it will not touch HEAD, the index, or the working
  tree, and that stays true of it. Sharing cannot honour that — a commit
  somebody else can fetch has to be on the branch — so the distinction is that
  this one only ever happens because a person asked for it. Anything the person
  has staged or dirty that is not part of the project is left exactly as it was.
- **A three-way merge of takes and projects, keyed by slug rather than by
  line.** Git's line merge conflicts on two clips that happen to be adjacent in
  the file; a slug-keyed merge does not, because it knows the two edits are to
  different clips. Only genuinely concurrent edits to the *same* clip reach the
  person.
- **A chooser for what genuinely conflicts.** Clip by clip: what you did, what
  they did, and which to keep. The result is written back through `TakeWriter`,
  so a merged file is byte-identical to one somebody saved by hand — no conflict
  markers ever reach a `.cuttr` file, where they would break the reader.
- **Refusal rather than half-done**, extending the two guard rails that exist.
  `Outcome.busy` already refuses over a repository mid-rebase;
  `ProjectVersions.inTheWay(of:)` already refuses when an open take window holds
  cuts that would be written back over what just landed. Share respects both.
- **Getting somebody authenticated is part of the feature, not a prerequisite.**
  `GitRepository.run` sets `GIT_TERMINAL_PROMPT=0` so git can never hang waiting
  on stdin, which means an HTTPS remote with no credential helper fails with
  nothing useful said. Share diagnoses that case and says what to do about it,
  because the person this is for does not know what a credential helper is.

## Capabilities

### New Capabilities

- `project-sharing`: the Share action — what it commits, in what order it
  fetches, integrates and pushes, when it refuses, and what it says in each
  outcome. Includes the credential diagnosis.
- `take-merge`: three-way merge of `.cuttr` and `.cuttrproj` files keyed by
  slug, what counts as a conflict, and the chooser that resolves one. Includes
  carrying unknown keys through from both sides.

### Modified Capabilities

None. `openspec/specs/` is empty; these are the first two.

## Impact

- **New**: merge and conflict types in `CuttrKit` beside `TakeFile`/`ProjectFile`
  (mergeable without AppKit, and therefore testable without a window); a
  `ProjectSharing` type in `CuttrUI` beside `ProjectHistory`; a conflict sheet
  beside `VersionsSheet`.
- **Changed**: `GitRepository` grows the remote questions it currently lacks —
  fetch, ahead/behind against the upstream, push — and a way to report *why* a
  command failed, which `run` currently discards along with stderr.
  `MainMenu` and `DocumentCapsule` grow the action.
- **Unchanged**: `ProjectVersions` keeps its promise not to touch HEAD, the
  index or the working tree. `TakeWriter` stays hand-written and stays the only
  thing that writes a take.
- **No new dependencies.** Shelling out to `/usr/bin/git`, as `GitRepository`
  already argues for.
- **Risk**: this is the first code in cuttr that writes to a branch and talks to
  a network. The guard rails above are the mitigation, plus the fact that
  everything it does is recoverable from `refs/cuttr/saves`.
