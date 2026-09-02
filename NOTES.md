# Recut — engineering notes

What will bite you when changing this, and why things are built the way they
are. The README covers what the app does; this covers what isn't obvious from
reading the code.

## Environment gotchas (all worked around — don't undo)

1. **Santa is in Lockdown mode with transitive allowlisting.** Two consequences,
   both already handled — the symptom of either is `exit 137`, no output, no
   crash log:

   - **Never `codesign` the bundle.** Compiler output inherits a transitive
     allow rule; re-signing rewrites the binary and voids it. `build_app.sh`
     therefore does *not* sign; `SIGN=1` opts back in if you have a cert.
   - **Never run a debug build.** Only the release link gets a transitive rule.
     `santactl fileinfo` on the two is decisive:

     ```
     release  Rule: Allowed (Binary, Transitive)
     debug    Rule: None → Blocked (Unknown, Lockdown mode)
     ```

     `swift build` and `swift run` default to *debug*, so the obvious command is
     the one that dies. Use `./Scripts/test.sh` and `./Scripts/run.sh`, which
     force release; `test.sh` refuses `CONFIG=debug` with an explanation.
     Building debug is fine — only executing it is denied — so
     `swift build -c debug` is still a valid syntax check.

   Every denial in `/var/db/santa/santa.log` so far has been this one binary:

   ```bash
   grep -a "decision=DENY" /var/db/santa/santa.log | sed -E 's/.*path=//' | sort | uniq -c
   ```

   The durable fix for both is a Developer ID certificate plus a Santa TeamID
   rule from whoever administers it — that's an IT request, not something to
   work around locally.
2. **Screen Recording permission is pinned to the ad-hoc cdhash**, so every
   rebuild invalidates it while System Settings still shows the toggle on. After
   a rebuild: `tccutil reset ScreenCapture com.recut.app`, then relaunch and hit
   **Request access**. `build_app.sh` prints this whenever the hash changes.
   `security find-identity -p codesigning` shows 0 identities — a Developer ID
   cert (and a Santa rule for its Team ID) is the only permanent fix.
3. **Overlay panels: use `.floating`, and make the view layer-backed.** The
   area selector at `.screenSaver` level reported `isVisible == true` with the
   right frame on both displays and never composited — nothing on screen, no
   error. Moving it to `.floating` fixed it. A probe showed `.screenSaver` does
   render for a *non-activating, layer-backed* panel, so the interaction is
   with key-window status and/or a non-layer-backed `drawRect` view; if you add
   another overlay, verify it with a screenshot rather than trusting
   `isVisible`.
4. **Don't use `osascript` for UI automation** — it hangs waiting on the
   Accessibility prompt. `screencapture` works: launch with a project argument
   and grab the whole screen.

## Architecture

```
Sources/Recut/
  Capture/    ScreenRecorder (ScreenCaptureKit → AVAssetWriter), CursorTracker,
              KeyTracker, RecordingTarget, AreaSelector (+ countdown),
              MicrophoneRecorder, WebcamRecorder
  Engine/     Timeline, ZoomPlanner, CameraSolver, CursorPath, TypingDetector,
              FrameRenderer, RecutCompositor + CompositionBuilder
  Tests/      TestHarness + TestSuites, run with ./Scripts/test.sh
  Export/     Exporter (AVAssetReader → AVAssetWriter, plus ImageIO for GIF)
  Model/      Models.swift (all codable types), Project (.recut package)
  UI/         EditorView, TimelineView, InspectorView, CropOverlay, ExportSheet,
              CommandMenu, SettingsView, LibraryView, RecordingHUD,
              WebcamPreviewPanel
  App/        Main (CLI vs GUI), AppState, PlayerController, CLI
Sources/RecutSample/
              generates a synthetic two-track .recut for testing
```

Invariants worth keeping:

- **Zooms, masks, the cursor track and key events are stored in _source_ time.**
  `Timeline` maps timeline time ↔ source time, so cutting a section takes its
  zooms with it and speeding a clip up speeds its zooms up too. The compositor
  calls `timeline.sourceTime(at:)` before evaluating anything.
- **Preview and export share one compositor.** `RenderState` is a lock-guarded
  box the UI writes and the render thread reads, so slider drags don't rebuild
  the `AVVideoComposition`. Only clip-list and aspect/crop changes rebuild it
  (`AppState.StructureKey`).
- **`RenderSnapshot.previewFullFrame`** makes the preview show the whole frame
  unzoomed and uncropped while the crop tool or the manual-zoom anchor dot is
  open, so those overlays map one-to-one onto the pixels.
- **Pausing shifts timestamps rather than leaving a gap.** ScreenCaptureKit has
  no pause, so `ScreenRecorder` drops samples while paused and subtracts the
  paused duration from every later PTS (`shift(_:by:)`). `CursorTracker` skips
  the same interval so the pointer track stays in sync.
- **The webcam is a second video track in the same movie**, not a separate file,
  so the two are aligned by construction — one `AVAssetWriter` session, no
  resynchronisation. Its size is measured from a **real delivered frame**, not
  from `device.activeFormat`: `activeFormat` keeps reporting the device's native
  format after a session preset is applied, and a virtual camera can send
  something else entirely. Declaring the wrong size makes `AVAssetWriter` scale
  every frame into it, which stretched an ultra-wide virtual camera vertically.
  The compositor itself handles any camera aspect — uniform scale then centre
  crop — so distortion there always means the *recorded track* is already wrong.
- **Undo holds whole `EditModel` snapshots**, not reversible operations — the
  model is a value type of a few hundred bytes, so sixty of them cost less than
  one video frame and no inverse operation can be subtly wrong. `edit` changes
  on every tick of a slider, so the state from *before* a burst is held back and
  committed only once edits go quiet (450 ms); that turns a drag into the single
  step a person thinks they made. Stack mechanics live in `History` so they can
  be tested without an `AppState`.
- **Every settings struct decodes leniently.** See below — this one bit hard.
- **The paused preview is drawn directly, not seeked.** Asking `AVPlayer` to
  redraw a paused frame means an exact seek, and on a composition with a custom
  compositor that costs ~107 ms — it decodes from the previous keyframe and
  composites forward. Compositing one frame costs ~4 ms. `StillPreview` decodes
  the source frame once, caches it, and re-composites on top while the playhead
  is parked, so a slider drag costs the renderer's own 4.5 ms rather than 107.
  `./Scripts/run.sh --bench <project.recut>` prints the comparison.

### Read this before adding a field to any stored struct

Swift's synthesized `Decodable` does **not** fall back to a property's default
when a key is missing; it throws. Adding `FrameSettings.device` therefore broke
every `edit.json` written by an earlier build — and because `Project.load` used
`try?`, the failure was swallowed and projects silently opened with default
settings. Aspect ratios and typing speed-ups quietly stopped applying.

Both halves are fixed and both matter:

- Each settings struct has a hand-written `init(from:)` using `decodeIfPresent`
  (bottom of `Models.swift`). **Add your new field there too**, or older
  projects will lose their edits.
- `Project.load` records `editLoadFailure` and the editor surfaces it instead of
  pretending everything is fine.

## Verifying changes

### Tests

```bash
./Scripts/test.sh
```

91 tests, 399 assertions, well under a second. They cover the pure engine —
`Timeline`, `ZoomPlanner`, `CameraSolver`, `CursorPath`, `TypingDetector`,
canvas sizing, `History`, `TextOverlay` fades, `Waveform`, the microphone meter
mapping, mask defaults, `RectDrag` and project decoding — and touch no AVFoundation, Core
Image or files. **Run them before and after any engine change.**

Two things to know:

- **XCTest is not available.** It ships with Xcode, not the Command Line Tools
  this project builds against, so `swift test` cannot link. The suites live in
  `Sources/Recut/Tests` and run from the app binary via `Recut --test`. The
  assertions (`equal`, `close`, `expect`, `greater`, `less`) map one-to-one onto
  XCTest's, so if Xcode ever gets installed, moving them to a real test target
  is mostly a rename plus making the engine a library target.
- **The script builds release.** Santa SIGKILLs the *debug* binary here (exit
  137) while the release one runs fine. `CONFIG=debug ./Scripts/test.sh` if you
  ever need it and Santa allows.

The decoding suite includes the exact regression that prompted it — a project
written before a field existed. Deleting `FrameSettings`' lenient decoder makes
that test fail, so it is known to bite rather than merely pass.

### Rendering

Headless, no permissions needed:

```bash
build/Recut.app/Contents/MacOS/Recut --frames <project.recut> <outdir> 1.5,6.3
build/Recut.app/Contents/MacOS/Recut --render <project.recut> out.mp4 640 30
build/Recut.app/Contents/MacOS/Recut --typing <project.recut> [--apply 2.0]
build/Recut.app/Contents/MacOS/Recut --waveform <project.recut>
```

`--frames` writes composited stills and prints the camera state at each time.
Check the *dimensions and duration* of a render, not just that a file appeared —
that's what caught the decoding bug. `Sources/RecutSample` generates a synthetic
project with a screen track, a webcam track and a cursor track.

When writing a test, keep fixtures clear of a threshold rather than sitting on
it: two identical typing runs at different offsets once landed on opposite sides
of a 1.2s minimum through float rounding alone.

### Audio

The export path is now verified end to end, and it took a purpose-built fixture
to do it. `AVAssetWriter` refused to produce a usable audio fixture by hand (the
sample buffers never became data-ready); what works is `say -o speech.aiff`, or
a sine tone written with Python's `wave`, muxed onto the sample video with
`AVMutableComposition` + `AVAssetExportSession`. Then render and measure.

**Measure a constant tone, not speech.** The first pass compared per-second RMS
of speech before and after, which is unreadable — speech is non-stationary, so
every ratio looked like a bug. A 440 Hz tone at a known amplitude made the real
defect obvious in one glance.

**Beware channel counts when measuring.** Decoding a mono source and a stereo
export both down to mono put a constant √2 into every comparison and looked
exactly like a gain bug. Per-channel levels were identical. Compare like with
like.

The real bug it found: `AVMutableAudioMixInputParameters.setVolume(_:at:)`
**interpolates from the previous set point** rather than stepping. Clips at 100%
and 25% came out as a six-second fade across the first clip. `setVolumeRamp`
with the same volume at both ends of each range gives the step the user asked
for — see `CompositionBuilder.build`.

### Layout

The editor's vertical stack is `frameBar / preview / transport / timeline`, and
only the preview may give way. It needs saying in code as well as in prose: with
five timeline lanes the stack no longer fits the 700pt content minimum, and
SwiftUI's answer to that was to keep the player at its natural size and push the
last lane off the bottom of the window. The fix is a `minHeight` plus
`layoutPriority(1)` on everything *except* the preview — see `EditorView`. Add a
sixth lane and check the minimum window size again.

**Known papercut:** the window never restores its size. `WindowGroup` +
`.frame(minWidth:minHeight:)` reopens at exactly the minimum every launch, and
neither `.defaultSize`, an explicit `idealWidth`/`idealHeight`, nor
`.windowResizability(.contentMinSize)` changed that here — all three were tried
and reverted rather than left in place doing nothing. A `setFrame` from
`AppDelegate.applicationDidFinishLaunching` would work if it becomes worth it.

### Dragging things on the preview

Three separate things make a drag jitter here, and the timeline hit all three.

**1. Coordinate space.** `DragGesture` reports `translation` in the space of the
view it is attached to. All three preview overlays move the very view carrying the gesture,
so measuring locally feeds each frame's movement into the next event's
translation and the shape accelerates away from the pointer — a mask dragged
100pt right and 80pt down came out nearly twice its original size in the wrong
place. **Every drag on the preview must use `coordinateSpace: .global`**, and
anything reading `value.location` rather than a delta has to map the global
point back through `geo.frame(in: .global).origin`. The arithmetic itself lives
in `RectDrag` so the clamping is testable away from the view.

**2. Cumulative, not incremental.** Apply the gesture's *total* translation to a
base captured when the drag began. Adding per-event deltas to the live value
compounds rounding, and it makes any lost event permanent.

**3. Where the base lives.** `@State` inside a row of a `ForEach` is not safe to
hold a drag base in: editing the model rebuilds the rows and resets it. A
`TrimHandle` that tracked "have I begun" locally re-based itself part-way
through and the clip edge ran at roughly 2.5× the pointer. Keep the base in the
enclosing view — `TimelineView.trimState` — which survives the rebuild, and
capture it lazily on the first event rather than in a begin callback.

A fourth thing is specific to this timeline: the lanes fit the *whole* timeline
to the available width, so trimming a clip changes seconds-per-point while the
drag is in flight. The scale is captured with the base and held for the gesture,
otherwise the edge accelerates away from the pointer. Zoom and mask spans don't
change the timeline's duration, so they don't need it.

Selection is the other half of the flicker. `didSet` on an `@Published` fires
even when the value is unchanged, and a drag re-selects the block it is already
on for every event — which was pausing the player and recompositing the preview
sixty times a second. All three selection properties now guard on
`!= oldValue`, and the blocks select once at the start of a drag.

### Microphones

`--mics` exists because none of this is visible from the outside. What the
investigation actually established:

- **The writer is not fussy.** An `AVAssetWriterInput` configured for 48 kHz
  stereo AAC accepts 44.1 kHz, 32 kHz, 16 kHz, 96 kHz, mono, 4-, 8- and
  18-channel input and resamples it correctly. Format mismatch was the obvious
  suspect and it was measured and ruled out — don't spend a second afternoon on
  it. `MicrophoneRecorder.canonicalOutputSettings` stays for predictability, not
  because the writer needs it.
- **Clocks are the real asymmetry.** `AVCaptureSession` stamps its output on
  `synchronizationClock`, which is read-only and, for an external interface, is
  that device's own clock. ScreenCaptureKit stamps video on the host clock and
  `ScreenRecorder` opens the writer session at a *video* timestamp. Mic buffers
  are therefore converted with `CMSyncConvertTime` in `hostTimed(_:)`, per
  buffer so that drift is tracked rather than just the initial offset. Both
  microphones available on this machine turned out to be host-aligned, so the
  divergent case is reasoned from the documented behaviour rather than measured
   — worth re-checking against a real USB interface.
- **The rest was plumbing, and plumbing is what usually breaks**: the device
  list only refreshed inside `refreshDisplays()` (and only with screen-recording
  permission), so a microphone plugged in after launch never appeared; `start()`
  returned early when the session was already running, making a device change a
  no-op; `stop()` skipped its cleanup if `startRunning` was still queued; a
  selection pointing at a vanished device silently recorded nothing; and
  `try? microphone.start(...)` swallowed every failure.

Validation is retried three times: the meter's own session has usually just
released the device, and USB hardware doesn't always let go on the same breath.

### Click capture

Auto-zoom is only as good as the timestamps on the pointer track, and two
things about it are easy to get wrong.

**Global monitors don't work here.** `NSEvent.addGlobalMonitorForEvents` would
hand over the exact moment of each click, but mouse monitors need Input
Monitoring permission, which Recut never asks for. The monitor installs without
complaint and then never fires — verified with `--clicks`, which caught zero
clicks through a monitor and every one of them by polling. That's why the
sampler polls, and it must stay that way unless the app starts requesting the
permission. The scroll and key monitors are kept because there is no polling
alternative for those, and they are best-effort.

**The sampler must not live on the main run loop.** It used to, and both
symptoms of that were reported from real recordings: clicks that never appeared
at all, and clicks dated up to a second late. A press and release that both land
between two ticks is invisible, and main-thread work — writer setup, the
controls appearing, a camera preview starting — stretches the gap between ticks
far beyond one frame. The timestamp came from the tick that noticed the click,
so a stall dated the click by however long it lasted; since auto-zoom eases in
*before* a click, a late click makes a late zoom. It now runs on its own queue
at 120 Hz reading `CGEventSource.buttonState` and `CGEvent(source:)?.location`,
both of which are safe off the main thread — `NSEvent.mouseLocation` and AppKit
are not. Core Graphics measures y from the top of the primary display and
`displayFrame` is in AppKit's bottom-left coordinates, so `primaryMaxY` is
captured on the main thread at `start` and the conversion done in the sampler.

Measured with `--clicks` against `clickseq`, five clicks posted 0.600s apart came
back 0.550 / 0.599 / 0.601 / 0.600 apart — within a tick.

`events` is now touched from two threads (the sampler's queue and the monitors'
main thread), so everything goes through `lock`.

Tracking also starts *before* `stream.startCapture()`, because starting the
stream, opening the microphone and bringing up the camera preview all take time
and a click in that window used to be lost. `finish(timeOrigin:)` rebases
anything early to zero and drops what is more than half a second early.

### Keeping Recut out of its own recording

`SCContentFilter(display:excludingApplications:)` can only exclude applications
handed to it, and those have to come out of `SCShareableContent`. An app that
owns **no windows does not appear there at all** — which is precisely what Recut
is at the moment it builds the filter, having hidden its own window, closed the
countdown, and not yet made the recording controls. The exclusion list came back
empty, nothing was excluded, and the timer and Finish button were filmed along
with the screen.

Two things guard it now, and the ordering is the important one:

- The controls are presented **before** the filter is built, so the application
  reliably owns an on-screen window when `SCShareableContent` is enumerated.
  Moving `presentHUD()` back after `recorder.start(...)` reintroduces the bug.
- The filter's own fetch uses `onScreenWindowsOnly: false`
  (`ScreenRecorder.contentForFiltering`), which is a second chance rather than a
  guarantee — with no window at all the app is missing from that list too. The
  window picker keeps `onScreenWindowsOnly: true`; widening it there brings back
  the junk entries that filter is there to remove.
- If the list still comes back without us, the recorder writes a warning to
  stderr rather than filming the controls silently.

`--exclusion` reports what the filter would see. Run with the app closed it
prints "NOT FOUND", which is the failing state reproduced.

## Where to take it next

- **Widen the test net.** The pure engine is covered; `FrameRenderer` and
  `CompositionBuilder` are not, because they need Core Image and AVFoundation.
  Golden-image tests against checked-in PNGs would catch compositing
  regressions the current suite can't see.
- **Motion blur** on fast camera moves, which is what makes Screen Studio's
  zooms feel expensive.
- **Audio**: silence trimming and background music. The waveform lane and the
  input meter are done; the envelope is cached in `waveform.json` per project.
- **Cursor polish**: distinct pointer shapes (I-beam, pointing hand) rather than
  one arrow; the recorded track has the position but not the type.
- **A real external microphone test.** The clock conversion above is correct by
  construction but has only been exercised against host-aligned devices.
- **Multi-format export in one pass** — a 16:9 for the blog and a 9:16 for
  social from a single render, which is the one thing the marketing pass asked
  for that isn't built.
