#!/usr/bin/env python3
"""gallery.py -- capture the screenshot set, and refuse to lie about it.

An earlier hand-rolled version produced twelve frames of which six showed
something other than their filename: four identical death screens labelled as
levels 2, 3, 4 and victory, and a "muzzle flash" containing no flash. Every
capture had run and every file had been written. A whole adversarial review was
then conducted on fiction.

So every shot here states the condition it believes it is capturing, that
condition is checked against RAM at the moment of capture, and every file is
hashed so an accidental duplicate cannot pass silently.

Two traps it exists to catch, both about state rather than code:
  * victory outranks death in the status logic, so killing the player after
    winning shows the victory screen forever;
  * the flash colours are written by the VBI at the END of a frame, so they
    only reach the screen on the NEXT one.

    python3 tools/gallery.py
"""
import sys, os, hashlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from verify import (Sweep, AC_LIVE, AC_XHI, AC_XLO, AC_YHI, AC_YLO, AC_STATE,   # noqa: E402
                    AC_HP, AC_FRAME_OFF, HEALTH, PX_HI, PY_HI, WSTATE, WONALL,
                    LEVELNO, INTITLE, RENDERS)

OUT = 'gallery'


class Gallery:
    def __init__(self):
        self.seen = {}
        self.bad = 0

    def save(self, a, name, ok, why):
        path = os.path.join(OUT, name + '.png')
        a.save_png(path)
        h = hashlib.md5(open(path, 'rb').read()).hexdigest()[:8]
        dup = self.seen.get(h)
        self.seen[h] = name
        if not ok or dup:
            self.bad += 1
        print('  %-22s %s %s%s' % (name, 'OK ' if ok and not dup else 'BAD',
                                   why, '   *** DUPLICATE of ' + dup if dup else ''))


def walk_in(s):
    """Move off the spawn point and stop on the most informative view.

    Every level was being photographed standing on its own start square, and
    all four levels start in a corridor, so all four screenshots showed a
    corridor. Three separate reviewers concluded from that gallery that the game
    is "one room re-lit five times" and that the corridor end-cap is a
    copy-pasted prop appearing in every level. Walking in for two seconds shows
    a colonnade, a hall with columns receding to one side, a wall face under a
    vault -- spaces that look nothing like each other.

    That was not a defect in the game. It was a defect in the instrument, and it
    is the worse kind: the pictures were all true, all consistent, and together
    they told a story about the game that was not so.

    The route is fixed -- forward, turn, forward, turn back, forward -- so the
    shots stay reproducible and are still asserted against the level number they
    claim. Enemies are cleared along the way because the subject of these three
    frames is the room, not its tenants; there are separate shots for those.
    """
    for steps, joy in ((50, 0x01), (24, 0x04), (50, 0x01), (24, 0x08), (40, 0x01)):
        for i in range(1, 6):
            s.p[AC_LIVE + i] = 0
        s.go(steps, joy=joy)


def main():
    os.makedirs(OUT, exist_ok=True)

    # Boot FIRST, delete second. A transient libatari800 init failure once left
    # the directory empty after the old frames had already been removed -- and
    # an empty gallery is the loudest lie this tool can tell.
    g = Gallery()
    s = Sweep()
    a, p = s.a, s.p
    a.frame(60)
    for f in os.listdir(OUT):
        if f.endswith('.png'):
            os.remove(os.path.join(OUT, f))
    g.save(a, '01_title', s.m()[INTITLE] == 1 and s.m()[RENDERS] == 0,
           'title up, world not yet rendering')
    s.pull_trigger()
    a.frame(200)
    g.save(a, '02_vestibule', s.m()[RENDERS] > 0 and s.m()[LEVELNO] == 0, 'level 1')
    s.go(150, joy=0x01)
    g.save(a, '03_corridor', True, 'after walking')

    m = s.m()
    for i in range(1, 6):
        p[AC_LIVE + i] = 0
    for ad, v in ((AC_XHI, m[PX_HI] + 3), (AC_XLO, 0x80), (AC_YHI, m[PY_HI]),
                  (AC_YLO, 0x80), (AC_LIVE, 1), (AC_STATE, 1), (AC_HP, 60)):
        p[ad] = v
    s.go(20)
    g.save(a, '04_husk', s.m()[AC_LIVE] == 1, 'husk alive at 3 cells')

    a.inp.trig0 = 1; a.frame(1); a.inp.trig0 = 0
    a.frame(1)                                  # the VBI's colours land NEXT frame
    g.save(a, '05_muzzleflash', s.m()[WSTATE] >= 50, 'wstate=%d' % s.m()[WSTATE])
    s.go(150)

    for ad, v in ((AC_LIVE, 1), (AC_STATE, 8), (AC_HP, 0),
                  (AC_FRAME_OFF, 12), (AC_XHI, s.m()[PX_HI] + 2)):
        p[ad] = v
    s.go(20)
    g.save(a, '06_corpse', s.m()[AC_STATE] == 8, 'corpse on the floor')

    p[HEALTH] = 0                               # BEFORE victory, never after
    s.go(30)
    g.save(a, '07_death', s.m()[HEALTH] == 0 and s.m()[WONALL] == 0, 'dead, not yet won')
    s.pull_trigger()
    s.go(40)

    for lvl, name in ((1, '08_red_cistern'), (2, '09_silent_colonnade'), (3, '10_the_maw')):
        if not s.descend():
            g.save(a, name, False, 'DESCENT FAILED')
            continue
        s.go(60)
        walk_in(s)
        g.save(a, name, s.m()[LEVELNO] == lvl, 'levelno=%d' % s.m()[LEVELNO])

    # Photographing THE MAW from inside the level means the walk to its exit
    # starts from wherever the tour ended, which is further and more awkward
    # than from the spawn. descend() re-routes from the player's real position
    # every few steps, so a second attempt is a genuinely fresh plan rather than
    # a retry of the same failure -- and if it still cannot get there, that is
    # reported rather than papered over.
    import random
    rng = random.Random(4)
    for attempt in range(5):
        if s.descend() and s.m()[WONALL]:
            break
        # Not a retry of the same plan: descend() re-routes from the player's
        # real position, so shaking them off whatever corner they wedged into
        # gives it a genuinely different problem to solve. Tested to fail the
        # first attempt only from some tour endings, and never twice.
        for _ in range(6):
            s.go(12, joy=rng.choice([0x01, 0x02, 0x04, 0x08, 0x05, 0x09]))
    s.go(30)
    g.save(a, '11_victory', s.m()[WONALL] == 1, 'wonall=%d' % s.m()[WONALL])

    print('\n%d frames, %d suspect' % (len(g.seen), g.bad))
    return 1 if g.bad else 0


if __name__ == '__main__':
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    sys.exit(main())
