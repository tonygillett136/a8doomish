#!/usr/bin/env python3
"""metrics.py -- measure what the picture actually contains.

The visual critique rounds were only useful because they counted pixels instead
of giving impressions, so the same numbers live here and can be re-run against
any build. In GTIA mode 9 the colour-register byte is HHHHLLLL: the high nibble
is the hue the DLI set for that band and the low nibble IS the pixel's
luminance, so the screen buffer can be read back as exact luminance values with
no estimation anywhere.

    python3 tools/metrics.py [xex]
"""
import sys, os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
from a8 import A8                                              # noqa: E402

SCREEN_W = 384
VIEW_TOP = 24                   # first scanline of the 3D view
VIEW_ROWS = 96                  # buffer rows, each shown on two scanlines
VIEW_COLS = 80                  # mode 9 pixels across the normal playfield
X0 = 32                         # normal playfield starts here in the 384 buffer
XSCALE = 4                      # ...at four screen pixels per logical pixel

CEIL = range(0, 30)             # hue bands, set by the DLI chain
WALL = range(30, 66)
FLOOR = range(66, 96)


def grab(a):
    """The viewport as a 96x80 grid of colour-register bytes."""
    buf = a.screen_rgb()
    return [[buf[(VIEW_TOP + 2 * r) * SCREEN_W + X0 + c * XSCALE]
             for c in range(VIEW_COLS)] for r in range(VIEW_ROWS)]


def luma(g):
    return [[v & 0x0F for v in row] for row in g]


def hue(g):
    return [[v >> 4 for v in row] for row in g]


def flat_fraction(L, rows):
    """Pixels identical to all four neighbours -- the critic's flatness metric."""
    flat = tot = 0
    for r in rows:
        if r == 0 or r == VIEW_ROWS - 1:
            continue
        for c in range(1, VIEW_COLS - 1):
            v = L[r][c]
            tot += 1
            if v == L[r - 1][c] == L[r + 1][c] == L[r][c - 1] == L[r][c + 1]:
                flat += 1
    return flat / tot if tot else 0.0


def stats(L, rows):
    vals = [v for r in rows for v in L[r]]
    m = sum(vals) / len(vals)
    sd = (sum((v - m) ** 2 for v in vals) / len(vals)) ** 0.5
    return m, sd, len(set(vals))


def ramp_from_ladders():
    """The ceiling and floor luminance the ladder paints at each buffer row.

    Read out of the generated ladders.asm rather than recomputed, so this
    measures the build rather than the generator's intent.
    """
    import re
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            '..', 'src', 'ladders.asm')).read()
    def imms(tag):
        body = re.search(r'LAD%s_A\n(.*?)\n        rts' % tag, src, re.S).group(1)
        return [int(m, 16) >> 4 for m in re.findall(r'lda #\$([0-9A-F]{2})', body)]
    ceil_emit, floor_emit = imms('R'), imms('F')
    ramp = {}
    for i, v in enumerate(ceil_emit):       # emitted horizon-first: row 47-i
        ramp[47 - i] = v
    for i, v in enumerate(floor_emit):      # emitted in row order from 48
        ramp[48 + i] = v
    return ramp


def band_crossings(g, ramp):
    """Wall luminance painted into the ceiling or floor HUE band.

    A wall taller than the 36-row wall band spills past it, and before the
    ladder caps were added it spilled at WALL brightness -- a cyan bar above
    every near wall and a gold one below.

    The caps that fixed it are themselves painted out here, deliberately, as a
    dark vignette, so "not the ramp value" is no longer enough to identify the
    bug: the threshold has to sit above the brightest cap. wallcap() tops out at
    6, so anything above that is wall luminance leaking out, which is the defect;
    1-6 is the intended vignette.
    """
    L = luma(g)
    return sum(1 for r in list(CEIL) + list(FLOOR) for c in range(VIEW_COLS)
               if L[r][c] > 6 and L[r][c] != ramp.get(r, -1)
               and not (r >= 70 and 28 <= c <= 66))      # the weapon lives here
               # (cols 28-66: the redrawn gun sweeps right to 65. When it was
               #  28-48 its own stock counted as 27 px of 'leak'.)


def report(xex='abyss.xex'):
    a = A8(pal=True)
    a.boot(xex)
    a.frame(80)
    a.inp.trig0 = 1; a.frame(3); a.inp.trig0 = 0     # dismiss the title
    a.frame(200)
    fps = a.memory()[0x600] / (203 / 50.0)
    g = grab(a)
    L = luma(g)

    print('%-34s %s' % ('render rate', '%.1f fps' % fps))
    print('%-34s %s' % ('', ''))
    for name, rows in (('ceiling (rows 0-29)', CEIL),
                       ('wall    (rows 30-65)', WALL),
                       ('floor   (rows 66-95)', FLOOR)):
        m, sd, n = stats(L, rows)
        print('%-34s mean %5.2f  sd %4.2f  %2d levels  flat %5.1f%%'
              % (name, m, sd, n, 100 * flat_fraction(L, rows)))
    m, sd, n = stats(L, range(VIEW_ROWS))
    print('%-34s mean %5.2f  sd %4.2f  %2d levels  flat %5.1f%%'
          % ('viewport', m, sd, n, 100 * flat_fraction(L, range(VIEW_ROWS))))
    print('%-34s %d px' % ('wall luma leaking past the cap', band_crossings(g, ramp_from_ladders())))
    print('%-34s %d' % ('darkest pixel in viewport', min(min(r) for r in L)))
    print('%-34s %d' % ('brightest pixel in viewport', max(max(r) for r in L)))

    # muzzle flash: the ceiling takes its hue from the COLBK shadow while the
    # wall and floor bands are set live by DLIs, so a shadow-only write lit the
    # ceiling a frame after the room. Sample the two bands frame by frame.
    print('\nmuzzle flash, per frame (ceiling luma vs wall luma):')
    a.frame(40)
    a.inp.trig0 = 1; a.frame(2); a.inp.trig0 = 0
    for i in range(6):
        a.frame(1)
        L2 = luma(grab(a))
        cm = sum(L2[r][c] for r in CEIL for c in range(VIEW_COLS)) / (30 * 80)
        wm = sum(L2[r][c] for r in WALL for c in range(VIEW_COLS)) / (36 * 80)
        print('   frame %d: ceiling %5.2f   wall %5.2f%s'
              % (i, cm, wm, '   <- lit' if cm > 8 or wm > 8 else ''))


if __name__ == '__main__':
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    report(sys.argv[1] if len(sys.argv) > 1 else 'abyss.xex')
