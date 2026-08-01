#!/usr/bin/env python3
"""gentables.py — build ABYSS's runtime tables as a flat binary INS'd by main.asm.

Everything the raycaster needs that would otherwise cost a runtime divide or
multiply is precomputed here. Layout is fixed and mirrored by TABLES.INC.

Fixed point: positions and distances are 8.8 (high byte = map cell).
Angles are 0..255 = full circle (a byte turns the whole way round).
"""
import math, os, struct, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'tables.bin')
INC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'tables.inc')

ANGLES = 256
COLS = 40           # ray columns; each is 2 screen px wide (1 byte in mode 9)
VIEW_H = 96         # 3D viewport BUFFER rows (each shown as 1 mode-F line + 1 blank)
HORIZON = VIEW_H // 2
FOV_DEG = 60.0
MAXDIST = 16.0      # cells; beyond this we clamp to the far shade

blobs = []          # (name, bytes)


def add(name, data):
    b = bytes(data)
    blobs.append((name, b))


def pad_to_page():
    total = sum(len(b) for _, b in blobs)
    r = total % 256
    if r:
        blobs.append(('_pad%d' % len(blobs), bytes(256 - r)))


def s88(v):
    """signed 8.8 -> (lo, hi) two's complement."""
    n = int(round(v * 256.0)) & 0xFFFF
    return n & 0xFF, (n >> 8) & 0xFF


# ---- ray direction per angle (8.8 signed) -----------------------------------
rdx_lo, rdx_hi, rdy_lo, rdy_hi = [], [], [], []
# deltaDist = |1/raydir|, clamped; 8.8 unsigned
ddx_lo, ddx_hi, ddy_lo, ddy_hi = [], [], [], []
stepx, stepy = [], []

BIG = 0xFFFF
for a in range(ANGLES):
    th = (a / ANGLES) * 2.0 * math.pi
    dx, dy = math.cos(th), math.sin(th)
    lo, hi = s88(dx); rdx_lo.append(lo); rdx_hi.append(hi)
    lo, hi = s88(dy); rdy_lo.append(lo); rdy_hi.append(hi)

    ddx = BIG if abs(dx) < 1.0 / 512 else min(BIG, int(round(abs(1.0 / dx) * 256)))
    ddy = BIG if abs(dy) < 1.0 / 512 else min(BIG, int(round(abs(1.0 / dy) * 256)))
    ddx_lo.append(ddx & 0xFF); ddx_hi.append((ddx >> 8) & 0xFF)
    ddy_lo.append(ddy & 0xFF); ddy_hi.append((ddy >> 8) & 0xFF)

    # step direction as +1 / -1 stored as $01 / $FF
    stepx.append(0x01 if dx >= 0 else 0xFF)
    stepy.append(0x01 if dy >= 0 else 0xFF)

stpxl = [0x01 if s == 0x01 else 0xFF for s in stepx]
stpxh = [0x00 if s == 0x01 else 0xFF for s in stepx]
stpyl = [0x20 if s == 0x01 else 0xE0 for s in stepy]
stpyh = [0x00 if s == 0x01 else 0xFF for s in stepy]
add('STPXL', stpxl); add('STPXH', stpxh)
add('STPYL', stpyl); add('STPYH', stpyh)

for nm, d in (('RDX_LO', rdx_lo), ('RDX_HI', rdx_hi), ('RDY_LO', rdy_lo), ('RDY_HI', rdy_hi),
              ('DDX_LO', ddx_lo), ('DDX_HI', ddx_hi), ('DDY_LO', ddy_lo), ('DDY_HI', ddy_hi),
              ('STEPX', stepx), ('STEPY', stepy)):
    add(nm, d)

# ---- per-column ray angle offset --------------------------------------------
# Screen-uniform (true perspective): offset = atan((c - centre)/planeDist).
# planeDist chosen so the outermost column sits at FOV/2.
half = math.radians(FOV_DEG / 2.0)
centre = (COLS - 1) / 2.0
plane_d = centre / math.tan(half)
col_ang, col_cos = [], []
for c in range(COLS):
    th = math.atan((c - centre) / plane_d)
    col_ang.append(int(round(th / (2 * math.pi) * ANGLES)) & 0xFF)
    col_cos.append(math.cos(th))
add('COL_ANG', col_ang)
pad_to_page()

# ---- height tables, fisheye baked in ----------------------------------------
# Distance is quantised to 8 bits over [0, MAXDIST) cells -> idx = dist * 16.
# Fisheye correction folded in per column-GROUP (8 groups of 5), so the runtime
# does ONE indexed lookup and never multiplies. Groups mirror about the centre,
# so only 4 distinct tables exist; GRPTAB maps group -> table index.
GROUPS = 8
PERGRP = COLS // GROUPS
grp_cos = []
for g in range(GROUPS):
    cs = col_cos[g * PERGRP:(g + 1) * PERGRP]
    grp_cos.append(sum(cs) / len(cs))

uniq, grpmap = [], []
for g in range(GROUPS):
    m = g if g < GROUPS // 2 else GROUPS - 1 - g       # mirror
    if m not in [u[0] for u in uniq]:
        uniq.append((m, grp_cos[m]))
    grpmap.append([u[0] for u in uniq].index(m))

htabs = []
for _, cs in uniq:
    t = []
    for i in range(256):
        d = (i + 0.5) / 16.0
        dd = d * cs                     # perpendicular distance
        h = VIEW_H / dd if dd > 0.01 else VIEW_H
        h = max(0, min(VIEW_H, int(round(h))))
        k = (VIEW_H - h) // 2
        t.append(max(0, min(VIEW_H // 2 - 1, k)))       # wall top row
    htabs.append(t)
for i, t in enumerate(htabs):
    add('HTAB%d' % i, t)
# One entry per COLUMN, not per group. The renderer indexed this with `col>>3`
# while it was built for `col//5`, so entries 5-7 were never read at all and the
# mapping came out monotonic instead of mirror-symmetric: the right-hand 40% of
# the screen got essentially no fisheye correction, and a dead-flat wall bowed
# by six buffer rows with the right edge four rows short of the left.
# Indexing per column costs 32 bytes of table and REMOVES five instructions.
add('GRPTAB', [grpmap[c // PERGRP] for c in range(COLS)])
pad_to_page()

# ---- shading ----------------------------------------------------------------
# Mode 9 pixel value IS luminance (0..15). Diminished lighting = the DOOM look.
# Near walls bright, far walls sink into the dark. N/S faces one step darker
# than E/W: the cheapest depth cue there is.
NEAR, FAR = 15.0, 2.0

def dither(v):
    """Luminance as a mode-9 byte. Both nibbles equal: a half-step dither
    (unequal nibbles) gives 31 levels but, because every byte in a region
    shares the same nibble pair, it reads as hard 2-pixel vertical bars
    rather than a half-tone. Flat nibbles, banding and all, looks cleaner."""
    v = int(round(max(1.0, min(15.0, v))))
    return (v << 4) | v


# NOTE: this curve is deliberately UNCHANGED from the original sqrt falloff.
# The ceiling and floor ramps were refitted to reciprocals because their rows
# map to depth exactly and the sqrt was flattest over the only depths visible.
# The wall's shade index is not a screen row, so the same argument does not
# apply, and refitting it measured as a loss. What did change is that the table
# is SHIFTED by the stone material's bias (see MATBIAS below), so a stone wall
# looks up exactly the luminance it did before materials existed.
def shade_curve(d):
    """Wall luminance at a distance of d cells."""
    t = min(1.0, max(0.0, d) / MAXDIST)
    return NEAR - (NEAR - FAR) * math.sqrt(t)


raw = [shade_curve((i + 0.5) / 16.0) for i in range(256)]


def _slope_at(target=8.0):
    """Luma lost per unit of shade index, near a typical mid-range wall."""
    i = min(range(256), key=lambda k: abs(raw[k] - target))
    lo, hi = max(0, i - 16), min(255, i + 16)
    return (raw[lo] - raw[hi]) / float(hi - lo)


# ---- per-material wall signature -------------------------------------------
# Indexed by the map's own solid-plane byte and applied exactly like the light:
# as apparent distance, so it reuses the shade ramp and costs one `adc`.
#
# The offsets are DERIVED from the ramp rather than guessed. A first attempt
# used hand-picked numbers in the 0-20 range and measured as two visible
# buckets instead of seven: at typical play distance the ramp falls only about
# 0.05 luma per index step, so a "+6 darker" material was 0.3 of a luminance
# level -- invisible.
#
# Because an offset can only ever DARKEN, stone (97% of the map) has to sit
# mid-table to leave room underneath for the materials that must read BRIGHTER
# -- doors and the exit, the two things a player actually hunts for. Done
# naively that darkens the entire game by stone's own offset, which measured as
# 1.4 luma off the whole wall band and cost more than it bought.
#
# So the shade tables below are pre-shifted by stone's offset. A stone wall
# looks up exactly the luminance it did before materials existed, and every
# other material deviates from it in either direction. It is free: the shift
# lives in the generated table, not in the 6502.
#
# secret and sealed MUST match stone exactly. They are walls the player is not
# meant to be able to spot, and any distinct shade gives every one of them away.
_SLOPE = _slope_at()
MAT_DARKER = {                  # luminance steps darker than the brightest
    0: 0.0,                     #  0 open -- never sampled
    7: 0.0,                     #  7 glow: a landmark you steer by
    12: 0.0,                    # 12 exit switch: the brightest thing in a level
    3: 1.2,                     #  3 metal: pale
    5: 1.2,                     #  5 tech: lit panelling
    8: 0.8, 9: 0.8, 10: 0.8, 11: 0.8,     # doors: second only to the exit itself.
                                #    Finding them is the whole point.
    1: 3.0,                     #  1 stone: the baseline
    13: 3.0,                    # 13 secret: indistinguishable from stone
    15: 3.0,                    # 15 sealed: likewise
    4: 4.2,                     #  4 flesh
    2: 4.5,                     #  2 brick: rougher
    14: 5.4,                    # 14 bars
    6: 6.0,                     #  6 rock: raw cavern, darkest
}
MATBIAS = [min(255, int(round(MAT_DARKER[m] / _SLOPE))) for m in range(16)]
STONE_BIAS = MATBIAS[1]
add('MATBIAS', MATBIAS)

# ...and here is the shift that makes stone free.
shade = [shade_curve((i + 0.5 - STONE_BIAS) / 16.0) for i in range(256)]
add('SHADE_EW', [dither(v) for v in shade])
# a hard dark column wherever the ray crosses onto a different wall cell:
# this is what makes a flat-shaded corridor read as BUILT
add('SHADE_EDGE', [dither(max(1.0, v - 7.0)) for v in shade])
# Course contrast as a function of distance. The masonry courses are baked
# into the wall ladder at a fixed screen pitch, so they cannot recede -- but
# they can FADE. The old fixed two-step contrast was at its most visible
# exactly where it was most wrong: on far walls, where real detail would have
# dissolved anyway and where a grating pinned to screen rows reads loudest.
# Near walls keep their masonry; past about five cells it goes.
add('CRSTAB', [0x22 if i < 4 else 0x11 if i < 10 else 0x00 for i in range(32)])
add('SHADE_NS', [dither(max(1.0, v - 3.0)) for v in shade])   # fake contrast, -3 of 16

# ceiling and floor ramps, indexed by buffer row: far (horizon) dark, near bright.
# Floor brighter than ceiling, as DOOM.
HALFV = VIEW_H // 2

# A sqrt falloff was measured to put only TWO luminance values across the 30
# ceiling rows that are actually visible, and three across the floor -- 62% of
# the screen was flat. The visible rows span roughly 1 to 2.5 cells of depth,
# and sqrt is at its flattest exactly there. A reciprocal (which is what
# perspective actually is) spends its range where the rows are.
def ramp_lum(d, k):
    return max(1.0, min(15.0, k / d))

# Receding bands: a one-step lift on alternate PLATEAUX of the ramp.
#
# The first version toggled at a fixed list of row numbers. Measured, that gave
# one real edge, two single-row blips (up one, straight back down -- a
# two-scanline stripe that reads as a scanline artefact, not a band) and two
# that did nothing at all, because the underlying reciprocal was climbing too
# fast at those rows for a +-1 to survive.
#
# Keying off the ramp's own plateaux fixes that. Note what the plateaux are NOT:
# they do not widen toward the viewer. Buffer row r maps to depth 48/(r+1), and
# diminishing light is k/d, so lum = k(r+1)/48 -- LINEAR in row. The two
# reciprocals cancel. That is the correct result (1/d lighting over a 1/r depth
# mapping really is linear in screen row), so the ramp is right and the plateaux
# are evenly spaced; it is only the intuition about them that was wrong.
def band_ramp(depth_of_row, k):
    base = [ramp_lum(depth_of_row(r), k) for r in range(HALFV)]
    out, i, plateau = [0] * HALFV, 0, 0
    while i < HALFV:
        j = i
        while j < HALFV and round(base[j]) == round(base[i]):
            j += 1
        wide = (j - i) >= 2
        # No offset. A +-1 on alternate plateaux was measured to MERGE them:
        # lifting a plateau of 10 down to 9 makes it identical to the next one
        # along, so the ceiling collapsed to odd values only and lost two of
        # its levels. The ramp's own plateaux are the gradient; they do not
        # need help, and (see the note above) they are evenly spaced rather
        # than widening -- the two reciprocals cancel.
        off = 0
        for r in range(i, j):
            out[r] = dither(round(base[i]) - off)   # the PLATEAU's value, not
                                                    # each row's: grouping on
                                                    # the rounded value while
                                                    # emitting the raw one let
                                                    # a row inside a plateau
                                                    # round the other way and
                                                    # put a blip back
        if wide:
            plateau += 1
        i = j
    return out


floor_ramp = band_ramp(lambda r: min(16.0, 48.0 / (r + 1)), 13.0)   # r=0 horizon
ceil_ramp = band_ramp(lambda j: min(16.0, 48.0 / (j + 1)), 11.0)    # dimmer than
ceil_ramp = ceil_ramp[::-1]                                         # the floor;
                                                                    # row 0 = overhead
pad_to_page()

# ---- quarter-square multiply (for the sideDist seeding) ---------------------
# mul(a,b) = f(a+b) - f(a-b), f(n) = n*n/4. 512-entry, lo/hi.
f = [(n * n) // 4 for n in range(512)]
add('SQ_LO', [v & 0xFF for v in f])
add('SQ_HI', [(v >> 8) & 0xFF for v in f])

# ---- ladder entry offsets ---------------------------------------------------
# W (wall): 96 entries ordered as symmetric pairs outermost-first
#   0,95,1,94,...,47,48 -> entering at index 2k paints exactly rows k..95-k.
# R (ceiling): rows 47,46,...,0 -> entering at 48-k paints rows 0..k-1.
# F (floor):   rows 48,49,...,95 -> entering at 48-k paints rows 96-k..95.
HALF = VIEW_H // 2
worder = []
for k in range(HALF):
    worder.append(k); worder.append(VIEW_H - 1 - k)
add('WORDER', worder)                      # row painted at each W ladder slot
add('WOFF_LO', [((k * 8) & 0xFF) for k in range(HALF + 1)])
add('WOFF_HI', [((k * 8) >> 8) for k in range(HALF + 1)])
add('RFOFF_LO', [(((HALF - k) * 5) & 0xFF) for k in range(HALF + 1)])
add('RFOFF_HI', [(((HALF - k) * 5) >> 8) for k in range(HALF + 1)])
pad_to_page()
add('RORDER', [HALF - 1 - i for i in range(HALF)])   # ceiling ladder row order
add('FORDER', [HALF + i for i in range(HALF)])       # floor ladder row order

# per-cell light -> apparent-distance offset. Light 7 = full brightness,
# light 0 = pitch dark. This is what DOOM's diminishing lighting actually is.
add('LIGHTOFS', [64, 48, 34, 24, 16, 10, 4, 0])
pad_to_page()

SCREEN_BASE = 0x8000
add('ROWLO', [((SCREEN_BASE + r * 40) & 0xFF) for r in range(VIEW_H)])
add('ROWHI', [((SCREEN_BASE + r * 40) >> 8) for r in range(VIEW_H)])
pad_to_page()

# ---- write ------------------------------------------------------------------
data = bytearray()
offs = []
for name, b in blobs:
    offs.append((name, len(data), len(b)))
    data += b

with open(OUT, 'wb') as fh:
    fh.write(data)

with open(INC, 'w') as fh:
    fh.write('; GENERATED by tools/gentables.py -- do not edit\n')
    fh.write('; total %d bytes\n' % len(data))
    for name, off, ln in offs:
        fh.write('%-10s = TABLES+%-6d ; %d bytes\n' % (name, off, ln))
    assert len(data) <= 0x2000, (
        'tables.bin is %d bytes; TABLES is at $5000 and the map is at $7000, so '
        'anything over 8192 silently overwrites the map. Adding a 256-byte table '
        'once did exactly that and the player walked out of the world.' % len(blob))
    fh.write('TABLES_LEN = %d\n' % len(data))
    fh.write('VIEW_H     = %d\n' % VIEW_H)
    fh.write('HORIZON    = %d\n' % HORIZON)
    fh.write('NCOLS      = %d\n' % COLS)

# The wall hue band is buffer rows 30..65 (set by the DLI chain); a wall taller
# than 36 rows spills past it at both ends.
WBAND_TOP = 30

def wallcap(k):
    """Luminance for a wall row that falls outside its own hue band.

    A smooth vignette rather than a step -- but it has to stay BELOW the ramp it
    sits against, or the wall's own silhouette disappears. Slot k paints rows k
    and 95-k, which abut the ceiling ramp at row k and the floor ramp at row
    95-k. A cap that reached 6 crossed a ceiling bottoming out at 4 and a floor
    starting at 5, and measured ZERO luminance steps of edge contrast at 2.8
    cells, with the top edge actually inverted. The eye then reads the hue seam
    at row 30 as the wall's top -- a dead straight line up to six rows below the
    real silhouette, at exactly the range where you decide whether to turn.

    Two steps of clearance, so the edge always reads.
    """
    v = 6 - (29 - k) // 5
    v = min(v, (ceil_ramp[k] >> 4) - 2, (floor_ramp[47 - k] >> 4) - 2)
    return dither(max(1, v))

LAD = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'ladders.asm')
with open(LAD, 'w') as fh:
    fh.write('; GENERATED by tools/gentables.py -- do not edit\n')
    fh.write('; Suffix ladders: entering at the right slot paints an EXACT run,\n')
    fh.write('; 5 cycles/byte, no loop counter, no overdraw.\n')
    for tag, org in (('A', '$2C00'), ('B', '$3400')):
        base = 'SCREEN' if tag == 'A' else 'SCREEN+$1000'
        fh.write('\n        org ' + org + '\n')
        # WALL: constant luminance held in A (it varies per column)
        # WALL: horizontal courses. Each pair reloads A from one of two
        # luminances, alternating every second pair -- the cheapest "built"
        # texture available, and reloading every pair keeps entry anywhere safe.
        fh.write('LADW_' + tag + '\n')
        for k in range(VIEW_H // 2):             # symmetric pairs, outermost first
            if k < WBAND_TOP:
                # Slot k paints rows k and 95-k, so slots 0..29 are the ONLY
                # ones that ever paint outside the wall's hue band -- and they
                # did it in wall luminance, which produced a bright cyan cap
                # above every near wall and a gold one below it. Immediates
                # here cost one cycle LESS than the zero-page load, and a dark
                # cap reads as the wall falling out of the light.
                fh.write('        lda #$%02X\n' % wallcap(k))
            else:
                # ONE dark row in four, not two: a 50% square wave reads as
                # corrugated steel, a single line reads as mortar.
                src = 'wlum2' if (k % 4) == 3 else 'wlum'
                fh.write('        lda %s\n' % src)
            fh.write('        sta %s+%d*40,x\n' % (base, k))
            fh.write('        sta %s+%d*40,x\n' % (base, VIEW_H - 1 - k))
        fh.write('        rts\n\n')
        # CEILING: the vertical ramp is baked in as immediates, so the depth
        # gradient costs 2 cycles a row and needs no table fetch.
        fh.write('LADR_' + tag + '\n')
        for r in range(VIEW_H // 2 - 1, -1, -1):
            fh.write('        lda #$%02X\n' % ceil_ramp[r])
            fh.write('        sta %s+%d*40,x\n' % (base, r))
        fh.write('        rts\n\n')
        # FLOOR: same trick, brighter toward the player's feet
        fh.write('LADF_' + tag + '\n')
        for r in range(VIEW_H // 2, VIEW_H):
            fh.write('        lda #$%02X\n' % floor_ramp[r - VIEW_H // 2])
            fh.write('        sta %s+%d*40,x\n' % (base, r))
        fh.write('        rts\n')
print('ladders.asm written')
print('tables.bin %d bytes' % len(data))
for name, off, ln in offs:
    print('  %-10s +%-6d %d' % (name, off, ln))
