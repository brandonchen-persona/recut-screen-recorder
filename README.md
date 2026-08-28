# Recut

A macOS screen recorder in the spirit of Screen Studio: it records your display,
watches where you click and scroll, and turns that into smooth automatic zooms
over a blurred backdrop. Everything it generates is editable.

Native Swift — ScreenCaptureKit for capture, Core Image for compositing,
AVFoundation for playback and export. No Xcode project; SwiftPM builds it.

## Build and run

```bash
./Scripts/build_app.sh && open build/Recut.app
```

The first launch will ask for **Screen Recording** permission (System Settings →
Privacy & Security → Screen & System Audio Recording). Grant it, then relaunch.
Nothing else is required — click tracking uses pointer polling rather than an
event tap, so Accessibility permission is never needed.

### Why permission has to be granted again after every rebuild

macOS doesn't grant Screen Recording to *an app*, it grants it to **a specific
binary**. Normally that identity comes from a Developer ID certificate and
survives updates. Recut isn't signed with one, so its identity is the ad-hoc
`cdhash` of the binary itself — and rebuilding changes that hash. As far as
macOS is concerned the new build is a different app that has never been
approved.

The confusing part is that the old approval doesn't disappear. System Settings
keeps showing a **Recut** toggle that's switched on, while the app insists it
has no permission. Both are telling the truth: the grant belongs to the previous
build. Toggling it off and on doesn't help, because the entry it refers to is
already stale.

To recover, clear the stale entry and let the new build ask for itself:

```bash
tccutil reset ScreenCapture com.recut.app
```

Then launch Recut, press **Request access**, and quit and reopen it. The
permission card shows the current build's signature ID so you can tell builds
apart, and `build_app.sh` prints this reminder whenever a rebuild changes the
hash.

Signing with a Developer ID certificate fixes it permanently: the identity then
comes from the certificate rather than the binary, and the grant sticks across
rebuilds.

## What it does

**Record.** Capture a whole **display**, a single **window**, or an **area** you
drag out. Choose system audio, a microphone, a webcam, a countdown, and whether
to draw the cursor. Recording the iPhone Mirroring window gives you an iPhone
capture — add a device bezel in the editor. The main window hides itself and a floating controller appears with
elapsed time, Finish, Pause, Restart and Delete; neither shows up in the
capture, because the content filter excludes the whole application. Recordings
land in `~/Movies/Recut` as `.recut` packages.

**Choose area…** covers every display, so you can drag a region on whichever
monitor you're working on — the display you drew on becomes the one that gets
recorded, and the record card names it.

Recording an **area** dims the rest of the screen and outlines the capture
region with a viewfinder, so you can see exactly what's being recorded. It's
click-through and only ever on your screen — the content filter excludes Recut
itself, so the dimming never reaches the output. Turn it off with "Dim the rest
of the screen while recording" on the record card.

Pausing doesn't leave a gap: ScreenCaptureKit has no pause, so Recut drops
samples while paused and shifts every later timestamp back by the paused
duration. The pointer track skips the same interval.

**Auto-zoom.** While recording, the pointer is sampled at 60 Hz and clicks and
scrolls are timestamped alongside it. Afterwards those events are grouped into
"bursts" — runs of activity close together in both time and space — and each
burst becomes one zoom that starts moving in *before* the click lands, holds
while you work, and eases out when you leave. Clicks zoom harder than scrolls.

Two bursts in the same place fold into a single zoom. Two bursts in different
places stay separate, and their ramps are lined up so the camera *pans* between
them at full magnification instead of dropping out and diving back in.

**Edit.** The timeline has four lanes: a ruler, the clips, the purple zoom
blocks, and masks. Drag a block to move it, drag its edges to restretch it,
click to select, right-click for the rest. Orange ticks under the clips are the
clicks the planner worked from; grey ones are scrolls. The slider on the right
stretches the timeline out when you need finer control.

Every edit is undoable with **⌘Z** (⇧⌘Z to redo). A slider drag counts as one
step rather than one per pixel, so undo moves in the increments you actually
made.

*Clips* — cut at the playhead, remove a section, and set speed (0.5× to 16×) or
volume per fragment from the right-click menu. Drag either end to trim.

*Zooms* — click an empty spot on the zoom lane to add one. Magnification from 1×
to 5× (with 1.25/1.5/2/3/5 presets), ease-in and ease-out, and one of three
modes: **Auto** points at the clicks inside the zoom, **Manual** at a purple dot
you drag on the preview, **Follow cursor** tracks the pointer throughout.
Right-click to disable a zoom without deleting it. Anything you touch by hand
survives a regenerate.

*Masks & highlights* — click the mask lane to cover something up (blur or solid)
or to draw attention to it (dims everything else).

**Frame.** Aspect ratio above the preview: Auto, Wide 16:9, Vertical 9:16,
Square, Classic 4:3 or Tall 3:4. Auto follows the recording's own shape, so a
narrow area recording stays narrow — pick **Wide 16:9** and the strip is centred
on a full 16:9 canvas with the background filling the space either side. The
editor offers this as a one-click suggestion when a recording is much taller
than it is wide. "Always keep zoomed in" fills the new ratio by
cropping and following the cursor rather than letterboxing. `C` opens the crop
tool — drag the corners over the un-zoomed frame. A device frame draws an iPhone
or iPad bezel around the recording.

**Webcam.** Recorded as a second video track inside the same movie, so it can
never drift out of sync. A floating preview shows your framing while you record
and stays out of the capture. In the editor: circle, rounded or square; size,
corner, margin, mirroring and shadow.

**Typing & shortcuts.** Recut can find the stretches where you were typing and
speed just those up, and caption the shortcuts you pressed. Both read the
keyboard, so both need **Accessibility** permission — the only features that do,
and they ask only when you turn them on.

**Cursor.** *As recorded* keeps whatever the capture baked in. *Smoothed* draws
its own pointer from the tracked path, with size, smoothing, a click ring,
hide-when-idle, and a return-to-start option for seamless loops. This needs
**Draw the cursor** turned on before recording, which hides the OS pointer —
one baked into the video can't be removed later.

**Background.** Blurred copy of the recording itself (the default), a wallpaper,
a gradient, a solid colour, or your own image — plus padding, corner radius,
inset border and drop shadow on the screen layer.

Zooms, blurs and callouts all carry a grab bar at each end: drag the middle to
move the effect, drag an end to change how much of the take it covers.

**Masks & highlights.** Select one on the timeline and the preview switches to
the unzoomed frame with the rectangle drawn on it — drag it to move, drag a
corner to resize. Exact percentages are still there under "Exact size and
position" for anyone who wants a number.

**Text & logo.** A text lane on the timeline for callouts — "New in 2.4",
"Click here" — as plain text, a pill or a card, with position, size, colours and
fade in/out. A logo watermark sits in any corner at whatever size and opacity
you like, and rides along with your saved look, so every recording carries it
without being set up again.

**Look presets.** Background, cursor, camera, aspect ratio, zoom feel and logo
can be saved as a named preset, and one of them marked as the house style. New
recordings start in it, so a team's clips match without anyone remembering the
numbers.

**Audio.** A level meter sits next to the microphone picker and in the recording
controller, so a dead mic shows up before the take rather than in the edit. The
clip lane draws the waveform of the recording, scaled by each clip's volume — the
silence at the top of a take, and the bit where you said "hang on", are visible
without playing it back.

**Still frames.** *Frame ▸ Save frame as PNG* writes the frame under the
playhead at full output size — background, shadow, zoom, callouts and all — or
copies it to the clipboard. A launch post usually needs a hero image as well as
a video.

**Export.** MP4, MOV or animated GIF; 854–3840 wide; 24, 30 or 60 fps; three
quality levels. Write a file, or copy it straight to the clipboard to paste into
Slack or a doc.

**Getting around.** `⌘K` opens a command palette over the editor — every tool,
aspect ratio, background and cursor mode is one search away. `⌘,` opens
Settings: recording defaults, where projects live, and how hard the preview
works (Quality / Performance / Power saving).

The preview and the export run the *same* compositor, so what you scrub is what
you get. The preview just renders at a smaller size to stay fluid, and while the
playhead is parked it composites the cached frame directly rather than asking
the player to seek — which is the difference between a slider that drags at
4.5 ms a frame and one that stutters at 107.

## Command line

```bash
build/Recut.app/Contents/MacOS/Recut --render ~/Movies/Recut/Something.recut out.mp4 1920 60
build/Recut.app/Contents/MacOS/Recut --frames ~/Movies/Recut/Something.recut ./frames 1.5,5.0,10.4
build/Recut.app/Contents/MacOS/Recut --typing ~/Movies/Recut/Something.recut --apply 2.0
build/Recut.app/Contents/MacOS/Recut --waveform ~/Movies/Recut/Something.recut
build/Recut.app/Contents/MacOS/Recut --mics            # list inputs
build/Recut.app/Contents/MacOS/Recut --mics 0          # record 2s and check one
```

`--render` is a batch export; the format comes from the file extension, GIF
included. `--frames` writes single composited stills and prints the camera state
at each time, which is the quickest way to check what the planner decided.
`--typing` reports the typing runs it finds, and with `--apply` cuts them into
their own sped-up clips. `--mics` lists the microphones the app can see with
their native formats; given an index it records two seconds, reports the
delivered format, clock and level, and pushes the result through the same
encoder settings a real take uses — which is the quickest way to tell a dead
microphone from a mis-selected one. Add `raw` to skip Recut's own conversion
and see what the device produces unaided. `--waveform` prints the audio envelope second by
second, which is how you tell a silent recording from a silent *export*.

## Tests

```bash
./Scripts/test.sh
```

91 tests over the pure engine — timeline mapping, zoom planning, the camera
solver, cursor smoothing, typing detection, canvas sizing, callout fades, the
audio envelope and meter, mask defaults, undo, and project decoding.
No AVFoundation, no Core Image, no files; the whole suite runs in well under a
second.

XCTest ships with Xcode rather than the Command Line Tools this project builds
against, so `swift test` can't link here. The suites live in
`Sources/Recut/Tests` and run from the app binary via `Recut --test`, with a
small harness whose assertions map onto XCTest's.

## Project format

A `.recut` package keeps the capture untouched and the edit beside it, so every
change is non-destructive:

```
Something.recut/
  video.mov      the capture — plus the webcam as a second video track
  events.json    pointer samples, clicks, scrolls, key presses
  meta.json      dimensions, duration, frame rate
  edit.json      clips, zooms, masks, text, cursor, frame, webcam, background
  waveform.json  cached audio envelope for the timeline (rebuilt if deleted)
```

`Recut --import` isn't needed for existing footage — **Import video…** wraps any
movie file in a project without copying it. There's no cursor track, so zooms
are placed by hand.

See [NOTES.md](NOTES.md) before changing anything — it records the traps this
codebase has already fallen into.

## Layout

```
Sources/Recut/
  Capture/    ScreenRecorder (ScreenCaptureKit → AVAssetWriter), CursorTracker
  Engine/     Timeline, ZoomPlanner, CameraSolver, CursorPath,
              FrameRenderer, RecutCompositor + CompositionBuilder
  Export/     Exporter (AVAssetReader → AVAssetWriter through the compositor)
  Model/      Codable models, the .recut package
  Tests/      the engine test suite
  UI/         SwiftUI editor, timeline, inspector, crop overlay, recording HUD
  App/        entry point, AppState, PlayerController, CLI
Sources/RecutSample/
              generates a synthetic .recut for testing without a real capture
```

## Code signing, Santa, and the permission prompt

These two are the same problem wearing different hats, so they're worth reading
together.

`Scripts/build_app.sh` deliberately does **not** run `codesign`. The binary
swiftc emits is already ad-hoc *linker-signed*, and on a machine running Santa
in Lockdown mode with transitive allowlisting, that's precisely what lets it
run: compiler output inherits an allow rule. Re-signing rewrites the binary,
which voids that rule — the process is then SIGKILLed on exec with no crash log
and no error message. `SIGN=1` (plus `SIGN_IDENTITY`) re-signs anyway, if you
have a certificate and Santa trusts its Team ID.

The same rule catches **debug builds**: only the release link picks up a
transitive allow rule, so a debug binary is denied and SIGKILLed (`exit 137`).
Since `swift build` and `swift run` default to debug, use `./Scripts/run.sh` and
`./Scripts/test.sh`, which force release. Compiling debug is fine — only running
it is blocked.

The cost of not signing is that macOS has no stable identity to hang the Screen
Recording grant on, so it pins the grant to the binary's **ad-hoc cdhash**.
Every rebuild changes that hash, which means:

> System Settings keeps showing a "Recut" toggle that's switched on, while the
> app insists it has no permission. Both are telling the truth — the grant
> belongs to a previous build.

To recover, clear the stale entry and grant it again:

```bash
tccutil reset ScreenCapture com.recut.app
```

Then launch Recut and press **Request access** on the permission card. The card
shows the current build's signature ID so you can tell builds apart.

The real fix is a Developer ID certificate: signing gives a Team ID-based
requirement that survives rebuilds, and the grant sticks for good.

## Adding a setting

Swift's synthesized `Decodable` throws on a missing key instead of falling back
to the property's default, so a new field breaks every project written by an
earlier build. Each settings struct therefore has a hand-written `init(from:)`
using `decodeIfPresent` at the bottom of `Models.swift` — **add your field there
too**. `Project.load` reports a decode failure rather than silently opening the
project with defaults, which is how this went unnoticed once.

## Notes

- The permission card only appears when TCC actually reports no access
  (`CGPreflightScreenCaptureAccess`). If capture fails for some other reason the
  app shows that error instead of sending you to Settings for a toggle that's
  already on.
- Captures are HEVC (falling back to H.264), capped at 3840 wide.
