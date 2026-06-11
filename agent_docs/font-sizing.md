# Font sizing — proportional vector, calibrated to MARQ 2

## Problem: bitmap `FONT_<size>` varies by device (and sim ≠ device)
The CIQ system bitmap fonts (`FONT_XTINY`/`TINY`/…) are defined **per device in firmware** at
device-chosen pixel sizes that are *not* proportional to the screen. So `getFontHeight(FONT_XTINY)`
returns a different pixel height on each device, and a layout tuned on one device renders out of
proportion on another. Worse, devices use different font *technologies*:

- **MARQ 2** ships pre-rasterized **bitmap** fonts (e.g. xtiny = `FNT_…_ROBOTO_19B`, a 19-px bitmap).
- **fenix 8** ships **scalable TTF** system fonts (Roboto-Regular) sized in a relative unit and
  rasterized to the panel's pixel density at runtime.

Measured `getFontHeight` (in-sim), the reference data behind this design:

| device | resolution | dial radius | XTINY | TINY |
|---|---|---|---|---|
| MARQ 2 | 390×390 | 195 | 29 | 39 |
| fenix 843mm | 416×416 | 208 | 34 | 43 |

fenix's XTINY is **+17 %** but its screen is only **+7 %** larger → text is disproportionately large
there. Because the whole face keyed its typography off `getFontHeight(FONT_XTINY)`, the entire text
layer scaled up on fenix 8 relative to MARQ 2.

Other divergence sources (Garmin forums/docs): the simulator's bundled font metrics can differ from
device firmware (Garmin's changelog repeatedly "fixes sim font sizes to match devices"); **switching
device in a running sim renders stale fonts — restart the sim**; `DeviceSettings.fontScale` and
enhanced-readability mode scale system text on-device (the sim defaults to 1.0); and
`getVectorFont(:size)` glyph height isn't guaranteed exactly equal to the requested px (face/device
specific — though it *was* exact in our sim runs).

## Solution: size all text off the dial radius, calibrated to MARQ 2, render via vector
Reference = **MARQ 2** (the device the layout was tuned on): `REF_RADIUS = 195`, `REF_XTINY = 29`,
`REF_TINY = 39` (its measured `getFontHeight`s). `ensureVectorFont` computes `scale = radius / 195`,
then builds vector fonts proportionally:

| font | size | role |
|---|---|---|
| `_xtinyFont` | `29·scale` | `FONT_XTINY` role |
| `_valueFont` | `39·scale` | `FONT_TINY` role (cardinal/side values) |
| `_labelFont` | `29·scale·0.8` | N/S type labels + the per-field "small values" font |
| `_vectorFont` | `29·scale·1.15` | the four diagonal radial-text fields |

So text keeps MARQ 2's proportion on every device, regardless of that device's bitmap-font sizes.

Drawing routes through three helpers (`AnalogView.mc`):
- **`roleFont(bm)`** — the proportional vector font for a bitmap role (`FONT_TINY`→`_valueFont`,
  `FONT_XTINY`→`_xtinyFont`), or **the bitmap font itself if no scalable face exists** (the fallback).
- **`vfont(font, slot)`** — `roleFont(font)`, or the smaller `_labelFont` when that field's
  `smallValuesN/S/E/W` toggle is on.
- **`fontH(dc, bm)`** = `getFontHeight(roleFont(bm))` — every layout offset measures the *resolved*
  font, so nudges track the rendered glyphs whether vector or bitmap fallback. (All former
  `getFontHeight(FONT_XTINY|cardFont)` layout sites now go through `fontH`.)

## Verification
- **MARQ 2:** renders xtiny/tiny at **29/39** — identical to its bitmap reference, so MARQ 2 is
  size-unchanged.
- **fenix 843mm:** **30/41** (was 34/43) — now MARQ-2-proportional.

The sim's `getVectorFont` rendered at the exact requested px, so no offset correction was needed.

## Caveats / notes
- **Radial fields have no bitmap fallback.** `drawRadialText` requires a `VectorFont`; if no face
  matches (`getVectorFont` returns null) the four diagonal fields silently vanish. (vívoactive 5 was
  dropped partly for this — no system vector fonts.) The cardinal/side *values* do fall back to bitmap.
- **MARQ 2 values changed face, not size.** They previously used the system *bitmap* font and now use
  the vector `RobotoCondensedBold` (same face the radial labels already used) at the same height —
  slightly narrower/bolder. This was an accepted trade for one consistent vector face everywhere.
- venu3 only has `RobotoRegular`; the `faces` fallback list (`RobotoCondensedBold` → … →
  `RobotoRegular`) covers it.
- If a future device's `getVectorFont(:size)` isn't 1:1, add a per-face size offset; `fontH` keeps
  layout consistent regardless.
