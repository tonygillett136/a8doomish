# ABYSS — extended map format v1

Authored in `levels/*.lev` (ASCII), compiled by `tools/levels.py`.
Nothing here changes what the renderer does today: the SOLID plane is
byte-identical in meaning to `map0.bin`, so the existing DDA keeps working
untouched. Everything else is additive.

---

## 1. Runtime planes

| Region | Size | Contents |
|---|---|---|
| `$7000-$73FF` | 1024 | **SOLID** plane — 32x32, one byte per cell |
| `$7400-$77FF` | 1024 | **ATTR** plane — 32x32, one byte per cell (NEW — needs a line in INTERFACE.md's memory map) |

The two planes are deliberately `$0400` apart, so the attribute byte for the
cell the DDA just hit costs **one add**:

```asm
        lda mptr+1
        clc
        adc #4          ; same low byte, +4 pages
        sta aptr+1
        lda mptr
        sta aptr
        lda (aptr),y    ; attribute byte
```

### 1.1 SOLID byte — the material id

`$00` **must stay** `$00` for open cells: the DDA is `lda (mptr),y : bne hit`,
so any non-zero byte is a wall. Non-zero values are a material id 1..15.

| id | name | meaning |
|---|---|---|
| `$00` | open | not a wall |
| `$01` | stone | baseline wall |
| `$02` | brick | a shade darker |
| `$03` | metal | pale, reads bright |
| `$04` | flesh | |
| `$05` | tech | panelling, bright |
| `$06` | rock | cavern, dark |
| `$07` | glow | brightest — landmark / light source |
| `$08` | door | unlocked, closed |
| `$09` | door_red | locked, needs RED key |
| `$0A` | door_blue | locked, needs BLUE key |
| `$0B` | door_yellow | locked, needs YELLOW key |
| `$0C` | exitsw | exit switch face |
| `$0D` | secret | renders as stone, opens on use |
| `$0E` | bars | see-through-ish, still solid |
| `$0F` | sealed | renders as stone; **only a trigger opens it** (monster closets) |

Doors and closets are solid bytes, so today's renderer draws and blocks them
for free. **Opening a door is `sta $00` into the SOLID cell.** The door list
(§2.4) keeps the original id so it can be closed again.

**Material shading is live.** `MATBIAS[id]` is added to the shade index exactly
like the light — one 16-byte table plus an `adc`, no extra 256-byte shade pages.

The table is *generated*, not hand-written: `tools/gentables.py` states the
wanted separation in **luminance steps** and converts through the shade ramp's
measured local slope, because at normal play distance that ramp falls only about
0.05 luminance per index unit and hand-picked offsets in the 0-20 range measured
as two visible steps instead of seven.

An offset can only darken, so stone sits mid-table and the shade tables are
**pre-shifted by stone's own bias**. A stone wall therefore looks up exactly the
luminance it would with no material system at all, and everything else deviates
from it in either direction — including *brighter*, which is what makes doors
and the exit findable.

Current values, measured as rendered luminance against a stone wall at the same
distance:

| id | name | vs stone |
|---|---|---|
| `$07` `$0C` | glow, exit switch | **+1.75** — the brightest things in a level |
| `$03` `$05` `$08`-`$0B` | metal, tech, doors | **+0.88** |
| `$01` `$0D` `$0F` | stone, secret, sealed | 0 |
| `$02` `$04` | brick, flesh | **−0.88** |
| `$06` `$0E` | rock, bars | **−1.75** |

`secret` and `sealed` are asserted to render **identically** to stone. They are
walls the player is not meant to be able to spot, and any distinctive shade
would give every one of them away for free. `tools/` has a regression check for
this; do not "improve" their bias.

### 1.2 ATTR byte

```
  bit 7   6   5   4   3   2   1   0
      H   N   S   B   T   \___ L ___/
```

| bits | name | meaning |
|---|---|---|
| 0-2 | **LIGHT** | 0 = pitch black … 7 = full bright |
| 3 | TRIG | entering fires the trigger record with this x,y |
| 4 | BLOCK | blocks actors, invisible to the renderer (ledge lip, closet threshold) |
| 5 | SECRET | counts as a secret the first time it is entered |
| 6 | NOSPAWN | AI hint: monsters may not wander here |
| 7 | HURT | damaging floor (nukage) |

**Light costs one table lookup, as specified.** The recommended
implementation is *light as apparent distance*, which is exactly what DOOM's
light diminishing is:

```asm
        lda (aptr),y
        and #7
        tax
        lda LIGHTOFS,x  ; 8 bytes: e.g. 112,88,68,50,34,20,8,0
        clc
        adc dist
        bcc *+4
        lda #$FF        ; saturate
        tax
        lda SHADE_EW,x
```

Eight bytes of table, one `and`, one indexed load, one `adc`, one branch. The
existing `SHADE_EW` / `SHADE_NS` tables are reused unchanged — no 8x256
per-light shade pages needed.

Floor and ceiling can take the *player's own* cell light, sampled once per
frame rather than per column, indexing the existing `CEILRAMP` / `FLOORRAMP`.

---

## 2. Container file — `src/mapN.lev.bin`

One file per level. RLE'd, so only the level being played is expanded into
`$7000` / `$7400`.

### 2.0 Layout

```
  off   size  field
  ----  ----  -------------------------------------------------------------
  $00      1  magic 'A'  ($41)
  $01      1  magic 'L'  ($4C)
  $02      1  format version = 1
  $03      1  level number (1..4)
  $04      1  spawn cell X
  $05      1  spawn cell Y
  $06      1  spawn angle (0..255, 0 = east, 64 = south)
  $07      1  exit cell X
  $08      1  exit cell Y
  $09      1  n_things
  $0A      1  n_triggers
  $0B      1  n_doors
  $0C      1  default light (0..7) -- for a loader that wants a fallback
  $0D      1  par time, seconds (0 = none)
  $0E      1  total file length, low byte
  $0F      1  total file length, high byte
  $10     16  level name, ASCII, NUL-padded, FIXED WIDTH (no length prefix)
  $20      2  solid RLE stream length (lo, hi)
  $22      L  solid RLE stream      -> expands to exactly 1024 B at $7000
   .       2  attr  RLE stream length (lo, hi)
   .       M  attr  RLE stream      -> expands to exactly 1024 B at $7400
   .   4*n_things    thing records
   .   4*n_triggers  trigger records
   .   4*n_doors     door records
```

Every record is **4 bytes**, so record `k` is at `base + k*4` — two `asl`s,
no multiply.

### 2.1 RLE codec

```
  ctrl $00        end of stream
  ctrl $01..$7F   that many literal bytes follow
  ctrl $80..$FF   run: (ctrl - $7F) copies of the ONE byte that follows  (1..128)

**CAREFUL — there are two RLE encodings in this project and they differ by one.**
The container above (`levels.py`) writes `$7F + run`, so a decoder must take
`ctrl - $7F`. The GAME payload (`genlevels.py` -> `src/levels.bin`, decoded by
`rle_decode` in `game.asm`) writes `$80 | run` and is decoded with `ctrl & $7F`.
Both are internally consistent and the planes round-trip byte-exact; they are
simply not the same format, because the container is a build-time artefact the
runtime never reads. A reviewer reading one and testing the other will conclude
the documentation is wrong. It is not — but the collision is a trap, and if
either is ever touched, check which one you are holding.
```

Decoder, ~30 bytes:

```asm
; src = ZP ptr to stream, dst = ZP ptr to plane
unrle   ldy #0
_next   lda (src),y
        jsr bumpsrc
        cmp #0
        beq _done
        bmi _run
        tax                     ; literal count
_lit    lda (src),y
        jsr bumpsrc
        sta (dst),y
        jsr bumpdst
        dex
        bne _lit
        beq _next
_run    sec
        sbc #$7F
        tax                     ; run length 1..128
        lda (src),y
        jsr bumpsrc
_rl     sta (dst),y
        jsr bumpdst
        dex
        bne _rl
        beq _next
_done   rts
```

Measured compression on the four shipped levels: **1024 B -> 209..350 B**
for the solid plane and **1024 B -> 145..262 B** for the attribute plane.

### 2.2 Thing record — `x, y, type, arg`

| type | name | | type | name |
|---|---|---|---|---|
| `$01` | player start | | `$21` | shell box |
| `$10` | husk (melee) | | `$22` | stimpack |
| `$11` | gunner (hitscan) | | `$23` | medkit |
| `$12` | spitter (projectile) | | `$24` | armour |
| `$13` | hulk (tanky) | | `$30` | shotgun |
| `$1F` | THE MAW (boss) | | `$31` | autogun |
| `$20` | shells | | `$40/$41/$42` | red / blue / yellow key |
| | | | `$50` | barrel (explosive) |
| | | | `$60` | torch (decoration) |

`arg` for **actors** (`$10..$1F`):

```
  bit 0-3  group id 0..15 (0 = ungrouped)
  bit 4    AMBUSH  deaf; wakes on line of sight only
  bit 5    ASLEEP  closet sleeper; wakes only on a WAKE / AMBUSH trigger
  bit 6    HIDDEN  not spawned until a trigger says so
```

`arg` for **items** (`>= $20`) is a quantity override, 0 = the type's default.

### 2.3 Trigger record — `x, y, action, arg`

The ATTR `TRIG` bit marks the cell; the record says what happens. A trigger
*line* is simply several records with the same action and arg. Scanning
`n_triggers` records only happens on the frame the player enters a TRIG cell.

| action | name | arg |
|---|---|---|
| `$01` | DOOR_OPEN | door group — set every cell of that group to `$00` |
| `$02` | DOOR_CLOSE | door group — restore each cell's saved material id |
| `$03` | WAKE | monster group |
| `$04` | EXIT | 0 |
| `$05` | MESSAGE | message id |
| `$06` | AMBUSH | group — DOOR_OPEN *and* WAKE it (the monster-closet macro) |

### 2.4 Door record — `x, y, group, material`

Every `door*`, `secret` and `sealed` cell gets one. `material` is the
original SOLID byte so the cell can be restored on DOOR_CLOSE, and `group`
is what a trigger names. Group 0 = a plain player-openable door.

---

## 3. Cost

| | per level |
|---|---|
| SOLID plane, expanded | 1024 B |
| ATTR plane, expanded | 1024 B |
| record lists | 4 x (things + triggers + doors) = 60..156 B |
| **RAM while playing (one level resident)** | **2108..2204 B** |
| **File in the XEX (RLE'd)** | **450..767 B** |
| **All four levels in the XEX** | **2625 B** |

Only one level is expanded at a time, so the resident cost is a flat ~2.2 KB
regardless of how many levels ship. Adding four more levels costs about
another 2.6 KB of XEX and no extra RAM.

---

## 4. Rules the validator enforces

* **The border ring must be solid.** The DDA has no bounds check and steps
  `mptr` by ±1 / ±32; a ray that escapes the south edge starts reading the
  ATTR plane as walls, and one escaping north reads `$6FE0`. This is an
  error, not a warning.
* Spawn and every thing must sit on an open cell.
* Every locked door has its key somewhere on the level.
* Every `sealed` cell belongs to a group that some trigger opens.
* Exit reachable from spawn, computed as a **key/door fixpoint**: flood with
  the keys currently held, collect newly reachable keys, repeat until stable.
* Warnings for: actors walled off without `asleep`, triggers naming an empty
  group, and open runs longer than 20 cells (the DDA step budget).
