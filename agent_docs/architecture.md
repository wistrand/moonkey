# Moonkey — architecture

Analog Connect IQ watchface for AMOLED Garmin devices (MARQ 2 / fenix 8). Monkey C.

## Layout
- `MoonkeyApp.mc` — `AppBase`; returns the view.
- `AnalogView.mc` — `WatchFace`; all drawing and computation.
- `resources/` — strings (app name), launcher icon, moon photo.
- `moonkey.jungle` points sources at `src/`. `manifest.xml` lists the target devices and the Positioning permission.

## Render flow (`onUpdate`)
Single full redraw per tick. Order matters for layering: clear → moon → day/night ring → cardinal data fields (incl. wind barb + precip bar) → diagonal radial fields → hands → hand cuts. The moon draws first because its bitmap's opaque corners would otherwise overlap the ring; everything else paints over them.

## Subsystems
- **Hands** — clipped to start outside the ring (no center spoke); each folds in the finer time units for smooth motion. **Differentiated by silhouette, not just length:** hour = tapered amber baton ending in an **open ring** (skeleton/pomme) tip — the longer minute sweeps through it; minute = tapered amber **lance** narrowing to a sharp point; second = white shaft with an amber tip (outer ~20%). A grey-under fill gives hour/minute a polished-bevel edge; the second hand uses a black outline. A thin black mark "cuts" hour/minute where they cross the outer ring, and the second hand at its colour split. `drawHourHand`/`drawMinuteHand` build the bodies from `handRect` (a tapered quad) + `lancePoly` + `drawCircle`; all `fillPolygon` points are integers.
- **Day/night ring** — a 24-hour track with midnight at top, noon at bottom. An amber arc spans daylight (from computed sunrise/sunset); a pointer marks the current time, coloured by whether it's day or night. Surrounded by hour ticks and a gradient "sun ring" whose brightness peaks at solar noon. (Pointer/arc share the *same* angle map — `90 − 15·h` degrees — so they can't disagree; the pointer dot's ~5 px radius is ≈ ~24 min of arc on this small ring, so its edge can touch the sunset boundary while its centre is the true time.)
- **Data fields** — four cardinal readouts (heart rate, steps, weather, time+date) and four diagonal radial-text fields (intensity, floors, UTC, sunrise/sunset), the latter drawn on a curve via a vector font (`drawRadialText`). The **weather** field stacks an icon over the temperature with a thin **precip-chance bar** between them, and a **wind barb** to its left:
  - *Weather glyphs* (`drawWeatherIcon`, all grey): clear (sun), cloud, rain (cloud+streaks), snow (cloud+dots), storm (cloud+lightning bolt), fog (stacked lines). `weatherCategory` buckets all ~54 `Weather.CONDITION_*` codes into those six; **"chance of" rain/snow codes map to `cloud`** on purpose so the precip bar — not the glyph — expresses the probability.
  - *Precip bar* (`drawPrecipBar`): a thin grey bar, fill ∝ `precipitationChance`, shown only when `>= 20%`.
  - *Wind barb* (`drawWindBarb`): a meteorological staff pointing **into** the wind (`windBearing` = direction FROM); feathers encode knots (half 5 / full 10 / pennant 50, capped 60 kt); skipped below 4 m/s (light/calm).
- **Moon** — phase and sky orientation, described below.

## Moon pipeline
The moon is the most involved element:
1. **Phase** — fraction through the synodic month from a known new-moon epoch.
2. **Shaded render (baked)** — the photo is drawn, then the unlit side darkened by a translucent-black overlay whose opacity ramps across the terminator for a soft edge; partial alpha keeps surface texture visible. This per-scanline work is expensive, so it is baked into a cached `BufferedBitmap` and only re-rendered when the hour changes (the phase barely moves between bakes). The bitmap is re-created if the system reclaims it.
3. **Inclination** — the terminator tilts as it appears in the sky: a low-precision sun/moon ephemeris gives the bright-limb position angle, corrected by the parallactic angle for the observer's location. Computed in-code; baked together with the shading **once per hour** (it drifts ~15°/hour, so hourly is plenty — a fresh GPS fix is reflected at the next hourly bake).
4. **Composite** — the **rotation is baked into the buffer**, not done per frame: the upright shaded moon is rendered into a transient scratch buffer, then rotated into the persistent (opaque) display buffer via one `drawBitmap2` transform with a fixed calibration offset (`MOON_TILT_OFFSET`, −90°), point-sampled (not bilinear, to avoid bright-edge bleed). **Every frame is then just a plain `drawBitmap`** — no per-frame ephemeris or rotation (≈1 ms/frame; see Performance).

Why baking: alpha-blended *fills* require `setStroke`/`setFill` (not `setColor`), a rotated terminator can't use axis-aligned scanlines, and palette buffers can't anti-alias — so the shading is baked upright in a full-colour scratch, the disc is rotated into the display buffer, and only the cheap blit happens per frame. The moon source photo has a slightly darkened limb so its bright rim doesn't survive on the shadowed side.

## Location & data sources
- **Moon inclination** uses the observer's GPS (`Position`) first, weather observation point as fallback — so it tracks the real location and the sim's position control. Computed at the hourly bake (not per frame).
- **Sun times** (day/night arc + sunrise/sunset field) use `sunLocation()`, which prefers the **weather observation location** (GPS fallback). This is correct on-device, but in the **simulator** the arc's angle/width can diverge if the simulated weather location isn't your real location — the device is authoritative.
- Sun times, weather (condition, temperature, **`precipitationChance`**, **`windSpeed`/`windBearing`**), HR, steps, floors, intensity from the standard `Weather`/`Activity`/`ActivityMonitor` APIs. There is no moon/astronomy API, so phase and inclination are computed in-code.
- Local-hour mapping (arc, UTC field) converts moments via `Gregorian.info` in the device's clock timezone; a sim timezone that differs from the device shifts the arc position (not its width).

## Always-on (AOD)
The OS dims and pixel-shifts, so colours are kept. Only elements that add lit pixels without at-a-glance value are dropped when sleeping: the moon, second hand, hour ticks, sun ring, radial gradient arcs, hand cuts, filled heart, wind barb, and precip bar. Everything is gated on the sleep flag set by the enter/exit-sleep callbacks. (The hour open-ring and minute lance silhouettes persist in AOD, so the hands stay distinguishable even dimmed.)

## Performance
The whole face is re-rendered every second (the moving hands force it; a full-screen cache won't fit the 128 KB watch-face cap). Profiling (see [perf-analysis.md](perf-analysis.md)) found the per-frame hotspots are **radial vector text** (`drawRadialText`, ~7 ms/label) and **`drawArc`**. Notes:
- **Constant geometry is precomputed once and reused every frame** (no per-frame trig): the parametric heart curve, the 24-hour tick sin/cos, and the gradient-arc per-step angles+colours (`_gradArcs`). This hoists ~350 `sin`/`cos` calls/awake-second out of the redraw.
- **Gradient arcs are real `drawArc`s**, with only their angles/colours precomputed. (Straight `drawLine` **chords** were tried as a cheaper substitute and **reverted** — the faceting and butt-cap seams looked bad; the visual win lost to the cost win.) The sun ring also uses `drawArc`.
- **The moon prebake** (above) cut its per-frame cost to ~1 ms.
- **Radial text can't be cached**: palette buffers can't anti-alias, the full-colour→palette quantize-blit is rejected by the runtime, and four full-colour buffers bust 128 KB. A straight-but-tilted `drawAngledText` replacement (cheaper, native, drops the curve) was tried and **reverted — looked bad**; the curved `drawRadialText` stays.

## Build & config
`make` builds/runs/sideloads (see `Makefile`); `make moon` regenerates the moon bitmap from `data/moon-raw.jpg`. Accent colour / timezone configurability is unresolved — see [finding-config.md](finding-config.md) (sideloaded `.prg` can't use phone-side settings).
