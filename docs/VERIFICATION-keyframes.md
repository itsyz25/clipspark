# Verification Report — Keyframes, Variations & Custom Settings (v1.0.1)

**Scope of this unit:** per-clip keyframe animation on both platforms, five keyframe
variation families (hold / linear / 9 easing presets / custom cubic Bézier / spring),
shared custom settings (velocity blend, clamp, reversed), a graph editor with drag +
tap-to-add, keyframe persistence in drafts, and render-pipeline application on iOS.
Clean-room implementation: designed from the *feature surface* observed in CapCut's
shipped bundle (localized strings) and from architecture-level notes in an independent
reference engine. No CapCut code, assets, names, or brand marks were copied.

## 1. Feature diff vs. request

| Requested | Delivered | Where |
|---|---|---|
| Keyframes on clips | 9 keyframable properties: scale, posX, posY, rotation, opacity, volume, brightness, contrast, saturation | `ClipSpark/Editor/Keyframes.swift`, `android/.../editor/Keyframes.kt` |
| Keyframe **variations** | hold, linear, 9 named easings (linear, ease-in, ease-out, ease-in-out, overshoot, bounce, elastic, anticipation, smooth), custom cubic Bézier, damped spring | `CSKeyframeVariation` / `KeyframeVariation` |
| **Custom settings** for variations | velocity blend (0…1), clamp-to-range toggle, reversed (mirrored) toggle; per-variation params: Bézier control points, spring stiffness 1…30 + damping 0.05…1 | shared settings structs + drawer inspector |
| Variation editing UI | iOS: graph with evaluator-sampled curve, playhead, point drag, tap-to-add, inspector | `ClipSpark/Editor/KeyframeDrawer.swift` |
| | Android: property chips, evaluator-sampled curve canvas, tap select/add, drag move, inspector with variant chips + sliders | `android/.../editor/Drawers.kt` (`KeyframeDrawer`) |
| Saved in drafts | iOS `SavedKeyframe` / `SavedKeyframeVariation` (optional → old drafts still load); Android `kfs` array (optional) | `Drafts/DraftStore.swift`, `android/.../drafts/DraftStore.kt` |
| Baked into output | iOS: compositor applies transform + opacity + effective look per track/frame; volume via `setVolumeRamp` in the audio mix, so preview == export | `TransitionCompositor.swift`, `EditorViewModel.buildComposition()` |
| | Android: preview applies transform/opacity via `graphicsLayer` and keyframed volume in the ~12 Hz playhead poll; **export baking remains a documented gap** | `EditorScreen.kt` |
| Undo semantics | one undo step per gesture (drag baseline), single step per discrete edit, split remaps keyframes to both halves | both view models |

## 2. Build check

- iOS (IPA) and Android (APK) are compiled only by GitHub Actions — no Mac/Android SDK
  on this machine. This report is updated with the run IDs when CI finishes.
- Pre-push static audit performed (results in §4 mistake ledger); every issue found was
  fixed before pushing.

## 3. Offline audit

Grep over all app sources for `URLSession`, `NSURLConnection`, `http://`, `https://`,
`INTERNET`, `WebView`, `OkHttp`, `Retrofit`, `socket(`:

- Only hits are XML namespace URIs in Android vector/manifest files and an existing
  comment stating no INTERNET permission is requested.
- `AndroidManifest.xml` declares **zero** `uses-permission` entries.
- Keyframe features are pure math (easing polynomials, spring ODE closed form,
  Bézier bisection) and local JSON — no assets, no network, no cloud.

**Verdict:** offline-only preserved. ✅

## 4. Mistake ledger (found and fixed before push)

| # | Defect | Where | Fix |
|---|---|---|---|
| 1 | `Float / Long` arithmetic (5 sites) — Kotlin has no mixed-type operators → compile error | `Drawers.kt` graph/gestures | Convert `span` with `.toFloat()` at each site |
| 2 | Missing `import Combine` for `ObservableObject` / `@Published` | `Keyframes.swift` | Added import |
| 3 | `.onEditingChanged` used as a Slider modifier (not a modifier in SwiftUI) | `KeyframeDrawer.swift` | Moved into the `Slider(value:in:onEditingChanged:)` initializer |
| 4 | Spring sliders reused the 0…1 curve slider → stiffness clamped to 1 | `KeyframeDrawer.swift` | `curveSlider` gained a range parameter; stiffness 1…30, damping 0.05…1 |
| 5 | `kf.format(kf.time)` — no `format` member on `CSKeyframe` | `KeyframeDrawer.swift` | `String(format: "%.2f", kf.time)` |
| 6 | `return@repeat` did not break the Bézier bisection loop | `Keyframes.kt` | Replaced with a `for` loop + `break` |
| 7 | `result.isFinite` property form used alongside `isFinite()` | `Keyframes.kt` | Standardized on `isFinite()` |
| 8 | Drawer file carried double-encoded UTF-8 (`â€”`, `âœ•`) from earlier tooling | `Drawers.kt` | Reversed via strict cp1252→UTF-8 pass; BOM removed; verified all non-ASCII code points |
| 9 | **Pre-existing:** Android split wrote timeline ms into source fields (wrong at speed ≠ 1) | `EditorViewModel.kt` | Split now multiplies by `speed`; keyframes remapped to both halves |
| 10 | **Pre-existing:** live look/keyframe edits reused stale junctions and spans | `EditorViewModel.swift` | `rebuildComposition` stores junctions/spans/track map; `applyVideoComposition` recomputes spans from current clips |
| 11 | Keyframe remove/clear used an `?? 0` index fallback that could corrupt clip 0 | `EditorViewModel.swift` | Replaced with `guard let index` |
| 12 | Second drag of an already-selected point never opened an undo batch | `KeyframeDrawer.swift` | Explicit `isDraggingPoint` flag opens/finalizes the batch |
| 13 | Android live sliders opened an undo batch but never committed it | `EditorViewModel.kt` / `Drawers.kt` | `updateKeyframeLive` auto-opens; `kfSlider` commits on `onValueChangeFinished` |
| 14 | Tap on an existing point could also add a duplicate keyframe (iOS) | `KeyframeDrawer.swift` | 22 pt hit test guards the add gesture |
| 15 | Version strings still 0.10.0 | `project.yml`, `build.gradle.kts` | 1.0.1 / build 2 |

## 5. Known gaps (honest)

- **Android export does not bake** keyframes, transitions, filters or overlays yet —
  preview is keyframed; exported files are a plain clip concatenation. Documented
  roadmap item (Media3 `Composition` + effects round).
- iOS keyframes apply to **video clips**; text/sticker overlays are drawn by SwiftUI
  and are not keyframable yet.
- Speed keyframes (variable speed curves) are not implemented; speed is per-clip.
- Runtime behavior is unverified until the user sideloads the artifacts — `[UNK]`
  device status, as with v1.0.0.

## 6. Verdict

Static audit: **PASS** (all 15 findings fixed before push).
Build verification: **PENDING CI** — updated below when the IPA/APK workflows finish.
Offline verification: **PASS**.
