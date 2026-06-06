# Performance analysis — Moonkey

Device watch-face memory cap: **128 KB** (`watchFace` appType limit). The whole face is
re-rendered every `onUpdate` (the second hand forces a full redraw; a full-screen cache
≈412 KB @16 bpp won't fit). So per-frame cost is what matters, and the sim hides it (fast
CPU, no per-update execution budget, ~no memory limit).

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

`drawArc`'s 420 calls = gradient arcs (4 fields × 12 segs × 6 = 288) + sun ring (20 × 6 = 120) + day/night track/arc (~12). Per frame: **48 gradient + 20 sun-ring** `drawArc`.

## Findings
1. **Radial text dominates** — `drawRadialText` ≈ **6.9 ms/label**, 4 labels = ~28 ms/frame. It runs as `<Native Code>` (no `Dc.drawRadialText` row). The cost is per-glyph AA rasterization, inherent to drawing curved vector text.
2. **`drawLine` is ~10× cheaper than `drawArc`** (24 µs vs 248 µs) — the basis for the chord optimization.
3. **The moon prebake worked** — rotation+shading baked hourly dropped `drawMoon` to ~1 ms/frame.
4. **`clear` costs ~5.4 ms/frame** — full-screen wipe, unavoidable without partial updates.

## Optimizations applied
- **Gradient arcs → `drawLine` chords** (was `drawArc` sub-arcs). 48 arcs/frame @248 µs → 48 lines @~24 µs ≈ **12 ms → ~1 ms**. Chord deviation at 5°/segment ≈ 0.2 px (invisible).
- **Moon rotation prebaked** into the display buffer hourly → ~1 ms/frame blit.

## Dead ends (don't retry)
- **Caching radial text:** palette `BufferedBitmap`s **can't anti-alias** (Garmin docs); the
  "render AA in full-colour then blit into a palette buffer" trick **fails** — the runtime throws
  *"Bitmap Palette cannot be larger than the target palette"* (it won't quantize, the source
  palette must be a subset of the target); and four **full-colour** buffers (the only AA-capable
  option) exceed 128 KB alongside the moon. So: cached + anti-aliased + fits-memory — pick two.
- **`ALPHA_BLENDING_FULL` buffers**: `drawRadialText`/`drawAngledText` fail to draw into them on AMOLED.

## Remaining levers (not yet done)
- **Radial text (~28 ms):** the big one. Switch curved → straight `drawText` (~0.4 ms/label, ~17× cheaper, loses the curve) or a single `drawAngledText`/label (cheap, tilted-straight, keeps orientation). Char-by-char `drawAngledText` to fake the curve is *not* a reliable win (keeps the per-glyph AA cost, loses batching).
- **Sun ring (~5 ms):** convert to `drawLine` chords like the gradient arcs, but raise segment count to ~36–60 (full 360° at 20 segs would facet ~2.7 px).
- **`clear` (~5.4 ms):** only avoidable via partial-update tricks (not feasible at 128 KB).
