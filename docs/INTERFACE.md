# ABYSS — module interface contract (frozen 2026-08-01 00:00)

> **This is the contract the parallel module agents were built against, kept as
> a historical record. It is NOT the current memory map** — integration moved
> several regions (actors needed 2.6 KB rather than 1 KB, the audio RAM sat
> inside framebuffer B, the actor table clashed with the HUD). For the layout
> the code actually uses, see the memory map in `README.md`, which is the one
> enforced by the nine `ert` assertions in the sources.

Everything below is FIXED. Modules are separate .asm files `icl`'d by main.asm.
Do not edit main.asm; do not use ZP outside your allocated range.

## Memory map
| Region | Use |
|---|---|
| $0080-$00AF | ZP: engine (renderer) — OWNED BY MAIN |
| $00B0-$00CF | ZP: game state (player, weapon, HUD) |
| $00D0-$00EF | ZP: sprites/actors |
| $00F0-$00FF | ZP: shared scratch, caller-saves |
| $0600/$0601 | RENDERS / ALIVE counters (harness reads these) |
| $0602-$06FF | free for module debug counters |
| $2000-$2FFF | engine code + ladders |
| $3000-$3FFF | RAMTAB (init-built tables) |
| $4000-$43FF | display list |
| $5000-$6FFF | generated tables (tables.bin) |
| $7000-$73FF | map, 32x32, 1 byte/cell |
| $8000-$8EFF | FRAMEBUFFER: 40 bytes x 96 rows |
| $9000-$9FFF | sprite/art data |
| $A000-$AFFF | module code |

## Framebuffer
GTIA mode 9. 40 bytes per row, 96 rows. Row r starts at $8000 + r*40.
**One byte = TWO pixels**, each a 4-bit luminance. A value must fill both
nibbles (`$77`) unless you deliberately want a half-step dither (`$78`).
The display shows each buffer row on two scanlines: 80x96 logical, 192 lines.

## Depth buffer
`COLDIST = $3000+448`, 40 bytes, one per column. Value = wall distance for
that column in 1/16-cell units (0..255, 255 = far). A sprite column is
visible only where `sprite_dist < COLDIST[col]`.

## Renderer state you may READ (ZP, engine-owned)
px_lo/px_hi ($80/$81), py_lo/py_hi ($82/$83) — player pos, 8.8 fixed, high
byte = map cell. pang ($84) — facing, 0..255 = full circle.

## Key tables in tables.bin (see src/tables.inc for addresses)
RDX_LO/HI, RDY_LO/HI  — cos/sin per angle, signed 8.8
SHADE_EW / SHADE_NS   — distance -> dithered luminance byte
COL_ANG               — per-column ray angle offset (40)

## Timing contract
The 3D view renders at ~14 fps. A 50 Hz VBI layer owns input, audio, HUD and
weapon position — those MUST NOT be gated on the render rate.
