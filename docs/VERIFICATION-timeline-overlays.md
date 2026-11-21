# Verification Report — Draggable Playhead, Pinch Timeline, Multi-Overlay Stack (v1.1.0)

**Scope of this unit:** a real two-platform editing timeline (draggable playhead,
scrub, pinch-zoom, per-overlay lanes with body drag + edge trims), multiple
independently timed text/sticker overlays with their own transform, opacity and
z-order, a contextual tool bar that only shows what applies to the selection, and
genuine adjustable motion blur on both platforms in preview **and** export.
Clean-room: layout and behaviour were designed from the *feature surface* of
CapCut screenshots supplied by the owner; no CapCut code, assets, names or brand
marks were copied.

## 1. Feature diff vs. request

| Requested | Delivered | Where |
|---|---|---|
| Playhead you can drag | iOS: grab zone around the flag, playhead moves with the finger, time follows; Android: same hit-test on a custom `Canvas` | `ClipSpark/Editor/TimelineView.swift`, `android/.../editor/Timeline.kt` |
| Pinch-zoom timeline | iOS `MagnificationGesture` × base pps; Android `calculateZoom()` in `awaitEachGesture`, both anchored on the playhead and clamped (12…220 px/s Android, model clamp iOS) | same files |
| Scrub | Drag anywhere on the strip; content moves under a centred playhead; taps park the playhead | same files |
| Multiple independent overlays | Each overlay = own start/duration, x/y, scale, rotation, opacity; CRUD: add, duplicate, delete, layer ±, start/end at playhead | iOS `EditorViewModel.swift`, Android `EditorViewModel.kt` |
| Overlays on the timeline | One lane per overlay (max 3 shown), body drag slides it in time, edge handles trim start/end, lifted lane block tinted by kind | both timelines |
| Overlays on the canvas | Move / pinch-resize / rotate gestures, dashed selection box, delete handle; type authored against a 400-reference canvas so preview == export | iOS `OverlayItem.swift`, Android `OverlayLayer.kt` |
| Contextual UI matching the screenshots | Top bar (back/undo/redo/split/save/timecode/export), 16:9 preview, fixed-height timeline, 64 dp tool row, bottom-anchored drawer with scrim, drawer never displaces the timeline | `EditorView.swift`, `EditorScreen.kt`, `MediaDrawers.swift`, `Drawers.kt` |
| Adjustable motion blur | iOS `CIMotionBlur` in the shared compositor (radius from amount, angle 0…180°); Android 17-tap directional GLSL effect shared by `ExoPlayer.setVideoEffects` and `Transformer` | `TransitionCompositor.swift`, `android/.../editor/LookEffects.kt` |
| Draft compatibility | New overlay/look fields are optional on load; overlays saved before `scale` existed get `fontSize × 1.7` so they keep their on-screen size | `DraftStore.swift`, `DraftStore.kt` |
| Undo semantics | One undo step per gesture: live updates never write history; the batch is committed on release. Taps no longer create empty undo steps | both view models + gesture code |

## 2. Build check

- iOS (IPA) and Android (APK): GitHub Actions, workflow `build.yml`, version bumped to
  **1.1.0** (`MARKETING_VERSION` / `versionName`), `CURRENT_PROJECT_VERSION = 3`,
  `versionCode = 3`.
- Commit `1850933` (after the two compile fixes below). CI run IDs and results in §7;
  the workflow is the only compiler available on this machine (no local Xcode /
  Android SDK), exactly as in earlier units.
- **PASS** — IPA ✅, APK ✅.

## 3. Offline audit

Grep over `android/app/src` and `ClipSpark/` for `java.net`, `okhttp`,
`HttpURLConnection`, `URLSession`, `NSURLConnection`, `http://`, `https://`,
`INTERNET`, `NSAppTransportSecurity`:

- Only hits are Android XML namespace URIs (`xmlns:android="http://schemas…"`) and
  the manifest comment that says no INTERNET permission is requested.
- `AndroidManifest.xml` declares **zero** `uses-permission` entries.
- Motion blur is a local GLSL program / Core Image filter; overlays are drawn with
  platform text and bitmap APIs; drafts are local JSON. No new assets, no network.

**Verdict:** offline-only preserved. ✅

## 4. Mistake ledger (found and fixed during this unit, pre-push or CI round 1)

| # | Defect | Where | Fix |
|---|---|---|---|
| 1 | Named argument on a Java constructor (`BaseGlShaderProgram(useHdr, texturePoolCapacity = 1)`) — Kotlin forbids named args for Java | `LookEffects.kt` | Positional second argument |
| 2 | `List<TimedBitmapOverlay>` passed to Java `OverlayEffect(List<TextureOverlay>)` — generics are invariant → compile error | `ExportController.kt` | Declared `val timedOverlays: List<TextureOverlay>` so the map is typed at the call site |
| 3 | Trailing-lambda-then-comma syntax in three `OverlaySlider` calls (invalid Kotlin) | `Drawers.kt` | Named `onChange` / `onFinished` arguments |
| 4 | `model.beginOverlayDrag()` on every touch-down made taps push an empty undo step | `Timeline.kt`, `OverlayLayer.kt` | Removed; `updateOverlayLive()` opens the batch on the first real change, `endOverlayDrag()` closes it |
| 5 | Overlay type sizes were authored at preview scale (20 pt) but exported at a different ratio | both platforms | Single reference: `fontSize` is authored against a 400-unit-tall canvas and multiplied by `height/400` in preview **and** export |
| 6 | Editing a text overlay from the drawer bypassed the timeline window (older code appended without start/duration) | `MediaDrawers.swift`, `Drawers.kt` → `addText()` | Drawer now calls the model's `addText`, which assigns start/duration and selects the new overlay |
| 7 | `EditorScreen` wrote Compose state from the Media3 callback thread | `EditorScreen.kt` | Completion is posted to the main `Looper` |
| 8 | Clip lists were mutated in place (trim/speed), so `mutableStateOf` saw an equal list and skipped recomposition | `EditorViewModel.kt` (Android) | `neverEqualPolicy()` on `clips` and `overlays` |
| 9 | Overlay gesture never consumed the down event, so the canvas tap handler could also fire and clear the selection | `OverlayLayer.kt` | Consume the first down; canvas clipped with `clipToBounds()` |
| 10 | Legacy drafts with no `scale` field would render tiny text after the reference-size change | both `DraftStore`s | Detect missing `scale`, multiply the saved size by 1.7 |
| 11 | `moveGesture` / `pinchGesture` declared `some View` although they return `Gesture` (CI round 1, iOS) | `OverlayItem.swift` | `some Gesture` |
| 12 | `fun setLook(Look)` and `var look` generate the same JVM setter `setLook(Look)` → platform declaration clash (CI round 1, Android) | `EditorViewModel.kt` | Removed the unused function; `updateLookLive` / direct assignment cover the call sites |

## 5. What is genuinely implemented vs. still limited

**Implemented (real logic, no mock UI):**

- Time model on both platforms: playhead-anchored scroll, time↔pixel conversion,
  pinch anchor preservation, clamped at both project ends.
- Overlay stack: independent timing/transform, z-order == array order, timeline
  body drag + both edge trims, canvas move/pinch/rotate, delete, duplicate, layer ±.
- Motion blur: shared effect list for preview and export on Android; Core Image
  filter in the iOS compositor that renders both preview and export.
- Android export burns the look, motion blur and every timed overlay into the
  encoded frames (`BitmapOverlay` with per-frame `OverlaySettings` alpha gating).
- iOS export bakes all overlays with a CA keyframe animation for their visibility
  window, in list order, at `renderHeight/400` type scale.
- Drafts persist everything new; old drafts still restore.

**Still limited (documented, not hidden):**

- Android transitions are still not blended by Media3 `Transformer` sequences
  (unchanged from v1.0.1); the preview applies them, the export does not.
- Android per-clip keyframe transforms are evaluated for the preview but not baked
  into the export (keyframed volume is not baked either).
- iOS overlays do not expose keyframes or speed curves; motion blur is global, not
  keyframed.
- Runtime behaviour (GLSL program on device, `PlayerView` + `setVideoEffects`,
  pinch feel, export render) is **not verified locally** — no device/emulator on
  this machine. It is verified by CI compile only and must be confirmed by
  sideloading the artifacts.

## 6. Manual test script (for the owner, after sideload)

1. Import 2–3 clips → preview plays; timeline shows coloured clip blocks.
2. Drag the yellow flag left/right → timecode changes and the preview seeks.
3. Drag on the strip → content scrolls under the playhead.
4. Pinch with two fingers → ruler density changes, playhead stays put.
5. Text → type → Add → overlay appears at the playhead; drag it, pinch it, rotate
   it with the corner/rotate handles; duplicate it; send it back/forward.
6. Add a second overlay and overlap them → both visible, front one drawn last.
7. Drag an overlay block's edges on the timeline → its shown window changes; the
   canvas hides it outside that window.
8. Filters → raise Motion blur and change its angle → preview blurs live.
9. Export → the saved file shows the graded/blurred footage and both overlays at
   the same positions and times as the preview.
10. Drafts → save, reopen → overlays, look and timing restored.

## 7. CI result log

- Baseline before this unit: `241541e` (v1.0.1, both platforms green).
- Unit commit: `59f4766` — CI round 1 **failed on both platforms**; both were
  genuine compile errors introduced by this unit:
  - iOS `OverlayItem.swift`: `moveGesture` / `pinchGesture` were declared
    `some View` but return a `Gesture` — changed to `some Gesture`.
  - Android `EditorViewModel.kt`: `fun setLook(Look)` collided with the JVM
    setter of the `look` property (`setLook`) — the unused function was removed.
- Fix commit: `1850933` — both workflows **green**:
  - `Build ClipSpark IPA` — run [44894983947](https://github.com/itsyz25/clipspark/actions/runs/44894983947) → **success**
  - `Build ClipSpark APK` — run [44894983840](https://github.com/itsyz25/clipspark/actions/runs/44894983840) → **success**
- Artifacts published as release **v1.1.0** (`ClipSpark-debug.apk`, `ClipSpark-unsigned.ipa`).
- Compile-only verification. Runtime behaviour (GLSL blur program, `PlayerView`
  + `setVideoEffects`, pinch feel, export render) still needs the owner to
  sideload and walk §6 — no device/emulator is available here.
