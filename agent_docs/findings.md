# Findings

Diagnostic findings worth keeping (gotchas that cost real time). See also
[finding-config.md](finding-config.md) for the configurability research.

## Simulator resets GPS to lat/lon = 180° after a restart → moon goes haywire (2026-06-07)

**Symptom:** after a few `make sim-restart` cycles, the moon tilt and moonrise/set looked wildly wrong ("off again"), with no code change to the moon math.

**Diagnosis (via a `System.println` in `drawMoon`):** `Position.getInfo().position.toRadians()` returned **lat/lon ≈ π rad = 180°** — an impossible latitude. The simulator had defaulted its simulated position to garbage after the restart. The ephemeris dutifully computed nonsense from it (`tilt=158°`, bogus rise/set). Re-setting a real position (Simulation → Position) restored it, and the values then matched `solunar` exactly (tilt 35.9° = independent Meeus; moonrise/set 01:36/11:32 vs solunar 01:35/11:31).

**Takeaways:**
- The moon math was never broken — **always re-set the sim position after a sim restart**, or the moon is garbage. A real watch never reports invalid coordinates.
- Added a guard: `observerLoc()` now **rejects `|lat| > ~90.5°`** → treated as no location → neutral moon instead of nonsense. Cheap defense against a bad/early fix.
- Debug `println` in a per-frame draw path is invaluable here (lands in `/tmp/monkeydo.log`) but **must be removed after** — this one also called `moonRiseSet()` every frame.

## Simulator persists app Properties in a `.SET` — new `properties.xml` defaults don't override it (2026-06-07)

**Symptom:** changed the `tz` default in `resources/settings/properties.xml` from `-1` to `2` (Stockholm) to test the offline `applyProperties()` path; rebuilt; the SW field still showed UTC.

**Diagnosis (via `System.println` in `applyProperties`, logged to `/tmp/monkeydo.log`):**
`Application.Properties.getValue("tz")` returned **`-1`**, not `2` — even though the freshly-built descriptor (`bin/moonkey-<dev>-settings.json`) correctly had `tz` `defaultValue: 2`. So `applyProperties()` was working; the *property value* it read was stale.

**Root cause:** the simulator persists each app's Properties in a binary store at
`/tmp/com.garmin.connectiq/GARMIN/APPS/SETTINGS/MOONKEY-<DEV>.SET` (keyed by the loaded `.prg` basename). It seeds that store from the compiled defaults **only when the `.SET` doesn't exist**. An earlier run had already seeded `tz = 0xFFFFFFFF` (-1); a new `properties.xml` default never overwrites an already-stored value — same semantics as a real device, where a default only applies if the user hasn't set the property.

**Fix / how to test default changes offline:** delete the persisted store, then reload:
```
rm -f /tmp/com.garmin.connectiq/GARMIN/APPS/SETTINGS/MOONKEY-<DEV>.SET
make run DEVICE=<dev>
```
After clearing, `getValue("tz")` returned `2` and `_tzStyle` became `2` (Stockholm) — confirming `applyProperties()` is correct.

**Related:** the sim's **App Settings Editor** is a `wxWebView` that POSTs the descriptor to Garmin's `appSettings2/sdk/input` and renders the returned form — it needs the IDE (VS Code) push *and* internet, and `monkeydo`/`make run` never hand it the descriptor (it reports "No settings file found"). Editing a `properties.xml` default + clearing the `.SET` is the only fully-offline way to exercise app settings in the sim. Details in [finding-config.md](finding-config.md#testing-app-settings-in-the-simulator).

## Watch face stuck in the low-power draw; and "low power" is a per-minute *burst*, not one tick (2026-06-10)

**Symptom:** on a real fenix 8 **not** in always-on, the face sometimes dropped to the sleeping variant and never came back — touch / wrist-move / buttons didn't restore it.

**Diagnosis:** `_isSleeping` is set only by `onEnterSleep`/`onExitSleep`, and there is **no API to query power mode** (neither `WatchFace` nor `DeviceSettings` exposes it — confirmed in the API docs/forums; `requiresBurnInProtection` is a static capability flag, not live state). A *dropped* `onExitSleep` (a documented AMOLED quirk — the wake-gesture setting can suppress it) therefore strands the flag, with nothing to clear it.

**Fix:** infer power mode from `onUpdate` **cadence** and self-correct. First attempt — "≥2 consecutive fast (<30 s-apart) updates ⇒ awake" — *broke AOD*: the face rendered the full awake variant (moon + frozen second hand) updating once a minute. Instrumenting (`System.println` → `/tmp/monkeydo.log`) showed why:
- awake ≈ **2 updates/sec**;
- the **sleep transition** fires a ~1.5 s burst of rapid updates (the `onEnterSleep` `requestUpdate` + stragglers);
- **steady low power is itself a ~1.5 s burst of ~3 updates each minute**, then a ~58 s gap — `654588,654665,656095` … then `714585,714671,716093` …

So *two* fast intervals occur **every minute**, not just at the transition; any small frame *count* trips. The discriminator is run **duration**: track the start of the consecutive-fast run (`_fastRunStartMs`) and only flip to awake if it lasts **≥5 s** — the per-minute burst (~1.5 s, then a >30 s gap that resets the run) never reaches it, a continuous awake stream does. `onEnterSleep` resets the run.

**Related (same fix set):** the **moon bake** was deferred off the first frame after a wake / cold start (`_deferBake`) — a cold bake (install: `_moonBuf == null`) on the wake frame can overrun the device's per-`onUpdate` budget and throttle back to low power, which *looks* like the stuck-sleep bug. See [architecture.md](architecture.md#always-on-aod) and [perf-analysis.md](perf-analysis.md#wake-frame-cost-not-steady-state).
