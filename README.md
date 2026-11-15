# ClipSpark

CapCut-inspired, clean-room iOS video editor (SwiftUI). "Every cut, instantly."

## Status — Unit 1: designsystem ✅
- Tokens (colors, spacing, radii, type, motion): `ClipSpark/DesignSystem/Tokens.swift`
- Icon registry (30 SF Symbols): `IconSet.swift` · Haptics: `Haptics.swift`
- Components: `Components.swift` · Live style guide: `DesignSystemPreview.swift`

## Getting the IPA
This repo builds an **unsigned IPA** on GitHub's macOS runners:
1. Create a GitHub repo, push this folder.
2. The `Build ClipSpark IPA` workflow runs automatically → download the
   `ClipSpark-unsigned-ipa` artifact.
3. Sign/install via your usual sideloading tool (ESign, Sideloadly, AltStore, TrollStore…).

## Local build (needs a Mac)
```bash
brew install xcodegen
xcodegen generate
open ClipSpark.xcodeproj   # Cmd+R on a simulator
```

## Roadmap (units)
1. ~~designsystem~~ ✅ · 2. ~~home shell~~ ✅ · 3. ~~album picker~~ ✅ · 4. ~~editor skeleton~~ ✅ · 5. ~~trim/split/speed/undo~~ ✅ · 1. ~~designsystem~~ ✅ · 2. ~~home shell~~ ✅ · 3. ~~album picker~~ ✅ · 4. ~~editor skeleton~~ ✅ · 5. ~~trim/split/speed/undo~~ ✅ · 6. ~~media drawers (offline)~~ ✅ · 7. ~~transitions~~ ✅ · 8. ~~export (offline)~~ ✅ · 9. ~~templates (bundled, offline)~~ ✅ · 10. ~~polish + drafts~~ ✅

## Definition of Done — v0.10.0
- ✅ Full flow: import → edit (trim/split/speed/reorder/text/stickers/filters/adjust/transitions/audio mix) → export MP4 (720p/1080p/4K, 30/60fps)
- ✅ 100% offline: no network code anywhere (audited by grep each unit); templates, filters, stickers all on-device
- ✅ Draft persistence: projects autosave as local JSON and reopen from Home
- ✅ Undo/redo (50 steps) across clips, overlays, and look
- ✅ CapCut-inspired clean-room UI: dark editor, center-fixed playhead timeline, tool chips + bottom drawers, haptics on snap/cut
- ⏳ Pending CI build on macOS runner (this repo can't compile Swift on Windows)
(canvas + timeline + playback) → 5. trim/split/undo → 6. media drawers →
7. transitions/effects → 8. export (AVFoundation) → 9. templates → 10. polish
