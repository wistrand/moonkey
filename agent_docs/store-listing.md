# Connect IQ Store listing — Moonkey

Draft copy + asset checklist for the production store submission. **Production is a
NEW store app with its own permanent id** (`ec31f7e162fb48578ddc754d58d040bb`,
`manifest.xml`): Garmin beta apps are un-publishable, so the existing beta
(`a3f1c2d4e5b649a78c0d1e2f3a4b5c6d`, store GUID
`67405e7d-b4b3-4eda-8d91-557439690e35`) stays as the RC channel and is **not**
promoted. Build the public package with `make package` → `bin/moonkey.iq`, upload
via the normal Submit-an-App flow, and freeze the prod id forever. See
[finding-config.md](finding-config.md) and the identity notes in
[CLAUDE.md](../CLAUDE.md).

## Short summary (one-liner field)
A photographic Moon at the center of an analog face — phase-shaded and tilted to match your sky.

## Full description
Moonkey is an analog watch face for AMOLED Garmin watches, built around a real photograph of the Moon.

The Moon is shaded for tonight's exact phase and rotated to the true inclination it shows in your sky — the terminator tilts the way the real Moon does for your latitude and the time of night, not as a generic icon. A thin ring hugging the disc traces the Moon's time above the horizon, from moonrise to moonset.

Around it, a 24-hour day/night ring puts midnight at the top and noon at the bottom, with an amber arc spanning daylight from your local sunrise to sunset and a pointer at the current time. A soft gradient sun ring brightens toward solar noon.

The hands are told apart by silhouette, not just length: the hour is a tapered baton ending in an open ring, the minute a tapered lance, and the second a white shaft tipped in amber.

The dial carries data fields you choose — heart rate, steps, calories, body battery, intensity minutes, floors, altitude, and more — alongside weather (a clear / cloud / rain / snow / storm / fog glyph, temperature, a precipitation-chance bar, and a meteorological wind barb), the date, the time, and a second-timezone world clock.

Make it yours, all from Garmin Connect:
- Accent and data colours, and the moon-arc colour (or hide the arc)
- The central image — moon, cat, fox, polar bear or seal (each still shows the phase)
- A world timezone for the corner clock, with automatic daylight saving
- Seven configurable fields — pick a complication for each, hide any, or choose a special mode: a Persian Solar date with the Tehran clock, or your own custom text

All of the astronomy is computed on the watch, no internet required, and tracks published almanacs to within a few minutes. The face is always-on aware: it keeps its colors but dims the battery-hungry detail to protect the display.

Location access is used only for sun and Moon calculations — your position stays on the watch and is never transmitted.

## Submission metadata
- **Category:** Watch Face
- **Pricing:** Free (paid would need Monetization / Merchant Onboarding)
- **Languages:** English (eng)
- **Version:** set a real release at upload (e.g. `1.0.0`), not `0.0.1-beta` (no version attr lives in the manifest)
- **Permissions to justify in review:** Positioning (sun/Moon location, on-device only), ComplicationSubscriber (configurable fields)
- **Privacy / GDPR:** no personal data collected or transmitted — location is used on-device only; state this in the listing. No privacy policy required while nothing leaves the watch.

## Asset checklist (TODO before submit)
- [ ] Store icon (separate from the 65x65 launcher icon — supply a proper store image)
- [ ] Screenshots — `data/snap.png` exists; add a couple more, ideally different device shapes (round 416x416, plus a venu3)
- [ ] Optional polish: per-device launcher icons (60/65/70 px via per-device `resourcePath`) to clear the build's scaling warning
- [ ] `make package` -> `bin/moonkey.iq` (8 products / 11 hardware variants) and confirm it runs on the device variants not physically tested

## Tone alternatives (if wanted)
Current tone is utilitarian/precise. A more playful opener could lead with the Moon
("Carry the real Moon on your wrist…"); a shorter variant could drop the hands and
weather paragraphs and keep Moon + configurability.
