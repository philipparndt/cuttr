# cuttr 0.10.1

Takes can be put in folders. And two deadlocks that could stop the program are
gone.

## Folders

A project with forty takes listed forty takes. `Takes` now holds the folders you
have made and the takes you have not filed; a folder holds takes; a take still
holds its clips.

    ▾ TAKES
      ▾ Interviews
        ▸ Mia 1        19
        ▸ Leni          8
      ▾ B-roll       empty
      ▸ Wie sieht Oma   4

Make one from the context menu — on `Takes`, or on a folder to make a sibling.
Put takes in with `Move to Folder ▸`, which lists every folder there is, the way
out of the one it is in, and a new one; or **drag a take onto a folder**.
Dropping one on `Takes` takes it back out, and dropping it on another take files
it beside that one.

**An empty folder is a folder.** Made now, filled later, and it survives a save —
which is the whole point of being able to make one before there is anything to
put in it. Removing a folder leaves its takes in the project: an arrangement is
not the material.

The arrangement is in the project file, so it travels with the project and is
shared like everything else. A project that has never made a folder writes
nothing new, and reads exactly as it did.

## Two ways the program could stop

Both were found by running the test suite until it wedged and then asking the
system what it was doing.

**Every `git` this program ran parked two threads.** One writing to its input,
one reading its errors, while the caller read its output. Run enough of them at
once — which sharing a project does — and there is no thread left to read the
errors with, so the wait for them never ends and the output pipe fills up behind
it. Both are read as they arrive now, and nothing waits. This is very likely
what failed a release cut a few versions back.

**And opening a row in a list blocked a thread.** macOS animates a list opening,
an animation holds a worker thread while it runs, and the material tree opens
every heading each time it is rebuilt. A window that reloads often could fill the
system's whole pool with animations and stop. Those rows appear without an
animation now, which is what they always looked like anyway.

## Requirements

macOS 14 or newer, Apple silicon or Intel. Transcription, sound detection and
proposed names need macOS 26; proposed names also need Apple Intelligence
switched on. Everything they do happens on this Mac.
