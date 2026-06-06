# Moonkey — Connect IQ analog watchface

Garmin Connect IQ watchface ("Moonkey") in Monkey C. Targets AMOLED: `marq2aviator` (default), `fenix843mm`, `fenix847mm`, `marq2`, `venu3`, `epix2pro47mm`, `fr965`. `minApiLevel 4.2.1`. (vívoactive 5 was evaluated and dropped — no system vector fonts for the radial fields, and no `drawScaledBitmap`/native-format buffer for the moon bake.)

**Full design: [agent_docs/architecture.md](agent_docs/architecture.md).** Profiling & per-frame budget: [agent_docs/perf-analysis.md](agent_docs/perf-analysis.md). Configurability research (accent colour / timezone, sideload constraints): [agent_docs/finding-config.md](agent_docs/finding-config.md).

## Layout
- `manifest.xml`, `moonkey.jungle` at root. **Sources live in `src/`** (not the default `source/`); the jungle sets `base.sourcePath = src`.
- `src/MoonkeyApp.mc` — `AppBase`, returns the view.
- `src/AnalogView.mc` — all the drawing (`WatchFace`).
- `resources/` — strings + launcher icon + moon photo. `bin/` — built `.prg`s (one per device). `agent_docs/` — design + research notes.
- `setup-connectiq.sh` — one-time toolchain setup. `install.sh [device]` — sideload to a watch over MTP. `Makefile` — `make run`/`all`/`install`/`moon` (regenerates the moon bitmap from `data/moon-raw.jpg`).

## Build & run
SDK is managed by `~/go/bin/connect-iq-sdk-manager-cli` (open-source replacement for the GUI SDK Manager). Dev key: `~/.connectiq/developer_key.der`.

```bash
export PATH="$(~/go/bin/connect-iq-sdk-manager-cli sdk current-path --bin):$PATH"
monkeyc -d marq2aviator -f moonkey.jungle -o bin/moonkey-marq2aviator.prg -y ~/.connectiq/developer_key.der -w
connectiq &                                       # start simulator (once)
monkeydo bin/moonkey-marq2aviator.prg marq2aviator # load/reload app
```

- Simulator on Wayland: launch with `GDK_BACKEND=x11`. `monkeydo` cannot switch the device of a running sim — kill and relaunch the sim to change device.
- Devices must be downloaded **with fonts** (`device download -d <id> --include-fonts`) or the sim segfaults rendering text.
- Set HR in the sim via **Simulation → Health Monitoring**; weather/GPS via the Simulation menu (else sun/weather fields show `--`).

## Design notes
- **Always-on (AOD):** the OS dims + pixel-shifts, so colours are kept. Dropped when `_isSleeping`: moon, second hand, hour ticks, sun ring, radial gradient arcs, hand cuts, filled heart, **wind barb, precip bar**; day-arc thinned. Gate every such element on `_isSleeping`.
- `ACCENT_COLOR = DAYLIGHT_COLOR` (amber). `RING_R_FRAC` drives both the day/night ring radius and the hand inner-clip.
- Day/night ring: midnight at top, noon at bottom; amber arc = daylight; pointer colour matches its side. (The current-time pointer is a filled dot whose ~5 px radius ≈ ~24 min of arc on this small ring — so its edge can visually touch sunset while its centre is the true time; not a bug.)
- **Hands clipped to start outside the ring** (no center segment); each folds in the finer time units for smooth motion; a black "cut" marks where hour/minute cross the outer ring. Differentiated by **silhouette**, not just length: hour = tapered amber baton ending in an **open ring** (skeleton/pomme) tip; minute = tapered amber **lance** to a sharp point; second = white shaft with an amber tip (outer ~20%). Grey-under-fill bevel on hour/minute; black outline on the second hand. `drawHourHand`/`drawMinuteHand`, with `handRect` (tapered quad) + `lancePoly` + `drawCircle`.
- **Weather glyphs** (`drawWeatherIcon`, all grey): clear (sun), cloud, rain (cloud+streaks), snow (cloud+dots), **storm (cloud+lightning bolt)**, **fog (stacked lines)**. `weatherCategory` buckets all ~54 `Weather.CONDITION_*` codes; **"chance of" rain/snow codes deliberately map to `cloud`** so the precip bar (not the glyph) carries the probability.
- **Wind barb** (`drawWindBarb`, left of the weather field): meteorological staff pointing **into** the wind (`windBearing` = direction FROM, compass deg); feathers = knots (half 5 / full 10 / pennant 50), capped 60 kt. Skipped entirely below **4 m/s** (light/calm).
- **Precip bar** (`drawPrecipBar`): thin grey bar between glyph and temperature, fill ∝ `precipitationChance`, shown only when `>= 20%`.
- **Moon** (see architecture.md): soft-terminator shaded photo **with the sky-inclination rotation baked in**, into a cached display `BufferedBitmap` **once per hour**; every frame is a plain `drawBitmap` (~1 ms). Inclination = bright-limb PA − parallactic angle (computed in-code at the bake); `MOON_TILT_OFFSET` (−90°) calibrates the baked orientation to the sky.

## Gotchas
- `dc.fillPolygon` only fills with **integer** points (floats render edges only); used for the heart curve and the hand bodies (`handRect` tapered quad, `lancePoly`).
- Radial text needs a `VectorFont` via `getVectorFont` (per-device faces; `RobotoCondensedBold` etc.); fields silently vanish if none match.
- HR for a watchface: `Activity.getActivityInfo().currentHeartRate` (live, on-device) with `ActivityMonitor.getHeartRateHistory` fallback (what the sim feeds).
- `drawTicks` is currently unused (hour marks removed) — kept intentionally.
- **Alpha/blend:** the sim (and direct-to-Dc draws) ignore alpha via `setColor` and ignore blend modes; alpha-blended lines/fills need `setStroke`/`setFill` (32-bit AARRGGBB). A later `setColor` re-takes precedence (no clear method).
- Moon uses `Graphics.createBufferedBitmap` + `drawBitmap2` with an `AffineTransform` (point filter); observer location for inclination is `Position` (GPS) first, weather fallback. Moon source has a darkened limb so its bright rim doesn't survive on the shadowed side.
- **Sun times use `sunLocation()` = weather observation location first** (GPS fallback) — unlike the moon (GPS-first). The device is authoritative; the day/night arc's angle/width can diverge **in the sim** if the simulated weather location isn't your real position. Local-hour mapping uses the device clock timezone, so a sim TZ ≠ device TZ shifts the arc position (not width).
- **Perf (see perf-analysis.md):** 128 KB cap, full redraw each second. `drawRadialText` is the dominant per-frame cost (~7 ms/label) and **can't be cached** — palette buffers don't anti-alias, the full-colour→palette blit is rejected ("Bitmap Palette cannot be larger than the target palette"), and 4 full-colour buffers bust the budget. (`drawAngledText` straight-but-tilted text was tried as a replacement and **reverted** — looked bad.)
- **Constant geometry is precomputed once and reused every frame** (no per-frame trig): the parametric heart curve (`_heartHx/_heartHy`), the 24-hour ring tick sin/cos (`_tickSin/_tickCos`), and the gradient-arc per-step angles+colours (`_gradArcs`). The gradient arcs are drawn as **real `drawArc`s** (straight-`drawLine` chords were tried for cost but **reverted — faceting/seams looked bad**); only the trig is hoisted, not the arc calls. The sun ring also uses `drawArc`.

## Conventions
Don't run `deno fmt`/lint or tests; no `sudo`. Match surrounding code style.
