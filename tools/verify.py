#!/usr/bin/env python3
"""verify.py -- the acceptance sweep, run headless in-process.

Every check drives the real binary through libatari800 and reads the result out
of RAM. There is no emulator subprocess, so there is nothing to leave behind.

The checks are written to depend on game STATE rather than on frame counts
wherever possible. An earlier version asserted "ammo drops by one when you
fire", which passed for weeks and then failed the day a title screen shifted
every timing by 83 frames and the player started walking over a shell box
mid-test. The shotgun was fine; the test was measuring the wrong thing.

    python3 tools/verify.py
"""
import sys, os, random

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from a8 import A8                                              # noqa: E402

# RAM the checks read. Kept in one place so a memory-map change breaks loudly.
RENDERS = 0x0600
SDMCTL  = 0x022F
PX_HI, PX_LO, PY_HI, PY_LO = 0x81, 0x80, 0x83, 0x82
PANG    = 0x84                  # player facing, NOT a level counter
AMMO    = 0x00BC
WSTATE  = 0x00B7
WKICK   = 0x00B8
AC_LIVE, AC_XHI, AC_XLO, AC_YHI, AC_YLO, AC_STATE, AC_HP = (
    0x7820, 0x7808, 0x7800, 0x7818, 0x7810, 0x7830, 0x7840)
AC_TYPE = 0x7820                # same array as AC_LIVE: 0 = empty slot
SPWNT   = 0x2BA8                # spawn TYPE table (genspawns.py)
KILLS   = 0x7A52
HEALTH  = 0x7878
MAPBASE = 0x7000
ATTRBASE = 0x7400
AUDSHAD = 0x9F1E                # the audio engine's POKEY shadow
HUDRAM  = 0x7900
WONDONE = 0x7A07
WONALL  = 0x7A13
INTITLE = 0x7A14
ITMGOT  = 0x7A12
ITMX, ITMY, ITMT = 0x2B40, 0x2B50, 0x2B60   # pickup tables (genitems.py)
LEVELNO = 0x7A09
AC_FRAME_OFF = 0x7828
AC_ANIM_OFF  = 0x7860
AC_TIMER_OFF = 0x7838
HCEIL, HWALL, HFLOOR = 0x00CA, 0x00CB, 0x00CC   # the three band hues (abyss.lab)
HUDCOL  = 0x7A50
DEATHFR = 0x7A51


class Sweep:
    def __init__(self, xex='abyss.xex', extra=()):
        self.xex = xex
        self.a = A8(pal=True, extra_args=extra)
        self.a.boot(xex)
        self.p = self.a.lib.libatari800_get_main_memory_ptr()
        self.n = self.tot = 0

    # -- helpers ------------------------------------------------------------
    def m(self):
        return self.a.memory()

    def go(self, n=1, joy=0, trig=0):
        self.a.inp.joy0 = joy
        self.a.inp.trig0 = trig
        self.a.frame(n)
        self.a.inp.joy0 = 0
        self.a.inp.trig0 = 0

    def until(self, pred, limit=400, joy=0):
        """Run until a condition holds. Returns whether it did."""
        for _ in range(limit):
            if pred(self.m()):
                return True
            self.go(1, joy=joy)
        return pred(self.m())

    def pull_trigger(self):
        self.go(3, trig=1)
        self.go(2)

    def chk(self, name, cond, extra=''):
        self.tot += 1
        self.n += 1 if cond else 0
        print('%-28s %s %s' % (name, 'PASS' if cond else 'FAIL', extra))

    # -- the sweep ----------------------------------------------------------
    def run(self):
        a, p = self.a, self.p

        a.frame(80)
        self.chk('title gates the game', self.m()[RENDERS] == 0)
        self.chk('title owns the text row', self.m()[INTITLE] == 1)
        self.pull_trigger()
        a.frame(200)
        m = self.m()
        self.chk('renders', m[RENDERS] > 0, '%.1f fps' % (m[RENDERS] / (205 / 50.0)))
        self.chk('title costs no ammo', m[AMMO] == 50)
        self.chk('HUD labels restored', bytes(m[HUDRAM + 40:HUDRAM + 46]) == b'HEALTH'.translate(
            bytes((c - 32) & 0xFF for c in range(256))))
        self.chk('playfield is $22 (wide)', m[SDMCTL] == 0x22)
        self.chk('five enemies spawned', sum(1 for i in range(6) if m[AC_LIVE + i] in (1, 3, 4, 5)) == 5)

        before = (m[PX_HI], m[PX_LO])
        self.go(120, joy=0x01)
        self.chk('movement', (self.m()[PX_HI], self.m()[PX_LO]) != before)

        # Fire is verified by the weapon entering its cycle, not by an ammo
        # delta: pickups also move ammo, and the player wanders over them.
        self.go(60)                                  # let any previous cycle end
        self.chk('weapon idle before firing', self.m()[WSTATE] == 0)
        self.go(3, trig=1)
        self.chk('shotgun fires', self.m()[WSTATE] != 0, 'wstate=%d' % self.m()[WSTATE])
        self.go(80)
        self.chk('weapon cycle completes', self.m()[WSTATE] == 0)

        # point blank: one shell kills, on every level. This is the weapon's
        # identity and is deliberately not scaled by level.
        m = self.m()
        for ad, v in ((AC_XHI, m[PX_HI] + 2), (AC_XLO, 0x80), (AC_YHI, m[PY_HI]),
                      (AC_YLO, 0x80), (AC_LIVE, 1), (AC_STATE, 1), (AC_HP, 60)):
            p[ad] = v
        self.go(20)
        self.pull_trigger()
        self.go(60)
        self.chk('point-blank one-shot', self.m()[AC_HP] == 0)

        # Walk onto a medkit read from the LIVE table -- the old version
        # teleported to (12,11), a coordinate copied out of the item table as
        # it stood the day the check was written. Regenerating the table would
        # have failed the check with the game working perfectly (and did).
        m = self.m()
        mi = next(i for i in range(4) if m[ITMT + i] == 0)
        p[HEALTH] = 40
        p[PX_HI], p[PX_LO] = m[ITMX + mi], 0x80
        p[PY_HI], p[PY_LO] = m[ITMY + mi], 0x80
        self.go(20)
        self.chk('medkit pickup', self.m()[HEALTH] == 65)

        p[HEALTH] = 0
        self.go(20)
        self.pull_trigger()
        self.go(40)
        self.chk('death and retry', self.m()[HEALTH] == 100)

        m = self.m()
        d = (m[PX_HI] + 1) + m[PY_HI] * 32
        p[MAPBASE + d] = 0x08                        # a door in front of the player
        opened = self.until(lambda mm: mm[MAPBASE + d] == 0, 200, joy=0x01)
        self.chk('door opens on touch', opened)

        # Every level must CONTAIN a reachable exit. The shipped build once
        # had none at all -- `$0C` appeared zero times in all four maps, so the
        # game could not be finished -- and this sweep did not notice, because
        # descend() used to poke an exit into the map before walking into it.
        self.chk('every level has an exit', self.exits_ok() == 4,
                 '%d of 4 levels have a reachable exit' % self.exits_ok())

        # BOTH planes. Comparing only the solid plane let a 54-byte overlap
        # between the level blob and the item table sit undetected: level 4's
        # per-cell lighting was corrupt over a quarter of the map and every
        # check still passed.
        ref = {n: (open(os.path.join('src', 'map%d.bin' % n), 'rb').read(),
                   open(os.path.join('src', 'map%d.attr.bin' % n), 'rb').read())
               for n in (2, 3, 4)}
        solid_ok = attr_ok = spawn_ok = True
        for lvl in (2, 3, 4):
            if not self.descend():
                solid_ok = attr_ok = False
                break
            mm = self.m()
            if bytes(mm[MAPBASE:MAPBASE + 0x400]) != ref[lvl][0]:
                solid_ok = False
            if bytes(mm[ATTRBASE:ATTRBASE + 0x400]) != ref[lvl][1]:
                attr_ok = False
            if sum(1 for i in range(6) if mm[AC_LIVE + i] in (1, 3, 4, 5)) != 5:
                spawn_ok = False
        self.chk('levels 2-4 solid plane exact', solid_ok)
        self.chk('levels 2-4 attribute plane exact', attr_ok)
        self.chk('levels 2-4 repopulated', spawn_ok)

        self.descend()
        self.chk('victory after the last level', self.m()[WONALL] == 1)

        # Pickups must be VISIBLE, and must vanish when collected. They used
        # to be neither: four per level, picked up by standing on the exact
        # cell, with nothing on screen to say they were ever there.
        drawn, gone, got = self.item_pixels()
        self.chk('pickups are visible', drawn > 40, '%d px' % drawn)
        self.chk('collected pickups vanish', got and gone == 0,
                 '%d px left after walking over it' % gone)

        # Material signatures. The two that MUST be exact are secret and
        # sealed: they are walls the player is not meant to be able to spot,
        # and any distinctive shade gives every one of them away for free.
        lum = self.material_luma({1: 'stone', 13: 'secret', 15: 'sealed',
                                  8: 'door', 12: 'exit', 6: 'rock'})
        st = lum[1]
        self.chk('secret is invisible', abs(lum[13] - st) < 0.01)
        self.chk('sealed is invisible', abs(lum[15] - st) < 0.01)
        self.chk('doors read brighter', lum[8] > st + 0.4, '%+.2f luma' % (lum[8] - st))
        self.chk('the exit is brightest', lum[12] >= max(lum.values()) - 0.01,
                 '%+.2f luma' % (lum[12] - st))
        self.chk('rock reads darker', lum[6] < st - 0.4, '%+.2f luma' % (lum[6] - st))

        # No two levels may read as the same room, and no level may be a
        # single-hue wash. Thresholds in RGB distance at luminance 8, out of a
        # possible 441. Two of the four levels used to fail all three.
        worst_in, worst_between = self.level_hue_separation()
        self.chk('levels are not monochrome', worst_in >= 60,
                 'worst ceiling-to-wall %d' % worst_in)
        self.chk('levels look different', worst_between >= 50,
                 'closest two walls %d' % worst_between)

        flash, kick = self.flash_and_kick()
        # Properties, not literals. The previous version of this check asserted
        # the exact triple the code happened to write, which is the
        # implementation copied into the test file: it failed the moment the
        # flash was improved, and it would have passed just as happily if the
        # flash had been made worse in some way that kept those three numbers.
        wall = [t[1] & 0x0F for t in flash]
        self.chk('muzzle flash is 3 frames',
                 len(flash) == 3 and all(v > 0 for v in wall)
                 and all(b <= a for a, b in zip(wall, wall[1:]))
                 and all(bin(v).count('1') == 1 for v in wall),
                 'wall luminance bits %s' % wall)
        # The flash must LIGHT the room, not replace it. The first version wrote
        # one value to all three bands, so ceiling, wall, floor, gun and enemy
        # all became the same flat gold and the frame read as a screen clear.
        # Three distinct hues in every flash frame is that failure made
        # impossible.
        hues = [len({t[0] >> 4, t[1] >> 4, t[2] >> 4}) for t in flash]
        self.chk('the flash lights the room, not replaces it',
                 bool(flash) and min(hues) == 3,
                 'distinct hues per flash frame: %s' % hues)
        # ...and it must not hide what you are shooting at. OR collapses pairs
        # of luminances, so the wrong bit merges the enemy into the wall behind
        # it at the exact moment of firing.
        base, worst = self.flash_enemy_contrast()
        self.chk('the flash does not hide the enemy', worst <= base + 2,
                 '%d of the husk edge pixels lost, against %d unflashed'
                 % (worst, base))
        # ...or your own gun, which is in a DIFFERENT band and answers the same
        # question the other way round: the floor runs 6-11, so bit 8 folds the
        # weapon's tones into it while bits 2 and 4 leave them alone.
        rest_e, flash_e = self.flash_weapon_detail()
        self.chk('the flash does not hide the gun', flash_e >= rest_e * 0.9,
                 '%d of %d edges in the weapon region survive' % (flash_e, rest_e))
        # ...and none of those frames may erase the picture. The low nibble is a
        # luminance FLOOR: $1E leaves only 14 and 15, so the image does not
        # brighten, it disappears.
        # The low nibble is OR'd into every pixel, so the surviving luminance
        # count is 16 >> popcount(nibble). Single-bit nibbles keep 8 of 16;
        # two-bit ones keep 4; $1E kept 2 and erased the picture. The same rule
        # governs the pain and victory tints, which is why they are $32 and $14.
        self.chk('the flash never blanks the view', self.flash_min_levels() >= 8,
                 '%d luminances in the brightest frame' % self.flash_min_levels())
        self.chk('the kick spans a render', kick >= 5, '%d frames of kick' % kick)

        # The last scanline of the 3D view must belong to the 3D view. The DLI
        # bit sat on the first of each row's two mode lines, so on the last row
        # the handover to the status band happened while row 95 was still on
        # screen -- a bright dashed line across the bottom of every frame.
        self.chk('the view owns its last scanline', self.last_view_scanline() > 2,
                 '%d distinct colours on scanline 215' % self.last_view_scanline())

        # A dead-flat wall must render flat and mirror-symmetric. The fisheye
        # table was indexed by col>>3 while it was built for col//5, so the
        # right-hand 40% of the screen got no correction at all.
        bow, asym = self.flat_wall_profile()
        self.chk('a flat wall renders flat', bow <= 2, '%d rows of bow' % bow)
        self.chk('the view is mirror-symmetric', asym == 0, '%d rows of asymmetry' % asym)

        # Audio is verified as register traces -- it has never been heard.
        vols = self.shotgun_envelope()
        # The ambient drone resumes at volume 3 as soon as the shot finishes,
        # so the envelope is the run UP TO the first zero, not the whole window.
        decay = vols[:vols.index(0) + 1] if 0 in vols else vols
        self.chk('shotgun envelope decays', len(decay) >= 8 and decay[0] >= 14
                 and decay[-1] == 0 and all(b <= a for a, b in zip(decay, decay[1:])),
                 'vol %d -> 0 over %d frames, then the drone' % (decay[0], len(decay)))

        still, walking = self.gun_bob()
        self.chk('the weapon bobs when walking', still == 0 and walking >= 2,
                 '%d rows standing, %d rows walking' % (still, walking))

        # Dying used to be the ordinary view with a red filter over it, gun
        # still held level and ready -- the pose of a player who is fine. It now
        # slides out of frame. Counted in the picture rather than off the kick
        # variable, because the variable moving proves nothing reached the
        # screen. The gun's outline is luminance 1 and nothing else in the
        # bottom band is that dark.
        alive_px, dead_px, reset = self.death_drop()
        self.chk('the gun drops when you die',
                 alive_px > 40 and dead_px == 0 and reset,
                 '%d outline px held, %d after dying, %s on retry'
                 % (alive_px, dead_px, 'reset' if reset else 'STILL DOWN'))

        # Three separate reviewers looking at the screenshots reported that the
        # weapon was not on screen -- one of them on two named levels and in the
        # muzzle-flash shot specifically. Measured, it is drawn on all four
        # levels with essentially identical pixel counts, so what they were
        # reporting was a failure to RECOGNISE it, not a failure to draw it.
        # Those are different problems with different fixes, and "is it drawn"
        # is the one a test can settle, so it is settled here rather than argued
        # about again.
        # THE CHECK THIS SWEEP DID NOT HAVE, and the one that mattered most.
        #
        # atari800 defaults to BASIC DISABLED. A real 800XL boots with BASIC
        # ENABLED unless you hold OPTION, and BASIC is ROM at $A000-$BFFF --
        # where this build puts the sprite renderer, the actor AI and the whole
        # audio engine. So 130-odd green sweeps were run against a machine
        # configuration the hardware does not boot into, and the first time it
        # touched real silicon it corrupted and rolled.
        #
        # Every configuration difference between the harness and the target is a
        # place a bug can live for free. This one is now checked; the general
        # lesson is in the DEVLOG.
        # THE OTHER ONE THE HARNESS HAD NO OPINION ABOUT. ANTIC displays
        # scanlines 8..247 and starts vertical blank at 248, so a display list
        # may ask for at most 240 scanlines. This one asked for 248 and the
        # picture rolled on a real 800XL -- while atari800 rendered a fixed
        # 240-line window, clipped the overflow and produced a stable frame in
        # every one of 130 runs. The emulator cannot show you a CRT losing lock,
        # so the frame's LENGTH has to be asserted rather than looked at.
        dls = self.dlist_scanlines()
        self.chk('the display list fits in a frame',
                 all(n <= 240 for n, _ in dls),
                 'scanlines per display list: %s (limit 240)' % [n for n, _ in dls])
        # ANTIC's display-list program counter is 10 bits wide: a list that
        # crosses a 1K address boundary wraps back to the start of the page
        # mid-list. Both lists currently END around $x24D -- ~430 bytes short
        # of their boundary -- which is layout luck, not a guarantee, and two
        # more text rows would not be the first time this file grew.
        self.chk('the display list stays inside its 1K page',
                 not any(x for _, x in dls),
                 'crossings: %s' % [x for _, x in dls])

        # The loader contract: the very FIRST thing in the file must be the
        # eight-byte stub that banks the BASIC ROM out, and the INIT vector
        # that runs it must come before anything loads at $A000+. Asserted
        # against the file's actual bytes, because segment order is decided by
        # source order in main.asm and nothing else pins it.
        self.chk('the XEX leads with the BASIC-off stub', self.xex_stub_first(),
                 '')

        rb, hb = self.runs_with_basic()
        self.chk('runs with BASIC enabled, as a real XL boots',
                 rb > 0 and hb == 100,
                 '%d world frames, health %d' % (rb, hb))

        # The bestiary: every level must spawn the TYPES its level file
        # authors, not a table's idea of them -- and the stats must follow.
        bes = self.bestiary_ok()
        self.chk('the levels spawn their own bestiary', bes[0],
                 'distinct types across the game: %d, mismatches: %d' % (bes[1], bes[2]))
        # ...and a hulk must visibly TOWER, measured in the picture: same spot,
        # same distance, ~a third taller than a husk.
        hr = self.hulk_ratio()
        self.chk('the hulk towers over a husk', hr >= 1.2,
                 'on-screen height ratio %.2f' % hr)
        # ...and the kills counter counts. One husk, one point-blank shot,
        # kills goes 0 -> 1. The end card reads this.
        kb, ka = self.kill_counts()
        self.chk('kills are counted', kb == 0 and ka == 1,
                 'kills %d -> %d over one point-blank shot' % (kb, ka))

        # A hit must SHOVE. The knockback sets velocity to 1.5x the player's
        # own top speed, away from the attacker; measured as the signed
        # velocity the frame the health drop lands.
        kv = self.knockback_speed()
        self.chk('a hit shoves the player', kv >= 0x60,
                 'impulse magnitude $%02X (top speed is $40)' % kv)

        gun = self.weapon_on_every_level()
        self.chk('the gun is drawn on every level', min(gun) >= 80,
                 'outline pixels per level: %s' % gun)

        # The gun is 26 rows tall again. It was cut to 20 once because a 24-row
        # version centred at the bottom of the view hid 90% of a corpse one cell
        # ahead; the height only became affordable again when the gun moved into
        # the bottom-RIGHT corner and left the middle of the floor clear. That is
        # a claim about the picture, so it gets checked rather than asserted --
        # and it is exactly the constraint a future redraw would silently break.
        near = self.corpse_at_your_feet()
        self.chk('the gun does not hide the body at your feet', near >= 120,
                 '%d px of a corpse one cell ahead' % near)

        # The status panel was a hard-coded near-black bar under every level.
        panel = self.hud_tint()
        self.chk('the status panel takes the level colour',
                 all(h == w for h, w in panel),
                 ' '.join('%02X/%02X' % (h, w) for h, w in panel))

        # An enemy behind a nearer wall must not be drawn through it. This
        # broke silently when the depth buffer was being fed the light- and
        # material-biased distance instead of the true one.
        vis, hid = self.occlusion_pixels()
        self.chk('sprites occlude behind walls', vis > 40 and hid == 0,
                 '%d px in the open, %d px behind a wall' % (vis, hid))

        # Sprites must be drawn far-to-near, not in slot order. The test is
        # order-invariance: put the same two husks in the same two places with
        # their table slots swapped, and the picture must be identical.
        self.chk('sprites are depth-sorted', self.slot_order_invariant() == 0)

        # THE check. Not "does the victory flag set" -- can a player start at
        # the title screen and finish all four levels by playing? Fighting what
        # gets close, path-finding to each real exit, retrying on death.
        done, shots, deaths = self.playthrough()
        self.chk('the game can be completed', done,
                 '%d shots, %d deaths' % (shots, deaths))

        # Winning must not be a dead end. It used to be: `wonall` was set
        # forever, fire re-entered next_level which refused (no level 5), and
        # the player sat in a gold room spending ammo into nothing.
        again = self.restart_after_victory()
        self.chk('the ending starts a new game', again, '' if again else 'stuck')

        # And can level 1 be CLEARED of enemies by playing?
        # Everything else measures that the machine behaves; this measures that
        # the design does. The autoplayer only turns toward the nearest enemy,
        # closes, and fires -- no map knowledge, no cheating.
        cleared, shots, hp = self.autoplay()
        self.chk('level 1 is clearable', cleared,
                 '%d shots, %d health left' % (shots, hp))
        self.chk('passive play is punished', self.passive_death() < 3000,
                 'dead in %.0fs doing nothing' % (self.passive_death() / 50.0))

        # The soak used to run at the very end of the sweep, which meant it
        # fuzzed the VICTORY state -- the one state where almost nothing is
        # live. Run it from a fresh boot on every level instead.
        for lvl in range(4):
            bad = self.soak(lvl, seed=11 + lvl)
            self.chk('soak, level %d' % (lvl + 1), bad is None,
                     '5,000 frames' if bad is None else str(bad))

        print('\nTOTAL: %d/%d' % (self.n, self.tot))
        return self.n == self.tot

    def level_hue_separation(self):
        """Worst ceiling-to-wall gap within a level, worst wall gap between two."""
        import metrics as M, itertools
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        pal = s.a.palette

        def dist(h1, h2):
            a, b = pal[(h1 << 4) | 8], pal[(h2 << 4) | 8]
            return sum((x - y) ** 2 for x, y in zip(a, b)) ** 0.5

        trips = []
        for lvl in range(4):
            if lvl:
                s.descend(); s.go(50)
            H = M.hue(M.grab(s.a))
            trips.append(tuple(
                max(set(H[r][c] for r in band for c in range(80)),
                    key=lambda h: sum(1 for r in band for c in range(80) if H[r][c] == h))
                for band in (M.CEIL, M.WALL, M.FLOOR)))
        within = min(dist(t[0], t[1]) for t in trips)
        between = min(dist(a[1], b[1]) for a, b in itertools.combinations(trips, 2))
        return int(within), int(between)

    def flash_and_kick(self):
        """The three band hues during the flash, and how long the kick lasts.

        Both were measured wrong before: wstate is decremented earlier in the
        same VBI, so the flash's brightest step was unreachable; and the kick
        halved (6-3-1-0, 60ms) against an 88ms render period, so most shots
        never showed one.

        This used to watch COLBK alone and assert the literal triple
        [0x18, 0x14, 0x12] -- which was the old implementation written out as an
        expectation rather than a property, so it failed the moment the flash
        stopped painting all three bands the same colour. It now records all
        three band variables, which lets the checks assert the two things that
        actually matter: the wall band steps three times, and the bands do NOT
        collapse to one hue.
        """
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        base = (s.m()[HCEIL], s.m()[HWALL], s.m()[HFLOOR])
        s.a.inp.trig0 = 1
        flash, kick = [], 0
        for i in range(10):
            s.a.frame(1)
            if i == 1:
                s.a.inp.trig0 = 0
            m = s.m()
            trio = (m[HCEIL], m[HWALL], m[HFLOOR])
            if trio != base:
                flash.append(trio)
            if m[WKICK]:
                kick += 1
        return flash, kick

    # ANTIC scanlines per display-list instruction, by mode nibble.
    _ANTIC_LINES = {0x2: 8, 0x3: 10, 0x4: 8, 0x5: 16, 0x6: 8, 0x7: 16, 0x8: 8,
                    0x9: 4, 0xA: 4, 0xB: 2, 0xC: 1, 0xD: 2, 0xE: 1, 0xF: 1}

    def dlist_scanlines(self):
        """Walk both display lists out of live RAM: (scanlines, crossed-1K).

        Out of RAM rather than out of the source, because what ANTIC executes is
        whatever build_dlist actually wrote -- and build_dlist is a loop with an
        LMS per row, which is exactly the kind of thing that is easy to get one
        iteration wrong in.
        """
        s = Sweep(self.xex)
        s.a.frame(80)
        m = s.m()
        out = []
        for base in (0x4000, 0x4400):
            a, lines = base, 0
            for _ in range(400):
                b = m[a]
                mode = b & 0x0F
                if mode == 0x01:                    # jump / JVB ends the list
                    a += 2
                    break
                if mode == 0x00:                    # 1-8 blank scanlines
                    lines += ((b >> 4) & 7) + 1
                else:
                    lines += self._ANTIC_LINES[mode]
                    if b & 0x40:                    # LMS: skip the address
                        a += 2
                a += 1
            out.append((lines, (base >> 10) != (a >> 10)))
        return out

    def xex_stub_first(self):
        """True if the file's first segment is the $0600 BASIC-off stub with an
        INIT vector immediately after it."""
        b = open(self.xex, 'rb').read()
        if b[:2] != b'\xff\xff':
            return False
        start = b[2] | (b[3] << 8)
        end = b[4] | (b[5] << 8)
        if start != 0x0600:
            return False
        seg = b[6:6 + end - start + 1]
        nxt = b[6 + len(seg):6 + len(seg) + 6]
        # lda $D301 / ora #$02 / sta $D301 somewhere in the stub, then an
        # INIT-vector segment ($02E2-$02E3) pointing back into it
        return (b'\xad\x01\xd3\x09\x02\x8d\x01\xd3' in seg
                and nxt[:4] == b'\xe2\x02\xe3\x02'
                and start <= (nxt[4] | (nxt[5] << 8)) <= end)

    def runs_with_basic(self):
        """World frames rendered and health, on a machine with BASIC ROM in.

        Not a variant of an existing check -- a whole second boot of the whole
        program on the memory map the target actually has. Before the fix this
        returned (0, 0): nothing rendered and the player was dead on arrival,
        because every call into $A000-$BFFF was executing BASIC.
        """
        s = Sweep(self.xex, extra=['-basic'])
        s.a.frame(120)
        s.pull_trigger()
        s.go(250)
        m = s.m()
        return m[RENDERS], m[HEALTH]

    def bestiary_ok(self):
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        seen, bad = set(), 0
        for lvl in range(4):
            if lvl:
                if not s.descend():
                    return (False, len(seen), 99)
                s.go(40)
            m = s.m()
            for i in range(5):
                t = m[AC_TYPE + i] or None
                # a slot may already be a corpse mid-check; type persists
                if t:
                    seen.add(t)
                if m[SPWNT + lvl * 5 + i] not in (m[AC_TYPE + i], 0)                    and m[AC_TYPE + i] != 0:
                    bad += 1
        return (bad == 0 and len(seen) >= 3, len(seen), bad)

    def hulk_ratio(self):
        import metrics as M

        def rows(ty):
            s = Sweep(self.xex)
            s.a.frame(80)
            s.pull_trigger()
            s.a.frame(200)
            for i in range(6):
                s.p[AC_LIVE + i] = 0
            s.go(20)
            ref = M.luma(M.grab(s.a))
            m = s.m()
            for ad, v in ((AC_XHI, m[PX_HI] + 3), (AC_XLO, 0x80),
                          (AC_YHI, m[PY_HI]), (AC_YLO, 0x80),
                          (AC_LIVE, 1), (AC_STATE, 1), (AC_HP, 250)):
                s.p[ad] = v
            s.p[AC_TYPE] = ty
            for _ in range(20):
                s.p[AC_HP] = 250
                s.p[AC_TYPE] = ty
                s.a.frame(1)
            now = M.luma(M.grab(s.a))
            return sum(1 for r in range(96)
                       if any(now[r][c] != ref[r][c] for c in range(80)))

        return rows(5) / max(1, rows(1))

    def kill_counts(self):
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        m = s.m()
        before = m[KILLS]
        for i in range(1, 6):
            s.p[AC_LIVE + i] = 0
        for ad, v in ((AC_XHI, m[PX_HI] + 1), (AC_XLO, 0x80),
                      (AC_YHI, m[PY_HI]), (AC_YLO, 0x80),
                      (AC_LIVE, 1), (AC_STATE, 1), (AC_HP, 60)):
            s.p[ad] = v
        s.go(10)
        s.pull_trigger()
        s.go(30)
        return before, s.m()[KILLS]

    def knockback_speed(self):
        VX_LO, VX_HI, VY_LO, VY_HI = 0xB0, 0xB1, 0xB2, 0xB3
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        m = s.m()
        for i in range(1, 6):
            s.p[AC_LIVE + i] = 0
        for ad, v in ((AC_XHI, m[PX_HI] + 1), (AC_XLO, 0x80),
                      (AC_YHI, m[PY_HI]), (AC_YLO, 0x80),
                      (AC_LIVE, 1), (AC_STATE, 1), (AC_HP, 250)):
            s.p[ad] = v
        s.p[AC_TYPE] = 5
        h0 = s.m()[HEALTH]
        for _ in range(400):
            s.p[AC_HP] = 250
            s.a.frame(1)
            if s.m()[HEALTH] < h0:
                break
        m = s.m()

        def mag(lo, hi):
            v = m[lo] | (m[hi] << 8)
            return (0x10000 - v) & 0xFFFF if v & 0x8000 else v

        return max(mag(VX_LO, VX_HI), mag(VY_LO, VY_HI))

    def weapon_on_every_level(self):
        """Outline pixels of the held weapon, one count per level.

        The outline is luminance 1 and nothing else in the bottom-right of the
        view is that dark, in any level's hue.
        """
        import metrics as M
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)

        def count():
            g = M.luma(M.grab(s.a))
            return sum(1 for r in range(70, 96) for c in range(40, 80)
                       if g[r][c] == 1)

        out = [count()]
        for _ in range(3):
            if not s.descend():
                break
            s.go(40)
            out.append(count())
        return out

    def flash_weapon_detail(self):
        """Horizontal edges in the weapon region, at rest and during the flash.

        Edges rather than pixel values, because what makes a shape legible is
        where it CHANGES. The flash frame used to add a flat +3 to every pixel of
        the gun on top of the band's own brightening, which pushed its mid-tones
        into the floor's range and cost a fifth of them.
        """
        import metrics as M
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)

        def edges(g):
            return sum(1 for r in range(70, 96) for c in range(40, 79)
                       if g[r][c] != g[r][c + 1])

        rest = edges(M.luma(M.grab(s.a)))
        s.a.inp.trig0 = 1
        s.a.frame(1)
        s.a.inp.trig0 = 0
        s.a.frame(1)                       # the VBI's colours land NEXT frame
        return rest, edges(M.luma(M.grab(s.a)))

    def corpse_at_your_feet(self):
        """Pixels of a corpse one cell dead ahead that survive the held weapon."""
        import metrics as M
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        for i in range(6):
            s.p[AC_LIVE + i] = 0
        s.go(20)
        ref = M.luma(M.grab(s.a))
        m = s.m()
        for ad, v in ((AC_XHI, m[PX_HI] + 1), (AC_XLO, 0x80), (AC_YHI, m[PY_HI]),
                      (AC_YLO, 0x80), (AC_LIVE, 1), (AC_STATE, 8), (AC_HP, 0),
                      (AC_FRAME_OFF, 12)):
            s.p[ad] = v
        s.go(20)
        now = M.luma(M.grab(s.a))
        return sum(1 for r in range(96) for c in range(80) if now[r][c] != ref[r][c])

    def flash_enemy_contrast(self):
        """Husk silhouette pixels lost to the wall, unflashed vs worst flash frame.

        A muzzle flash exists to tell you that you fired at something. If the
        flash merges the something into the wall behind it, the effect is
        working against the only job it has.

        The flash is exactly `pixel | bit` on every pixel in the band, so the
        cost of any candidate bit can be computed from one ordinary frame rather
        than built and screenshotted. A silhouette pixel counts as lost when it
        becomes identical to the wall pixel immediately left or right of it --
        the edge is what carries the shape.
        """
        import metrics as M
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        for i in range(6):
            s.p[AC_LIVE + i] = 0
        s.go(20)
        ref = M.luma(M.grab(s.a))
        m = s.m()
        for ad, v in ((AC_XHI, m[PX_HI] + 3), (AC_XLO, 0x80), (AC_YHI, m[PY_HI]),
                      (AC_YLO, 0x80), (AC_LIVE, 1), (AC_STATE, 1), (AC_HP, 250)):
            s.p[ad] = v
        s.go(20)
        now = M.luma(M.grab(s.a))
        husk = {(r, c) for r in range(30, 66) for c in range(80)
                if now[r][c] != ref[r][c]}
        if not husk:
            return 0, 99

        def lost(bit):
            n = 0
            for r, c in husk:
                for dc in (-1, 1):
                    cc = c + dc
                    if 0 <= cc < 80 and (r, cc) not in husk \
                       and (now[r][c] | bit) == (now[r][cc] | bit):
                        n += 1
                        break
            return n

        bits = {v & 0x0F for v in self.flash_wall_bits()}
        return lost(0), max(lost(b) for b in bits)

    def flash_wall_bits(self):
        return [t[1] for t in self.flash_and_kick()[0]]

    def death_drop(self):
        """Weapon outline pixels in the bottom band: alive, dead, and on retry.

        The outline is the one thing in the picture at luminance 1, so counting
        it is a direct answer to "is the gun on screen", independent of the
        red death wash that repaints every hue.
        """
        import metrics as M
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)

        def outline():
            L = M.luma(M.grab(s.a))
            return sum(1 for r in range(76, 96) for c in range(80) if L[r][c] == 1)

        alive = outline()
        s.p[HEALTH] = 0
        s.go(60)                       # the drop takes WPN_ROWS+8 = 28 frames
        dead = outline()
        s.pull_trigger()               # FIRE retries the level
        s.go(60)
        return alive, dead, outline() > 40

    def hud_tint(self):
        """(panel hue, wall hue) for each level -- they must match."""
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        out = [(s.m()[HUDCOL] & 0xF0, s.m()[HWALL] & 0xF0)]
        for _ in range(3):
            if not s.descend():
                break
            s.go(20)
            out.append((s.m()[HUDCOL] & 0xF0, s.m()[HWALL] & 0xF0))
        return out

    _flashlv = None

    def flash_min_levels(self):
        if Sweep._flashlv is not None:
            return Sweep._flashlv
        import metrics as M
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        s.a.inp.trig0 = 1
        worst = 99
        for i in range(5):
            s.a.frame(1)
            if i == 1:
                s.a.inp.trig0 = 0
            L = M.luma(M.grab(s.a))
            n = len(set(L[r][c] for r in range(96) for c in range(80)))
            if i:                                  # skip the pre-flash frame
                worst = min(worst, n)
        Sweep._flashlv = worst
        return worst

    def last_view_scanline(self):
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        buf = s.a.screen_rgb()
        return len(set(buf[215 * 384 + 32 + c] for c in range(320)))

    def flat_wall_profile(self):
        """Bow and left/right asymmetry of the wall top across a flat surface."""
        import metrics as M
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        m = s.m()
        for i in range(6):
            s.p[AC_LIVE + i] = 0
        px, py = m[PX_HI], m[PY_HI]
        s.p[PANG] = 0
        s.p[PX_LO] = s.p[PY_LO] = 0x80
        for dy in range(-12, 13):
            for dx in range(2, 5):
                s.p[MAPBASE + (px + dx) + (py + dy) * 32] = 1
        s.go(30)
        L = M.luma(M.grab(s.a))
        ramp = M.ramp_from_ladders()
        tops = []
        for c in range(80):
            tops.append(next((r for r in range(60) if L[r][c] != ramp.get(r, -1)), 99))
        return max(tops) - min(tops), max(abs(tops[c] - tops[79 - c]) for c in range(40))

    def shotgun_envelope(self):
        """POKEY channel-0 volume, frame by frame, from the trigger pull."""
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        s.a.inp.trig0 = 1
        out = []
        for i in range(11):
            s.a.frame(1)
            if i == 1:
                s.a.inp.trig0 = 0
            out.append(s.a.memory()[AUDSHAD + 3] & 15)
        return out

    def gun_bob(self):
        """Vertical travel of the weapon's top edge, standing versus walking."""
        import metrics as M
        ramp = M.ramp_from_ladders()

        def top(L):
            for r in range(70, 96):
                if sum(1 for c in range(30, 50) if L[r][c] != ramp.get(r, -1)) >= 8:
                    return r
            return 0

        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(200)
        rows = []
        for _ in range(8):
            s.a.frame(5); rows.append(top(M.luma(M.grab(s.a))))
        still = max(rows) - min(rows)
        rows = []
        s.a.inp.joy0 = 0x01
        for _ in range(16):
            s.a.frame(5); rows.append(top(M.luma(M.grab(s.a))))
        s.a.inp.joy0 = 0
        return still, max(rows) - min(rows)

    def occlusion_pixels(self):
        """Husk pixels drawn at six cells, with and without a wall at three."""
        import metrics as M
        out = []
        for wall in (False, True):
            frames = []
            for place_husk in (True, False):
                s = Sweep(self.xex)
                s.a.frame(80)
                s.pull_trigger()
                s.a.frame(200)
                m = s.m()
                for i in range(6):
                    s.p[AC_LIVE + i] = 0
                px, py = m[PX_HI], m[PY_HI]
                s.p[PANG] = 0
                if wall:
                    for dy in range(-4, 5):
                        s.p[MAPBASE + (px + 3) + (py + dy) * 32] = 1
                if place_husk:
                    for ad, v in ((AC_XHI, px + 6), (AC_XLO, 0x80), (AC_YHI, py),
                                  (AC_YLO, 0x80), (AC_LIVE, 1), (AC_STATE, 1),
                                  (AC_HP, 60)):
                        s.p[ad] = v
                s.go(25)
                frames.append(M.luma(M.grab(s.a)))
            out.append(sum(1 for r in range(96) for c in range(80)
                           if frames[0][r][c] != frames[1][r][c]))
        return out[0], out[1]

    def slot_order_invariant(self):
        import metrics as M
        shots = []
        for far_first in (True, False):
            s = Sweep(self.xex)
            s.a.frame(80)
            s.pull_trigger()
            s.a.frame(200)
            m = s.m()
            for i in range(6):
                s.p[AC_LIVE + i] = 0
            px, py = m[PX_HI], m[PY_HI]
            s.p[PANG] = 0
            for slot, d in ([(0, 6), (1, 2)] if far_first else [(0, 2), (1, 6)]):
                for ad, v in ((AC_XHI + slot, px + d), (AC_XLO + slot, 0x80),
                              (AC_YHI + slot, py), (AC_YLO + slot, 0x80),
                              (AC_LIVE + slot, 1), (AC_STATE + slot, 1),
                              (AC_HP + slot, 60),
                              # Pin the whole animation state. The AI walks even
                              # and odd slots on ALTERNATE ticks, so otherwise
                              # the two husks end up on different frames and the
                              # test measures animation instead of draw order.
                              # AC_ANIM high so the walk cycle cannot tick
                              # within the settle window.
                              (AC_FRAME_OFF + slot, 0),
                              (AC_ANIM_OFF + slot, 200),
                              (AC_TIMER_OFF + slot, 200)):
                    s.p[ad] = v
            # Re-pin every frame. The AI walks even and odd slots on ALTERNATE
            # ticks, so with the slots swapped the two husks drift apart by a
            # fraction of a cell and the frames differ for reasons that have
            # nothing to do with draw order. Freezing them makes this measure
            # the one thing it claims to.
            for _ in range(12):
                for slot, d in ([(0, 6), (1, 2)] if far_first else [(0, 2), (1, 6)]):
                    s.p[AC_XHI + slot] = px + d
                    s.p[AC_XLO + slot] = 0x80
                    s.p[AC_YHI + slot] = py
                    s.p[AC_YLO + slot] = 0x80
                    s.p[AC_FRAME_OFF + slot] = 0
                s.go(1)
            shots.append(M.luma(M.grab(s.a)))
        return sum(1 for r in range(96) for c in range(80)
                   if shots[0][r][c] != shots[1][r][c])

    def restart_after_victory(self):
        """Win, press fire, and check you are back at the start of level 1."""
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(60)
        for _ in range(4):
            if not s.descend():
                return False
        if not s.m()[WONALL]:
            return False
        s.pull_trigger()
        s.go(60)
        m = s.m()
        return (m[WONALL] == 0 and m[LEVELNO] == 0 and m[HEALTH] == 100
                and bytes(m[MAPBASE:MAPBASE + 0x400]) == open('src/map0.bin', 'rb').read()
                and sum(1 for i in range(6) if m[AC_LIVE + i] == 1) == 5)

    def playthrough(self, limit=6000):
        """Start to finish: four levels, fighting, path-finding, retrying."""
        import math
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(60)
        shots = deaths = 0
        for _ in range(4):
            m = s.m()
            grid = bytes(m[MAPBASE:MAPBASE + 0x400])
            found = [(i % 32, i // 32) for i, v in enumerate(grid) if v == 0x0C]
            if not found:
                return False, shots, deaths
            goal = found[0]
            path = s.route(grid, (m[PX_HI], m[PY_HI]), goal)
            if path is None:
                return False, shots, deaths
            i = 1
            engaged = False
            stuck = 0
            was = None
            for step in range(limit):
                m = s.m()
                if m[WONDONE] or m[WONALL]:
                    break
                if m[HEALTH] == 0:
                    deaths += 1
                    s.pull_trigger(); s.go(40)
                    m = s.m()
                    path = s.route(bytes(m[MAPBASE:MAPBASE + 0x400]),
                                   (m[PX_HI], m[PY_HI]), goal)
                    i = 1
                    if path is None:
                        return False, shots, deaths
                    continue
                px = m[PX_HI] + m[PX_LO] / 256.0
                py = m[PY_HI] + m[PY_LO] / 256.0
                # Stuck detector. The player has a body radius and the maps have
                # inside corners, so aiming straight at a waypoint can wedge you
                # against a wall with no component of motion left. A human turns
                # and shuffles; so does this. Without it the walk stalls forever
                # at exactly one cell boundary and reports a level unreachable.
                if was is not None and abs(px - was[0]) + abs(py - was[1]) < 0.02:
                    stuck += 1
                else:
                    stuck = 0
                was = (px, py)
                if stuck > 6:
                    s.go(10, joy=0x08)          # turn off the wall...
                    s.go(8, joy=0x01)           # ...and shuffle clear
                    fresh = s.route(bytes(s.m()[MAPBASE:MAPBASE + 0x400]),
                                    (s.m()[PX_HI], s.m()[PY_HI]), goal)
                    if fresh:
                        path, i = fresh, 1
                    stuck = 0
                    continue
                live = [(m[AC_XHI + k] + m[AC_XLO + k] / 256.0,
                         m[AC_YHI + k] + m[AC_YLO + k] / 256.0)
                        for k in range(6)
                        if m[AC_LIVE + k] == 1 and m[AC_STATE + k] not in (7, 8)]
                near = min(live, key=lambda t: (t[0] - px) ** 2 + (t[1] - py) ** 2) \
                    if live else None
                # Hysteresis: engage at 3.5 cells, disengage at 5. Without it
                # the walker alternates between turning to shoot and turning to
                # walk when an enemy sits right on the threshold, and spins on
                # the spot forever -- which is what a level looks like when it
                # has just been given back the enemies it was missing.
                dist = math.hypot(near[0] - px, near[1] - py) if near else 99
                engaged = near is not None and (dist < 3.5 or (engaged and dist < 5.0))
                if engaged:
                    want = int(math.atan2(near[1] - py, near[0] - px) / (2 * math.pi) * 256) & 255
                    err = ((want - m[PANG] + 128) & 255) - 128
                    if abs(err) > 12:
                        s.go(6, joy=0x08 if err > 0 else 0x04)
                    elif m[WSTATE] == 0:
                        s.go(3, trig=1); shots += 1
                    else:
                        s.go(3)
                    continue
                if step % 150 == 149:
                    fresh = s.route(bytes(m[MAPBASE:MAPBASE + 0x400]),
                                    (m[PX_HI], m[PY_HI]), goal)
                    if fresh:
                        path, i = fresh, 1
                while i < len(path) - 1 and \
                        math.hypot(path[i][0] + 0.5 - px, path[i][1] + 0.5 - py) < 0.9:
                    i += 1
                tx, ty = path[i]
                want = int(math.atan2(ty + 0.5 - py, tx + 0.5 - px) / (2 * math.pi) * 256) & 255
                err = ((want - m[PANG] + 128) & 255) - 128
                if abs(err) > 24:
                    s.go(6, joy=0x08 if err > 0 else 0x04)
                else:
                    s.go(4, joy=0x01)
            if not s.m()[WONDONE] and not s.m()[WONALL]:
                return False, shots, deaths
            s.pull_trigger(); s.go(60)
        return bool(s.m()[WONALL]), shots, deaths

    def autoplay(self, limit=1200):
        """Play level 1 with every enemy awake from the first frame.

        Turn toward the nearest live enemy, close to shotgun range, fire. That
        is the whole strategy -- if this cannot clear the level, no human will.
        """
        import math
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(60)
        for i in range(6):
            if s.p[AC_LIVE + i]:
                s.p[AC_STATE + i] = 1                 # worst case: all awake
        shots = 0
        for _ in range(limit):
            m = s.m()
            if m[HEALTH] == 0:
                return False, shots, 0
            px = m[PX_HI] + m[PX_LO] / 256.0
            py = m[PY_HI] + m[PY_LO] / 256.0
            live = [(i, m[AC_XHI + i] + m[AC_XLO + i] / 256.0,
                        m[AC_YHI + i] + m[AC_YLO + i] / 256.0)
                    for i in range(6)
                    if m[AC_LIVE + i] == 1 and m[AC_STATE + i] not in (7, 8)]
            if not live:
                return True, shots, m[HEALTH]
            i, ax, ay = min(live, key=lambda t: (t[1] - px) ** 2 + (t[2] - py) ** 2)
            want = int(math.atan2(ay - py, ax - px) / (2 * math.pi) * 256) & 255
            err = ((want - m[PANG] + 128) & 255) - 128
            if abs(err) > 8:
                s.go(2, joy=0x08 if err > 0 else 0x04)
            elif math.hypot(ax - px, ay - py) > 2.5:
                s.go(3, joy=0x01)
            elif m[WSTATE] == 0:
                s.go(3, trig=1); shots += 1
            else:
                s.go(3)
        return False, shots, s.m()[HEALTH]

    _passive = None

    def passive_death(self):
        """Frames a player survives doing nothing at all, with all enemies awake."""
        if Sweep._passive is not None:
            return Sweep._passive
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(60)
        for i in range(6):
            if s.p[AC_LIVE + i]:
                s.p[AC_STATE + i] = 1
        t = 0
        while t < 3000 and s.m()[HEALTH] > 0:
            s.go(50); t += 50
        Sweep._passive = t
        return t

    def soak(self, level, seed, blocks=50):
        """Randomised play on one level from a fresh boot.

        Returns None if the machine stayed sane throughout, else the state that
        broke. Checks the things that cannot be allowed to drift: DMA still
        configured, the player still inside the map, and every actor inside it
        too -- an actor that escapes indexes the map out of bounds.
        """
        import random
        rng = random.Random(seed)
        s = Sweep(self.xex)
        s.a.frame(80)
        s.pull_trigger()
        s.a.frame(60)
        for _ in range(level):
            if not s.descend():
                return ('could not reach level %d' % (level + 1),)
        for _ in range(blocks):
            s.go(100, joy=rng.choice([0x01, 0x01, 0x04, 0x08, 0x02, 0x09, 0x00]),
                 trig=1 if rng.random() < 0.3 else 0)
            m = s.m()
            if m[SDMCTL] != 0x22 or m[PX_HI] >= 32 or m[PY_HI] >= 32:
                return ('DMA/player', m[SDMCTL], m[PX_HI], m[PY_HI])
            for i in range(6):
                if m[AC_LIVE + i] and (m[AC_XHI + i] >= 32 or m[AC_YHI + i] >= 32):
                    return ('actor %d escaped the map' % i, m[AC_XHI + i], m[AC_YHI + i])
        return None

    def _item_viewpoint(self, m):
        """A spot 3 open cells from a level-1 pickup, facing it.

        Read from the live tables rather than hard-coded: the previous version
        baked "the shells at (8,6)" into the test, so regenerating the item
        table would have broken the check -- a test constant that was really a
        copy of the data under test. All four items are tried, because which of
        them happens to sit at the end of a straight corridor is a property of
        the current level design, not of the renderer under test.
        """
        for i, mask in ((0, 1), (1, 2), (2, 4), (3, 8)):
            ix, iy = m[ITMX + i], m[ITMY + i]
            for dx, dy, ang in ((-1, 0, 0), (1, 0, 128), (0, -1, 64), (0, 1, 192)):
                if all(m[MAPBASE + (ix + dx * k) + (iy + dy * k) * 32] in (0, 8, 12)
                       for k in (1, 2, 3)):
                    return ix + dx * 3, iy + dy * 3, ang, ix, iy, mask
        return None

    def item_pixels(self):
        """Pixels a pickup puts on screen; pixels that survive REAL collection.

        The old version of the second number was diff('taken','taken') -- a
        frame compared against itself, structurally zero, a check that could
        not fail. (The project has a whole document about tests like that. It
        was in this file anyway.) The property now measured: collect the item
        through the game's own path -- stand on it, let check_items fire --
        and the picture must become identical to the renderer's no-item path.
        That catches a wrong bitmask, a wrong table index, or a stale sprite
        left in either framebuffer.
        """
        import metrics as M

        def boot():
            s = Sweep(self.xex)
            s.a.frame(80)
            s.pull_trigger()
            s.a.frame(200)
            for k in range(6):
                s.p[AC_LIVE + k] = 0              # the item is the subject
            return s

        s = boot()
        vp = self._item_viewpoint(s.m())
        if vp is None:
            return 0, 99, False
        px, py, ang, ix, iy, mask = vp

        def look(s):
            s.p[PX_HI], s.p[PX_LO] = px, 0x80
            s.p[PY_HI], s.p[PY_LO] = py, 0x80
            s.p[PANG] = ang
            s.go(20)                              # repaint BOTH buffers
            return M.luma(M.grab(s.a))

        present = look(s)
        s.p[PX_HI], s.p[PY_HI] = ix, iy           # stand on it: the real path
        s.go(15)
        collected = bool(s.m()[ITMGOT] & mask)
        after = look(s)

        s2 = boot()                               # control: never drawn at all
        s2.p[ITMGOT] = 0xFF
        taken = look(s2)

        diff = lambda a, b: sum(1 for r in range(96) for c in range(80)
                                if a[r][c] != b[r][c])
        return diff(present, taken), diff(after, taken), collected

    def material_luma(self, mats):
        """Mean rendered luminance of a flat facing wall of each material.

        Each material gets its own fresh run so the player is in an identical
        position every time and the only variable is the wall in front of them.
        """
        import metrics as M
        out = {}
        for mat in mats:
            s = Sweep(self.xex)
            s.a.frame(80)
            s.pull_trigger()
            s.a.frame(200)
            m = s.m()
            for dy in range(-3, 4):
                s.p[MAPBASE + (m[PX_HI] + 4) + (m[PY_HI] + dy) * 32] = mat
            for i in range(6):
                s.p[AC_LIVE + i] = 0          # nothing may occlude the wall
            s.go(30)
            L = M.luma(M.grab(s.a))
            out[mat] = sum(L[r][40] for r in range(44, 52)) / 8.0
        return out

    _exits = None

    def exits_ok(self):
        """Levels whose compiled map holds exactly one exit, at the coordinates
        in their own container header, reachable from their own spawn using only
        what the engine implements (open cells and plain doors)."""
        if Sweep._exits is not None:
            return Sweep._exits
        good = 0
        for n, mapfile in ((1, 'map0.bin'), (2, 'map2.bin'), (3, 'map3.bin'), (4, 'map4.bin')):
            grid = open(os.path.join('src', mapfile), 'rb').read()
            hdr = open(os.path.join('src', 'map%d.lev.bin' % n), 'rb').read()
            want = (hdr[7], hdr[8])
            spawn = (hdr[4], hdr[5])
            found = [(i % 32, i // 32) for i, v in enumerate(grid) if v == 0x0C]
            if found == [want] and self.route(grid, spawn, want) is not None:
                good += 1
        Sweep._exits = good
        return good

    def descend(self):
        """Walk to the level's REAL exit and take it.

        This used to POKE an exit cell into the map in front of the player and
        walk one step into it -- so "victory after the last level" passed on a
        build in which no level contained an exit at all. The harness was
        manufacturing the thing it was testing. Now it path-finds to the
        genuine `$0C` and drives the player there.
        """
        import math
        m = self.m()
        grid = bytes(m[MAPBASE:MAPBASE + 0x400])
        exits = [(i % 32, i // 32) for i, v in enumerate(grid) if v == 0x0C]
        if not exits:
            return False
        goal = exits[0]
        path = self.route(grid, (m[PX_HI], m[PY_HI]), goal)
        if path is None:
            return False
        # Re-route from wherever the player actually IS every so often. A
        # single fixed path plus a follow loop drifts: the player rounds a
        # corner wide, the next waypoint ends up behind them, and the walker
        # oscillates. Re-planning costs nothing here and makes the check
        # measure the level rather than the quality of my steering.
        i = 1
        for step in range(8000):
            mm = self.m()
            if mm[WONDONE]:
                break
            # Keep the walker alive. This check asks "is the exit reachable and
            # does taking it work"; whether you can SURVIVE the trip is what
            # the autoplayer and passive-death checks measure. Without this it
            # died at waypoint 58 of 64 on SILENT COLONNADE -- which says the
            # level is dangerous, not that the exit is unreachable.
            if mm[HEALTH] < 60:
                self.p[HEALTH] = 100
            px = mm[PX_HI] + mm[PX_LO] / 256.0
            py = mm[PY_HI] + mm[PY_LO] / 256.0
            if step % 150 == 149:
                fresh = self.route(bytes(mm[MAPBASE:MAPBASE + 0x400]),
                                   (mm[PX_HI], mm[PY_HI]), goal)
                if fresh:
                    path, i = fresh, 1
            while i < len(path) - 1 and \
                    math.hypot(path[i][0] + 0.5 - px, path[i][1] + 0.5 - py) < 0.9:
                i += 1
            tx, ty = path[i]
            dx, dy = (tx + 0.5) - px, (ty + 0.5) - py
            if math.hypot(dx, dy) < 0.5 and i >= len(path) - 1:
                break
            want = int(math.atan2(dy, dx) / (2 * math.pi) * 256) & 255
            err = ((want - mm[PANG] + 128) & 255) - 128
            if abs(err) > 24:
                self.go(2, joy=0x08 if err > 0 else 0x04)
            else:
                self.go(2, joy=0x01)
        if not self.m()[WONDONE]:
            return False
        self.pull_trigger()
        self.go(60)
        return True

    @staticmethod
    def route(grid, start, goal):
        """Breadth-first path over cells the engine can actually walk."""
        from collections import deque
        passable = lambda v: v in (0, 0x08, 0x0C)
        prev = {start: None}
        q = deque([start])
        while q:
            cur = q.popleft()
            if cur == goal:
                out = []
                while cur is not None:
                    out.append(cur)
                    cur = prev[cur]
                return out[::-1]
            x, y = cur
            for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                if 0 <= nx < 32 and 0 <= ny < 32 and (nx, ny) not in prev \
                        and passable(grid[ny * 32 + nx]):
                    prev[(nx, ny)] = cur
                    q.append((nx, ny))
        return None


if __name__ == '__main__':
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    sys.exit(0 if Sweep(sys.argv[1] if len(sys.argv) > 1 else 'abyss.xex').run() else 1)
