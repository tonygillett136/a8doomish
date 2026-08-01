# ABYSS — the road from here

Where the "exponentially more fantastic" plan stands after the 39-minute
sprint of 1 August 2026, and what comes next, in order of gameplay-per-byte.

## Done in the sprint

- **v1.0 tagged and released** from the hardware-confirmed build — a release
  should be the proven thing, so this happened *before* any new code.
- **M1, the bestiary — SHIPPED.** Each level casts the monsters its level file
  authors: husks (60 HP, the one-shot baseline), gunners (32 HP, fires almost
  twice as often), spitters (constant weak fireballs), hulks (exactly two
  point-blank shots, melee 16, towers 1.23× on screen — measured). Fireballs
  carry their shooter's damage. A KILLS counter feeds the end card.
  61/61 checks, deployed to the website the same half-hour.

## Next, in order

### M2 — The Machinery
- **Triggers / monster closets.** The single most DOOM feeling there is —
  a wall drops and the room you cleared isn't clear. The level format authors
  them; the runtime never loads them. Needs the packed-level format extended
  to carry trigger records (genlevels.py + rle_decode + a per-move cell check),
  which is why it did not fit in 39 minutes: it touches the byte-exact plane
  checks and deserves a calm session. SILENT COLONNADE has eight enemies
  waiting in closets for this.
- **Keys and locked doors.** Two levels author them; the compiler currently
  downgrades locked doors to plain so exits stay reachable. Key pickups exist
  in the item format. Needs: key state, door gating, HUD indicator.
- **Exploding barrels.** Authored in THE MAW. A barrel is an actor with 1 HP
  whose death deals radius damage — the infight machinery already knows how to
  hurt actors by slot.

### M3 — The Maw
The boss. The authored maw currently ships with hulk stats (honest placeholder).
Real behaviour wants: a bigger sprite (band-shifted like the hulk trick),
a two-phase attack pattern (spit volley → charge), and a death that ends the
level. The end card already reports kills; add par time.

### M4 — The Score
- Title music + level-start sting (the audio engine has priority room).
- Attract mode: self-playing demo on the title (recipe exists from Scopa).
- Difficulty arc pass across the four levels, using the type mix per level —
  the knobs all exist now.

### M5 — The Release
- **ABBUC Software Contest** entry (submissions typically close late summer —
  check the current year's deadline EARLY).
- AtariAge homebrew forum post with the site link.
- itch.io page embedding the web build.
- **Cartridge feasibility**: 28.9 KB fits a 32K cart image; investigate
  bank-free $8000-$BFFF mapping vs the current load map (framebuffers at
  $8000-$9EFF conflict — a cart build needs a copy-to-RAM loader stub).

## Constraints to respect

- **Memory:** ~29 KB placed; the free-region audit (scout, 2026-08-01) found
  the useful gaps: ~$2487-$2B3F engine tail (guarded), $4E76-$4FFF, $A230-$A8FF
  (~1.6 KB, the big one), $AC44-$AFFF, $BE7B-$BFFF. Sprite art for new poses is
  the hungriest consumer (~1 KB per pose set across 5 bands) — RLE the sprite
  blob before adding a second full character.
- **The design law:** HP steps are whole point-blank shots. Never inflation.
- **Every boundary gets an `ert` on both sides**, and every new behaviour gets
  a sweep check that would fail if the behaviour were absent — the bestiary
  shipped bulletproof statues past 60 green checks for twenty minutes because
  the checks proved spawning, not fighting.
- **Nothing ships without the full sweep green, and hardware retests after
  display/memory-map changes.**
