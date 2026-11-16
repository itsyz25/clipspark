# ClipSpark Android (APK)

CapCut-inspired, clean-room Android video editor. Kotlin + Jetpack Compose + Media3.

## Status — scaffolded across all modules
- Design tokens (`designsystem/Theme.kt`) mirror the iOS tokens 1:1
- Editor model (`editor/EditorViewModel.kt`): trim/split/speed/reorder/undo/redo,
  transitions enum, overlays, audio volume — same snapshot-undo semantics
- UI (`editor/EditorScreen.kt`, `editor/Drawers.kt`): canvas → state strip →
  center-fixed playhead timeline → tool chips → bottom drawers
- Picker: system Photo Picker (no storage permission, offline)
- Templates: bundled offline recipes (no network)
- Manifest requests **no INTERNET permission** — offline by construction

## Getting the APK
1. Push this folder to GitHub — `Build ClipSpark APK` workflow runs on ubuntu.
2. Download the `ClipSpark-debug-apk` artifact and install it directly.
   (Debug APK: self-signed for testing; add a release signing config later.)

## Local build
```bash
# needs JDK 17 + Android SDK
./gradlew assembleDebug
adb install app/build/outputs/apk/debug/app-debug.apk
```

## Architecture notes (from REA inspection of the official CapCut APK)
Evidence-level observations only — no assets/code copied:
- CapCut Android's engine is native (`libttffmpeg`, `libttmplayer`,
  `libmiddle-bridge`, `libeffect`) with on-device AI (`libbytenn`,
  `libretouch_sdk`) and bundled Lottie/asset packs — i.e., the offline-first
  design is CapCut's own architecture. ClipSpark mirrors that structure with
  Media3 (ExoPlayer preview, Transformer export) on top of Android's own
  hardware codecs.
