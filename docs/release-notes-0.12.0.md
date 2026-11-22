# cuttr 0.12.0

An assistant that works in your documents through your own AI, a levels lane on
the programme, and no more burst of sound at a cut between a loud shot and a
quiet one.

## The assistant

`⌃⌘A`, or the speech bubble at the end of the bar, opens a chat down the side of
the window. Ask it about the cut or tell it what to change:

    make a clip of the sentence about the driver
    start the music two seconds later
    the recorder is half a second late
    transcribe this take, then tag everything Mia says

It does it in the open documents, where you can watch. It works the way this
program does — it reads a take or a project as the file would say it and hands
back the text it wants — so every change is one step in the document's own undo
and `⌘Z` takes it back. A take is not written until you save. A project is
written as it is edited, exactly as it is when you edit it yourself.

Beyond the files it can cut a clip, move a take's separate audio against its
picture without moving a single cut mark, move a sound of the programme, read
the transcript, put the playhead somewhere, switch documents, and run **any
command in the menu bar by name** — aligning, transcribing, rendering,
exporting. It reads cuttr's own documentation before writing syntax it has not
seen in your file.

**Some things are asked first**, in the chat, and do not happen until you press
Allow: saving, closing, quitting, sharing, deleting, reloading from disk, and
writing a take that is not open — which has no undo to put the change on.

### It answers through your own AI

[ai-connector](https://github.com/philipparndt/ai-connector) runs Claude Code
and local models on your Mac. If it is running, there is nothing to set up:
cuttr finds it by the file it keeps while it runs, and the model menu at the top
of the panel lists what it offers.

If it is not, the panel says so and shows **one command to paste into
Terminal**. It downloads the newest ai-connector, checks it against the
release's checksums, and starts it now and at every login; the panel notices by
itself a few seconds later. Two things to know about a connector that is new:
Claude Code has to be installed and signed in on that Mac for the Claude Code
models to appear, and a local model has to be downloaded before there is one to
choose. Needs Apple silicon.

An ai-connector **elsewhere on your network** is found by Bonjour and linked
with a PIN you approve on that machine. Its local models can be used from here;
Claude Code only on this Mac, because it reaches cuttr through a server cuttr
opens on the loopback interface for the length of a turn. macOS asks once
whether cuttr may look at the local network — only when there is no AI on this
Mac to find first.

And **any OpenAI-compatible address** works, named in `~/.config/cuttr/config.yaml`:

```yaml
ai:
  url: https://openrouter.ai/api/v1
  key: sk-…
```

The key is kept in that file as plain text, like the others there. The
conversation is kept in `~/.config/cuttr/chat.json`, on this computer and not in
the project. Nothing goes anywhere you have not set up.

## Levels on the programme

The strip gains a lane under the clips: every clip's sound drawn at the level it
will be heard at, with the take's level curve over it. Drag a point, click the
line to add one, backspace to remove it, and ⌥-drag across a stretch to lay a
four-point dip over it. An edit pins the curve at the clip's edges first, so the
rest of the take is left alone, and goes to the take's file. The curve's ceiling
is +12 dB.

The ruler is the playhead's colour and the scrollbar sits along the bottom, so
placing the playhead and moving the view are at opposite ends of the strip. A
zoomed strip pages along with playback.

## No burst at a cut

A shot levelled at +20 dB followed by one at −12 played the first fraction of
the quiet shot eight times too loud — a burst at every such cut, and a dip drawn
just after one drowned in it. The renderer does not step a volume; it smooths a
change across about a hundred and ninety milliseconds, and that smoothing was
happening inside the next shot.

The programme's sound now takes two lanes in turn, and each clip's level is put
on its lane before the clip begins, while the lane carries nothing. Measured on
an export.
