# Plan: let any complication field be set to "none" (blank)

Goal: allow each configurable field to be turned **off** (rendered blank) from settings,
in addition to picking a complication type. Analysis only so far — not implemented.

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
- Covers the **five complication slots** (N / S / NE / SE / NW).
- **Weather, time, date** are fixed fields, not slots — making *those* hideable is a
  separate, smaller addition (a boolean setting each + a render guard), out of scope here.

## Effort / risk
Moderate, low-risk: one off-marker, three one-line render guards, a `settings.xml` entry +
a couple of lines in `applyCompProp`, and one delegate tweak. No schema or API changes.

## Open decisions
1. `_compOff` boolean array vs a 3-way `_compState` enum.
2. Should "None" also be exposed in `watchface-config.xml` somehow, or rely purely on the
   editor's built-in clear action (pending on-device confirmation)?
3. Do we also want weather/date/time hide toggles (separate feature)?
