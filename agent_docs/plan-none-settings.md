# Plan: let any complication field be set to "none" (blank)

Goal: allow each configurable field to be turned **off** (rendered blank) from settings,
in addition to picking a complication type.

**Status: Phases 1 & 2 + SW-hide implemented; Phase 3 is now MOOT** — the native
watch-face editor was dropped entirely (`watchface-config.xml` + `AnalogWatchFaceDelegate`
deleted; config is Garmin Connect app settings only), so there is no native "none" path to
build. The `_compNativeOff` precedence layer was removed with it. See the Implementation
phases section.

## The gap
There is no "off" state today. `_compId[slot] == null` currently means **"use the
built-in fallback"** (NW→`sunText`, NE→intensity-minutes, SE→floors, N→heart rate,
S→steps — the original fixed-field behaviour), *not* "blank". Every slot always renders
something (a complication value, a fallback, or `"--"`). So "none" needs a **distinct
third state** that suppresses both the complication value *and* the fallback. The design
hinge is keeping **OFF vs DEFAULT vs SET** distinct so the existing fallbacks still work
for the default case.

## What it touches

### 1. Data model
Add a per-slot off marker — cleanest is a `_compOff[SLOT_COUNT]` boolean array (or a
3-way `_compState[slot] ∈ {OFF, DEFAULT, SET}`). Keep it separate from `_compId == null`
so the default/fallback semantics are unchanged.

### 2. Rendering — three paths skip when off
- **N/S** (`drawCardinalComp`) → return early (no value, no heart icon / label).
- **NE/SE** (`compInline`, used by `drawRadialFields`) → emit `""` so the cached radial
  label draws nothing.
- **NW** (`nwFieldText`) → return `""`.

The radial fields are cached by their text (`_radKey`), so `""` is a valid key and the
buffer re-renders to nothing. The **SW timezone field is not a complication**, so it is
unaffected.

### 3. Connect IQ app settings (Garmin Connect) — the path already in use
Add a **"None"** list entry per slot (`compSE/compNE/compN/compS/compNW`) with a sentinel
code distinct from the existing ones: `0` = "unset / use native", types = `1..19`. Use
`-1` = **none**. `applyCompProp` already gates on `v > 0`; extend it:
- `v == -1` → set `_compOff[slot] = true`
- `v > 0`   → set the type (`_compOff[slot] = false`)
- `v == 0`  → leave (default / let the native config stand)

Needs a `<listEntry value="-1">@Strings.optNone</listEntry>` in each slot's `settings.xml`
list + an `optNone` string. This works immediately on the **beta** (GCM settings).

### 4. Native watch-face editor
Garmin's complication editor usually offers an empty/off choice when you tap a slot, which
comes back as a **null `complicationId`** in `settings.complicationSettings`. But
`AnalogWatchFaceDelegate.onWatchFaceConfigEdited` currently does
`if (cid != null) { setComplication(...) }` — it **silently ignores the clear**. Handle
`cid == null` → set the slot off to light up native-editor "none" too. (Confirm on-device
that the editor actually surfaces a clear action; the GCM path does not depend on it.)

## Scope
- Covers the **seven complication slots** (SE / NE / N / S / NW / W / E = `SLOT_COUNT`),
  once Phase 1 promotes W/E. (Originally five: N / S / NE / SE / NW.)
- **SW is NOT a slot.** There are **8 field positions** (N, NE, E, SE, S, SW, NW, W) but
  only **7 complication slots** — **SW is the timezone / world-clock field** (`swFieldText`,
  driven by the TZ picker / `TZ_OFFSET`/`TZ_LABEL`/`TZ_DST`), living outside the `_compId`
  array. So the none machinery doesn't touch it: **SW cannot be set to none.**
  - *SW-hide — ✅ DONE:* the `tz` app-setting gained a **`-2` = off** sentinel (alongside
    `-1` = unset, `0..16` = zone). `applyProperties` sets `_swOff = (tz == -2)`;
    `swFieldText` returns `""` when `_swOff`, so the SW radial label renders nothing.
    Settings list got a `None` (`-2`) entry. Verified in-sim (forced `_swOff` →
    `SW-utc=""`). Separate from `_compOff` since SW has no slot index. Native-editor
    `<styles>` path has no "off" entry — GCM-only, like the other none paths.

### If W/E become slots, "none" unifies with them
The separate "configurable W (weather) / E (time)" idea promotes those positions to
**slots 5 (W) and 6 (E)** with the composite render kept as the *default*. If that lands,
the **"Off" option proposed for W/E is just this same "none" state** — so don't build a
separate weather-hide boolean. Instead:
- Make the none mechanism a **uniform 7-slot path** (`_compOff[7]`), and W/E's `Off`
  list entry maps to the `-1` none sentinel like everyone else.
- `drawDataFields` already needs a `default → drawComposite() else drawValue()` branch for
  W/E; "none" is simply the third arm: `off → draw nothing`.
- **The clock at E can be set to none too** (decided). The analog hands already show the
  time, so hiding the digital readout is a legitimate choice — e.g. a clean, moon-only
  face. So E is a **full slot with no exemption**: `Time (default) | Date | complication |
  None` (option B from the W/E config), and "none" hides the whole E field (date line
  included), not just a secondary line.

Net: doing W/E-as-slots first means weather/date/time hide **for free** through this
mechanism, rather than as one-off toggles. Every one of the 7 slots — including the clock —
is uniformly nullable.

## Implementation phases
Sequenced per the "W/E-first" decision, so the none mechanism covers all 7 slots in one
pass. Each phase builds and ships to the beta on its own.

### Phase 1 — W/E become slots (configurability, no "none" yet) ✅ DONE
Promote weather (W) and time (E) to **slots 5 & 6**, composite render kept as the default.
- Slot consts `SLOT_W = 5`, `SLOT_E = 6`, `SLOT_COUNT = 7`; grow `_compId` / `_compVal`.
- `drawDataFields`: per-side two-way branch — `default (unset) → drawComposite()` (the
  existing weather widget / date+time) `else → drawValue()`·`compInline()` at that position.
- Curated short lists (**not** `allowAny`): `compW = Weather | Steps | Body Battery |
  Battery`, `compE = Time | Date | Battery | Heart rate`. Add the two `settings.xml`
  entries, `watchface-config.xml` complications id 5/6, and tap-to-select hit areas for the
  W/E fields.
- **Done when:** W/E are configurable; existing installs look identical (composite default).
- **Status:** implemented. `drawSideComp` (label + value) renders a complication at W/E;
  defaults stay weather / date+time. Verified in-sim (default render unchanged; forced
  `_compId[W/E]` renders the value). GCM path uses the same `applyCompProp` loop as the
  other slots. Native-editor `id 5/6` have no default type (= composite) — on-device clear
  behaviour still to confirm.

### Phase 2 — "none" across all 7 slots ✅ DONE
Add the off state uniformly (mechanism in §1–§3 above).
- `_compOff[SLOT_COUNT]` (7) — the OFF vs DEFAULT vs SET marker.
- Render guards: N/S early-return; NE/SE/NW emit `""`; W/E gain the third arm
  `off → draw nothing`.
- Settings: a `None` (`-1`) list entry on **every** slot incl. `compW`/`compE`;
  `applyCompProp` maps `-1 → off`; add the `optNone` string.
- **Done when:** every field — the 5 data slots, weather, and the clock — can be turned off
  from Garmin Connect (clock-off is fine; the analog hands still tell time).
- **Status:** implemented. `_compOff[7]`; `applyCompProp` sets `_compOff = (code == -1)`;
  guards in `drawCardinalComp` (N/S), `compInline` (NE/SE), `nwFieldText` (NW), and the W/E
  `drawDataFields` arms. `None (-1)` entry on all 7 settings lists + `optNone`. Verified
  in-sim: a forced-off slot's field text collapses to `""` (hidden) while neighbours render.
  SW (timezone) is **not** a slot, so it's not covered — see Scope.

### Phase 3 — native-editor "none" ❌ MOOT (native editor dropped)
*(Was implemented, then removed.)* The native watch-face editor is gone, so there is no
on-watch editor "none" to support — Garmin Connect's `None (-1)` is the only path, and it
covers every device. The `_compNativeOff` base, `setComplicationOff`, the delegate's
`cid == null` handling, and the original code below no longer exist.

- Handle `cid == null` in `AnalogWatchFaceDelegate.onWatchFaceConfigEdited` → set the slot
  off (§4). Confirm on-device that the editor surfaces a clear action.
- **Done when:** "none" is reachable from the on-watch editor too, not just GCM.
- **Status:** implemented. Both native paths (`ensureConfig`'s `complicationSettings` loop
  and the live `onWatchFaceConfigEdited`) treat a **null `complicationId` as off**; the
  delegate calls the new `setComplicationOff(slot)`. Precedence is resolved with a
  **`_compNativeOff[7]` base**: GCM `-1` → off, `>0` → type (overrides a native clear),
  **`0` (unset) → defers to `_compNativeOff`**. So the GCM None→Default toggle still clears
  off on editor-less devices (base is false there), *and* a native clear survives a GCM
  unset on fēnix 8. Builds clean on all 8 targets; no in-sim regression. **Still to verify
  on a real fēnix 8:** that the native complication editor actually surfaces a clear/empty
  action (returns `cid == null`) — the GCM path doesn't depend on it.

Phase 2 depends on Phase 1 only for the W/E slots to exist; the 5-slot none could ship
without Phase 1 if W/E are deferred. Phase 3 is independent polish on top of Phase 2.

## Effort / risk
Moderate, low-risk: one off-marker, three one-line render guards, a `settings.xml` entry +
a couple of lines in `applyCompProp`, and one delegate tweak. No schema or API changes.

## Open decisions
1. `_compOff` boolean array vs a 3-way `_compState` enum.
2. Should "None" also be exposed in `watchface-config.xml` somehow, or rely purely on the
   editor's built-in clear action (pending on-device confirmation)?
3. Sequencing: do **W/E-as-slots first**, then this none mechanism covers all 7 slots
   uniformly (weather/date hide falls out of it) — vs. shipping none for the 5 slots now
   and a separate weather toggle later. Former is less total code if both are planned.
