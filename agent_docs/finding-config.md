# Finding: on-device configurability (accent / data colour / timezone / complications)

## What shipped (resolution)
We went with **Option C, the native watch-face configuration API** (CIQ 5.1.0) — which this research had flagged as "limited/uncertain," but it turned out to cover everything for the fenix 8 family: `resources/watchface-config.xml` + `Application.WatchFaceConfig.getSettings()`, with `AnalogWatchFaceDelegate.onWatchFaceConfigEdited` for live preview. `marq2` compiles but has no editor, so it falls back to the in-code defaults (the build-time path below still applies there). What's exposed: **accent colour**, **data colour**, a **timezone** picker (the `<styles>` selector repurposed, since the numeric-setting path isn't available to custom faces), and **five complication slots** (selected by tapping the field on the face via `onTap`/`setSelectedComplication`). The open decisions resolved as: accent drives the daylight arc too; the **SW** field is the configurable-TZ clock; DST is computed in-code per rule group (no tz database). See [architecture.md](architecture.md#configuration). The rest of this note is the original research that led there.

## Key constraint — sideloaded settings
Standard Connect IQ app settings (`resources/settings/settings.xml` edited in **Garmin Connect Mobile / Garmin Express**) **do NOT work for a plain file-copy sideload**. The compiled settings JSON is only consumed by GCM/Express for **store-installed or beta** apps.

> "Settings don't work for apps which were sideloaded by just copying the file to the device — you have to upload the app to the store for settings to work."
> — [Garmin forum](https://forums.garmin.com/developer/connect-iq/f/discussion/4805/advice-for-watch-face-with-settings-from-newbie)

On-device "Apply/Customize" is mainly for native faces; the newer **native watch-face configuration API** (SDK 8.1 / CIQ 5.1.0 — our devices support it) targets the native editor and is limited for custom Monkey C faces.
([config-without-customize thread](https://forums.garmin.com/developer/connect-iq/f/discussion/405661/), [AOD watch-face guidelines](https://developer.garmin.com/connect-iq/user-experience-guidelines/watch-faces/))

## Options

### A. Build-time config (recommended — we control the build)
Values compile into the `.prg`; change → `make` → re-sideload.
- **`Application.Properties` + `properties.xml` defaults** — read via `Application.Properties.getValue(...)`. For a raw sideload the **default values** are what apply (GCM can't edit them), so change the default + rebuild. Bonus: editable in the **simulator settings editor**, and instantly phone-editable if ever beta/store-uploaded (no rebuild then).
- **Plain constants / `config.mc`** (or `make ACCENT=0x.. TZ=-5` via a generated file) — simplest, no settings plumbing, no sim UI.

### B. Beta-store upload (only no-rebuild path on a real device)
Upload the `.prg` as a **beta** app (private, no approval) → install via the store → GCM/Express settings become live/runtime-editable. Not a file-copy sideload, but private.

### C. Native config API (CIQ 5.1.0)
Only for true on-device no-rebuild editing; limited/uncertain for custom faces. Not recommended to rely on.

## Setting shapes
- **Accent colour** — settings `list` of named colours → hex (`0xCC5500`…), or numeric hex. Becomes `Properties.getValue("accentColor")`. Note it currently also drives the daylight arc (`ACCENT_COLOR = DAYLIGHT_COLOR`) — decide whether the setting drives both or just hands/marks.
- **LR-field timezone** — numeric **UTC offset** in hours (`-5`, `5.5`, `5.75`) applied to the lower-right field. **No automatic DST** (CIQ has no tz database) — fixed offset or a small named list. Optional second setting for the field label. Confirm target field: SE (currently `FL` floors) vs. the existing SW/UTC field.

## Recommendation
**A via `Application.Properties`** — standard, sim-editable, store/beta-ready, and degrades to "edit default + rebuild" for raw sideload (our loop). Zero-rebuild on-watch changes require **B (beta upload)**.

## Open decisions
1. Does the accent setting drive the daylight arc too, or only the hands/marks/heart?
2. Which radial field becomes the configurable-TZ clock (SE/floors, or repurpose SW/UTC)?
3. Acceptable that changing settings on a sideloaded watch needs a rebuild+re-sideload (option A), or do we want beta-upload (option B)?
