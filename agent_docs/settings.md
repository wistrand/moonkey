# Moonkey — settings reference

_Generated from `resources/settings/` by `gen-settings-doc.py` (`make settings-doc`) — do not edit by hand._

Values shown are what the property stores, i.e. what an env-var override (`make run` / `make shot` / `make install`) accepts, e.g. `metalHands=true`, `compE=103`, `accentColor=0xFF3030`.

## Accent Color
`accentColor` — Colour of the hands, hour marks, and the day/night arc.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| Amber | `0xFFAA00` |
| White | `0xFFFFFF` |
| Red | `0xFF3030` |
| Orange | `0xFF6600` |
| Yellow | `0xFFDD00` |
| Green | `0x33CC33` |
| Cyan | `0x00DDFF` |
| Blue | `0x3399FF` |
| Purple | `0xBB66FF` |
| Pink | `0xFF55AA` |

## Data Color
`dataColor` — Colour of the data readouts, weather glyph, wind barb, and precip bar.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| Light Gray | `0xAAAAAA` |
| Silver | `0xCCCCCC` |
| White | `0xFFFFFF` |
| Dark Gray | `0x777777` |
| Amber | `0xFFAA00` |
| Cyan | `0x00DDFF` |

## Moon Arc Color
`moonArcColor` — Colour of the arc tracing the moon's time above the horizon. None hides it.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| Dark Gray | `0x777777` |
| Light Gray | `0xAAAAAA` |
| White | `0xFFFFFF` |
| Amber | `0xFFAA00` |

## Moon Image
`moonImage` — Picture at the dial centre, still phase-shaded and tilted like the moon.

Default: **Moon**

| Option | Value |
|---|---|
| Moon | `0` |
| Cat | `1` |
| Fox | `2` |
| Polar Bear | `3` |
| Seal | `4` |

## Custom Text (N field)
`text` — Custom text shown when the N field is set to Show Text.

Free text — default `(empty)`.

## Skip E/W Labels
`skipLabels` — Hide the small grey label on a W or E complication and centre its value.

Toggle — default **Off**.

## Second Ticks
`secTickColor` — Colour of the minute/second tick marks around the edge. None hides them.

Default: **None (off)**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| White | `0xFFFFFF` |
| Light Gray | `0xAAAAAA` |
| Dark Gray | `0x777777` |
| Amber | `0xFFAA00` |

## Radial Gradient
`radialGradient` — Show the soft gradient arcs behind the diagonal data fields.

Toggle — default **On**.

## Small Font: N (top)
`smallValuesN` — Draw this field's value in a smaller font.

Toggle — default **Off**.

## Small Font: S (bottom)
`smallValuesS` — Draw this field's value in a smaller font.

Toggle — default **Off**.

## Small Font: E (right)
`smallValuesE` — Draw this field's value in a smaller font.

Toggle — default **Off**.

## Small Font: W (left)
`smallValuesW` — Draw this field's value in a smaller font.

Toggle — default **Off**.

## Metal Hands
`metalHands` — Give the accent-coloured hands a brushed-metal gradient.

Toggle — default **Off**.

## N/S Markers
`nsMarkers` — Mark south and north on the day/night ring at the sun's meridian crossing (the daylight-arc midpoint).

Toggle — default **Off**.

## Timezone (SW field)
`tz` — Second timezone for the SW corner clock, with automatic DST. None hides it.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| UTC | `0` |
| London | `1` |
| Stockholm | `2` |
| Tehran | `3` |
| Dubai | `4` |
| India | `5` |
| Tokyo | `6` |
| Sydney | `7` |
| New York | `8` |
| Los Angeles | `9` |
| Chicago | `10` |
| Sao Paulo | `11` |
| Moscow | `12` |
| Shanghai | `13` |
| Bangkok | `14` |
| Auckland | `15` |
| Honolulu | `16` |

## SE field (height)
`compSE` — Lower-right field: pick a complication, or hide it.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| Floors Climbed | `9` |
| Altitude | `12` |
| Sea Level Pressure | `13` |

## NE field (energy)
`compNE` — Upper-right field: pick a complication, or hide it.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| Intensity Minutes | `8` |
| Calories | `3` |
| Body Battery | `4` |

## N field
`compN` — Top field: a complication, custom Text, inline Weather, or hidden.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| Show Text | `101` |
| Weather | `102` |
| Heart Rate | `1` |
| Steps | `2` |
| Calories | `3` |
| Body Battery | `4` |
| Stress | `5` |
| Pulse Ox | `6` |
| Respiration | `7` |
| Intensity Minutes | `8` |
| Floors Climbed | `9` |
| Weekly Run Dist | `10` |
| Weekly Bike Dist | `11` |

## S field
`compS` — Bottom field: a complication, Persian Solar, inline Weather, or hidden.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| Persian Solar | `100` |
| Weather | `102` |
| Heart Rate | `1` |
| Steps | `2` |
| Calories | `3` |
| Body Battery | `4` |
| Stress | `5` |
| Pulse Ox | `6` |
| Respiration | `7` |
| Intensity Minutes | `8` |
| Floors Climbed | `9` |
| Weekly Run Dist | `10` |
| Weekly Bike Dist | `11` |

## NW field (time/position)
`compNW` — Upper-left field: pick a complication, or hide it.

Default: **Default**

| Option | Value |
|---|---|
| Default | `-1` |
| None (off) | `-2` |
| Sunset | `15` |
| Sunrise | `14` |
| Date | `16` |
| Weekday + Date | `17` |
| Calendar Events | `18` |
| Battery | `19` |

## W field (weather)
`compW` — Left field: Weather widget, Steps + Heart Rate, a complication, or hidden.

Default: **Weather**

| Option | Value |
|---|---|
| Weather | `-1` |
| None (off) | `-2` |
| Steps + HR | `104` |
| Steps | `2` |
| Body Battery | `4` |
| Battery | `19` |

## E field (time)
`compE` — Right field: Date + time, Persian Solar, Date + Weekday, a complication, or hidden.

Default: **Time**

| Option | Value |
|---|---|
| Time | `-1` |
| None (off) | `-2` |
| Persian Solar | `100` |
| Date + Weekday | `103` |
| Date | `16` |
| Heart Rate | `1` |
| Battery | `19` |

