# Performance analysis — Moonkey

Device watch-face memory cap: **128 KB** (`watchFace` appType limit). The whole face is
re-rendered every `onUpdate` (the second hand forces a full redraw; a full-screen cache
≈412 KB @16 bpp won't fit). So per-frame cost is what matters, and the sim hides it (fast
CPU, no per-update execution budget, ~no memory limit).

**128 KB is a fixed app-*type* policy, not a per-device figure** — verified across every
target (marq2aviator, marq2, fenix843mm/847mm, venu3, epix2pro47mm, fr965): all report
`watchFace = 131072` in their `compiler.json`, while the *same* hardware allows 768 KB for a
`watchApp`, 256–512 KB for datafields/audio. So newer/flagship targets buy **no** extra
watch-face memory; the cap never moves. The only door to >128 KB is shipping a watch *app*
(768 KB) instead of a face — a different product (not always-on, different lifecycle), so not
an option here. The radial-text caching dead-end below therefore stands on all targets.

## Profiler snapshot (6 full-draw frames captured)
Profiler **Call Count is cumulative over all captured frames**; divide by 6 for per-frame.
Use **Actual Time** (self/exclusive), not Total.

| Item | Actual total | Calls | Per call | Per frame |
|---|---|---|---|---|
| `<Native Code>` = `drawRadialText` | 165,899 µs | 24 (=4×6) | **6,912 µs** | **~28 ms** |
| `Dc.drawArc` | 104,066 µs | 420 | 248 µs | ~17 ms |
| `Dc.clear` | 32,365 µs | 6 | 5,394 µs | ~5.4 ms |
| `Dc.fillCircle` | 11,948 µs | 42 | 284 µs | ~2 ms |
| `Dc.drawText` (straight) | 11,870 µs | 30 | **396 µs** | ~2 ms |
| `Dc.drawLine` | 5,438 µs | 228 | **24 µs** | — |
| `drawMoon` (after prebake) | 5,736 µs | 6 | 956 µs | ~1 ms |

`drawArc`'s 420 calls = gradient arcs (4 fields × 12 segs × 6 = 288) + sun ring (20 × 6 = 120) + day/night track/arc (~12). Per frame: **48 gradient + 20 sun-ring** `drawArc`. *(Snapshot is historical: gradient and sun-ring segment counts have since been cut to 8 each, so the live `drawArc` count is lower — ~32 gradient + 8 sun-ring per frame.)*

## Findings
1. **Radial text dominates** — `drawRadialText` ≈ **6.9 ms/label**, 4 labels = ~28 ms/frame. It runs as `<Native Code>` (no `Dc.drawRadialText` row). The cost is per-glyph AA rasterization, inherent to drawing curved vector text.
2. **`drawLine` is ~10× cheaper than `drawArc`** (24 µs vs 248 µs) — motivated the chord experiment for the gradient/sun arcs (since reverted for looks; see below).
3. **The moon prebake worked** — rotation+shading baked hourly dropped `drawMoon` to ~1 ms/frame.
4. **`clear` costs ~5.4 ms/frame** — full-screen wipe, unavoidable without partial updates.

## Optimizations applied
- **Constant geometry precomputed once, reused every frame** — hoists ~350 `sin`/`cos` calls per awake-second out of the redraw: the parametric **heart curve** (`_heartHx/_heartHy`), the **24-hour tick** sin/cos (`_tickSin/_tickCos`), and the **gradient-arc** per-step angles+colours (`_gradArcs`). Also deduped the hour/minute hand trig (computed `sin`/`cos` once each). Pure math hoisting — pixel-identical.
- **Moon rotation prebaked** into the display buffer hourly → ~1 ms/frame blit.
- **Gradient arcs: chords tried, reverted.** A `drawLine`-chord version (48 arcs/frame @248 µs → 48 lines @~24 µs) was a real CPU win but **looked bad** — chord faceting and butt-cap seams at the arc apex. Reverted to real `drawArc`; only the angles/colours are precomputed, so the per-frame trig is gone but the `drawArc` calls remain. Segment count cut 12 → 8 to claw some of it back.

## Dead ends (don't retry)
- **Caching radial text:** palette `BufferedBitmap`s **can't anti-alias** (Garmin docs); the
  "render AA in full-colour then blit into a palette buffer" trick **fails** — the runtime throws
  *"Bitmap Palette cannot be larger than the target palette"* (it won't quantize, the source
  palette must be a subset of the target); and four **full-colour** buffers (the only AA-capable
  option) exceed 128 KB alongside the moon. So: cached + anti-aliased + fits-memory — pick two.
- **`ALPHA_BLENDING_FULL` buffers**: `drawRadialText`/`drawAngledText` fail to draw into them on AMOLED.

## Remaining levers (not yet done)
- **Radial text (~28 ms):** the big one, still open. A single **`drawAngledText`/label** (cheap, native, tilted-straight, drops the curve) was implemented and **reverted — looked bad** as a replacement for the curved look. Straight `drawText` (~0.4 ms/label, loses the curve) remains an option if the curve is ever sacrificed. Char-by-char `drawAngledText` to fake the curve is *not* a reliable win (keeps per-glyph AA cost, loses batching).
- **Sun ring (~5 ms):** converting to `drawLine` chords is the obvious win, but note gradient-arc chords were reverted for looks — the same faceting risk applies, so raise segment count if attempted.
- **`clear` (~5.4 ms):** only avoidable via partial-update tricks (not feasible at 128 KB).
