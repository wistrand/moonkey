# Credits

Moonkey is created by **Erik Wistrand** and licensed under the MIT License (see [LICENSE](LICENSE)).

## Artwork
All bundled imagery is the author's and is free to redistribute; no third-party-owned
assets or icons are included.

- The Moon photograph (`data/moon-raw.jpg`) and the baked dial bitmap
  (`resources/drawables/moon.png`) are the author's own photograph.
- The alternate centre images — cat, fox, polar bear and seal
  (`resources/drawables/{cat,fox,polarbear,seal}.png`) are the author's.
- The store/launcher artwork in `docs/` and `resources-launcher/` is generated from the
  Moon photo by the `make store-assets` / `make launcher-icons` targets.

On-device text uses the watch's built-in system/vector fonts supplied by the Garmin
device; no fonts are bundled with the app.

## Astronomy
The ephemeris is implemented independently in `src/Astro.mc` from published algorithms —
no third-party code is included:

- **Moon** position: principal periodic terms from Jean Meeus, *Astronomical Algorithms*
  (chapter 47).
- **Sun** position: Paul Schlyter's low-precision formulae.

Results were cross-checked against the `solunar` ephemeris tool during development.

## Trademarks
Garmin, Connect IQ, fēnix, epix, MARQ, Venu, Forerunner and quatix are trademarks of
Garmin Ltd. Moonkey is an independent project, not affiliated with or endorsed by Garmin.
