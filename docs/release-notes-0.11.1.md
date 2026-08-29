# cuttr 0.11.1

Three fixes, two of them for faults 0.11.0 introduced.

## The preview could be taken down by one recording

If the play button did nothing, quick look did nothing and the picture stayed
black, this is why.

0.11.0 asked every clip's source for its time range on the way past, with no
guard, for a number that only a *held* picture uses. A single recording whose
track would not answer — one on a slow or sleeping volume, one still being
written, one AVFoundation simply disliked — threw out of the whole build.

From the front that does not look like a problem with a clip. The window holds
one composition or none, and the preview, the play button and quick look all read
the same one, so all three go quiet together and nothing says which recording was
at fault.

It is asked for only when something is actually held now — which for most
projects is never — and it falls back to the clip's own end rather than throwing.
A programme with a hold in it should lose the hold, not the film.

## A section's length could be pushed off its own row

The length was drawn after the name and the count, left to right, and the code
that draws it puts text where it is told without looking at how wide the row is.
A section with a long name pushed the length past the edge of the row, where it
was not clipped so much as simply gone: a name of forty-three characters on a
200-point row put it at x=416.

Nothing said so. The row looked ordinary and the one number somebody opens a
section row for was missing, which reads as a feature that had been taken away.

It is against the right edge now, so there is nothing to push it. The count goes
in whatever is left, or is dropped — of the two, the length is the one that
cannot be worked out by looking.

## WebM says why it cannot be read

macOS knows the extension, gives it the type `org.webmproject.webm`, and reports
that the type conforms to `public.movie` — so every open panel in cuttr offered a
`.webm` and accepted it. AVFoundation then cannot open it: no VP8, no VP9, no
Matroska.

What that produced was a take that resolved, appeared in the material tree, and
had no picture, no waveform and no render.

    cuttr cannot read WebM — macOS has no decoder for it, so nothing on
    this Mac can open demo.webm except a browser. Convert it to .mov or
    .mp4 first.

The two places media is *chosen* ask before anything is written, because a take
pointing at a file that will not open is worse than no take: it is in the tree, it
is in the project file, and everything about it looks ordinary until somebody
tries to cut it.

The format names are used only for wording, and are looked up after a file has
already failed. Deciding from an extension whether something will work is how a
format that starts being supported goes on being refused.
