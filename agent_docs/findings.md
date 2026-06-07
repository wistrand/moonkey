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
