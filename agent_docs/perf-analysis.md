# Performance analysis — Moonkey

Device watch-face memory cap: **128 KB** (`watchFace` appType limit). The whole face is
re-rendered every `onUpdate` (the second hand forces a full redraw; a full-screen cache
≈412 KB @16 bpp won't fit). So per-frame cost is what matters, and the sim hides it (fast
CPU, no per-update execution budget, ~no memory limit).

**128 KB is a fixed app-*type* policy, not a per-device figure** — verified across every
target (marq2aviator, marq2, fenix843mm/847mm, venu3, epix2pro47mm, fr965): all report
`watchFace = 131072` in their `compiler.json`, while the *same* hardware allows 768 KB for a
`watchApp`, 256–512 KB for datafields/audio. So newer/flagship targets buy **no** extra
watch-face memory; the cap never moves. Shipping a watch *app* (768 KB) is a different product
(not always-on), so not an option.

**But the heap isn't the only memory.** A separate **graphics pool** (CIQ 4, `enhancedGraphicSupport`)
holds `BufferedBitmap`s *outside* the 128 KB — **3 MB** on marq2/fenix8/epix/fr965, **4 MB** on
venu3 (`graphicsResourcePoolSize` in each device's `simulator.json`). Buffers from
`createBufferedBitmap` allocate there, not on the heap. That's where the moon buffers already
live — and now the radial-label cache too (see Optimizations). This is what **overturned the old
"can't cache radial text" dead-end**: it had been sized against the wrong (128 KB) budget.

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
1. **Radial text dominated** — `drawRadialText` ≈ **6.9 ms/label**, 4 labels = ~28 ms/frame. It runs as `<Native Code>` (no `Dc.drawRadialText` row). The cost is per-glyph AA rasterization, inherent to drawing curved vector text. **Now cached** (see Optimizations), so it runs ~once/min instead of every frame.
2. **`drawLine` is ~10× cheaper than `drawArc`** (24 µs vs 248 µs) — motivated the chord experiment for the gradient/sun arcs (since reverted for looks; see below).
3. **The moon prebake worked** — rotation+shading baked hourly dropped `drawMoon` to ~1 ms/frame. The heavier ephemeris added since (Meeus ch.47 position, ~44 terms, + the moonrise/set solve) also runs at the **hourly** bake, so it stays off the per-frame budget.
4. **`clear` costs ~5.4 ms/frame** — full-screen wipe, unavoidable without partial updates.

## Optimizations applied
- **Radial labels + gradient arcs cached in a graphics-pool buffer** — the big one. The four
  curved labels (and the static gradient arcs) are rendered into one transparent dial-sized
  `createBufferedBitmap` (pool, **not** the 128 KB heap; `_radBuf`) and each frame is a single
  `drawBitmap`. The costly `drawRadialText` (~28 ms) + gradient `drawArc` (~8 ms) only run when
  the buffer is rebuilt — i.e. when a label string changes (~once/min) or on a sleep transition.
  The cache **key includes the field text and the sleep flag**, so the arcs (awake-only) bake in
  when awake and drop when asleep. Pool purges are handled: `get()` returns null → re-render
  (same guard the moon uses). Verified by a scratch probe that `drawRadialText` renders into a
  non-palette (and even `ALPHA_BLENDING_FULL`) pool buffer on AMOLED — see Dead ends, corrected.
- **Constant geometry precomputed once, reused every frame** — hoists ~350 `sin`/`cos` calls per awake-second out of the redraw: the parametric **heart curve** (`_heartHx/_heartHy`), the **24-hour tick** sin/cos (`_tickSin/_tickCos`), and the **gradient-arc** per-step angles+colours (`_gradArcs`). Also deduped the hour/minute hand trig (computed `sin`/`cos` once each). Pure math hoisting — pixel-identical.
- **Moon rotation prebaked** into the display buffer hourly → ~1 ms/frame blit.
- **Gradient arcs: chords tried, reverted.** A `drawLine`-chord version (48 arcs/frame @248 µs → 48 lines @~24 µs) was a real CPU win but **looked bad** — chord faceting and butt-cap seams at the arc apex. Reverted to real `drawArc`; only the angles/colours are precomputed, so the per-frame trig is gone but the `drawArc` calls remain. Segment count cut 12 → 8 to claw some of it back.

## Corrected (were "dead ends", now overturned)
- **Caching radial text — now done.** The old objection ("four full-colour buffers exceed 128 KB
  alongside the moon") measured the wrong budget: those buffers live in the **3–4 MB graphics
  pool**, not the heap. And the AA limitation is **palette-only** — full-colour pool buffers *can*
  anti-alias (Garmin docs forbid AA only for *paletted* `BufferedBitmap`s). A scratch probe on
  marq2aviator confirmed `drawRadialText` renders into a non-palette pool buffer (visible,
  anti-aliased). So: cached + anti-aliased + fits-memory is achievable — the pool is the missing leg.
- **`ALPHA_BLENDING_FULL` buffers — did not reproduce.** The earlier "`drawRadialText`/`drawAngledText`
  fail to draw into `ALPHA_BLENDING_FULL` on AMOLED" finding did **not** repro on SDK 9.1.0: the
  probe rendered radial text into an alpha buffer fine, and the live cache uses an
  `ALPHA_BLENDING_FULL` buffer (transparent background) that composites correctly. Likely stale
  (older SDK) or a different path (palette+alpha, or `setStroke` blend).

## Still true (don't retry)
- **Palette buffers can't anti-alias** (and the full-colour→palette quantize-blit is rejected:
  *"Bitmap Palette cannot be larger than the target palette"*). Irrelevant now — the pool removes
  any reason to use palette buffers for this.

## Remaining levers (not yet done)
- **Radial text (~28 ms): DONE** via the pool-buffer cache above — no longer a per-frame cost.
  (Aside: `drawAngledText` straight-tilted text was tried as a *visual* alternative and reverted —
  it looked bad; unrelated to the caching win.)
- **Sun ring (~5 ms):** still drawn live (`drawArc`), in `drawDayNightArc`, awake-only. It could
  **ride the same cache** — it's static like the gradient arcs — but it sits in a different
  function and render position (radius 0.38, over the central ring), so folding it in needs care
  with layering. Not yet done.
- **`clear` (~5.4 ms):** only avoidable via partial-update tricks (not feasible at 128 KB).
