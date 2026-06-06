# Moonkey — Connect IQ analog watchface

Garmin Connect IQ watchface ("Moonkey") in Monkey C. Targets AMOLED: `marq2aviator` (default), `fenix843mm`, `fenix847mm`, `marq2`. `minApiLevel 4.2.1`.

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
- **Always-on (AOD):** the OS dims + pixel-shifts, so colours are kept. Dropped when `_isSleeping`: moon, second hand, hour ticks, sun ring, radial gradient arcs, hand cuts, filled heart; day-arc thinned. Gate every such element on `_isSleeping`.
- `ACCENT_COLOR = DAYLIGHT_COLOR` (amber). `RING_R_FRAC` drives both the day/night ring radius and the hand inner-clip.
- Day/night ring: midnight at top, noon at bottom; amber arc = daylight; pointer colour matches its side.
- Hands clipped to start outside the ring (no center segment); hour hand includes seconds for smooth motion; a black "cut" marks where they cross the outer ring.
- **Moon** (see architecture.md): soft-terminator shaded photo **with the sky-inclination rotation baked in**, into a cached display `BufferedBitmap` **once per hour**; every frame is a plain `drawBitmap` (~1 ms). Inclination = bright-limb PA − parallactic angle (computed in-code at the bake); `MOON_TILT_OFFSET` (−90°) calibrates the baked orientation to the sky.

## Gotchas
- `dc.fillPolygon` only fills with **integer** points (floats render edges only) and is used for the heart curve.
- Radial text needs a `VectorFont` via `getVectorFont` (per-device faces; `RobotoCondensedBold` etc.); fields silently vanish if none match.
- HR for a watchface: `Activity.getActivityInfo().currentHeartRate` (live, on-device) with `ActivityMonitor.getHeartRateHistory` fallback (what the sim feeds).
- `drawTicks` is currently unused (hour marks removed) — kept intentionally.
- **Alpha/blend:** the sim (and direct-to-Dc draws) ignore alpha via `setColor` and ignore blend modes; alpha-blended lines/fills need `setStroke`/`setFill` (32-bit AARRGGBB). A later `setColor` re-takes precedence (no clear method).
- Moon uses `Graphics.createBufferedBitmap` + `drawBitmap2` with an `AffineTransform` (point filter); observer location for inclination is `Position` (GPS) first, weather fallback. Moon source has a darkened limb so its bright rim doesn't survive on the shadowed side.
- **Sun times use `sunLocation()` = weather observation location first** (GPS fallback) — unlike the moon (GPS-first). The device is authoritative; the day/night arc's angle/width can diverge **in the sim** if the simulated weather location isn't your real position. Local-hour mapping uses the device clock timezone, so a sim TZ ≠ device TZ shifts the arc position (not width).
- **Perf (see perf-analysis.md):** 128 KB cap, full redraw each second. `drawRadialText` is the dominant per-frame cost (~7 ms/label) and **can't be cached** — palette buffers don't anti-alias, the full-colour→palette blit is rejected ("Bitmap Palette cannot be larger than the target palette"), and 4 full-colour buffers bust the budget. `drawLine` is ~10× cheaper than `drawArc`, so gradient arcs are drawn as straight chords; the sun ring still uses `drawArc`.

## Conventions
Don't run `deno fmt`/lint or tests; no `sudo`. Match surrounding code style.
