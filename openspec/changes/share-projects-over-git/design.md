## Context

cuttr already knows about git, and deliberately keeps its hands off it.
`ProjectVersions` writes a snapshot to `refs/cuttr/saves` after every pause in
the editing, entirely through plumbing — `hash-object`, `write-tree` against a
*temporary* index, `commit-tree`, `update-ref` — so that HEAD, the index and the
working tree are never touched. `nothingIsTouchedInTheRepository` holds that
down. `BranchMenu` switches branches and otherwise hands the folder to a real
git client, on the stated grounds that "cuttr is not a git client and never will
be".

Nothing contacts a remote. `GitRepository.forge` reads `origin` once, to build a
web address. So the whole feature set is single-machine, and two people editing
one programme never see each other's work.

What makes sharing tractable here is the file format. `TakeWriter` is
hand-written precisely so that re-saving an unchanged take produces an unchanged
file, and every clip carries a slug that is a *reference* rather than a label.
A three-way merge can therefore be done per clip, by slug, rather than per line.

**The constraint that shapes everything below**: the two guard rails that
already exist. `Outcome.busy` refuses to act on a repository whose owner is
mid-rebase. `ProjectVersions.inTheWay(of:)` refuses when an open `TakeDocument`
holds cuts in memory that would be written back over whatever just landed.

## Goals / Non-Goals

**Goals:**

- One action, **Share**, that a person who does not know git can press to send
  their work and receive everyone else's.
- Concurrent edits to *different* clips of the same take merge without anyone
  being asked anything.
- Concurrent edits to the *same* clip are resolved in cuttr's own vocabulary —
  clip by clip, "what you did / what they did" — never by conflict markers.
- A conflict marker MUST never reach a `.cuttr` or `.cuttrproj` file. The reader
  would fail on it, and the person would be looking at a broken project.
- Refusal is always preferred to a half-done state.
- The person's own repository stays theirs: nothing they staged or left dirty
  outside the project is committed, moved or reverted.

**Non-Goals:**

- Becoming a git client. No staging UI, no history rewriting, no remote
  management, no stash. `BranchMenu` keeps handing that to Fork.
- Syncing footage. **This shares text only** — see the risk below.
- Merging arbitrary files. Only the project, its takes and their sidecars get
  the structured merge; anything else in the tree is left to git.
- Real-time collaboration. This is send-and-receive at a moment somebody
  chooses, not a shared session.

## Decisions

### Share moves HEAD; versions still do not

`ProjectVersions` documents at length why it will not touch HEAD, the index or
the working tree. That stays true of it. Sharing cannot honour it — a commit
somebody else can fetch has to be reachable from a branch — so the two are
separated by *who asked*: versions happen on a timer and touch nothing; sharing
happens because a person pressed a button and is allowed to move the branch.

Alternative considered: sharing the `refs/cuttr/saves` ref itself. Rejected —
it would push tens of machine-made commits an afternoon, and the receiving side
would have no branch to put them on.

### The commit is built with plumbing, on a temporary index

Not `git add` + `git commit`. The person may have staged something, or have
unrelated dirty files; a release-the-brakes `git commit -a` would sweep those in.

The sequence, all through plumbing:

1. Seed a temporary index from HEAD (`GIT_INDEX_FILE=… git read-tree HEAD`).
2. `git update-index --add` **only** the paths `ProjectVersions.files()` returns.
3. `write-tree`, then `commit-tree -p HEAD`.
4. `update-ref refs/heads/<branch>` — the one deliberate move.
5. Refresh the *real* index for exactly those paths, so `git status` does not
   afterwards report the just-committed files as modified. Nothing else in the
   index is read or written.

`ProjectVersions.files()` is reused verbatim rather than reimplemented: it
already walks the project, every take it names, and each take's `words:`
transcript and solved anchor paths.

### The merge is slug-keyed, and happens in cuttr, not in git

Git's line merge conflicts on two clips that merely sit next to each other in
the file. Worse, when it does conflict it writes markers into the file, and a
`.cuttr` with markers in it does not parse.

So cuttr merges the files itself, in `CuttrKit` (no AppKit, therefore testable
without a window). Given base, mine and theirs, decoded through the existing
readers:

- a clip present on one side only → taken
- a clip removed on one side only → removed
- a clip changed on one side only → the changed one
- a clip changed on **both** sides, differently → a conflict, and the only kind
  that reaches a person
- take-level keys (`video:`, `audio:`, `offset:`, `words:`) are merged the same
  way, each key on its own
- **unknown keys are carried through from both sides**, per the house rule that
  a file written by a later version must survive an older one

The result is written by `TakeWriter`, so a merged file is byte-identical to one
somebody saved by hand.

Alternative considered: registering a git merge driver via `.gitattributes` and
`.git/config`. Rejected — it writes into the person's repository configuration,
and it only works for people who have cuttr installed, which is exactly the
collaborator this feature is for.

### Integrate by rebasing our own commits, and refuse to rebase theirs

After fetching, if the upstream has moved, cuttr replays *its own* share commits
on top. Commits it did not make are not rebased: someone who has been committing
by hand has a history worth more than a linear graph, and rewriting it silently
is the kind of thing that ends trust in a tool. In that case Share merges
instead, with two parents.

### Credentials are diagnosed, not hidden

`GitRepository.run` sets `GIT_TERMINAL_PROMPT=0` so git can never hang waiting on
stdin. The cost is that an HTTPS remote with no credential helper fails with
nothing useful said. `run` currently discards stderr entirely; it grows a variant
that keeps it, and Share reads it to tell the difference between "no network",
"you are not signed in to <host>", and "you do not have push rights here" —
each with the one next step, in words that do not assume the reader knows what a
credential helper is.

## Risks / Trade-offs

- **Footage is not shared.** Takes and projects are kilobytes of text; the
  recordings they point at are gigabytes and are not in the repository. Two
  people sharing a project still need the media on a shared volume, at the same
  relative paths. → Share says so plainly the first time a take names a file
  that is not on this machine, rather than presenting a project that opens to
  black. This is a genuine limit of the feature and the notes must not oversell
  it.
- **A slug-keyed merge can be semantically wrong while being textually clean.**
  Two people who both re-cut around the same moment, in different clips, merge
  without a word — and the result is a programme neither of them cut. → Every
  share is a version on `refs/cuttr/saves` first, so the state before it is
  always recoverable, and the outcome line says how many of whose changes came
  in.
- **A push can be rejected by a race** — somebody pushed between our fetch and
  our push. → Retry the fetch-integrate-push cycle, bounded (three attempts),
  then refuse and say so. Never `--force`, under any circumstance.
- **An open take window makes any incoming change unsafe**, because
  `TakeDocument` holds its cuts in memory and never re-reads. → The existing
  `inTheWay(of:)` refusal, extended to Share. It is the same hazard the branch
  menu and the versions list already refuse over.
- **First code in cuttr that touches the network.** Every git invocation already
  runs with `GIT_TERMINAL_PROMPT=0`; Share adds a timeout, so a hung remote
  cannot leave the action spinning with no way out.
- **A merge is written by the same emitter that guards diff stability.** If the
  merge produced a file `TakeWriter` would not have produced, every subsequent
  save would churn. → The merge returns a `Take`, never text; only `TakeWriter`
  writes. `writingIsStableForTheSameTake` covers the rest.
