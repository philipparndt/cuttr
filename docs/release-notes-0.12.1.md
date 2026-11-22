# cuttr 0.12.1

A sound can start part-way into its file, the assistant can find the sounds it
could not and cut a copy when one is wanted, and a sound placed inside a clip no
longer writes a project that will not open.

## `start:` — a song from its chorus

A sound has two clocks, and until now only one of them had a key. `from:` and
`to:` say when it plays, on the programme. `start:` says where in the *file* it
begins:

```yaml
sounds:
  - file:  music/song.mp3
    from:  04:55.485
    to:    06:10.000
    start: 00:13.915   # in the file
    end:   01:15.000   # in the file
```

It moves nothing. The sound comes in at the same moment it did before and plays
from further into the recording, which is the thing that used to need a second
file — a copy of somebody's music, kept for the sake of fourteen seconds.
`end:` is optional and is where in the file it stops; a sound whose `end:` comes
before its span is up ends there. The gain, the fades and `ducks:` apply to the
part that is heard, and the bar on the strip is the length that plays.

In the window it is under **which part of the file** in a sound's properties. A
start before the beginning, or an end that is not after the start, is refused
when the file is read rather than played as a silent track.

## A sound inside a clip broke the file

A sound set to play *inside a clip* — `within:` and two times — was written
without the space after `within:`, as one word. The project would not read back:
choosing "inside a clip" for a sound in the window and saving left a file that
opened with a YAML error. Overlays were not affected. It is written properly
now, and a project that already has the line can be mended by putting the space
in.

## The assistant

- **It can start a sound part-way into its file.** It knows the two clocks
  apart, and its answer after an edit lists every sound as cuttr now takes it —
  when it plays and from where in the file — so a key that was read can be told
  from one that was not.
- **It finds sounds written inside a timeline entry.** `shift_sound` looked only
  at the top-level list and said there was no such sound. The sounds are one
  list now, numbered the same way wherever they are asked about. One that plays
  for exactly its placement has no time to shift, and it says so, with what can
  be done instead.
- **It can cut a copy of part of an audio file** when a copy is what is wanted.
  The original is not touched, nothing is overwritten, and the copy can only go
  inside the project's folder or beside the file it came from. It asks first.
  WAV, AIFF and CAF stay uncompressed at the depth they came in at; anything
  else is written as AAC in an `.m4a`.
