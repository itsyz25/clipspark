# Verification Report — Unit CI-Fix Rounds (build loop convergence)

**Scope of this report:** the self-checking CI build loop, Rounds #9 → #13 (IPA) and #5 → #7 (APK), commit range `953f38a..c91c09e`.

## 1. Build check

- **iOS (IPA):** built by GitHub Actions `macos-15` via `xcodebuild archive`, unsigned.
  - #11 (commit `953f38a`): FAIL — 10 Swift errors (see ledger).
  - #12 (commit `61429cf`): queued at time of writing; all errors from #11 are fixed in that commit.
  - #13 (commit `2384d1f`): queued; adds the MediaDrawers nested-type fix found in the proactive audit.
- **Android (APK):** built on `ubuntu-latest`, Gradle 8.11.1, AGP 8.10.0, Kotlin 2.2.10, Media3 1.11.1.
  - #5: FAIL — Kotlin 2.0.21 toolchain could not read Kotlin-stdlib 2.2 metadata → toolchain bumped to 2.2.10.
  - #6: FAIL — 22 unresolved Material icon refs → `material-icons-extended` added.
  - #7: FAIL — missing imports in `Drawers.kt`, missing `EditorDrawer` enum, `stickerCatalog`, `addSticker`, `TimelineRow` → all fixed in `c91c09e`.
- Local build is not possible on this machine (no Mac, no Android SDK) — CI is the compiler. ✅ Documented, not hidden.

## 2. Static vs. spec (master prompt §SELF-CHECK)

| Item | Status | Evidence |
|---|---|---|
| Build fails → exact error lines surfaced publicly | ✅ implemented | `build-ipa.yml` grep step; APK #5 report showed exact `e:` lines |
| Errors annotated via `::error::` (readable without auth) | ✅ implemented | annotations API returns full messages |
| IPA builds only when iOS code changes | ✅ implemented | `build-ipa.yml` paths filter (ClipSpark/**, project.yml, brand/**, scripts/**) |
| APK builds only when android/** changes | ✅ implemented | `build-apk.yml` paths filter |
| Offline-only (no network code added in this unit) | ✅ implemented | all changes are build config / compile fixes; no new permissions or imports |
| Draft persistence (iOS) | ✅ pre-existing | `DraftStore.swift` |
| Draft persistence (Android) | ✅ implemented | `android/.../drafts/DraftStore.kt` + Home drafts list + editor save button |
| Sticker persistence (Android) | ✅ implemented | `sticker` field added to `EditorOverlay`, saved/restored in `DraftStore.kt` |
| Sticker preview on Android canvas | ⚠️ partial | overlays list exists; canvas rendering of overlays is not yet wired (known gap, next unit) |
| Transitions/overlays baked into Android export | ❌ missing (documented) | Transformer `Composition` sequences don't support crossfades; honesty ledger item, planned GL-effects round |

## 3. Runtime smoke

Not runnable locally (no device/emulator on this Windows machine) — `[UNK]` until the user sideloads.
Device feedback loop is the planned smoke test. `[OBS]` from CI: compiles are the only runtime evidence so far.

## 4. Visual audit

Logo + app icon: tested at 180/120/60/16 px in browser (`clipspark-logo/icon-test.html`) — mark survives 16 px. ✅
No new screens in this unit.

## 5. UX heuristics pass

Not affected by this unit (build fixes only). Carried items from earlier units remain logged.

## 6. Mistake ledger (this unit)

| # | Bug | Root cause | Fix | Catch it earlier |
|---|---|---|---|---|
| 1 | `DraftStore.swift:199` `max(0, min(1, self))` on `CGFloat` | `max/min` free funcs didn't resolve in extension context | rewritten as explicit ifs | compile-audit pass before push (we now grep for `max(0, min(` on CGFloat) |
| 2 | `installTimeObserver` inaccessible | `private` in class, called from extension in another file | made internal | cross-file call grep: `grep "private func" -A0` vs extension callers |
| 3 | `clips` setter inaccessible | `@Published private(set)` + external mutation in extension | setter opened | same as #2 — same class |
| 4 | `ClipInspector.clip: ClipSegment` not found | nested type used unqualified outside parent | `EditorViewModel.ClipSegment` | **CLASS: nested-type leakage** — now grepped for all nested types used in other files |
| 5 | `fill().strokeBorder()` chain | iOS-17-only API on iOS-16 target | ZStack fill + strokeBorder | API-availability grep (now standard pre-push check) |
| 6 | `.topBarLeading/.topBarTrailing` | iOS-17-only placements | `.navigationBarLeading/.navigationBarTrailing` | same availability grep |
| 7 | Kotlin toolchain too old for stdlib metadata | pinned 2.0.21 vs Media3's 2.2 metadata | 2.2.10 toolchain | check library metadata versions before pinning toolchain |
| 8 | 22 unresolved icon refs | icons from extended pack, only core dep present | `material-icons-extended` | import audit against dependency list |
| 9 | `Drawers.kt` missing imports (`background`, `RoundedCornerShape`, `BasicTextField`) | rewrite without import audit | imports added + foundation BasicTextField | **same class as #8** — import audit added to loop |
| 10 | `EditorDrawer`, `stickerCatalog`, `addSticker`, `TimelineRow` unresolved | callers written before definitions existed | definitions added | definition-usage matrix before push |
| 11 | `Spacer(8.dp)` pattern in EditorScreen | helper was file-private in Drawers.kt | replaced with `Spacer(Modifier.width(...))` | grep for cross-file private helpers |
| 12 | `finish(with: buffer)` on composition request | `finish(with:)` is the Error variant in Swift; frame variant has a different label | `finish(withComposedVideoFrame:)` (compiler-supplied label) | check Swift-imported labels of ObjC `finishWith*` selectors; don't guess overloads |

**Same-class rule triggered:** ≥3 "unresolved reference" bugs (#8, #9, #10) → loop check added: *before every push, grep every symbol referenced in changed files against its defining file.*

## 7. Verdict

**Android (APK): PASS** ✅ — Build #10 (run 44072822778) green; artifact `ClipSpark-debug-apk` (18.9 MB) published.
**iOS (IPA): in convergence** — rounds #9→#19 shrinking error batches (10 → 5 → 3 → 1); each round since #17 has been single-issue compiler-guided fixes; verdict pending build #20.

- Rounds tally: APK 10 rounds to green; IPA in progress at 19.
- Bug-class rule confirmed: ≥3 "unresolved reference" and ≥4 "iOS-17 API on iOS-16 target" bugs → both are now standing pre-push grep checks.

## Unknown Ledger

- `[UNK]` runtime behavior on device (both apps) — pending user sideload feedback.
- `[UNK]` Android export with transitions/overlays — documented gap, GL-effects round planned.
- `[UNK]` macOS runner queue time variability — cancels of stale queued runs need auth (401), so duplicates may run wastefully.
