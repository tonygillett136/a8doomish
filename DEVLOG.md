# ABYSS — build log

One night, 2026-07-31 22:07 → 2026-08-01. Everything below is what actually
happened, including the parts that went wrong, because the wrong turns are
where the reusable knowledge is.

---

## The gate

The project opened with a kill criterion: **≥10 fps for a 40-column raycaster
in GTIA mode 9, measured, or stop.** A frame counter in RAM (`RENDERS` at
`$0600`) read back by the headless harness gave a real number rather than an
impression.

First spike: **7.7 fps.** Below the gate. Two bugs and one architectural
mistake explained it.

- **Mode 9 packs two pixels per byte.** Writing a single luminance into a byte
  left every other pixel black — visible as vertical stripes, and it halved the
  apparent brightness. A value has to fill both nibbles (`$77`, not `$07`).
- **The height tables were indexed with the wrong stride.** `build_ramtabs`
  multiplied the table index by 2 to make a page offset, but consecutive
  256-byte tables are one page apart, not two. The lookup landed in garbage,
  which produced an out-of-range wall top, which indexed past the ladder
  address table, which made the code `JSR` to a junk address. One `asl`.
- **The architecture was wrong.** A full-height 192-row repaint costs 39,720
  cycles against a ~24,772-cycle budget — 1.6 frames before a single ray is
  cast.

The fix was 96 buffer rows shown over 192 scanlines. **14.6 fps.** Gate cleared.

## Suffix ladders

Columns are painted by `JSR`-ing into an unrolled chain of
`sta SCREEN+row*40,x` at a computed offset. The wall ladder stores its 96 rows
as symmetric pairs (0, 95, 1, 94, …), so entering at slot *k* paints exactly
rows *k..95−k*: the run length is chosen by the entry point. No loop counter,
no per-pixel compare, no overdraw, 5 cycles a pixel.

Ceiling and floor use plain suffix ladders with their vertical gradient baked
in as **immediate operands** (`lda #$66 / sta …`), which costs 2 cycles a row
and no table fetch.

## The striped display, and undoing half of it

96 buffer rows with a blank scanline between them halves ANTIC's DMA *and* the
fill. But the black lines dominated the picture. Swapping the blank line for a
second LMS pointing at the same row gave up the DMA saving and kept the fill
saving — about 1.5 fps for a picture that no longer looks like a venetian
blind.

## Double buffering

The weapon forced it: the wall pass repaints every row of every column, so a
sprite drawn after it is erased and redrawn constantly. Two framebuffers exactly
`$1000` apart, two ladder sets `$0400` apart, and the set is chosen by *adding
a byte to the dispatch address*. The flip writes the `SDLSTL` **shadow**, so
the OS installs it at vertical blank and the swap is beam-synced for free.

## Bugs worth remembering

**The VBI clobbered the main loop's scratch.** `hud_num` ran at 50 Hz and used
`gt0`–`gt2`; `move_player` used the same three bytes for its collision test. The
player drifted five cells with no input. A VBI must not touch main-loop scratch
— it preempts mid-calculation.

**Zero page overflowed into another module, twice.** The game layer's ZP
allocation was `$B0-$CF`; adding variables silently pushed them into
`$D0-$DF`, which the actor module owns. First time it corrupted the shotgun's
damage (48 instead of 60) and spawned an actor already dead. Second time it
jammed the pain flash on. The fix is a build-time assertion:
`ert * > $D0, "game.asm ZP overflowed"`. Cheap, and it makes the class of bug
impossible rather than merely unlikely.

**A chained DLI needs re-arming every frame.** Three chained handlers
(`dli_1 → dli_2 → dli_3`) with no per-frame reset: one slipped DLI desynced the
chain permanently, `dli_3` cleared GTIA mode mid-view, and the mode-9 bitmap
rendered as 1-bit hi-res — a band of fine vertical stripes. The PLAYBOOK says
"VBI resets the chain"; it is right.

**`SDMCTL = $21` is a NARROW playfield.** 32 bytes a line, while the renderer
wrote 40. ANTIC fetched bytes 0–31 and discarded the rest: 8 of 40 ray columns
computed and thrown away, the view 20% cropped and off-centre, and the aim
point five pixels right of where the crosshair would be. Caught by an
adversarial review agent measuring the mirror-symmetry axis of a corridor
against its predicted position. `$22` costs ~1,500 cycles a frame and is worth
every one.

**Two-pass assembler forward references.** `sta _label+2` where `_label` comes
later makes mads guess zero-page on pass 1 and absolute on pass 2; the code
changes size and addresses never settle ("Infinite loop by label"). Force it
with `a:`.

**A `dta` in an include emits bytes wherever the program counter happens to
be.** The sprite band tables landed at `$240B`, inside ladder set A, and were
then overwritten by it. Generated tables need their own `org`.

**Code silently grew over a fixed `org`.** The engine reached `$23DA`; ladder
set A began at `$2400`. The assembler cheerfully placed the ladders on top of
the tail of `build_dlist` and all of `clear_screen`, and the program still
*ran* — the overwritten code happened to reach an `rts` by luck. The only
symptom was a missing status bar, and it survived several builds before I
noticed. Two lessons: a fixed `org` after code needs an assertion
(`ert * > $2C00, "…"`), and "it still runs" is not evidence that memory is
laid out the way you think.

**Addressing mode changes instruction length, and unrolled code cares.** The
wall ladder's entry offsets assume every pair is exactly 8 bytes. Moving
`wlum2` from zero page to absolute RAM made `lda wlum2` three bytes instead of
two, so half the pairs became 9 bytes and every dispatch landed mid-instruction.
The machine ran wild — instrumentation showed counters *later* in the frame
incrementing more often than the loop head, which is the signature of execution
running through code as data. If a computed jump indexes unrolled code, every
instruction in it must have a pinned size.

## What the agents found

Four subsystems were built in parallel by separate agents against a frozen
interface contract, then integrated by hand.

- **Levels** discovered the most useful thing anyone found: with flat shading,
  *distant walls converge on floor and ceiling luminance and disappear*. Big
  open halls render as featureless bands. Rebuilding every level around
  columned "hypostyle" geometry made the spaces read as architecture **and made
  them faster** (16.5–18.8 fps vs 14.6), because dense near geometry terminates
  rays sooner.
- **Audio** produced a frame-stepped POKEY engine with priority, measured at
  693 cycles worst case, and verified it by dumping the register values it
  emits each frame and recomputing every frequency from the PAL clock. It also
  reported honestly that none of it has been heard.
- **Actor AI** delivered a two-fidelity NPC simulation and a state machine whose
  timings it proved by tracing counters through real runs, and flagged that it
  needed 2.6 KB rather than the 1 KB allocated — a contract violation reported
  rather than hidden.
- **Sprites** delivered no code. The analysis was sound (pre-scaled frames beat
  runtime scaling four to one) but nothing ran, so the renderer was written in
  the main thread instead. Asking for a partial delivery early is what surfaced
  it; the honest "no" was worth more than an optimistic status.

## The flash

In GTIA mode 9 the pixel nibble ORs into COLBK's **low** nibble. Every
reference says keep that nibble zero. Writing a non-zero value instead raises
the luminance *floor* of every pixel on screen — a full-screen brightness flash
in a mode that is not supposed to have one, for four register writes, decayed
over three frames. Emulator-verified; unconfirmed on hardware.

## Wall courses

Flat-shaded walls were the last big visual gap. The wall ladder reloads `A`
from one of two zero-page luminances every row-pair, alternating every second
pair, which gives horizontal masonry courses for ~3 cycles a pair — and
measured **no** frame-rate cost. Reloading every pair also keeps entry at any
pair safe.

## Things tried and reverted

Kept here so they are not re-attempted blind:

- **Adjacent hue bands** (violet/red/orange) with a near-black ceiling. Correct
  in theory — it stops a single wall being painted three colours — but the
  result was monochrome pink with no depth separation.
- **Per-row nibble-swap dithering** on the floor: reads as a hard checkerboard
  in an emulator, and cannot be judged without a CRT.
- **Dark columns at wall-cell boundaries.** Along a *receding* wall every column
  hits a different cell, so nearly every column became an "edge" and the detail
  was erased. Doing it properly needs the fractional hit coordinate.
- **A title screen.** Four attempts destabilised the display. Reverted each
  time. This is the one failure never root-caused, and the reason there is no
  title screen.

## The critics

Three rounds of adversarial visual review, each measuring pixels rather than
giving impressions. The findings that mattered most were ones I would not have
found by looking:

- **`SDMCTL = $21` is a narrow playfield.** Caught by measuring the corridor's
  mirror-symmetry axis against its predicted position and finding it one
  logical pixel off. 20% of the render was being discarded.
- **The husk was camouflaged at range.** Measured mean |ΔY| between sprite
  pixels and the background behind them: 74 in round 1, 30 in round 2 after I
  "improved" the shading. Half the silhouette was the exact luminance of the
  wall. The critic's line — *seeing the monster before it reaches you is the
  thing the entire genre is built on* — was right, and the fix was to floor the
  body luminance rather than shade it consistently.
- **A close husk was three colours**, cyan head and gold legs, because sprites
  crossed the hue-band seams. Sixty-one mis-hued pixels, counted.

## The title screen, on the fifth attempt

Four earlier attempts destabilised the display and were reverted; the README
listed "no title screen" as the one failure never root-caused. It has one now,
and the reason the fifth attempt worked is that it does *less* than the others:

- It does not install a display list. The game's own list and DLI chain are
  already running by the time it is called.
- It does not add work to the main loop. It is called once, between
  `game_init` and the loop, and it simply does not return until FIRE.
- It does not store a background image. A full-screen mode 9 picture is 3,840
  bytes and there were 1,536 free; the gradient is painted by code from a
  twelve-byte ramp, and only the wordmark is stored as row spans.

The general lesson is the one the DLI bugs kept teaching: on this machine the
display is a running mechanism, not a surface. Borrow it, do not rebuild it.

Two real bugs came out of it, both about a 50 Hz interrupt racing a main-line
routine:

**The title's exit press fired the shotgun.** The VBI latches the trigger's
rising edge; the title polls the hardware register directly, so it sees the
press *first*, and clearing the latch is not enough -- the VBI then finds
`trigprv` still zero, calls it a fresh edge and spends a shell. The title has
to claim the edge itself (`trigprv = 1`) before releasing the gate, and the
gate must be cleared *last*, because clearing it first leaves a
one-instruction window in which the VBI can preempt and fire.

## The exit that silently stopped working

The worst bug of the session, and a repeat offender.

Adding five bytes to `vbi_fire` pushed `check_cell` nine bytes past `$3B00`,
which is where `game.asm` resumed after its zero-page block. The assembler laid
`draw_crosshair` on top of `_cc_exit`. No error, no crash, no visible glitch:
the exit simply behaved like a plain wall, and the level progression stopped
working. It would have shipped.

That is the third time a fixed `org` has silently eaten code in this project.
The fix is two-part and both parts matter:

1. **Do not resume at a magic address.** `game.asm` now stashes the program
   counter across its zero-page block (`_code_resume = *`) and resumes exactly
   where the code reached, so there is nothing to overrun.
2. **Assert every remaining boundary.** There are now nine `ert` assertions,
   one per fixed org, and one of them was already wrong before this session:
   the engine was checked against `$2C00` when the level data actually begins
   at `$2500`, 169 bytes away. Each was verified to fire by deliberately
   breaking it.

An assembler that silently overlays code on code is not a tool you can hold
correctly by being careful. It has to be constrained.

## What the critics measured

Three rounds of adversarial visual review scored the picture 4.5, 5.5 and 6.0
out of 10, each round counting pixels rather than giving impressions. Round 3's
findings drove most of the work above, and the numbers are worth recording
because two of them were the opposite of what the code intended:

| | round 3 | now |
|---|---|---|
| ceiling luminance levels | 2 | 7 |
| ceiling flat-pixel fraction | 92.9% | 51.7% |
| floor luminance levels | 3 | 12 |
| floor flat-pixel fraction | 70.0% | 40.6% |
| wall luminance in the wrong hue band | 764 px | 0 px |
| darkest pixel in the viewport | 5 | 0 |
| muzzle flash | ceiling lit one frame LATE | ceiling and walls lit together |

The two instructive ones:

**A sqrt falloff spends its range where nobody is looking.** The ceiling and
floor ramps were correct diminishing-lighting curves that resolved to *two* and
*three* luminance values on screen, because the rows actually visible span
about 1 to 2.5 cells of depth and sqrt is at its flattest exactly there. A
reciprocal put eight and thirteen levels in the same rows for the same zero
cycles, because both ramps are unrolled immediates.

One correction to how this was first written up: the resulting bands do **not**
widen toward the viewer. Row r maps to depth 48/(r+1) and the light is k/d, so
the luminance works out linear in screen row -- the two reciprocals cancel. That
is the correct answer rather than a bug, but "plateaux that widen toward the
viewer" was simply not what the numbers said.

**A wall taller than its hue band spills out of it.** The wall ladder pairs
slot *k* with rows *k* and *95-k*, so slots 0-29 are the only ones that can
ever paint outside the 36-row wall band -- and they were painting there in wall
luminance, which is a bright cyan bar above every near wall and a gold one
below. Emitting dark immediates for those thirty slots removed 764 stray pixels
and is one cycle a slot *faster* than the zero-page load it replaced. The
frame rate went up.

## Materials, and a table that says what it means

The map format always carried a material id per wall cell and the renderer
always ignored it, so every surface in the game was the same surface. Feeding
it through the same apparent-distance trick as the light costs one `adc`.

The first attempt hand-picked offsets in the 0-20 range and measured as **two**
visible steps instead of seven: at normal play distance the shade ramp falls
about 0.05 luminance per index unit, so a "six darker" material was three
hundredths of a level. The table now states the delta it wants *in luminance*
and converts through the ramp's measured local slope, so it means what it says
and keeps meaning it if the ramp is refitted again.

Two details that matter more than the look:

- Because an offset can only darken, stone -- 97% of every map -- has to sit
  mid-table to leave room for materials that read *brighter*. Done naively that
  darkens the whole game by stone's own offset, measured at 1.4 luminance off
  the entire wall band. So the shade tables are **pre-shifted by stone's
  offset**: a stone wall looks up exactly the value it did before materials
  existed, and everything else deviates from it in either direction. The shift
  lives in the generated table; the 6502 does not know it happened.
- `secret` and `sealed` are asserted to render *identically* to stone. They are
  walls the player is not supposed to be able to spot, and any distinctive
  shade would give every one of them away for free.

Doors and the exit switch now read about one and two luminance steps brighter
than the wall they sit in. That is not decoration -- they are the two things a
player actually hunts for.

## The bodies were invisible

The critic's third round said there were no corpses left where you killed
things. That was an inference, and half of it was wrong: dead actors *do* keep
their slot indefinitely, in the corpse pose, and a corpse placed by hand renders
perfectly. What was true is that you never saw one — and measuring found why.

The sprite placement clamped only the sprite's TOP to row 30, to keep a close
husk's head out of the ceiling hue band. A corpse is a flat heap: its art lives
entirely in the bottom seven of twenty-four source rows, so at the largest depth
band it sat at rows 81-101 of a frame the row loop discards above row 66.
**Nothing was drawn at all at two cells** — which is exactly the range you kill
things at. Further away the sprite was short enough to survive by luck.

Two changes:

- Clamp the BOTTOM as well, seating the sprite's feet on the band edge before
  the top clamp gets a say.
- Crop each pose to its own occupied rows before scaling, so the corpse is a
  21-row sprite rather than a 72-row sprite with art in the last nine. That also
  took 745 bytes off the sprite data.

Corpses now draw at every range including point blank, and the standing husk is
pixel-identical to before.

While there: a close husk is still sliced off at row 65, and a hard horizontal
cut across a body reads as a saw line. The cut row is now drawn at rim
luminance, so the figure sinks into shadow instead. That block lives **past the
routine's `rts`** — the first attempt put it inside the row loop, which pushed
that loop's backward branch out of range, and the second parked it just before
the next label, directly on the loop's fall-through path, where it ran on
garbage and stopped every sprite in the game from being drawn. Out-of-line code
has to be genuinely out of line.

## The bug that was making every wall a quarter of its size

The fourth critic round found the worst defect in the project, and it had been
there from early on -- my own changes had simply made it four times worse.

Per-cell light is applied as *apparent distance*: `dist + LIGHTOFS[light]`,
reusing the shade ramp so a dark corridor costs one `adc`. Materials were added
the same way. Both wrote the result **back into `dist`** -- and forty lines
later `dist` is what indexes the wall-height table, and what is written into
the per-column depth buffer the sprites test against.

So the height of a wall depended on how brightly the level designer had lit it
and what stone it was made of. Two cells of the *same flat wall* with different
authored light rendered at different heights. And since every stone wall was
carrying +42 of material bias and +34 of light, every wall in the game was drawn
at roughly a quarter of its correct height.

The measured consequences, before and after keeping the true distance in its own
byte for the geometry:

| | before | after |
|---|---|---|
| viewport change on a 45° turn | 15.1% | **47.4%** |
| wall-band mean luminance | 4.07 | **6.02** |
| wall-band flat-pixel fraction | 28.3% | **23.4%** |

Those are means over a seeded 24-position walk, measured against a control
binary built with only that change reverted -- a **3.1x** improvement. My first
figures for this were 9.0% and 62.1%, which were single positions and looked far
more dramatic than the truth; the same walk ranges from 21% to 76% depending on
where you stand. The fix is one extra zero-page byte and about 240 cycles a
frame, under 0.2%, and it is the difference between a gradient demo and a place.

The lesson is not "be careful with variables". It is that **a value borrowed
for one purpose must not be written back over the value another purpose
depends on.** `dist` meant "distance" to the geometry and "shade index" to the
shading, and nothing in the code said so.

## Things that turned out not to be true

Two of the critic's findings were inferences that measurement did not support,
and chasing them anyway would have been wasted work:

- **"No corpses left where you killed them."** Dead actors *do* hold their slot
  indefinitely in the corpse pose. What was true was that you never saw one --
  for the clipping reason above, which is a different bug with a different fix.
- **"Source and binary have diverged" on the material table.** They agree; the
  reviewer had read a copy out of `.snapshots/`. Regenerating produces the
  shipped bytes exactly.

Both were worth checking rather than either accepting or dismissing. A reported
defect is a hypothesis, not a premise.

## Small things with large returns

- **The victory screen was a whiteout.** `$1C` -- low nibble 12 -- floors every
  pixel at luminance 12, so geometry, weapon and crosshair all vanished and it
  read as a display fault rather than a win. Exactly the mistake already found
  and fixed for the pain flash, sitting untouched in a worse place. Measured
  across the viewport: `$1C` sd 0.94, `$18` sd 2.04, `$14` sd 4.42. `$14` --
  the world still turns to gold and you can still see the room you won in. No
  bytes, no cycles.
- **Every level looked the same.** All four shipped the same hue triple, and
  the floor and ceiling ramps are immediates baked into the ladders, so THE RED
  CISTERN was pixel-identical in two thirds of its frame to THE VESTIBULE.
  Twelve bytes of per-level hue table later, the Silent Colonnade is grey stone
  under a blue vault and the Maw is red under purple. Cheapest art in the build.
- **There was no weapon bob.** `bobph` was declared, zeroed once, and never
  touched again -- the gun was welded to the bottom of the screen, byte-identical
  in every frame ever captured. Sixteen bytes of table and an `inc` in the VBI.
- **The pickups were invisible.** Four per level, collected by standing on the
  exact cell with nothing on screen to say they had ever been there. They are
  billboards like everything else, so the fix was to factor the billboard body
  out of the actor loop and give the item table its own loop over it -- one that
  produces a delta and a pose and hands over. Medkits and shell boxes now read
  as objects on the floor, and the acceptance sweep asserts both that they are
  visible and that they vanish when taken.

## The screenshots were lying

Six of twelve gallery frames showed something other than their filename: four
identical death screens labelled as levels 2, 3, 4 and victory, and a "muzzle
flash" with no flash in it. The captures had run, the files had been written,
and nothing had complained.

Two causes, both about state rather than code. Victory outranks death in the
status logic, so killing the player *after* winning shows the victory screen
forever. And the flash colours are set by the VBI at the end of a frame, so they
only reach the screen on the next one -- sampling immediately caught the frame
before.

The gallery capture now asserts the game is in the claimed state before it saves
each frame, and hashes every file to catch duplicates. It found both of these
itself on the next run. **An unverified screenshot is not evidence**, and a
review conducted on one is worse than no review, because it spends the reviewer
on fiction.

## The same bug, a fourth time — and what actually stops it

Adding the level names to the status bar meant parking a 128-byte table in free
space. `$A980` looked free. It was not: adding two sprite poses had grown the
generated sprite tables from twenty frames to thirty, pushing `POSEMAP` to
`$A987`, and the first eight characters of every level name were quietly
overwritten. The symptom was eight junk glyphs on level 1 only.

The guards added earlier did not catch it, and the reason is worth stating: they
all check that *code does not grow into a fixed org*. This was the opposite —
a fixed org placed **into something else that had grown**. A boundary has two
sides and both need asserting, so generated tables now carry an `ert` at their
end as well as their start.

The one guard that did work, and worked immediately, was the `$4000` one: the
first attempt put the name table inline in `game.asm` and the assembler stopped
with "game.asm has grown into the display lists at $4000" before a single byte
was emitted. That is what these assertions are for — the difference between a
build error and an afternoon.

## The assertion that certified a bug

An adversarial code review of the night's changes found something worse than
anything I had introduced, and the way it survived is the point.

The level RLE blob loads at `$2500` and is 1,654 bytes, so it ends at `$2B75`.
The item table is at `$2B40` — **inside it**. The XEX emits the item segment
after the blob, so at load time the last 54 bytes of level 4's *attribute*
stream are replaced by item coordinates, and 248 of level 4's 1,024 cells have
garbage lighting. The reviewer decoded the corrupt cells and read the item
coordinates straight out of them.

It survived for three separate reasons, and each is worth naming:

1. **The assertion guarded the wrong address.** I had added
   `ert * > $2C00-64` after the blob. The real ceiling was `$2B40`, 128 bytes
   lower. The guard passed, so the layout was certified safe — an assertion
   aimed at the wrong boundary is worse than none, because it stops you looking.
2. **The acceptance test compared the wrong plane.** "Levels 2-4 byte-exact"
   compared only the *solid* plane. The corruption was entirely in the
   *attribute* plane, so all four levels passed byte-exact while a quarter of
   level 4's lighting was rubbish.
3. **Nothing looked wrong.** Light values are masked with `and #7`, so corrupt
   lighting renders as *different* lighting, not as a crash or a stripe.

The blob now lives at `$4800`, in the genuinely free 2 KB between the display
lists and the generated tables; the guard checks `$5000`; and the sweep compares
both planes and reports them separately.

Immediately afterwards I proved the same lesson on myself. Adding a 256-byte
table pushed `tables.bin` from 8,192 to 8,448 bytes — `TABLES` is at `$5000`
and the map is at `$7000`, so the overflow landed on the map and the soak
caught the player at cell 255, outside the world. There is now a generate-time
assertion on the table blob's length, and one on the sprite frames against the
title screen, and both were verified to fire by deliberately breaking them.

Four boundary collisions in one night, in a project that already had a section
in this log about boundary collisions. The conclusion is not that more care was
needed. It is that **every boundary needs an assertion on both sides, and every
assertion needs to be seen to fail once**, because the failure mode is silence.

## The lighting was being read off the wrong cell

Per-cell light is the one genuinely DOOM-shaped feature the engine has, and for
most of the project it did nothing. The critic found why, and it was not the
transfer curve I had spent time re-fitting.

The renderer sampled the light byte of **the wall cell the ray hit**. The level
compiler paints light onto **open** cells — walls are 93-97% a single light
value on every level — so the whole authored lighting design was being read off
the one surface that does not carry it. Re-fitting `LIGHTOFS` was re-fitting the
transfer curve of a signal that is 95% constant.

The fix is to sample the open cell the ray was in when it hit: undo the step the
DDA just took, which `side` already tells you the direction of. It is also the
more truthful of the two — a wall is lit by the room in front of it, not by
itself. About 20 cycles a column, half a per cent of the render.

Measured on level 1: wall-band spread (sd) 2.13 → 2.69, and a short walk now
puts **14 of the 15 available luminances** on the walls. Corridors have lit and
unlit stretches for the first time.

The general shape of this one: I had assumed the defect was in how strongly the
signal was applied, and spent two rounds tuning that. The defect was that the
signal was being read from the wrong place. **Check what you are measuring
before you tune how much of it you use.**

## Sprites drawn in table order

The billboards were depth-clipped against the walls but not against each other,
so the draw order was whichever table slot an actor happened to occupy. Put two
husks in the same column, one at two cells and one at six, and swap their slots:
**94 pixels change**. The far one paints over the near one whenever it is
earlier in the table.

Fixed with a `|dx| + |dy|` key and an insertion sort over at most eight entries,
once a frame — about 0.2 fps. The test is the interesting part: rather than
asserting a particular picture, it asserts **order invariance**. The same two
husks in the same two places with their slots swapped must produce an identical
frame. That is a property the renderer either has or does not, and it cannot be
satisfied by accident.

## The crosshair was lying about where the shot goes

In an 80-pixel-wide view the exact centre falls *between* pixels 39 and 40, so
the horizontal bar straddles both — byte 19's low nibble and byte 20's high
nibble. The vertical ticks only ever wrote byte 19. The cross therefore leaned
one whole pixel left of the bar it was supposed to intersect, on the one piece
of UI whose entire job is to say where the shot is going. Two more nibble
writes.

## Tools that outlived the bug that caused them

- `tools/verify.py` -- the 45-point acceptance sweep, in-process, no
  subprocess, nothing to leave behind. It now asserts on game *state* rather
  than frame counts: the previous version checked "ammo drops by one when you
  fire", which passed for weeks and then failed the day the title screen
  shifted every timing by 83 frames and the player started walking over a shell
  box mid-test. The shotgun was fine; the test was measuring the wrong thing.
- `tools/metrics.py` -- the critics' own measurements, re-runnable against any
  build: per-band luminance mean, spread, level count and flat-pixel fraction,
  stray wall luminance in the wrong hue band, and the muzzle flash frame by
  frame.

- `tools/gallery.py` -- the screenshot set, each frame checked against the game
  state it claims to show and hashed against the others.

The sweep's last two checks are the only ones that measure the *design* rather
than the machine, and they are the ones I would keep if I could keep two:

- **The game can be completed.** Not "does the victory flag set" — an
  autoplayer starts at the title screen, path-finds to each level's real exit,
  fights whatever comes within 3.5 cells, retries on death, and finishes all
  four levels. Measured at **22 shots and 0 deaths** on the seeded run.
- **Level 1 is clearable.** An autoplayer with no map knowledge -- turn toward
  the nearest live enemy, close to shotgun range, fire -- clears all five with
  **five shots and 92 of 100 health**, starting with every enemy already awake.
- **Passive play is punished.** The same situation with no input at all kills
  the player in **37 seconds**.

Together those two numbers are the difficulty curve, and they can regress
silently in a way no rendering metric would catch.

The soak is worth a line of its own. It used to run at the end of the sweep,
which meant it fuzzed the **victory** state -- the one state in which almost
nothing is live. It now boots fresh and plays 5,000 randomised frames on each
of the four levels, and checks that no actor has escaped the map, because an
actor outside it indexes the map out of bounds.

The first two read the colour-register byte straight out of the screen buffer, where the
low nibble *is* the mode 9 pixel luminance, so every number is exact.

## Three wrong answers from hasty tests

Worth recording because the failure mode is the same each time and it is not
obvious: **poking game state from outside does not hold that state**, because
the AI runs between your writes and overwrites it.

- "Corpses do not persist" — the test walked the player for a different number
  of frames in the control run, so the two captures were of different scenes.
  Corpses persist indefinitely.
- "The corpse draws nothing" — true, but only at the range the test happened to
  use. The real bug was the clip, and it appeared and disappeared depending on
  distance.
- "A dormant husk plays a walk cycle" — the test wrote `ST_DORMANT` every ten
  frames, and the husk woke, chased and animated in the gaps. Blocking its line
  of sight with an actual wall and then *leaving it alone* showed what really
  happens: state 0, frame 0, static.

Each of these was a claim I nearly wrote down as fact. The rule that caught all
three: **arrange the condition through the game's own mechanics and then stop
touching it**, and read back the state you are asserting about (here `AC_STATE`
and `AC_LOS`) alongside the thing you are measuring, so a test that has lost
control of its own premise says so.

## Round five: four defects that were in every single frame

The fifth critic round scored 7.0 (from 5.5) and found four things that had been
on screen 100% of the time and that three previous review rounds had missed.

**Nothing in the game was standing on the floor.** Billboards were clamped into
rows 30-65 because that is the wall's hue band. At one cell a medkit's feet sat
**30 buffer rows -- a third of the viewport -- above its own floor line**, and a
corpse was pixel-identical at two and three cells because the clamp pinned it,
so there was no depth cue at all across the range you actually kill things at.
Deleting the row-66 cutoff and the bottom clamp costs *negative* bytes. Corpses
now sit at rows 78-86 at one cell, 66-74 at two and 57-65 at three -- they
recede. A near sprite's feet take the floor's hue, which is where the floor is.

**The fisheye correction was indexed by the wrong divisor.** `GRPTAB` was
generated per *group* of five columns and read with `col>>3`. Entries 5-7 were
never fetched, so the mapping came out monotonic instead of mirror-symmetric and
**the right-hand 40% of the screen got essentially no correction**. A dead-flat
wall bowed by six buffer rows with a 7.8% left/right mismatch. Emitting one
entry per column costs 32 bytes of table and *removes five instructions*:
measured after, **2 rows of bow and exactly 0 rows of asymmetry**. To be exact
about what was fixed: the **indexing**. The correction itself is still eight
column groups sharing four cosine tables, whose worst within-group error is
2.50% -- which is precisely the 1-2 rows of residual bow that remain. Per-column
cosine tables would cost three more 256-byte pages to reach zero.

This is the wall-height bug in a different costume: *a table indexed by a
quantity it was not built for.*

**The last scanline of the 3D view was rendering in the status bar's mode.** The
DLI bit went on the first of each row's two mode lines; ANTIC runs the handler
at the *end* of the line carrying it, so the handover to the text band happened
while buffer row 95 was still on screen. Measured: scanline 215 carried **2
distinct colours** (the HUD's text pair) against 5 on scanline 214 -- a bright
dashed line across the full width of every frame ever captured. Moving the bit
to the second mode line also corrects both hue seams, a scanline early for the
same reason.

**The vignette had grown into the ramps it sits against.** Re-fitted after the
wall-height fix, the caps were allowed to reach luminance 6 while the ceiling
ramp bottoms out at 4 and the floor starts at 5. They crossed, and at 2.8 cells
the wall's own silhouette measured **zero luminance steps** of edge contrast
with the top edge *inverted* -- so the eye read the hue seam at row 30 as the
wall's top, a dead straight line up to six rows below the real one, at exactly
the range where you decide whether to turn. Clamping the cap two steps below
whichever ramp it abuts is a change of immediates: same instructions, and edge
contrast is now never below 2.

Two smaller ones from the same round. The screen kick *halved* each frame
(6-3-1-0, 60 ms) against an 88 ms render period, so seven shots in twenty showed
no kick at all. A linear decay gives 5 non-zero frames = 100 ms against an 89 ms
render period, which is **1.12 renders** -- measured over eight shots, seven put
the kick in exactly one render and one in two. It is a real improvement on
"usually none"; it is not the "spans two renders" an earlier draft of this log
claimed, and the arithmetic never supported that. And the muzzle flash's
white-hot first step was unreachable, because `wstate` is decremented earlier in
the same VBI and the test compared against its pre-decrement value -- the flash
had been two frames rather than three since the day it was written.

Finally, two of the four levels were single-hue washes and two levels' walls
were 19 RGB apart out of 441. The hue triples are re-picked and the rule is now
**asserted**: at least 60 RGB between a level's own ceiling and wall, 30 between
its wall and floor, 50 between any two levels' walls. Worst case is now 86 and
64. THE MAW is a bilious green gullet under purple with a raw red floor; nobody
will mistake it for THE VESTIBULE.

## Round six: the room was finished, so the things in it became the problem

7.5, from 7.0, and the verdict was sharp: *"a genuinely good-looking corridor
renderer with placeholder actors in it."* Every remaining first-rank defect was
on the objects, not the architecture.

**A regression I had just introduced.** Restoring the muzzle flash's white-hot
first step made that frame a total whiteout. `$1E`'s low nibble is 14, and since
the nibble is a luminance FLOOR, every pixel becomes 14 or 15: the picture does
not brighten, it **ceases to exist** for one 20 ms frame, and the gallery shipped
a screenshot containing literally no information. Measured luminance counts for
the whole viewport: `$1E` 2, `$1C` 3, `$1A` 5, `$16` 9, `$14` 11. The flash now
opens at `$1A` and decays `$16`, `$14` -- still a clear spike over the usual mean
of 7.3, with the room legible in every frame of it. There is now an assertion
that no flash frame may drop below four luminances.

**Sprite size was quantised to five bands, and the nearest one was pinned.** A
husk measured *pixel-identical from 1.00 to 1.75 cells*, then jumped 45% in a
single frame, and was **larger at 6 cells than at 4**. Two causes, and the
second was the real one:

- the row-30 top clamp always fires for the largest band, so nothing in that
  band could move or change size at all;
- and the distance itself was computed from the delta's **high bytes only** --
  whole cells. Every downstream lookup, including the height, could therefore
  only change once per cell.

Fixing the distance to sixteenths of a cell and scaling the art with a
Bresenham accumulator over its span records gives continuous height at no data
cost. Measured: monotonic 67 rows at 1 cell down to 9 at 8, worst single step
27% instead of 45-59%, at an unchanged 11.1 fps.

**Your own gun hid what you had just shot.** The weapon was 24 rows tall and
up to 45% of the view's width -- 14.7% of every frame's ink -- and dead ahead it
hid **90% of a corpse one cell away**. It also had no form to justify that
footprint: 96.4% of its pixels sat at luminance 4 or below out of 15, with
exactly two above 6. Two redraws failed before one worked (a 16-row version read
as a diagonal sliver; a widening-bands version reproduced the same pyramid at a
smaller size), and the lesson was that the *shape* had always been fine. Four
rows shorter, held eight pixels right of centre, and lit: **5.3% of the frame,
peak luminance 13, and a corpse dead ahead went from 30 visible pixels to 70.**

**Sprites dissolved into the background.** Sprite luminances are absolute
constants drawn over a floor ramp that runs 1 to 13, and where they coincide the
sprite is a hole -- four of a husk's eighteen rows vanished at 4 cells, which is
what produced the "bigger at 6 than at 4" reading. Forcing the outermost pixel
of every row to the band's dark value guarantees a silhouette against any
background, and costs nothing: it happens in the generator.

## The game could not be finished, and every test said it could

The worst defects of the whole project were not in the picture, and no visual
critic would ever have found them. They surfaced from a plain question asked of
the level data: *where is the exit?*

**There isn't one.** `$0C` -- the exit switch, and the only thing
`check_cell` recognises as an end of level -- appears **zero times** in all four
compiled solid planes. The engine has no other end-of-level mechanism, so the
shipped game could not be completed, by anyone, ever.

The reason is a seam between two tools. `levels.py` authors the exit as a
*trigger*, validates that it is reachable, and reports every level
"COMPLETABLE" -- but it stores it in the container header, and `genlevels.py`
extracts only the two map planes and the spawn point. The trigger list is
compiled and then dropped on the floor.

**And two of the four exits are behind locked doors the engine cannot open.**
`check_cell` handles `$08` only; `door_red`, `door_blue` and `door_yellow`
(9/10/11) fall through to the ordinary-cell test and are solid wall. Measured
reachability from each level's own spawn, using only what the game implements:

| | exit | enemies reachable | open cells |
|---|---|---|---|
| THE VESTIBULE | reachable | 4 of 5 | 255 |
| THE RED CISTERN | **blocked** | 1 of 5 | 256 |
| SILENT COLONNADE | reachable | 3 of 5 | 376 |
| THE MAW | **blocked** | **0 of 5** | 130 of 357 |

THE MAW shipped as a closet with a name: a third of its space, and not one of
its five enemies.

Both are fixed where the level is compiled, because in this engine the exit
*is* geometry and a lock nothing can open is not a door: `solid()` now stamps
`$0C` at the authored exit and compiles locked doors down to plain ones. Zero
runtime code, zero bytes.

### Why forty-four passing checks did not notice

This is the part worth keeping. The acceptance sweep had a check called
"victory after the last level", and it passed. It passed because its own
helper, `descend()`, **poked an exit cell into the map** before walking into
it. The harness was manufacturing the thing it was testing, and then confirming
it existed.

A test that constructs its own precondition tests the code that runs after the
precondition. That is a real thing to test -- the descent logic genuinely
works -- but it says nothing whatever about whether the game contains an exit,
and I had been reading it as though it did. `descend()` now walks to the real
exit, and there is a check that each level's solid plane contains exactly one
`$0C` at the coordinates in its own container header.

The general form: **when a test sets up the world, list what it is asserting
and what it is assuming.** Everything in the second list is untested, and the
more elaborate the setup, the longer that list gets.

## Dying sent you into a wall

`restart_level`, the death-and-retry path, reset `levelno` to 0 but never
reloaded the map. Die on level 2, 3 or 4 and you kept that level's geometry
while everything indexed by level number believed you were on level 1: the
status bar read THE VESTIBULE, the spawn was always level 1's (4,6) -- and
cell (4,6) is **solid** in both THE RED CISTERN and SILENT COLONNADE, so the
player was placed inside a wall.

The sweep's death-and-retry check missed it by running on level 1, where
`levelno` is already 0.

Retry now restarts the level you died on, which is also better play than being
sent back three. It needs no new data: for levels 2-4 the RLE tables are
already indexed `levelno - 1`, and when `levelno` is 0 the resident level-1 map
is still correct.

## Continuous sprite WIDTH: tried, measured, reverted

Round 7's top recommendation, and the one thing on its list I could not make
pay. Height was made continuous; width stayed quantised to the five art bands,
which measures as a 43% single-frame snap at four cells.

It was implemented: an output width derived from the same wall height as the
height, and a per-sprite map from output byte to source byte so the hot copy
loop paid one indexed load rather than a divide. It worked, in the sense that
the width then changed every couple of frames instead of four times in total.

It was reverted because the measurements did not support it:

- **Mode 9 stores two pixels per byte, and a span blit can only start and end
  on a byte.** So the finest width step available is 2 pixels. On a 20-pixel
  near sprite that is a 10% step -- a real improvement. On a 4-pixel far one it
  is **50%**, which is worse than the band it replaced.
- Truncating the byte count consistently under-shot, so sprites came out
  narrower than their own art: pickups fell from 76 visible pixels to 24, and
  three acceptance checks went red.

The honest summary is that vertical scaling is cheap because a row is the unit
the renderer already works in, and horizontal scaling is not, because the unit
is two pixels wide and the sprite is only ten of them across. Fixing it
properly means a different blit -- per-pixel with a shift, roughly doubling the
cost of the hottest loop in the sprite pass -- and that is not worth 3 fps.

Reverted, with the reasoning kept here so it is not re-attempted blind.

## Round eight: the ending, and the thing RAM does when you turn it on

8.5, and the verdict flipped: *"Yes -- genuinely."* The reviewer wrote its own
BFS driver, with none of my harness code, and finished the game unaided. That
is the first outside confirmation that ABYSS is a game.

**The ending was a dead end.** Winning set `wonall` and left it set. Fire fell
through to the exit branch, `next_level` refused because there is no level 5,
and the player sat in a gold room forever spending ammo into nothing -- 1,500
frames and ten trigger pulls with no state change at all. There was no way out
but a power cycle. Fire now starts a fresh game.

That needed level 1's map back, which had been overwritten on the way down, so
all four levels are packed now instead of three. `levels.bin` went 1,664 to
2,022 bytes and still clears the table region with 26 bytes to spare, and as a
bonus the RLE tables are indexed by level number directly, so `load_level`
stopped needing two different index conventions.

**The pain flash was the muzzle flash's bug, still live, twenty lines below the
comment explaining it.** `$36` is `%0110`: popcount two, so `16 >> 2` = four
luminances -- for six frames, every single time you are hit, which is far more
often than you fire. `$32` is `%0010` and keeps eight, in the same hue. One
byte. The victory tint's comment still described the old floor model too.

**And the one that matters for hardware: the game never initialised its own
level state.** A systematic pass over every declared variable found exactly one
that is never stored anywhere -- `levelno`, which is only ever `inc`'d -- and
`itmgot`, `wonall` and `wondone` are written only by the death and descend
paths. All four live in the `$7A00` scratch page. The emulator brings RAM up
zeroed, so it has never once shown; a real Atari does not. Poking plausible
garbage in before the title is dismissed:

| `levelno` | status bar | ceiling hue |
|---|---|---|
| `$00` | THE VESTIBULE | `$90` correct |
| `$07` | blank | `$C0` green |
| `$5A` | SILENT COLONNADE, on level 1 | `$00` grey |

That byte indexes the level name, the item table, the hue triple and the test
for whether you have already won. Twelve bytes clearing the page at boot, and
the whole class is gone.

**Four of twenty enemies were permanently inert** -- three sealed in monster
closets, one behind a secret, all needing a trigger system the engine does not
have. SILENT COLONNADE was quietly missing 40% of its opposition. The generator
named in `spawns.inc`'s header, `genspawns.py`, **did not exist**: the table was
orphaned output that could not be reproduced. It exists now, keeps every
reachable position exactly where it was, and relocates only the four that the
player can never get to.

That last fix promptly broke the playthrough check, which is the right kind of
problem to have: with the missing enemies restored, my walker wedged itself on
an inside corner at exactly one cell boundary and stalled forever. Turning
happens once per *render* tick at four units a time, so its two-frame turn steps
were frequently doing nothing at all. It now takes real turn steps, engages and
disengages combat with hysteresis, and shuffles clear when it detects it has
stopped moving -- and the game completes again, 28 shots, no deaths.

**One thing the reviewer got wrong**, worth recording because I nearly "fixed"
a correct file: it reported `MAPFORMAT.md` documenting RLE runs as `ctrl - $7F`
while the code uses `and #$7F`. Both are true of different formats. The level
*container* writes `$7F + run`; the game *payload* writes `$80 | run`. They
differ by one, they are separately consistent, and the runtime never reads the
container. The doc was right; the collision is a genuine trap and is now called
out in the file.

## The ending got a screen

Fixing the dead end still left the *frame*: whatever wall the player happened to
be facing, tinted gold. Eight distinct colours against 34-39 for a gameplay
frame, and thirteen of sixteen sampled rows a single colour edge to edge.

It now shows an end card, and it costs almost nothing because the title screen
already had a painter: the same wordmark, a warmer ramp, and "YOU ESCAPED --
FIRE TO REPLAY". The game bookends with one image, teal on the way in and gold
on the way out.

One catch worth recording. The title's painter wrote to framebuffer A
unconditionally, which is correct exactly once -- at boot, before anything has
flipped. Called mid-game the card landed in the buffer that was NOT on screen
and nothing appeared. Both painters now take the buffer page as a parameter,
and the end card explicitly targets the *displayed* one, because `flip_buffers`
leaves the pointer on the back buffer. A routine that works only at boot is
easy to write and hard to notice.

## One thing measured and then deliberately not done

The hue bands are split at fixed buffer rows 30 and 66 while the geometric
horizon moves with the player. The obvious fix — accumulate the frame's median
wall top and move the DLI split to it — is about two dozen bytes, and the critic
ranked it third.

It was measured and then declined, for reasons worth writing down:

- The **wall band is mostly wall** after the height fix. Measured on two
  frames, 17.6% of it carries a ceiling/floor ramp value on the opening frame
  and 24.6% after walking -- so 75-82% wall, against 34% before. (An earlier
  draft of this log said 98.9%, from a single frame and a looser test; it does
  not reproduce.) The remaining mismatch is the other way about: much of the
  ceiling and floor bands is the top and foot of near walls. Those pixels are the dark
  vignette cap, so the wrong hue lands on luminance 1-6 and reads as the wall
  going into shadow rather than as a colour error.
- The change is not local. The sprite renderer clamps billboards to rows 30-65
  *because* that is the wall band, and the wall ladder's dark caps are generated
  for slots 0-29 for the same reason. Moving the split means moving both, and
  the ladder caps are baked into 768 bytes of unrolled code per buffer.
- The display list and DLI chain are the most fragile part of this build. Four
  attempts at a title screen destabilised them earlier in the project.

So: a genuine defect, measured, with a known fix whose blast radius is three
subsystems and whose payoff lands on pixels that are already nearly black. It
stays on the list rather than in the build. A prototype that passes 35 checks is
worth more than one that might look marginally better and might not boot.

## Where it stood after round eight

*(Written mid-project. The numbers here — 35 checks, 13.4 fps — were true when
this was written and are superseded by the closing section below. Left in place
rather than corrected, because the point of this log is what was believed at the
time.)*

**11.2 fps** with everything running: raycast walls with per-cell lighting read
from the room in front of them, per-material shading, distance-faded masonry
courses, dark caps where a wall leaves its hue band, reciprocal ceiling and
floor ramps whose plateaux widen toward the viewer, depth-sorted billboards for
enemies, corpses and pickups, a shotgun with kick and a whole-screen flash,
doors, four named levels each with its own hue triple, death and retry, victory,
a weapon that bobs when you walk, and a title screen.

The numbers that matter, all measured in the shipped binary:

| | |
|---|---|
| Acceptance sweep | **35 / 35** |
| Render rate | 13.4 fps walls only, 11.2 fps with everything |
| Randomised soak | 20,000 frames, 5,000 per level from a fresh boot |
| Level 1 clearable by an autoplayer | 5 shots, 92 of 100 health left |
| Passive play | dead in 37 seconds |
| Viewport change on a 45° turn | 62% |
| Luminance levels in the viewport | 15 of a possible 15 |
| Build reproducibility | byte-identical from a clean regeneration |
| Memory boundaries asserted | 11 at assembly time, 2 at generate time |

The single most useful thing built tonight was not in the game. It was the
habit, forced by three critic rounds, of **measuring the picture instead of
looking at it**: reading the colour-register byte back out of the screen buffer,
where the low nibble is the exact pixel luminance. Every real defect of the
night — the wall heights, the lighting read off the wrong cell, the invisible
pickups, the invisible corpses, the sprites drawn in table order, the corrupt
level-4 lighting — was found by a number, and several of them were invisible to
the eye even once you knew they were there.

The corollary is the other lesson: **a reported defect is a hypothesis, not a
premise.** Two of the critic's findings did not survive measurement, and a third
was real but had a completely different cause from the one proposed. Checking
each one cost minutes; acting on any of them blind would have cost hours and
made the build worse.

It has never run on real hardware. That is the next gate, and it is the only
one that counts.

## The frame rate row was measured against a binary that no longer exists

The README had carried two render-rate numbers since round five: 13.4 fps
"walls only" and 11.2 fps "full game". The first was measured by stubbing the
sprite, weapon and crosshair passes out of the build — a number nobody can see,
from a binary that was thrown away, and one that predated every piece of sprite
work that came after it. It had been quoted for hours as though it described
the shipped game.

Re-measured on the shipped binary with nothing stubbed, in the condition a
player is actually in:

| | |
|---|---|
| Empty corridor, no enemy in view | **11.94 fps** (min 11.75, max 12.00) |
| One husk two cells away | **9.31 fps** (min 8.75, max 10.00) |
| Cost of one close enemy | **22%** |

Two methodology notes, both of which cost a wrong answer first:

**`RENDERS` is one byte.** The first distance sweep produced `-53.50 fps` at
eight cells, because the counter had wrapped past 256 and the delta went
negative. A negative frame rate is at least an honest failure — the same wrap at
a smaller magnitude would have silently shaved a plausible-looking amount off a
plausible-looking number. Deltas on an 8-bit counter are taken mod 256 now.

**A curve I could not explain, so I did not publish it.** The cost-versus-
distance sweep came out non-monotonic: a husk at three cells was *cheaper* than
one at four, and one at four was more expensive than one at six. The obvious
story — cost tracks on-screen sprite area — did not fit, and adding a pixel
footprint measurement did not rescue it either, because several of the offsets I
was parking the husk at put it inside level 1's geometry, where it was occluded
and never drawn at all. Rather than pick the subset of points that made a nice
curve, I dropped the curve and kept the two-point comparison, run A/B/A/B so
that drift shows up as scatter within a condition rather than as a difference
between them. The honest claim is "one close enemy costs about a fifth of the
frame rate", not a model of why.

The `pain flash` also had to be pinned out of it: with health left alone, the
husk beats the player down during the measurement window and the flash changes
the work per frame. Health held at 100 across both conditions.

## The critic that stalled, and the count I got wrong on my own

Round nine never reported. The agent read source for fourteen minutes and its
watchdog killed it with nothing written down. Round ten was relaunched with a
tighter brief: look at the pictures rather than the source, cap the tool budget,
and append each finding to a file as it is found so that a stall still leaves
something behind. Losing a whole review to a process failure is cheap to
prevent and expensive to repeat.

While it was running I re-counted the authored content, which the README
described as "39 actors across 5 types and 42 items across 12". I had a note to
myself claiming the real figures were 71 actor records across 12 type ids. That
note was wrong — I had counted with my own guess at where the actor type ids
stop and the item ids start. Counting with the level compiler's own `ACTORS`
set, which is the format's definition rather than mine:

- **39 actors across 5 types** — 18 husks, 10 gunners, 5 spitters, 5 hulks, and
  one maw, the boss that exists only in the level file.
- **42 items across 11 types** — the README said 12.

So the figure I was about to "correct" was right, and the one number that was
actually wrong was off by one. The lesson is the one this project keeps
teaching: when a tool already defines a category, ask the tool, do not re-derive
the category by eye. It took one line of Python to get the authoritative answer
and the guess had been sitting in a notes file for an hour.

## Where it stood after nine rounds

*(Superseded by the closing tally at the end of this log — rounds ten to
fourteen added seven checks, a 60,000-frame endurance run and the level
designer's own enemy placements. Left as written, because this log is a record
of what was believed when.)*

Everything above is emulator-measured. **It has never run on real hardware, and
that is the only gate that counts.**

| | |
|---|---|
| Acceptance sweep | **47 / 47** |
| Render rate | 11.9 fps empty, 9.3 fps with an enemy in your face |
| Full playthrough | all four levels, ~25 shots, 0 deaths |
| Endurance | three consecutive completions, replaying from the end card |
| Cold-boot state | clean from `$00`, `$5A` and `$FF` scratch pages |
| Randomised soak | 20,000 frames, 5,000 per level from a fresh boot |
| Build reproducibility | byte-identical from a clean regeneration |
| Memory boundaries asserted | 11 at assembly time, 2 at generate time |

Four things this project is worth remembering for, none of them about raycasting:

1. **A value borrowed for one purpose must not be written back over the value
   another purpose depends on.** Lighting and material were folded into `dist`,
   and `dist` also indexed the wall-height table, so wall height depended on how
   brightly a cell was lit. Every wall in the game rendered at a quarter of its
   size for hours.
2. **Every fixed-`org` boundary needs an assertion on both sides, and every
   assertion needs to be seen to fail once.** Four collisions in one night,
   including one where the assertion I had added guarded the wrong address and
   certified a live bug as safe.
3. **A test that builds its own precondition tests only what runs after it.**
   Forty-four checks were green on a build in which no level contained an exit,
   because the exit check poked an exit into the map before walking into it.
4. **Measure the picture instead of looking at it — and then ask a question no
   test is standing in front of.** Every rendering defect was found by counting
   pixels. The one defect that mattered most was found by asking where the exit
   was and counting how many times `$0C` appeared in the shipped maps. Zero.

## Round ten: what a fresh critic saw that nine rounds had stopped seeing

Rounds one to nine were run against a build I already knew, and they converged.
Round ten was given the screenshot set and nothing else — look at the pictures,
judge them as a player would, do not read the source — and it found ten things,
of which the first three had been in every frame of every previous round.

**The gun was camouflaged against the floor.** It is drawn inside the floor's
hue band, so the only thing separating it from the floor is luminance, and the
two histograms were sitting on top of each other: the floor ran 6-11 and so did
the bulk of the gun. Measured, not argued — the fix had to be an outline rather
than a darker gun, because darkening the gun had already been tried once and
reverted (96.4% of its pixels below luminance 4, a silhouette with no interior).
A one-pixel luminance-1 ring around the whole shape costs 68 bytes and
guarantees a step of at least five luminances against any floor tone the ramp
can make. 129 outline pixels now, measured in the picture.

**The status panel was a hard-coded `$02` under every level.** The same
near-black bar under a red level, a magenta one, a grey one and a green one,
which is why it read as an overlay glued onto the frame. It now takes the
level's own wall hue at luminance 2, and because ANTIC 2 takes COLPF2's hue and
COLPF1's luminance, one byte tints the panel and the text together. Level 3's
grey stone lands back on the old `$02` by construction.

**The muzzle flash was a screen clear, not a flash.** It wrote ONE value to all
three bands, so ceiling, wall, floor, gun and enemy all became the same flat
gold and the enemy you were shooting at nearly vanished into it. The bands now
keep their own hues and only the luminance bit moves, graded from the floor
upward because the blast comes from a gun held at the bottom of the screen. The
number that says it worked is not aesthetic: the brightest flash frame went from
8 distinct luminances to 12.

**Dying did not read as dying.** The view was the ordinary view with a red
filter over it and the shotgun still held level and ready, which is the pose of
a player who is fine. The kick offset already pushes the gun down the screen and
clips it, so death just drives that offset to the bottom, one scanline per
50 Hz frame. Half a second to slide out of frame, no new state in the renderer.

**The husk was a lollipop.** Round head, oval torso, two straight legs, arms
absorbed into the torso mass — at every distance it read as a chess pawn. The
arms are now outside the torso with a dark gap between them, so the silhouette
goes wide at the shoulders, narrow at the waist, then legs. That, not detail, is
what makes a shape read as a body.

The corpse got the same treatment for the same reason: it was a symmetric
rounded lump, and a shape with no ends has no story. It now has a head at one
end with the husk's eye highlight in it.

**The end card was the title card in a different colour.** Finishing looked
structurally identical to not having started. It now reports the state you got
out with — health and shells, both values that already existed — and the two
cards' background ramps are inverses of each other: the title falls into black
before the floor band, the end card is lit from above. Twelve bytes each, no new
art.

### Two bugs found by looking for space rather than for bugs

game.asm's code region hit its `ert` at $4000 twice during this, and the second
time the cheapest thing to move was 128 bytes of status-bar text sitting inline
between an `rts` and the next label. Lengths had to be checked to move them, and
one was wrong: `won_msg` was 31 characters against a `cpx #32` copy loop, so the
"LEVEL CLEARED" banner's last column was reading the first opcode byte of the
routine that followed it and drawing it as a glyph. It had shipped that way.
Nobody saw it because it is only on screen for the couple of seconds between
reaching an exit and the next level loading, which is a window no screenshot in
the gallery covers. `victory_msg` was 33 and had been silently truncated.

Neither was found by a test or a critic. They were found because moving code
forces you to state its size, and a size you have to state is a size you check.

### The check that was an implementation written down as an expectation

The flash change broke `muzzle flash is 3 frames`, which asserted the literal
triple `[0x18, 0x14, 0x12]` read off COLBK. That is not a property; it is the
old code copied into the test file. It now records all three band variables and
asserts the two things that actually matter — the wall band steps three times,
and the three bands never collapse to one hue, which is the failure the change
existed to fix. Two new checks went in with the two new behaviours: the gun
drops when you die (counted as outline pixels in the picture, not as a variable
moving), and the status panel matches the level's wall hue on all four levels.

## Round eleven: the fix that was worse than the thing it fixed, measured

Round eleven's headline was that the new muzzle flash had traded a global
wash-out for a local one: the wall band brightens, the husk is drawn in the wall
band, and at the moment of firing the enemy went nearly tonally flat against the
wall behind it. That is a serious charge -- the effect exists to tell you that
you shot at something.

It is also exactly computable, which beats arguing about it. The flash is
`pixel | bit` on every pixel in the band, so the effect of any candidate bit can
be derived from one ordinary frame: take the husk's pixels and the wall pixels
around them, OR both, and count the silhouette pixels that become identical to
the wall pixel immediately beside them. Out of 194 husk pixels:

| bit | silhouette pixels lost |
|---|---|
| none (no flash) | 5 |
| 8 — the brightest step | **5** |
| 4 | 11 |
| 2 | **23** |

The brightest step costs nothing at all. It is the DIM TAIL of the decay that
hides the enemy, because OR collapses pairs and which pairs it collapses depends
on the bit: `3|8` and `11|8` are both 11, but a wall at 3 and a husk at 11 stay
apart under bit 8 in every other pairing that matters, while under bit 2 the two
distributions fold into each other.

So the reviewer was right that there was a problem and wrong about where it was.
The obvious reading — "the flash is too bright, dim it" — is precisely backwards:
an 8/4/2 decay starts at the best value and ends at the worst, over the three
frames of the one effect whose job is visibility. The wall and floor bands now
hold the top bit and the ceiling carries the decay. Measured again afterwards:
**4 pixels lost unflashed, 4 during the flash** — the flash now costs nothing at
all, against 12 before.

The check that went in with it asserts that property directly: the worst flash
frame may not lose more than two silhouette pixels beyond what the unflashed
frame loses. And the flash's own check was rewritten from `== [0x28, 0x24,
0x22]` to the properties it was standing in for — three frames, single-bit
nibbles only, non-increasing, three distinct hues throughout. The literal
version would have passed a change that made the picture worse as long as those
three numbers came out, and failed a change that made it better. It had already
done the second thing once.

## The build was shipping a draft

Restoring the gun after three rejected redraws produced a binary 44 bytes larger
than the one it was supposed to be identical to. The cause: `build.sh` only ever
ran the assembler, and the assembler `ins`-includes `src/weapon.bin` -- a file
produced by `tools/genweapon.py`. The preview script I was using to look at
draft art imported that module to get at its tables, importing it RAN it, and
running it wrote `weapon.bin`. So a discarded draft sat on disk and the next
build shipped it. No warning, no staleness, nothing out of date: the `.bin`
simply stopped being the thing the `.py` describes.

`build.sh` now runs the three art generators before assembling, every time,
which makes the `.py` files the single source of truth by construction rather
than by remembering. Three seconds a build.

The reusable shape of this: **a generated artefact checked into the tree is a
cache, and a cache that is not rebuilt by the build is just a stale file with a
plausible timestamp.**

## The weapon nobody could see

Round twelve was told, in as many words, to go and judge the redrawn shotgun.
It came back saying there was no weapon in any of the eleven screenshots, and
described what it saw at the bottom of the frame as "a small symmetric floor
structure — a dais or a threshold". Round eleven, looking at an earlier draft,
had called it a mitten. Two independent reviewers, looking straight at the
thing, did not see a gun.

Five redraws went by before the actual problem surfaced, and it was not the
shape at all:

1. a symmetric pyramid — a solid blob with no interior
2. an asymmetric wedge — read as a bird's head, complete with an eye
3. a vertical barrel over a wedge body — the version reviewers called a dais
4. wider, with more mass — read as a table lamp
5. interior raised into the floor's own 6-11 luminance range — read as an
   outline drawing, because once the interior matches the floor only the ring
   is left
6. hands gripping the fore-end and the stock — at 40x20 the hands came out as
   two pale square pads and the whole thing read as a machine with buttons

What every one of them had in common was that the gun was a COMPLETE OBJECT,
fully visible, sitting at the bottom-centre of the view. And a whole object at
the bottom of a corridor is not read as something you are holding. It is read as
something standing on the floor a few feet away, because that is what it is.

Every first-person weapon since Wolfenstein runs off the bottom and the side of
the frame. **Being cut off is what says "this is attached to you".** The art now
fills the bottom-right corner and its right-hand column lands on the last pixel
of the buffer, so the stock continues past the edge of the world.

The general lesson is not about guns. It is that six iterations on the SHAPE of
a thing could not fix a problem that lived in its RELATIONSHIP TO THE FRAME, and
no amount of further iteration on the shape was going to find that, because each
iteration was answering the question the previous reviewer asked rather than the
question of why they were asking it.

Related and cheaper: a lit bevel. The gun's mass sits at luminance 2-5 against a
floor at 6-11, so it renders as a shadow, and the bottom of a corridor is
already the darkest part of the picture. Every opaque pixel with nothing above
it or nothing to its left is now a highlight, applied programmatically rather
than painted, so it survives the next redraw. A dark object reads as an object,
rather than as a hole, when it catches light on the edges facing the light.

## Twenty minutes on one boot

The acceptance sweep soaks 5,000 frames per level from a fresh boot each time,
which proves each level is stable and says nothing about a machine that has been
running for a while. So: one boot, **60,000 PAL frames**, randomised play,
invariants checked every 500.

**No invariant failures.** 103 deaths and retries. The display control register,
the level number, the player and every live actor stayed in range throughout;
the three band hues never collapsed to one outside a flash; the status panel
colour stayed valid; the map still decoded at the end.

The render rate needs its own sentence, because the raw numbers look like
degradation and are not: 10.84 fps over the first quarter, 8.62 over the last.
Sampled every 10,000 frames it reads 8.6, 8.6, 8.6, 8.6, 8.6, 8.6 — flat for
45,000 frames. The first quarter is higher because the opening seconds are an
empty corridor, and one enemy in view costs about a fifth of the frame rate.
A single before-and-after would have called that a 20% decay.

## The enemies now stand where the designer put them

The four level files place 39 actors by hand — at chokepoints, around corners,
in the rooms they are meant to guard. The game ignored every one of them and
spawned five enemies per level from a generated table of arbitrary positions.
That table existed because `spawns.inc` was orphaned output with no generator,
and the generator written to fix that only fixed REACHABILITY: it kept whatever
positions were already there and moved the four that were sealed inside monster
closets. It never asked where the enemies were supposed to be.

They come from the level design now. Eighteen of the twenty spawns are authored
positions; only THE VESTIBULE needed filling, because it authors three actors
and the engine spawns five.

Two design decisions were needed, because a level that authors thirteen actors
has to be cut to five:

- **Which five.** Taking the first five in file order clusters them wherever the
  designer happened to start typing. It takes the authored actor NEAREST the
  player's start — so there is always an early encounter — and then
  farthest-point sampling over the rest, which spreads the other four through
  the level instead of bunching them.
- **What about the types.** The levels ask for gunners, spitters, hulks and a
  boss. The engine has one enemy. Positions are the part of the design the game
  can honour today, so that is the part it honours; the type field is still
  ignored and still documented as ignored.

The effect is measurable, and it is the effect a level designer is for. With the
arbitrary table, standing still and doing nothing killed you in 36-38 seconds and
clearing level 1 cost between zero and twenty health. With the authored
positions it is **31 seconds** and **32 health**. Same enemies, same AI, same
count — just standing in the places someone chose. The playthrough still
completes all four levels with no deaths, so it got harder without getting
unfair.

SILENT COLONNADE is worth a note: it authors thirteen actors and only five are
reachable. The other eight are behind `sealed` and `secret` cells that need the
trigger system the engine does not implement, so 60% of that level's intended
opposition is still sitting in closets that will never open.

## The same question, asked of a different band, gets the opposite answer

Round thirteen said the weapon vanished during the muzzle flash. Measured in the
weapon region of a real frame: 12 distinct luminances at rest against 8 during
the flash, the darkest pixel jumping from 1 to 8 — the outline gone — and the
horizontal edges that carry the shape dropping from 171 to 138.

Two causes, and both were things I had added.

**The flash frame's art was the whole gun with +3 on every pixel**, on top of a
band flash that already ORs a luminance bit into every pixel on screen. Two
brightenings stacked, and the gun's mid-tones landed in the floor's range. A
blast catches the LIT surfaces of a gun and leaves its shadows dark, so the
flash frame now raises only the highlight and the bright metal and leaves the
outline, the shadow and the wood exactly where they are. More contrast, not less.

**The floor band was using the same bit as the wall band**, and that is where it
gets interesting. Earlier in the night the measurement said the wall band must
use bit 8, because the dim tail of the decay was what merged the ENEMY into the
wall. Run the identical measurement on the floor band and the weapon:

| bit | weapon-region edges surviving |
|---|---|
| 2 | 100% |
| 4 | 100% |
| 8 | 81% |

**Exactly the opposite ranking.** The wall's luminances are low, so the top bit
lifts them clear of the enemy; the floor's run 6-11, so the top bit maps 6 and 7
up to 14 and 15 and leaves 8-11 alone, folding the gun's tones into the floor's.
The wall band must have bit 8 and the floor band must not.

The general point is worth more than the fix: **the same effect, applied to two
different backgrounds, needed opposite settings, and no amount of reasoning from
the first result would have got the second.** Both were one measurement away.

So the blast is physically brightest at the floor and is drawn dimmest there,
because the two things a player must not lose sight of while firing are the
enemy and their own gun, and they live in different bands.

## "There is no weapon on screen" — measured

Three reviewers in a row reported that the gun was not being drawn; the last one
named two specific levels and the muzzle-flash frame. Counted, in the picture,
per level:

| level | weapon outline pixels |
|---|---|
| THE VESTIBULE | 118 |
| THE RED CISTERN | 109 |
| SILENT COLONNADE | 113 |
| THE MAW | 115 |

It is drawn everywhere, in essentially identical quantity. What was being
reported was a failure to RECOGNISE it, not a failure to draw it — which is a
real finding, and a completely different one with a completely different fix.
Their conclusion (it does not read as a firearm) stands and is documented in the
README. Their claim of fact does not.

"Is it drawn" is the half a test can settle, so it is settled now rather than
argued about a fourth time.

## THE MAW stops being cheerful

Three independent reviewers flagged the same thing: saturated lime-green walls
under a violet sky read as toxic-slime platformer, not as the deepest floor of a
descent. Three independent flags on a taste question is not taste any more.

The constraint is that the acceptance sweep requires at least 60 RGB between a
level's own ceiling and wall, 30 between wall and floor, and 50 between any two
levels' walls, so the replacement was chosen by enumerating every hue triple that
passes and picking from the survivors rather than by eye. THE MAW is now a
burning red sky over violet stone with a dull gold floor. Closest two walls
across the game: 59, against a threshold of 50.

## The instrument was lying, not the game

Three reviewers, independently, concluded from the screenshot gallery that
ABYSS is "one room re-lit five times", and one of them singled out a recessed
alcove with a little stack of bars as a copy-pasted prop appearing dead-centre
in every level. That went into the README as a known limitation with a technical
explanation: the masonry course pattern is baked into 768 bytes of unrolled
ladder per buffer and cannot vary per level.

The explanation was true and the conclusion was wrong. `gallery.py` photographed
each level **standing on its own start square**, and all four levels start in a
corridor. So the gallery contained four pictures of four corridors.

Walking in for two seconds and photographing again: THE RED CISTERN is a wide
magenta hall with columns receding into the dark; SILENT COLONNADE is a flat
grey stone face under a deep blue vault, no corridor at all; THE MAW is a lit
violet wall on one side and a colonnade running away on the other, with a pickup
on the floor. They look nothing like each other and nothing like their own
entrances.

Every one of those screenshots was true. Every one was correctly labelled and
correctly asserted against the game state it claimed to show — the gallery has
had that discipline since it was caught telling a worse lie earlier in the
project. And together they still told a story about the game that was not so,
because they all sampled the same uninteresting moment.

**A set of individually-true measurements can still be a misleading picture of
the thing measured, and no amount of per-measurement rigour catches it.** What
catches it is asking what the sample has in common — here, "every one of these
is taken from a standing start" — which is a question about the instrument, not
about any of its readings.

The three level shots now walk a fixed route in before photographing. The one
follow-on defect that surfaced from that, honestly: taking the tour on THE MAW
leaves the autoplayer further from the exit than it has ever had to walk, and
its first attempt sometimes fails. It re-routes from the player's live position,
so shaking them out of whatever corner they wedged into and asking again gives it
a genuinely different problem; BFS confirmed the exit is reachable from the tour
end, so this is the walker's steering and not the level's geometry. That
distinction was worth measuring rather than assuming — it is the difference
between a harness bug and a game that cannot be finished.

## Where it actually ended

**It has never run on real hardware. That is the only gate that counts and it
has not happened.** Everything below is emulator-measured, in process, with
nothing left running afterwards.

| | |
|---|---|
| Acceptance sweep | **54 / 54** |
| Full playthrough | all four levels, ~22 shots, 0 deaths |
| Render rate | 11.9 fps in an empty corridor, 9.3 with an enemy in your face |
| Endurance, one boot | 60,000 frames, 103 deaths and retries, 0 invariant failures |
| Render rate under load | 8.6 fps, flat across 45,000 of those frames |
| Passive play | dead in 31 s, from 36-38 s before the enemies moved onto the designer's positions |
| Randomised soak | 20,000 frames, 5,000 per level from a fresh boot |
| Build reproducibility | byte-identical across three consecutive clean builds |
| Memory boundaries asserted | 15 at assembly time, 9 at generate time |
| Orphaned processes | none, by construction |

Fourteen adversarial critic rounds, 4.5/10 to the score in the closing review.
The five rounds after the ninth were worth more than the four before them, for
one reason: they were given the pictures and forbidden the source. A reviewer
who knows how something works stops being able to see what it looks like.

Six things this project is worth remembering for, none of them about raycasting:

1. **A value borrowed for one purpose must not be written back over the value
   another purpose depends on.** Lighting and material were folded into `dist`,
   and `dist` also indexed the wall-height table, so wall height depended on how
   brightly a cell was lit. Every wall rendered at a quarter of its size for
   hours.
2. **Every fixed-`org` boundary needs an assertion on both sides, and every
   assertion needs to be seen to fail once.** Four collisions in one night,
   including one where the assertion I had added guarded the wrong address and
   certified a live bug as safe.
3. **A test that builds its own precondition tests only what runs after it.**
   Forty-four checks were green on a build in which no level contained an exit.
4. **A check that encodes an implementation is not a check.** `== [0x18, 0x14,
   0x12]` failed the moment the flash was improved and would have passed a
   change that made the picture worse.
5. **The same effect on two different backgrounds can need opposite settings.**
   The flash bit that keeps the enemy clear of the wall is the one that hides
   the gun against the floor. Reasoning from the first result gives the wrong
   answer for the second; both were one measurement away.
6. **Individually true measurements can add up to a false picture.** Every
   screenshot in the gallery was real, correctly labelled and asserted against
   the game state it claimed — and all four level shots were taken from a
   standing start, so three reviewers independently concluded the game was one
   room re-lit. The question that finds this is not "is each reading right" but
   "what do all these readings have in common".

## Two more weapon experiments, one kept

Round fourteen finally found the gun without help, described it accurately —
barrel highlight, dark ejection port, diagonal stock — and still said it read as
"an object lying on the ground a few tiles away, not a gun in your hands". Its
diagnosis was specific and correct: nothing in the picture said FOREGROUND.

**Kept: the outline stops at the frame edge.** The gun was placed in the corner
so the frame would cut it off, but `outlined()` draws its ring on every side,
including along the last column of the buffer — so a dark line was drawn exactly
where the object was supposed to run out of the world, closing the shape again.
The ring is suppressed on the last column now and the stock's mass reaches pixel
79 with nothing after it. Measured: column 79 carries weapon luminances (outline
1, highlight 13, wood 4) where it used to carry floor.

**Reverted: crossing the hue seam.** The reasoning was the best of the night. The
DLI hue seam sits at buffer row 66 and everything below it is drawn in the
floor's hue; a 26-row gun starts at row 70, so it lives entirely inside the floor
band, in the floor's own colour — which is precisely why it reads as being on the
floor. Grow it to 34 rows and the barrel crosses into the wall band. Nothing in
the world can span two hue bands, so the gun would be the only object on screen
that does.

Built it, and the barrel merged into the dark red-brown wall and read as a
PILLAR standing in the corridor.

So it was rebuilt a second time with the rows above the seam drawn as a
near-black tube — luminance 1, with the bevel putting a highlight down its lit
edge, so it is dark against a lit wall and bright-edged against a dark one, and
the wall cannot be both at once. That fixed the tone problem completely and it
read as a DOORWAY EDGE instead.

Two attempts, two different failures, and the second one names the cause: **it
was never about tone, which is why fixing the tone did not help.** The wall
band's own content IS thin vertical elements — corridor edges, column faces, the
dark seams between wall segments. A vertical barrel up there is camouflaged BY
CATEGORY. To cross the seam legibly the barrel would have to stop being a
vertical bar: angled across the seam, or wide enough to read as a mass. That is
a different gun, not a different shade, and it is where the next attempt should
start.

Both experiments reverted; the build is byte-identical to the one that passed
54/54 before them. The reasoning is left in the generator, because a rejected
approach with a known cause is worth more than an untried one.

## It went to real hardware, and the harness had been testing the wrong machine

Tony ran it on an 800XL from a Lotharek SIO2SD. The picture rolled and
corrupted on load.

The cause took one grep. This build puts the sprite renderer at `$A000`, its
frame tables at `$A900`, the level names at `$AA00`, `load_level` at `$AA80`, the
hue and flash tables at `$AB00`, the title strings at `$ABA0`, the entire actor
AI at `$B000` and the entire audio engine at `$BB00`. On an 800XL,
**`$A000-$BFFF` is the BASIC ROM** unless something turns it off — and nothing
did. Every `jsr` into any of those modules was executing BASIC.

It survived 130-odd green sweeps because **atari800 defaults to BASIC
DISABLED, and a real XL boots with it ENABLED unless you hold OPTION.** The
harness had been testing a memory map the target machine does not have.

Reproduced in ninety seconds by passing `-basic`:

| | world frames rendered | health |
|---|---|---|
| harness default (BASIC off) | 55 | 100 |
| **`-basic` (as an XL boots)** | **0** | **0** |

Nothing rendered and the player was dead on arrival. That is the photograph.

The fix is eight bytes and has to be the FIRST segment in the file, with an
`ini` vector so the loader runs it the moment it is read:

        org $0600
    _basic_off
        lda $D301
        ora #$02        ; PORTB bit 1: 0 = BASIC ROM, 1 = RAM
        sta $D301
        rts
        ini _basic_off

First, and not something `start` does, because a loader writing into
`$A000-$BFFF` while the ROM is enabled cannot be relied on to reach the RAM
underneath — the window has to be RAM *before* the segments that target it come
off the card. `start` sets it again anyway, in case a loader ignores INIT
vectors. Read-modify-write, because the same register holds the OS ROM enable
and the self-test bank.

Verified both ways: 55 world frames and full health with BASIC on and off, and
the acceptance sweep now boots the whole program a second time with `-basic` and
asserts it. 55/55.

### The lesson, which is not about BASIC

**Every configuration difference between the harness and the target is a place a
bug can live rent-free, and it will live there indefinitely, because the harness
is the only thing looking.** Fifty-four checks, 60,000-frame endurance runs,
byte-reproducible builds, thirteen adversarial reviewers — none of it could see
this, because all of it ran on the same wrong machine. The measurements were not
wrong. They were measurements of something else.

It is the same failure as the gallery photographing every level from its start
square, one level up: there the *sample* was unrepresentative, here the *machine*
was. The question that catches both is the same one — not "is this reading
correct?" but "what does every one of these readings have in common?"

The honest note: `--machine=-nobasic` was already written down in my own
reference notes for this toolchain, as a gotcha, in those words. I had recorded
the difference and never asked what it implied about anything running under it.

## Second hardware run: the title screen appears, and the picture still rolls

The BASIC fix worked — the wordmark and the tagline both render correctly, so
everything above `$A000` is executing from RAM now. The picture still rolled.

That is a vertical sync fault, and this time the cause is arithmetic rather than
memory. ANTIC displays scanlines 8..247 and begins vertical blank at 248, so a
display list may ask for **at most 240 scanlines**. Walking both display lists
out of live RAM and totalling them:

    DLIST A: 248 scanlines
    DLIST B: 248 scanlines

24 blank + 96 rows shown twice (192) + **four** rows of ANTIC 2 text (32) = 248.
The last text row was still doing playfield DMA while ANTIC should have been
generating sync. Eight scanlines over, and a frame eight lines too long is a
picture that will not lock.

Two of those four text rows were blank. Only `HUDRAM+40` (health and ammo) and
`HUDRAM+80` (the level name) ever carry anything — I had measured exactly that
hours earlier, when checking the banner strings, and read it as a curiosity
rather than as sixteen spare scanlines. Starting the text band at `+40` and
drawing two rows costs nothing visible and brings the list to **232**: eight
inside the limit instead of eight outside it.

### Why 130 green runs could not see it

**atari800 renders a fixed 240-line window.** Ask it for 248 and it clips the
overflow and hands back a stable, correct-looking frame. It cannot show you a
CRT losing lock, because it does not model a CRT at all — it models a
framebuffer.

So this is not the harness testing the wrong machine, as the BASIC bug was. It
is the harness being *structurally incapable* of observing the failure, which is
worse, because no amount of looking at its output would ever have helped. The
frame's LENGTH is not visible in a picture of the frame. It has to be computed
from the display list and asserted.

It now is, out of live RAM rather than out of the source — because what ANTIC
executes is whatever `build_dlist` actually wrote, and `build_dlist` is a loop
with an LMS per row, which is precisely the sort of thing that is easy to get one
iteration wrong in.

### The pattern, now that there are two of them

Both hardware bugs were in the same blind spot and neither was subtle:

| | the emulator | a real 800XL |
|---|---|---|
| `$A000-$BFFF` | RAM by default | BASIC ROM by default |
| a 248-line display list | clipped, drawn stable | rolls |

**An emulator is a model, and every bug you ship to hardware lives in the gap
between the model and the machine.** The useful question is not "does it pass?"
but "what can this harness not, even in principle, tell me?" Two answers so far:
it cannot tell me the machine's default configuration is different from its own,
and it cannot tell me a frame is the wrong length. Both are now checked.

56/56.

## A fresh-eyes review, on a different model

The project changed hands — same partnership, different Claude — and the new
eyes were pointed at the whole tree with one standing question, learned from two
hardware failures: *what can the harness not, even in principle, see?*

**Checked and NOT a bug, which is worth recording:** the OS attract mode. This
is a joystick-only game and only keyboard IRQs reset the attract timer, so after
~9 minutes the OS starts colour-cycling the screen — a classic trap for exactly
this kind of program. Forced `ATRACT` to `$FE` and ran twelve seconds: the sky
band's pixel set is identical, because the VBI and DLIs rewrite every hardware
colour register from clean values every frame, *after* the OS applies its
mangling. Attract is defeated by construction. No code change — a measured
negative is worth more than defensive code for a fault that cannot occur.

**Two new hardware-trap assertions.** ANTIC's display-list program counter is
10 bits, so a list crossing a 1K address boundary wraps mid-list. Both lists end
~430 bytes short of their boundary — layout luck, now asserted. And the XEX's
own bytes are now parsed to prove the BASIC-off stub is the *first* segment
with its INIT vector before anything loads at `$A000+` — segment order is
decided by source order and nothing else pinned it.

**The pickups now stand where the designer put them.** `items.inc` carried a
"GENERATED — do not edit" header naming no generator at all — orphaned output,
exactly as the spawn table was — with arbitrary positions and types literally
alternating 1,0,1,0. `genitems.py` now derives all 16 from the level files:
stim/medkit collapse to medkits, shells/shellbox to shell pickups, two of each
per level by farthest-point sampling from the player spawn, so deep items
reward exploring. The full playthrough still completes (19 shots, 0 deaths).

**Three self-referencing test constants, one of which could never fail.** The
review's best finds were in the test file, not the game:

1. `item_pixels` computed its "vanish" number as `diff('taken','taken')` — a
   frame compared against ITSELF, structurally zero. The check "collected
   pickups vanish" had never been capable of failing. This project has a whole
   memory document about self-fulfilling checks. It was in this file anyway.
2. The same helper hard-coded "the shells at (8,6)" — a coordinate copied from
   the table under test.
3. `medkit pickup` teleported to (12,11), another baked coordinate — and this
   one FAILED loudly the moment the table was regenerated, which is the correct
   behaviour of a wrong test and how it was caught.

The vanish check now measures a real property: collect the item through the
game's own path — stand on it, let `check_items` fire — and the resulting
picture must be identical to the renderer's no-item path. 90 pixels drawn, 0
after collection, bitmask verified. Both position-dependent checks now read the
live tables.

58/58.

## Run 3: it runs — and then everyone else could run it too

**1 August 2026: the fixed build boots, locks and plays on the real 800XL.**
Both hardware fixes confirmed on the CRT. The gate this project was named after
is passed.

The same day it went public twice over: the source at
github.com/tonygillett136/a8doomish, and a website with the game PLAYABLE IN THE
BROWSER at **https://abyss.gillett-projects.com** — the identical 28,723-byte
XEX, running in the project's own emulator core compiled to WebAssembly.

That last part is worth recording, because it inverted the usual embed problem.
The Scopa site's emulator hunt (JSSpeccy abandoned, Qaop adopted) taught three
laws: main thread, no COOP/COEP headers, and never ship an embed you cannot
verify headless. Rather than audition third-party Atari emulators against those
laws, the answer was already in the toolchain: **libatari800 — the exact C API
the whole acceptance sweep drives in-process through Python — compiles to WASM
in one pass**, and `site/emu/player.js` is simply `tools/a8.py` ported to
JavaScript: same input struct, same 336-px visible window, same palette table,
driven from requestAnimationFrame instead of a Python loop. Single-threaded, so
no SharedArrayBuffer, so no COEP. 456 KB of wasm.

One build gotcha for the notes: emconfigure/emmake worked until the archive
step, where the Makefile called the HOST macOS `ranlib` on wasm objects and
produced a 96-byte empty archive that `make` then reported as up to date. The
fix is to archive the objects directly with `emar`. An empty archive with a
fresh timestamp is another instance of the project's oldest lesson — a
plausible artefact is worse than an error.

And the embed was verified the Scopa way before it shipped: Playwright drove
the LIVE page, clicked the gate, dispatched a held Space, and then read the
game's own RAM through an exposed peek — `intitle` 1→0, `RENDERS` counting,
health 100 — the same state assertions the acceptance sweep makes, now made
against the deployed site. The screenshots on the page are asserted screenshots;
the emulator behind them got the same treatment.

The audio engine — eleven effects verified for a whole project as POKEY
register traces and never heard by anyone — now plays out loud on a CRT's
speaker and in every visitor's browser.

## The bestiary: the levels finally cast their own monsters

Thirty-nine minutes on the clock, so this went in the order value falls:
v1.0 tagged from the hardware-confirmed commit FIRST (a release should be the
proven thing), then the single biggest gameplay multiplier the engine had been
refusing: **enemy TYPES**.

The level files have always asked for gunners, spitters, hulks and a maw; the
engine shipped identical husks. The machinery was already there — projectiles,
telegraphs, infighting, per-slot state — so types are four small tables indexed
by `AC_TYPE` (HP, attack chance, melee damage, ball damage), a `SPWNT` table
carried from the level files by genspawns.py, and per-type damage lookups at
the four combat sites. The design law from spawn_actors holds: **HP steps are
whole point-blank shots, never inflation.** A husk is one blast, exactly; a
hulk is exactly two; a gunner dies to one point-blank or two mid-range. The
one-shot stays the shotgun's identity precisely because the hulk is the
exception to it.

- **husk** (60 HP, chance 24) — the baseline, unchanged
- **gunner** (32 HP, chance 40) — fragile, fires nearly twice as often
- **spitter** (60 HP, chance 48, weak balls) — constant suppression
- **hulk** (120 HP, chance 12, melee 16) — and it TOWERS: +25% sprite height,
  measured on screen at 1.32× a husk at the same distance. The scale hook is
  guarded by POSE, not just slot, because the same height path draws pickups
  with a stale slot variable — the guard is what keeps a medkit from towering.
- the authored **maw** ships with hulk stats: the boss STATS existed tonight,
  the boss BEHAVIOUR did not, and a placeholder that plays fair beats a rushed
  one that doesn't.

Fireballs now carry their SHOOTER's damage, looked up through the ball's owner
slot at the moment of impact — with the honest caveat in the comment that a
recycled slot can flavour the number, never crash it.

THE RED CISTERN now fields a hulk and two gunners; THE MAW greets you with
gunners and spitters. THE VESTIBULE is all husks, exactly as authored — which
also means every existing level-1 check kept its meaning, by design of the
levels rather than by luck of the tests.

Plus: a **KILLS counter** (incremented on the death transition, reset on retry,
surviving mid-run descents) reported on the end card next to health and ammo.

Three new sweep checks: the levels spawn their own bestiary (types match SPWNT
on all four levels, three-plus distinct types across the game), the hulk towers
(≥1.2× on-screen, measured in pixels), and kills are counted (0→1 over one
point-blank shot). The type-table org promptly tripped the $ABA0 guard and was
moved to $AC20 with its own — the guard law keeps earning its keep.

### The statue army the sweep waved through

The type tables went in, all four levels spawned their authored roster with the
right HP, the hulk measurably towered — and the parallel scout that had been
reading every `AC_TYPE` reference in the codebase came back with the real
state of things: **six separate sites tested `cmp #TY_HUSK` for equality.**
The shotgun (`cmp #1`, a literal). Damage. Line-of-sight waking. Gunfire
alerting. Awake-counting. Both infight paths. Every new type was a bulletproof,
deaf statue: never woken, never alerted, immune to every source of damage,
invisible to infighting.

And the acceptance sweep, run against exactly that build, came back **60 of
61** — the one failure an incidental type-literal in a *check*, not a combat
test. "The game can be completed" PASSED: the autoplayer simply shot the
statues, gave up, and routed around them. Sixty green checks against a build
whose headline feature did not function.

The fix is one subroutine — `is_enemy`, Z=1 for any living enemy class,
preserving each caller's flag semantics — swapped in at all seven sites, plus
the two type-literals in the sweep itself. Verified the decisive way: a hulk
goes 120 → 60 → 0 over exactly two point-blank shots, and a dormant gunner
placed in view is awake and ATTACKING within 150 frames.

Two lessons, both old friends wearing new hats. **Spawning is not
functioning** — every one of my checks proved the types were BORN correctly and
none proved they could fight or die. And the ultracode point, measured: the
scout cost 169k tokens of parallel reading and caught in minutes what sixty
green checks could not see at all, because it read for *references*, not for
symptoms.

## The juice sprint: hits you can feel

Second ultracode burst of the morning, same shape as the first: scouts out on
the fact-questions (how are fireballs actually drawn? does anything author the
hurt bit?), the main thread implementing what depends on neither.

**Knockback.** A hit you only read about on the health counter is a hit you did
not feel. `push_player` sets the player's velocity to 1.5× their own top speed,
directly away from whichever slot did the damage — the melee claw uses the
attacker's position, a fireball uses its own, since the ball IS the impact
point. Setting rather than adding means two hits in one tick cannot launch the
player; the friction model turns the impulse into a sharp jolt that decays over
about three ticks; and move_player's collision keeps it from shoving anyone
through a wall. Plus the gun now jolts (`wkick`) when YOU are hit, not only
when you fire — same path, same decay, four bytes.

Proven live before the sweep: a hulk claw took health 100→84 (the per-type 16
landing in play) and left velocity at exactly $FFA0 — the −KNOCK impulse,
pointing away. The sweep gained "a hit shoves the player": impulse ≥ $60
against a top speed of $40, measured the frame the health drop lands.

**And the fireball howler.** The scout reading the sprite draw path reported
that slots 6-7 go through POSEMAP like actors: spawn_ball sets AC_FRAME=0,
ball_tick toggles it 0↔1 — poses 0/1, scale 192, walk-animated. **Every
incoming fireball had been drawn as a full-size walking husk since the day
projectiles went in.** Eleven screenshots, fourteen critic rounds and three
blind identification tests never caught it, because nobody ever screenshotted
the two-second window with a ball in flight. Slots ≥6 now force pose 5 (the
shells art, scale 48): measured, a ball at 3 cells went from a ~200-pixel,
28-row walking figure to a 76-pixel, 6-row blob at the floor line. The sweep
asserts it stays one.

63/63. Hurt floors and the rest of the juice list stay in ROADMAP.md — the
lava needs a level-file edit and a map rebuild, and twenty minutes to the
hard stop is not the window to re-verify byte-exact map planes in.

## The floor was always lava

The hurt-floor scout came back with the fact that turned a planned feature into
a twenty-byte patch: **THE RED CISTERN's glowing nukage channel and THE MAW's
causeway gutters have authored attribute bit 7 — HURT — since the levels were
written.** Thirty-two cells of lava, compiled into the shipped attr planes,
RLE-packed, decompressed on every descent, byte-compared by the sweep on every
run… and never once read by the runtime. The level designer built hazards; the
engine walked the player through them like they were carpet.

`check_floor` now runs on the render tick: row-table addressing plus the $0400
attr-plane offset, test bit 7, and ~4 HP a bite gated on the wall clock so the
rate ignores the frame rate. The pain flash, the sound and the gun-jolt all
arrive free through the lasthp path — the VBI notices health fell and does the
rest. No level edit, no map rebuild, no new data: the content was waiting.

Measured: 16 HP lost over five seconds standing in the channel, exactly 0
standing beside it — both halves checked, because a hazard that never stops is
a softlock, not a hazard. And the full playthrough still finishes with zero
deaths, so the autoplayer routes past what the designer intended players to
route past. 64/64.

### And the intermission learned to count

Last feature under the wire: the FLOOR CLEARED banner — on screen for the two
seconds between every level and previously saying nothing — now reports the
kill tally. A tail call into the VBI-safe hud_num, three bytes of string
change, and the check that verifies the counter now also reads the digits
straight out of the text row, because a number that is counted but never shown
is a debug variable, not a feature. 64/64.

## The non-scaling wall pattern, spotted from outside

Angelo Colucci, shown the game with no access to any of this, wrote: *"The
non-scaling wall pattern is slightly off, but apart from that, it's impressive.
Decent frame rate too!"* — and put his finger on the exact top item of the
project's own "what is still true" list, from a screenshot, cold. The best
possible validation of an honest limitations section, and of the fresh-eyes
principle: he had never read the list he was reproducing.

Measured first, as always. The masonry courses were one dark row in four at a
FIXED screen pitch — and a wall two cells away rendered *byte-identically* to
one five cells away in the hue band. Meanwhile ktop (the wall's top row) runs
16 at two cells to 43 at ten: the wall's height varies sixfold across the useful
range while its bricks did not vary at all.

The irony worth stating: **the flaw and the frame rate are the same decision.**
Courses cost zero cycles because they are baked into straight-line unrolled
code. Making them scale properly is texture mapping — a multiply and a divide
per pixel — which is the entire budget that buys the frame rate he complimented.

### Stage 1: a mechanism change with a byte-identical acceptance test

The blocker was that the wall dispatch computed `WADR_HI[ktop] + bufhi`, so
buffer B's ladder had to sit exactly $0800 above buffer A's — and no pair of
free regions in this memory map is $0800 apart. Buffer B now gets its own
dispatch table (98 bytes of RAMTAB, which had 536 spare) and the renderer
switches between them by patching two operand bytes at each buffer flip. That
is 160 cycles a frame CHEAPER than the add it replaced.

Pure mechanism, so the acceptance test is that **nothing changes**. The gallery
was the wrong instrument — it walks the game, and the game has randomness, so
six frames differed for reasons unrelated to the change. A render fingerprint
was written instead: player parked at 21 fixed viewpoints, every actor removed,
luminance grid hashed. Same binary, same hash, always. Before and after the
refactor: **identical**. That is what "behaviour-neutral" has to mean.

### Stage 2: four variants, and the guard law collecting its fourth payment

Four ladder variants, course pitch 12/8/5/3, each holding only the slots its
distance band can enter at (385/289/193/97 bytes) — selected through the
dispatch table that was already indexed by ktop, so **the selection costs
nothing at all**. 1,158 bytes for both buffers.

The first placement put them at $A230, on the authority of a memory-map table
reading "$A000-$A226 sprite renderer". True when written; the renderer had since
grown past $A394 as poses and the hulk scale went in. The variants landed on top
of it and every sprite in the game vanished — four sweep checks failed at once
and said so precisely. The existing `ert * > $A900` could not see it: it guards
sprites growing UP into their tables, not something else being dropped in
underneath. **Guard both sides of every fixed org** — and the corollary this
adds: *a memory-map document is not a memory-map measurement.* The variants now
live in the engine tail, measured free from the ENGINE_END symbol, with a guard
at each end. (The first version of the lower guard tested the live PC, which by
that point in assembly was wherever ladder set B had ended — an assertion that
fires on the wrong fact is the same bug as one that never fires.)

Result: pitch 8 rows on a near wall, 5 on a far one, where it was 4 on both.
65/65, and the property is now its own check.

---

## Perspective mortar — the courses follow the wall (v1.5)

Angelo Colucci, having seen v1.4: *"The non-scaling wall pattern is slightly
off, but apart from that, it's impressive."* The scaling was fixed first (above).
Then Tony asked the better question: **could the mortar lines follow the
perspective of the walls themselves, rather than being parallel to the
horizontal?**

They could, and the answer deleted more code than it added.

### Why the variants could never have done it

The four pre-scaled variants scaled the courses correctly and still drew every
one of them dead level. That is not a bug in them, it is what a suffix ladder
*is*: it is entered at an offset and runs to the end, so a given byte in the
ladder always lands on the same screen row no matter where you entered. Pattern
position is therefore absolute, never relative to the wall. Making it relative
needs one ladder per entry point — 48 of them, **18,912 bytes** across both
buffers, which does not exist on this machine.

So the ladder went back to painting a flat wall, the 1,158 bytes of variants
were deleted, and the courses are now painted **per column, after the ladder**,
at fractions of that column's own wall extent:

```
h = 48 - ktop                  ; half the wall's height, this column
courses at horizon +/- h/4 and +/- 3h/4
```

Four `sta`s through a self-modifying store. `ktop` already follows perspective
exactly — it is why the top edge of a receding wall is a proper diagonal — so
**anything measured as a fraction of the wall inherits perspective for free.**
A head-on wall has constant `ktop` and keeps level courses, which is also right.

Net: **−1,158 bytes of variants, +81 bytes of engine**, 11.2 → 10.5 fps.

### The bug was in the instrument, not the engine

The new check failed — `pitch 0 rows near, 0 far`. Six increasingly baffled
measurements said the code requested rows 40, 55, 24 and 71 and only 24 and 55
ever got painted, from four unconditional `jsr`s to the same subroutine.

The engine was correct throughout. `MAPBASE` is `$7000`; `ROWLO`/`ROWHI`, the
row→address table the painter indexes, sits at `$6F00`, **immediately below
it**. The test built its synthetic wall with

```python
s.p[MAPBASE + (px + dx) + (py + dy) * 32] = 1
```

and the player starts at (4,6), so every `dy` below −6 wrote *underneath* the
map and into the row table. 90 of 375 writes escaped; 51 of 96 table entries
were left reading `$0101`, and the two "missing" mortar writes had gone
faithfully to `$1101`, where a 30-byte run of the marker value was duly found.

Four checks in `verify.py` built maps that way. All now go through
`Sweep.cell()`, which discards anything off the 32×32 grid — and the guard was
watched discarding 90 writes before it was believed.

The lesson is sharper than "clamp your indices". **A harness that pokes memory
is part of the system under test, and it has no bounds checking either.** The
symptom was a rendering check failing on a renderer that was right, which is the
most expensive kind of false report there is: every instinct says to go and
change the code that just changed.

### Two checks, both watched failing first

- `masonry courses scale with distance` — **15 rows near, 6 far** (was 8 and 5
  with the variants; the pitch is now `h/2` and falls out of the geometry).
- `mortar follows the wall, not the horizon` — new. Stands in a corridor and
  measures the innermost course's distance from the horizon per column, since a
  nearer wall shows *more* courses and "the first dark row" would compare
  different ones. Reads **11.5 rows at the near end, 0.5 at the far end, 11
  distinct offsets**. Run against the shipped v1.4 binary it reads 0.5 and 0.5,
  2 distinct — pinned to the horizon whatever the wall does. That is what makes
  it a test rather than a description.

**66/66**, byte-identical across rebuilds.

---

## The hue seam follows the walls (v1.6)

Tony, having looked at v1.5: *"the colour for the ceiling/floor colour the walls,
as you move closer to them. Is it feasible to have the wall colour very
specifically apply to the walls?"*

Half of it is a hard limit and half of it was a constant nobody had questioned.

### What cannot be done

GTIA mode 9 gives **one hue per scanline**, from `COLBK`. A scanline holding both
wall and ceiling has to pick one, and no amount of cleverness changes that. Two
hues on one line means cycle-exact mid-scanline `COLBK` writes at positions that
differ per line and change every frame — a full-time kernel that would eat the
whole CPU with nothing left to render. ANTIC mode E buys genuinely independent
colours per pixel at the same 40 bytes a row, but only four of them and no
luminance ramp, and the ramp is what every bit of the distance shading, per-cell
lighting and material bias is *encoded in*. That is not a tweak, it is a
different and flatter-looking game.

### What could

The seams were nailed down: `WBAND_TOP = 30` in the generator, and `build_dlist`
planting the interrupt bits at rows 29 and 65 for the life of the program. A wall
two cells away spans rows 16..79, so **44% of it was painted in the ceiling's and
floor's hues** — measured on the pixels, by hue, not inferred.

A column shows wall at row *r* above the horizon exactly when `ktop <= r`. So the
number of columns showing wall is **monotone** in *r*, the majority flips exactly
once, and the best seam is simply the **median `ktop`**. No extra DLIs, no change
to the list's length — which matters, because an overlong display list is what
rolled the picture on hardware run 2. A 48-bucket tally (`HTAB` clamps `ktop` to
0..47, so that is exactly wide enough), one `inc` per column, and a scan to the
halfway point.

Measured, wall pixels carrying the wall's own hue:

| | fixed seams 30/65 | seam = median ktop |
|---|---|---|
| wall head-on, 2 cells | 56.1% | **99.5%** |
| wall head-on, 3 cells | 92.3% | **100%** |
| corridor, looking along | 53.7% | **79.0%** |

and in the other direction, ceiling and floor pixels stolen by the wall band at 4
and 6 cells: **640 and 1,440 → zero**. The corridor is a trade, not a win — its
ceiling/floor error rises from 308 to 972 px, because the two side walls disagree
about where the seam belongs. Looked at side by side it is still plainly better:
the mis-hued ceiling sits near the horizon where the ramp is dark and one dark
hue reads much like another, while a teal band across the top of a wall two cells
away is the thing you actually see.

**+214 bytes, 10.5 → 10.2 fps.**

### The VBI applies it, and that is not fussiness

`seam_calc` runs at the end of a render but only *records* what it wants. The VBI
moves the bits. Patch a display list ANTIC is part-way through and a cleared
interrupt bit the beam has already passed means `dli_1` never fires that frame:
the chain runs one handler short, and the status band takes the floor's hue for a
frame. Rare, brief, and a flash on a CRT. At vertical blank there is no beam and
the question does not arise.

There is no slew limiting. The seam moves in steps of at least two rows (a
deadband, or a one-row wobble would pump it every render), and over 140 ticks of
walking, **0 of its 28 moves reversed direction**. The large jumps are real scene
changes — a wall leaving the view — where snapping is correct and slewing would
show as a colour band crawling up the screen.

### A negative result: the dark caps stay

`wallcap()` darkens wall rows outside the band, and its stated purpose was to
disguise the hue mismatch this change removes. So the obvious follow-on was to
delete it and let near walls run at full luminance to their top edge.

Built it. Head-on it is richer but flat — the vignette was reading as a wall
falling out of the light. In a **corridor it is much worse**: the ceiling vault's
stepped silhouette disappears completely. Above the seam, ceiling and wall now
share a hue, so luminance is the *only* thing separating them, which is precisely
what the function's own comment warned about — "it has to stay BELOW the ramp it
sits against, or the wall's own silhouette disappears." Correct hue made the cap
*more* necessary, not less. Reverted, byte-identical.

(And the first attempt at that experiment measured nothing at all: `build.sh`
deliberately does not run `gentables.py`, so the rebuild contained the old
ladder. [[generated-files-are-caches]] collecting again, on the very session that
wrote the rule down.)

### The occlusion check was a false positive

`sprites occlude behind walls` failed at 4 px. It was not this change, and it was
not the renderer.

The check differenced two whole frames — husk placed, husk absent — and called
every changed pixel a husk drawn through a wall. Measured: the husk's billboard
occupies **columns 36-43**; the offending pixels were at **columns 2-13**. They
were never husk pixels. The two runs sit at different points in the double-buffer
cycle, so a handful of pixels can differ anywhere; this change shifted the frame
timing just enough to land on it. **The shipped v1.5 binary fails the old form of
the check too**, at other frame counts, with a dormant husk that cannot move.

It now counts only differences *inside the husk's own footprint*, measured from
the no-wall pass. Proved it still fires: with the wall removed it reports 70 of 70
pixels visible and fails, so it detects husk pixels rather than having been
softened into always passing.

**67/67**, byte-identical across rebuilds.

---

## Two hues on one scanline: stopped on observability, not on merit

Tony: *"Is it not possible to break the 'one colour per line' rule with some
fancy timing?"* On real hardware, yes — mid-scanline `COLBK` writes are ordinary
Atari practice, and mode 9 is unusually friendly to them because **one mode-9
pixel is exactly one CPU cycle**, so a write can be landed on any pixel boundary
without sub-cycle tricks.

The spike ran with a kill criterion agreed up front: *hold ≥9 fps and lose the
seam artefacts on the CRT, or stop.* It stopped, but not where expected.

### The probe that ended it

Six different hues, written ~10 instruction cycles apart, across a single
scanline, twenty-four lines running. If a mid-line write registers at all, that
has to show six vertical bands.

Every line came out **one hue — `B`, the last value written.** Our libatari800
samples the colour registers once per scanline and takes the final value;
intra-line changes are not modelled. `-cycle-exact` and `-antic-cycle-exact` are
not options in this build (the emulator treats them as filenames), and there is
no local source tree to rebuild with `NEW_CYCLE_EXACT`.

So the harness cannot see the thing being built. Every iteration would be blind,
with the only feedback a CRT in another room — on the most timing-sensitive
class of code there is. That is a *third* instance of the standing question, and
the first time the answer has been "this harness cannot see it **at all**".

### What the spike did establish, by measurement

The cost stopped being an estimate. A tight WSYNC-paced kernel over 24 scanlines
runs at **10.00 fps against 10.40 baseline** — 3.8%, or ~0.16% a scanline, which
is the ~62-free-cycles-per-line figure confirmed from the other side.
Extrapolated: **~9.1 fps** for a level start (80 scanlines) and **~7.2 fps** down
a corridor (192). That is *better* than the 8.3/5.4 I quoted, which was an upper
bound — the real cost is about two thirds of it.

And a hard design constraint, found the expensive way: **the loop body must fit
inside one scanline.** The first version's computed jump cost 23 cycles, the body
overran, each iteration ate *two* lines — 15% for the same 24 lines, and whole
lines flipping hue rather than splitting. Dropping to a patched low byte and a
page-aligned slide brought it to 18 cycles. With ~62 instruction cycles a line
and ~18 fixed, only ~44 remain for positioning: roughly two thirds of the screen
width, at 2-cycle (≈3-pixel) granularity. Not the free hand it looks like.

Two self-inflicted bugs worth keeping:

- The NOP slide was indexed **two bytes per NOP**. `NOP` is one byte and two
  cycles; conflating those jumped clean past the slide into whatever followed.
- The slide's entry byte defaulted to **zero**, which pointed at the routine's
  own entry point. The DLI recursed and the machine hung from boot — diagnosed
  from the frame rate reading exactly `0.00`.

The `ert * > $4000` guard also fired the moment the experiment grew game.asm
into the display lists, which is the fifth time that law has collected.
### The cycle-exact rebuild — tried, and it does not help

The obvious escape was to rebuild the emulator with sight. The source tree was
already here, so: `./configure --target=libatari800 --enable-newcycleexact`.

Configure printed **"Using cycle exact?....................: yes"** and left
`/* #undef NEW_CYCLE_EXACT */` in `config.h`. Its own logic:

```
if [ "$a8_target" = "libatari800" ]; then
    WANT_NEW_CYCLE_EXACT=yes          # sets the variable...
elif [ ... ]; then
    ...  #define NEW_CYCLE_EXACT 1    # ...but only this branch emits the macro
```

For the libatari800 target the flag is set and the macro is never defined. An
upstream bug, and a fine specimen of the genre: the build **reports a capability
it does not have.** `antic.c` carries 40 references to that macro and `gtia.c`
20 — all compiled out, while the summary says yes.

Defined it by hand and rebuilt; `antic.o` now genuinely calls `CYCLE_MAP_*`, so
the cycle-exact code is live. Linked a second dylib alongside the original,
re-ran the probe. **No change.** Then, to separate "the emulator cannot" from
"GTIA mode 9 specifically resists", ran the same probe in plain ANTIC F writing
COLPF2 — the register that actually paints the hi-res background. Also no
change: different lines take different values, no line ever splits.

Settled across two graphics modes, two colour registers and two emulator builds:
**libatari800 renders one colour-register value per scanline.** NEW_CYCLE_EXACT
buys DMA and CPU cycle accounting, not intra-scanline colour.

The link needed unpicking, which is worth recording. `src/` and
`src/libatari800/` each contain `sound.o`, `input.o`, `video.o` and
`statesav.o`, and they are not duplicates but *complements*: `src/` defines
`Sound_*`/`INPUT_*`/`StateSav_*`, the subdirectory defines the `PLATFORM_*`
backends. Both are needed. `file_export.o` cannot link for this target at all —
`video_frame_count` is compiled out — so it takes a no-op stub.

### Where it rests

Not killed on merit — killed on observability, and the one fix available does
not fix it. It needs either a different emulator (Altirra models this properly)
or a calibrate-on-hardware round trip: ship a test image whose every line
carries a *known* delay, photograph the CRT once, read the delay→pixel mapping
straight off the picture, and write the real kernel against measured constants
instead of guesses. That converts "blind" into one round trip.

Reverted byte-identical to v1.6; sweep still 67/67; nothing shipped.

---

## Run 5, and the calibration image

**v1.5 and v1.6 confirmed on the CRT.** The perspective mortar and the moving
hue seam — the two changes that had been measured but never seen on real
hardware, and both of them renderer changes — are good on the 800XL. Nothing in
this document is emulator-only again.

That clears the way for the mid-scanline experiment, on the terms it stopped on:
the harness cannot see sub-scanline colour, so the constants have to come from
the machine. Rather than write the kernel blind, `calib.xex` asks the machine
directly.

### What it is

`./build.sh -d:CALIB=1` builds a calibration image instead of the game. It
borrows ABYSS's own display — same display list (232 scanlines), same GTIA mode
9, same BASIC-off INIT stub — because setting up a screen is exactly the part
that went wrong twice when this was attempted standalone.

The picture is a **staircase**: ninety scanlines in fifteen steps of six, each
step waiting two cycles longer than the one below before switching COLBK from
hue A to hue B. Underneath is a **ruler drawn in luminance** — a bright tick
every eight pixels, a black notch at centre — which is independent of the hue
being switched, so the photograph carries its own scale.

One photograph answers all three open questions: whether a mid-line write splits
a line in GTIA 9 at all; whether the edge is clean or smears across GTIA's
four-hi-res-pixel cell; and the delay→pixel mapping, so the real kernel can be
written against measured constants. If the top steps do not split, that marks
where the per-line cycle budget runs out — which is also worth knowing.

### Three placement bugs, all caught before it went near hardware

- **Buffer B is not free.** It looks unused in this build (nothing flips pages)
  but init calls `clear_screen`, which zeroes 31 pages from `$8000`. Code parked
  at `$9400` was wiped between load and entry and the jump landed in zeros. The
  code now lives in the 442-byte gap between DLISTB's end and `LEVELDATA`, the
  table at `$9F00`, one page above where `clear_screen` stops.
- **mads has a flat, case-insensitive namespace.** `_cf_st` in the new file
  silently bound to `check_floor`'s `_cf_st` in game.asm at `$3F61` — reported
  as "branch out of range by $5423 bytes", which is exactly that distance. Every
  label in the file now carries a `_kal_` prefix.
- **`tya` clobbers the accumulator.** `lda #$44` immediately before it meant the
  ruler's background came out as the column index rather than a constant.

Verified in the emulator as far as it can go: boots, does not hang, display list
still 232 scanlines, the picture is identical across frames, the HUD is blanked,
the ruler is exact in memory, and the staircase's table steps every six lines.
What it cannot show is the only thing being asked.

---

## It works. Two hues on one scanline, on a real 800XL

The calibration image went onto the CRT and came back a **clean staircase**.

That answers, at a stroke, the question this emulator could not be made to
answer at all — not in the default build, not in a cycle-exact one, not in GTIA
mode 9 and not in plain ANTIC F. **A mid-scanline `COLBK` write splits a line on
real hardware, and the edges are crisp.** No smear across GTIA's four-hi-res-
pixel cell, which was the failure mode I thought most likely to sink it.

Read off the photograph, against the luminance ruler:

- the steps are **even**, so delay → pixel is linear, as predicted
- the staircase spans roughly **pixels 0 to 32** for 14 NOPs (28 cycles), so
  about **1.1–1.2 pixels per cycle** — close to the theoretical one mode-9 pixel
  per machine cycle
- full-width bands at the top of the run are, most likely, the steps whose body
  overran its scanline

That last one is the number that matters most and the one the image was too
timid to pin down: **how far right can the transition be pushed before the
per-line budget runs out?** With only 14 NOPs in the slide I may simply not have
asked for enough. If the true ceiling is ~32 pixels then the trick only helps on
the left third of the screen — in a corridor that is the left wall and not the
right one, which is half a feature.

### Round two asks the question properly

`calib.xex` now carries a **40-NOP slide over 20 steps, four cycles apart**,
deliberately demanding far more delay than a scanline can afford. Steps past the
limit take two scanlines instead of one and so come out **double height** — so
the first tall step *is* the measurement. Above and below the staircase sit
solid bands in a **third hue**, because the first version's top marker was hue A
against a screen that was already hue A and therefore invisible.

One more photograph gives the slope, the reachable window, and the cliff edge —
and then the kernel gets written against measured constants with nothing left to
guess.

---

## The measurement, and what it costs

Four rounds on the CRT. The constants, with the confidence each deserves:

| | value | how |
|---|---|---|
| mid-line `COLBK` split in GTIA 9 | **works, edges clean** | CRT, rounds 1/3/4 — no smear across GTIA's 4-pixel cell |
| per-line budget | **12 NOPs fit, 14 do not** | emulator: an overrunning step takes two scanlines, so the band's HEIGHT gives it away. ~58–61 instruction cycles |
| delay → pixel | **≈4 pixels per cycle** (≈8 per NOP) | CRT round 4: three block edges at ~pixels 14 / 54 / 76, four NOPs apart. ±25% |
| reachable range | **12 NOPs ≈ 94 px > the 80-px width** | follows from the above, and explains why round 3's steps kept running off the left edge |
| placement granularity | **~8 px per NOP** (~4 with odd-cycle padding) | one NOP is the finest step the slide offers |

So the whole width is reachable, the edge is clean, and the seam can be placed
to within about a tenth of the screen — which is far finer than the thing being
corrected. **The idea is sound and buildable.**

### The honest price

A serviced scanline costs its whole free-cycle budget: measured earlier at
**~0.16% of a frame per scanline**. Against the 67-check sweep's baseline of
10.4 fps that is:

- 20 buffer rows (40 scanlines) — a fixed budget spent on the worst rows: **~9.7 fps**
- every mixed row at a level start (80 scanlines): **~9.1 fps**
- every mixed row down a corridor (192 scanlines): **~7.2 fps**

against ~79% wall-hue correctness in a corridor today, which the per-scanline
version would take close to 100% — and would fix the mis-hued ceiling as well,
which the moving seam cannot.

### Four rounds, three of them my fault

Round 1 answered the real question and I should have stopped to think harder
about what round 2 needed to be. Round 2 asked for 40 NOPs — far past the
budget — so most steps overran and the picture was unreadable. Round 3 was
correct but drew twelve steps a few pixels apart, finer than a photograph of a
CRT resolves; my slope estimates off it ranged over a factor of three. Round 4
asked for four big blocks and was legible immediately.

The lesson is not about the 6502. **An instrument has a resolution, and asking
it for more precision than it has does not give you a rough answer — it gives
you a confident wrong one.** Three of my four rounds asked the CRT and a phone
camera for more than they could deliver. The fix each time was to ask for less,
more clearly.

---

## Built it, measured it, did not ship it

The mid-line hue kernel works. It is not worth its price, and the number that
says so is not close.

**Whole-view wall/ceiling hue correctness, against v1.6:**

| scene | v1.6 seam | + mid-line kernel |
|---|---|---|
| level 1 as it starts | 92.3% | **92.3%** (+0.0) |
| flat wall, 3 cells | 97.9% | 99.0% (+1.0) |
| flat wall, 4 cells | 99.0% | 100.0% (+1.0) |
| wide corridor | 90.5% | 91.9% (+1.4) |

**Cost: 10.40 → 9.40 fps.** A tenth of the frame rate for at most 1.4 points.

The reason is v1.6 itself. The moving seam already took the whole view from
56–79% to 90–99%, so what remains is thin and scattered, and one split per line
can only recover part of it. **The predecessor was too good for its successor to
justify itself.**

Nor does a better version exist. The *theoretical best* single split adds only 3
further points inside the band (~0.5 across the view); servicing all 96 rows
instead of 16 would cost ~30% of the frame rate for a few points more; and two
splits a line — which is what a doorway view actually needs — does not fit in
58 cycles. Every direction is worse.

### What the build taught anyway

- **A doorway is the common case, and it is the one case a single split cannot
  help.** Looking through a door the row reads wall│ceiling│wall; one split
  rescues one wall and loses the other. Measured, the best possible split ties
  the seam exactly, and a *carelessly chosen* one scored **76% against the
  seam's 85% — worse than doing nothing.** The fix was to compare the two costs
  per row and leave the row alone unless the split wins, which makes the kernel
  never-worse by construction. Any optimisation that can fire when it does not
  help will eventually fire when it hurts.
- **`ert` earned its keep twice more.** The zero-page guard caught main.asm's
  block growing past `$AF`; the new overlap assertion caught `ml_kernel` org'd
  at `$3370`, exactly on top of `mlon`/`mlrow` at `RAMTAB+880`. The
  end-of-region guard could not see that — a region can fit perfectly and still
  be sitting on something. **Guard the start as well as the end.**
- The kernel itself is sound: 38 fixed cycles plus two a NOP, ten NOPs, 58
  against a measured 58–61 budget, entry read from a table because computing it
  cost 23 cycles on its own. If anyone wants it, it is in this commit's history.

### The shape of the whole thread

A question — *can fancy timing beat one colour per line?* — that turned out to
have three separate answers. **Yes** on real hardware, with clean edges. **No**
in any emulator available here, which took a cycle-exact rebuild and an upstream
configure bug to establish. And **not worth it** in this game, which took
building the thing and measuring it against the version it was meant to beat.

Only the third answer required writing the feature, and only measuring it
against the incumbent could have produced it. **v1.6 stands.** 67/67,
byte-identical, nothing shipped.

---

## Gameplay: what the levels were already asking for

Tony asked what could improve the *game* rather than the renderer. Rather than
reach for new mechanics, I read what the four level files ask for and the
runtime ignores. The `.lev` format turns out to specify a complete design that
was never wired up:

| authored | in the game before this |
|---|---|
| 17 trigger records (`trig ambush group=N`) | never loaded |
| 20 door records, 14 sealed cells | never open |
| 14 actors `asleep group=N` behind them | unreachable |
| a locked door + matching key on two levels | flattened to plain doors |
| par times: 90 / 150 / 180 / 240 s | unread |

The designer's notes say what they were for. THE RED CISTERN: *"show the locked
door on the way IN, not on the way back."* THE MAW: *"trying the door and being
refused. The refusal is the level's first real beat."* Neither beat happened.

### Par times — shipped

The end card now reads `TIME 017  PAR 660`. PARTOTAL is summed from the level
files at generate time and the digits computed at assembly time, so editing a
par in a `.lev` moves what the card shows: derived, not typed. The clock is kept
as **three digits** by the VBI rather than a 16-bit second count, so the end card
needs no divide -- three increments with a carry, one frame in fifty, clamped at
999. `run_clock` lives in the RAMTAB gap because game.asm had 53 bytes to the
display lists and the clock is about 70; its guard said so immediately.

### "Too hard" was a legibility bug, and the sweep was complicit — shipped

Tony reported wandering without finding the exit. Tested rather than assumed:
**no bug.** All four exits exist and are reachable on foot, 26-64 steps from
spawn. The sweep's `every level has an exit` was true and useless -- it
**path-finds with perfect knowledge of the map**. Reachable is not findable, and
that is the self-fulfilling-test family aimed at level design instead of code.

Measured, the exit was:

- in line of sight from only **13-18%** of a level's open cells (36% in THE MAW),
  and within the 4-cell range where it looked distinctive from **6-12%**
- **fading with distance** -- +3.8 luminance steps clear of stone at three cells,
  +1.2 at ten -- because a material bias shifts the shade INDEX and the ramp
  flattens with range. It shouted when you stood on it and whispered when you
  were looking for it.
- **byte-identical to the decorative glow material at every distance**
  (14.0/13.8/10.8/9.6/9.0 for both), since both are `MAT_DARKER` 0.0 and 0.0 is
  the cap. "Bright" could not mean "out".

Three table-level fixes: glow steps back to 0.8; the exit gets an absolute
luminance immune to the ramp; and it **pulses**, from the 50 Hz layer. Nothing
else in this world moves, so the eye finds it with no HUD, no arrow and no map --
and it still says nothing about *where* the exit is until you can already see it.
The challenge is untouched; only the legibility changed. Now +1.2 steps clear at
two cells rising to **+5.0 at eight**: the advantage GROWS with range instead of
collapsing. The pulse floor is 12 because measured stone reaches 10.9 up close,
and a first attempt with a trough of 9 made the exit read DARKER than the wall at
two cells -- the one range where it had been working.

### Keys and locked doors — built, measured, NOT shipped

The engine half is done and proven on the real binary:

    keys=0 -> stopped at cell 16, door stays $09          REFUSED
    keys=1 -> door opens to $00, player walks to cell 18  THROUGH

The compiler places each key at the position its designer chose, ahead of
supplies, because without it the level cannot be finished.

**The same mistake three times in one sitting, and it is worth naming.** This
engine carries live state in X across routine boundaries in three places, and I
clobbered it in all three:

1. `open_last` writes the cell through X, which still holds the index
   `cell_solid` left there -- its comment literally says *"X must be untouched"*.
   Indexing `bitmask` with `tax` for the key test opened a cell in the far column
   of the same row instead of the door, silently, and the door stayed shut.
2. `check_items` iterates with X. The same `tax` destroyed the loop counter and
   **hung the whole game** the instant you touched a key -- which from outside
   looked exactly like the autoplayer refusing to walk, and sent me debugging the
   harness for an hour. The giveaway was `renders +0`: not a wedged walker, a
   stopped machine.
3. and the walker's own stuck-escape, which turned blindly right regardless of
   where the goal was.

Rule earned: **before using X or Y as a scratch index, find out what the caller
left there.** A register is an interface.

It is still held back at the compiler, and the reason has narrowed to one thing:
picking up level 2's red key (type 2, bit 0) leaves the inventory reading **5** --
bit 0 and bit 2, and bit 2 is level 4's yellow. Inside a single tick, with
`itmgot` showing exactly one item taken, and both the assembled branches and the
runtime item tables correct on inspection. Until that is understood a key could
open a door it never earned, which is worse than having no keys. One loop in
`levels.py`, clearly marked, is the whole switch-on.

### Harness work banked along the way

- `route()` takes a keys bitmask and treats a coloured door as wall without it --
  the same rule the player plays by, so it cannot route through a door it has
  not earned
- `_exits` computes reachability as a **fixed point**: expand, collect any key
  within reach, expand again
- `walk_to()` / `level_keys()` drive the player to an arbitrary cell and read the
  authored key positions out of `items.inc`
- both stuck detectors now measure **progress toward the goal** rather than exact
  position equality (a wedged walker still jitters a fraction of a cell every
  tick, so equality never accumulated and the escape never fired), and both
  escapes **back out** before turning, because the key on THE RED CISTERN sits in
  a one-cell alcove between two columns that a turn-and-push walker can enter and
  never leave

With those, all four descents complete -- including the one that needs a key.

**69/69.** Triggers and ambushes are next; they need the same descent machinery,
which now works.

---

## The phantom yellow key, and a bug that had corrupted every pickup

Keys ship. The thing standing in the way was not the key code.

Picking up level 2's red key -- type 2, bit 0 -- left the inventory reading **5**:
bit 0 *and* bit 2, and bit 2 is level 4's yellow. A key the player had never
found. Static reading got nowhere, so I stopped reading and started measuring:

- **Probe 1: is my code even the writer?** Changed red to set bit 3 instead of
  bit 0. Inventory read **12**, not 8. So my code wrote its 8 and something else
  contributed a 4.
- **Probe 2: is it a stray write to that address?** Moved the inventory byte from
  `$7A59` to `$7A70`. The phantom bit **followed the symbol**, so it was not a
  stray store into the old location -- it was going through the one and only
  `sta keys`.
- **Probe 3: how many times does that line run?** `inc` on a spare byte at the
  branch. Answer: **22 times, then 72, then 196** -- continuously, while `itmgot`
  showed exactly one item taken. Not two pickups. One pickup and a loop that
  would not end.

`audio_play` takes the sound id in X (`tax`) and never gives it back.
`check_items` iterates on X. So **every pickup since items existed** left the
loop counter at 10 and ran the loop on for ~250 iterations over garbage item
records. Harmless-looking for the game's whole life, because a stray type byte
could only ever mean "medkit" -- until keys arrived and garbage started reading
as type 4.

Four bytes of `pha`/`pla` around the sound call. The inventory reads 1.

**That is the fourth X-clobber of this stretch**, and the pattern is no longer a
coincidence: `open_last` carries the cell index in X, `check_items` carries its
loop counter in X, `audio_play` destroys X, and the walker's escape had its own
version. **A register is an interface.** Three of the four were mine; the fourth
had been shipping since the audio engine went in.

Worth noting what pointed the way. The assembled branches had already been
checked in the LISTING and the item tables in RAM, both correct -- which is
exactly what ruled out the arithmetic and left the loop. Verifying the things
that were right is what made the remaining possibility obvious.

### What ships

THE RED CISTERN's red door and THE MAW's yellow one, as authored, each with the
key its designer placed -- ahead of supplies in the item table, because without
it the level cannot be finished. Both had been flattened to plain doors for the
game's entire life.

    descend 1 -> level 2   keys 0
    descend 2 -> level 3   keys 1    (red)
    descend 3 -> level 4   keys 1
    descend 4 -> victory   keys 5    (red + yellow)

The harness plays by the same rules: `route()` treats a coloured door as wall
without its key, `_exits` computes reachability as a fixed point over keys within
reach, and both `descend()` and `playthrough()` fetch a key when the exit needs
one. The new check asserts refused-without, opens-with, **and that one key sets
exactly one bit** -- the half that was silently wrong and would have passed a
check that only tested the door.

**70/70**, byte-identical across rebuilds.

---

## "I don't seem to move to the next floor"

Tony, on hardware: clears THE VESTIBULE, reads *FLOOR CLEARED - KILLS 005*,
walks onto the pulsing exit, and nothing happens.

Tested rather than assumed, and the code is innocent. Standing on the exit sets
`wondone`; I left it sixty ticks and the level did not advance; one trigger pull
and `levelno` went 0 to 1. **Reaching the exit halts and waits for FIRE, by
design** -- a beat to read the tally before dropping.

The bug is that the banner never said so:

| state | what it told you |
|---|---|
| title | PRESS FIRE TO DESCEND |
| death | YOU DIED - FIRE TO RETRY |
| end card | FIRE AGAIN |
| **floor cleared** | **FLOOR CLEARED - KILLS 005** |

Every waiting state in the game announced itself except the one a player meets
three times a run. It now reads `FIRE TO DESCEND      KILLS 000`.

Two things worth keeping from this.

**Only a fresh player could find it.** Everyone who knew the game pressed fire
without thinking, because pressing fire is what you do -- the knowledge that made
the sweep's `descend()` correct (it pulls the trigger) is the same knowledge that
made the omission invisible. Round ten of the visual critique found three defects
by being forbidden the source; this is the same instrument pointed at
interaction. **A reviewer who knows the controls stops being able to see the
prompt.**

**Sixty-nine green checks and none of them asked "does the player know what to
do?"** They asked whether the mechanism worked, in every direction, at pixel
level. The new check asks a different question: does a state that STOPS say what
it is waiting for? It asserts both halves -- that reaching the exit really does
halt (60 ticks, no advance), and that the banner names the key. Either half alone
would pass a broken game.

**71/71.**

---

## The manual, and the two things writing it found

Tony: *"I think we need to write up game instructions, for players to read!"*

Fair. The game had, until yesterday, a floor-cleared banner that did not say
what it wanted; the deeper version of that problem is that nothing anywhere
said what the shotgun does, why you should walk into a monster's face, or that
a click means a key rather than a wall.

So: [`docs/PLAYING.md`](docs/PLAYING.md), and a HOW TO PLAY section on the site
for the people who arrive at the browser build and start pressing things.

Writing it meant reading the game rather than remembering it, and that turned
up two defects and a lie.

### 1. Keys were cleared per SESSION, not per run

`keys` lives in the `$7A00` page that `game_init` wipes **once, at boot**.
Nothing else ever touched it. So the red ring you found on THE RED CISTERN
stayed on your belt through dying, through escaping, and into every game you
started afterwards — the locked doors stood open on a run that had not earned
them. The comment beside the variable said *"cleared per RUN"*. It had never
been true.

One instruction in `restart_level`, which both the death retry and the
victory restart pass through.

Why 71 checks missed it: **every one of them boots a fresh machine**, which is
the single condition under which the bug cannot appear. A test suite that
always starts clean cannot see state that fails to reset.

Before shipping it I checked the obvious way to make this a soft-lock — die on
a floor whose exit is behind a locked door, and lose the key you needed. It
isn't one, and the reason is in the level design rather than the code: every
locked floor carries its own key, so the retry can always fetch it again.
Measured on the running machine, not reasoned about:

```
THE RED CISTERN  key before death=1  after retry=0  recovered=1  exit reachable: yes (38 steps)
THE MAW          key before death=5  after retry=0  recovered=4  exit reachable: yes (33 steps)
```

That fix then broke `the game can be completed`, and correctly: the autoplayer
re-routed after dying but never went back for the key, because until now it had
never had to. It does now. The sweep's own re-route calls were also passing
`keys=0` implicitly — harmless while keys were immortal, wrong the moment they
weren't.

**72/72.**

### 2. The site described monsters the game does not place

`THE DESCENT` promised *"spitters that never stop"* and *"hulks"*, plural. The
spawn table says otherwise, and the spawn table is what runs:

| floor | what is actually there |
|---|---|
| THE VESTIBULE | 5 husks |
| THE RED CISTERN | 3 husks, 2 gunners |
| SILENT COLONNADE | 3 husks, 2 gunners |
| THE MAW | 2 husks, 2 gunners, **1 hulk** |

There are no spitters in the shipped game, and exactly one hulk in the whole
descent — which is a better fact than the one the copy invented. The bestiary
screenshot was captioned *"a hulk towers over a husk in THE RED CISTERN"*, a
floor that has no hulk on it: the shot predates typed monsters entirely, from
when the engine had one enemy and the levels' types were discarded.

Recaptured the real thing — the actual hulk, three cells away on THE MAW, with
`AC_TYPE` asserted at the moment of capture, the same rule `gallery.py` already
applies to everything else. The caption now says what the picture shows.

### What both have in common

Neither is a coding error. Both are **claims that stopped tracking the code** —
a comment that described intent, and marketing copy written when the engine
had one enemy. The code moved; the words did not.

Which is the argument for writing the manual at all. Documentation for players
is the one document you cannot write from memory, because it has to describe
what the machine does rather than what you meant it to do. Two rounds of
adversarial visual review and 71 green checks did not find these. *Writing down
how to play* found both in an afternoon.

---

## The map, and who owns a colour

Tony asked about two ideas: a compass in the status bar, and a map on a
keypress. The levels answered the first question. Every floor in this game is
dominated by pillar halls with a regular `#..#..#..#` lattice — stand anywhere
in one, face any direction, and the view is identical. That is a manufactured
disorientation and there was nothing in the game that answered it.

But the same geometry argues against a *plain* map. These floors are not mazes;
they are three or four halls chained by short corridors, and THE VESTIBULE is
26% open. A map of that is not a tool for solving anything — there is nothing
to solve — it is just the answer, handed over on every floor from the first
second, and it would have walked straight over the one thing the exit is built
around: the pulsing doorway says nothing about *where* the way out is until you
can already see it.

So: fog of war, which is the version that keeps both.

### The fog is the raycaster's own work

No second system, no visibility pass, no flood fill. The DDA already walks the
grid 40 times a frame and already knows two things at the moment it stops: the
wall cell it landed on, and the open cell it was standing in when it did. The
first is in `mptr`; the second the light sampler computes anyway, because a
wall is lit by the room in front of it. Both get written into `VIS`, and that
is the entire fog system — about 40 bytes of code inside `render_view`, at a
cost too small to measure (renders per 20 frames: 4 before, 4 after).

`VIS` holds the finished *map byte*, not the material id. The lookup happens
once, at the instant a cell is seen, which is the one moment the material is
already in a register — and it turns drawing the map into a straight copy with
no per-cell decisions at all.

The wall mark alone was not enough. Forty rays walking down a corridor all land
on the far wall and none of them land on the walls they are passing, so a hall
you had crossed drew as a dotted line and two pillars. Adding the open cell —
one more store, on a pointer that was already there — took a crossing of THE
VESTIBULE from 113 mapped cells to 190, and turned speckle into a floor plan.

### What the table is for

`MAPLUM` is a 16-entry table rather than a chain of comparisons for exactly one
reason: index `$0D` is the secret wall, and it must come out byte-identical to
stone at `$01`. A comparison would have been shorter and would have invited
somebody to give secrets their own shade "so they read properly". One table
entry is the difference between a map and a cheat sheet. The sweep now reads
that table back out of the binary and asserts it — checking a played floor
would only have covered the secrets the autoplayer happened to glance at, and
on a run where it glanced at none, the check would have passed by testing
nothing.

### Three scanlines, not two

The first version drew cells 2×2 pixels. It was wrong, and wrong in the way a
navigation aid must never be: a mode 9 pixel is 2 colour clocks across and a
buffer row is 2 scanlines, so on a 4:3 screen one pixel is 1.6 times wider than
it is tall — and every square hall in the game drew as a landscape rectangle
twice its real width. Two pixels by *three* rows comes out at 1.07:1, and 32
rows of 3 is exactly the 96 the buffer has. The map fills the screen and the
rooms are the shape they are.

### The bug: a colour is not yours to set

`map_mode` set `hceil`, `hwall` and `hfloor` to a flat blue and drew. The map
came up in the level's own ceiling, wall and floor stripes anyway, seamed at
whatever row the last render had left the DLIs — and the stores were provably
landing, `85 CA / 85 CB / 85 CC` right there in the listing.

The VBI rewrites all three, from the level tables, **every single frame**. It
is a priority chain — victory, death, pain flash, muzzle flash, normal — and
the bottom of it repaints the hues unconditionally. Nothing outside that chain
can hold a colour for longer than 20ms. The writes were landing and being
undone before the beam reached them.

The fix is not to write harder. It is `mapon`: a flag the VBI reads, and a new
top entry in the chain that owns the hue while the map is up. Which is the
general shape of the thing — **if some code repaints a register every frame,
that code owns the register**, and everyone else asks.

### What it costs the player

The world stops while the map is up and the run clock does not. That fell out
of the implementation rather than being designed: the main loop is not
frame-locked, so freezing it was the only way to look at the map without the
loop free-running and driving the enemies at three times speed. But it is the
right rule. The map is free in blood and expensive in par, and par is the thing
the game actually scores.

Dying wipes it, like the doors, the items, the kill tally and the keys.

### Verifying it

Three new checks, **75/75**:

- **the map only shows what you looked at** — after crossing THE VESTIBULE, 190
  cells seen, 834 still dark, and **0 disagreeing with the grid**. That last
  number is the one with teeth: an off-by-one in the `VIS` offset still produces
  a perfectly plausible map, drawn one cell or one row out of true, and no
  screenshot can tell you, because there is nothing in the picture to compare it
  against. Comparing it cell by cell against the grid it came from is the only
  way to know.
- **the map does not give the secrets away** — the palette, read back out of the
  binary.
- **START holds the map up and stops the world** — the framebuffer compared
  against `VIS` row by row: exactly **2 cells** disagree, the player blip and its
  facing nose, which are the only two allowed to.

The web player needed the same wiring — byte 5 of the input template was never
being set, so `M` did nothing in a browser. Verified in Playwright the only way
that means anything: with the key held, the ceiling band and the floor band
sample to the *same* RGB (0,22,36); released, they are (27,33,43) and
(106,35,22). The key reaches the machine.

Checked on the CRT and signed off: the flat hue holds, and luminance 4 floor
against luminance 8 wall separates as cleanly on a real screen as it does in a
PNG. Which was the open question — the aspect-ratio arithmetic said the cells
would come out square on a 4:3 tube, but the emulator renders 384x240 square
buffer pixels and cannot show you that, so the shape of the map was the one
thing no amount of sweeping could confirm.
