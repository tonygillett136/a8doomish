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
- **ABBUC Software Contest**: the 2026 game deadline appears to have been
  31 July 2026 — the day ABYSS was built (verify on abbuc.de; found via search
  2026-08-01). Target the **2027** contest, which buys a year for M2-M4 to land
  first. AtariAge + itch.io need no deadline; do those any time.
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

## The wider menu (banked 2026-08-01, priced against the real engine)

### Cheap juice — hours each, mostly one-site changes
- **Hit knockback + screen kick when YOU are hit** — reuse `wkick` on damage
  taken; a velocity impulse away from the attacker. Three lines; damage FELT.
- **Enemy pain flash** — brighten a husk's sprite for one render tick on hit
  (the pain state already exists in the AI; only the draw needs to know).
- **Fireball visibility audit** — slots 6-7 are drawn via the same husk art
  path; VERIFY what an incoming ball actually looks like and give it a real
  sprite (a bright blob; band-4 pickup art is nearly free). Fairness issue.
- **Secrets that count** — the map format has an A_SECRET attribute bit and
  secret doors already open on use; count first entries, report on the end
  card next to kills.
- **Hurt floors** — the attribute format has a bit7 `hurt` flag NOBODY reads.
  Lava in THE MAW for the cost of one attr test in move_player.
- **Title shimmer** — VBI-cycle the wordmark ramp. Demoscene points.

### Medium — a session each
- **Strafing** — the DOOM feel gap. One joystick button, so it needs a
  modifier design: OPTION/SELECT console keys as strafe-hold is period-correct
  and free of the fire button.
- **Doors that open visibly** — animate the luminance over ~4 ticks.
- **Per-type attack sounds** — the audio engine has priority slots spare;
  a hulk should ROAR.
- **Floor intermission card** — "FLOOR CLEARED · KILLS 4/5 · 0:47" between
  levels; the banner row exists, par times are a table.
- **NTSC verification** — the 232-line display list already fits NTSC's 240;
  timings run ~17% faster (telegraph 0.40s→0.33s). One sweep run under
  `-ntsc` + a README note opens the US hardware audience.
- **Web: Gamepad API + touch polish** in player.js (~20 lines).
- **Web: a GLOBAL leaderboard** — the site already peeks kills/health out of
  emulated RAM at victory; a tiny Cloudflare Worker + KV turns that into a
  worldwide high-score table around an unmodified 1983 binary. This is the
  single most "exponential" cheap thing on the list.
- **CI** — GitHub Action building mads + libatari800 from source (cached) and
  running the 61-check sweep on every push.

### Big rocks — the ones already in M2-M5 above
Triggers/closets → keys → barrels → the Maw's real boss behaviour → music +
attract mode → four MORE floors (authoring is cheap: ~550 packed bytes per
level; an eight-floor "episode" is ~2.2 KB) → cartridge build (needs a
copy-to-RAM stub; framebuffers occupy the cart window) → the weapon-reads-as-
held endgame (angled barrel crossing the hue seam against depth-aware wall
luminance).
