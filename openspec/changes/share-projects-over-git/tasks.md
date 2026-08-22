## 1. The remote questions git can answer

- [x] 1.1 Add a variant of `GitRepository.run` that keeps standard error instead
      of discarding it, and returns exit status alongside output. Everything
      existing keeps the quiet `nil`-on-failure behaviour.
- [x] 1.2 Add `fetch(in:)`, `upstream(of:in:)` and `counts(against:in:)`
      (ahead/behind) to `GitRepository`, each with a timeout so a hung remote
      cannot leave the action spinning.
- [x] 1.3 Add `push(_:in:)` returning either success or git's own stderr. Never
      `--force`, and no code path that could construct one.
- [x] 1.4 Add `Trouble`: read git's stderr and classify it as unreachable,
      unauthenticated, forbidden, rejected-race, or other. `RepositoryTests`
      covers each against real stderr text.

## 2. The merge, in CuttrKit

- [x] 2.1 Add `TakeMerge` beside `TakeFile`: given base, mine and theirs as
      `Take` values, return either a merged `Take` or a list of conflicts. No
      AppKit, so it is testable without a window.
- [x] 2.2 Merge the clip list by slug — added, removed, changed-on-one-side,
      changed-identically — with a conflict only for same-slug different-value.
- [x] 2.3 Merge take-level keys (`video:`, `audio:`, `offset:`, `words:`) each on
      its own, so re-aligning and re-cutting do not collide.
- [x] 2.4 Carry unknown keys through from both sides; a key present on one side
      only is kept. Test with a key no build knows.
- [x] 2.5 Add `ProjectMerge` for `.cuttrproj` on the same shape, keyed by the
      timeline entry's `as:`/section name where it has one.
- [x] 2.6 Test that a merged take written by `TakeWriter` re-saves byte-identical,
      the same guarantee `writingIsStableForTheSameTake` makes.

## 3. Building the commit without disturbing the repository

- [x] 3.1 Add `ProjectSharing` in `CuttrUI` beside `ProjectHistory`, reusing
      `ProjectVersions.files()` for what to commit.
- [x] 3.2 Commit through plumbing on a temporary index: `read-tree HEAD`,
      `update-index --add` the project's paths only, `write-tree`,
      `commit-tree -p HEAD`, `update-ref refs/heads/<branch>`.
- [x] 3.3 Refresh the real index for exactly those paths so `git status` does not
      report them modified afterwards, touching nothing else.
- [x] 3.4 Test: an unrelated dirty file stays dirty and uncommitted; an unrelated
      staged change stays staged. This is the analogue of
      `nothingIsTouchedInTheRepository` and is the test that matters most here.

## 4. The Share action

- [ ] 4.1 Wire the sequence: flush the pending version, refuse on `busy` or
      `inTheWay`, commit, fetch, integrate, push.
- [ ] 4.2 Integrate by replaying our own share commits; merge with two parents
      instead when the person has commits of their own on the branch.
- [ ] 4.3 Retry the fetch-integrate-push cycle on a rejected push, at most three
      times, then refuse and say so.
- [ ] 4.4 Add the outcome vocabulary — nothing to send, sent, brought in and
      sent, refused-and-why — in the program's own words, no git terms.
- [ ] 4.5 Say when an incoming take names footage this machine has not got.

## 5. Resolving a conflict

- [ ] 5.1 Add the conflict sheet beside `VersionsSheet`: one conflicting clip at
      a time, named by name and slug, times as timecode, mine and theirs side by
      side.
- [ ] 5.2 Write nothing until every conflict is answered; dismissing leaves the
      work tree exactly as it was.
- [ ] 5.3 Test that no conflict marker is ever written to a `.cuttr` or
      `.cuttrproj`, including transiently.

## 6. Where it lives

- [ ] 6.1 Add Share to `MainMenu` with a key equivalent, and to the capsule's
      branch half via `BranchMenu`.
- [ ] 6.2 Show it only for a work tree that has an `origin`; absent, not
      disabled, when there is none.
- [ ] 6.3 Extend `BranchMenu.documentsInTheWay` use so Share refuses over the
      same open take windows a checkout and a restore already refuse over.

## 7. Finishing

- [ ] 7.1 A `docs/sharing.md` written for somebody who does not know git: what
      Share does, what it cannot do (footage), and what to do when it refuses.
- [ ] 7.2 `make test` clean, including the real-decode test.
