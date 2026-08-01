#!/usr/bin/env python3
"""gensprites.py — the HUSK, pre-scaled.

Runtime scaling costs a multiply per pixel; pre-scaled frames cost a straight
copy. Five size bands cover the useful depth range, and each frame is stored
as HORIZONTAL row spans (start_byte, count, data...) so the blit runs along
consecutive bytes at 5 cycles each, exactly like the weapon.

Pixels are luminance 0-15, 0 = transparent. A byte is two pixels.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'sprites.bin')
INC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'sprites.inc')

# Master art, 16 wide x 24 tall. A hunched, long-armed figure -- silhouette is
# all that survives at these sizes, so it has to read at 8px tall.
#   . transparent   d dark   m mid   b bright   e eye (hottest)
POSES = {}
# The first version of this was a lollipop: a round head on an oval torso on two
# straight legs, with the arms absorbed into the torso mass. At every size it
# read as a chess pawn. The arms are now OUTSIDE the torso with a dark gap
# between, so the silhouette goes wide at the shoulders, narrow at the waist,
# then legs -- which is what makes a shape read as a body rather than a blob.
POSES["walk_a"] = [
    "......dddd......",
    ".....dmmmmd.....",
    "....dmmbbmmd....",
    "....dmbeebmd....",
    "....dmmbbmmd....",
    ".....dmmmmd.....",
    "......dmmd......",
    "..dddmmmmmmddd..",
    ".dmmdmmmmmmdmmd.",
    "dmmmdmbbbbmdmmmd",
    "dmmmdmbbbbmdmmmd",
    "dmmmdmbbbbmdmmmd",
    "dmmmdmbbbbmdmmmd",
    ".dmmdmbbbbmdmmd.",
    "..dmdmmbbmmdmd..",
    "...ddmmmmmmdd...",
    "...dmmd..dmmd...",
    "...dmmd..dmmd...",
    "...dmmd..dmmd...",
    "...dmmd..dmmd...",
    "..dmmmd..dmmmd..",
    "..dmmd....dmmd..",
    ".dmmmd....dmmmd.",
    ".dddd......dddd.",
]
POSES["walk_b"] = [
    "......dddd......",
    ".....dmmmmd.....",
    "....dmmbbmmd....",
    "....dmbeebmd....",
    "....dmmbbmmd....",
    ".....dmmmmd.....",
    "......dmmd......",
    "..dddmmmmmmddd..",
    ".dmmdmmmmmmdmmd.",
    "dmmmdmbbbbmdmmmd",
    "dmmmdmbbbbmdmmmd",
    "dmmmdmbbbbmdmmmd",
    "dmmmdmbbbbmdmmmd",
    ".dmmdmbbbbmdmmd.",
    "..dmdmmbbmmdmd..",
    "...ddmmmmmmdd...",
    "...dmmd..dmmd...",
    "...dmmd..dmmd...",
    "..dmmd....dmmd..",
    "..dmmd....dmmd..",
    ".dmmd......dmmd.",
    ".dmmd......dmmd.",
    "dmmd........dmmd",
    "dddd........dddd",
]
# arms up: the telegraph. The brightest thing on the figure is the raised
# hand, so the wind-up reads even at eight pixels tall.
POSES["windup"] = [
    "de..........ee..",
    "dee........eee..",
    ".dee......eee...",
    "..dmd....dmmd...",
    "...dmd..dmmd....",
    "....dddd.dd.....",
    "......dddd......",
    ".....dmmmmd.....",
    "....dmbeebmd....",
    "....dmmbbmmd....",
    "...ddmmmmmmdd...",
    "..dmmmbbbbmmmd..",
    ".dmmbbbbbbbbmmd.",
    "dmmbbbbbbbbbbmmd",
    "dmmbbbbbbbbbbmmd",
    ".dmmmbbbbbbmmmd.",
    "..dmmmmmmmmmmd..",
    "...dmmd..dmmd...",
    "...dmmd..dmmd...",
    "...dmmd..dmmd...",
    "..dmmmd..dmmmd..",
    "..dmmd....dmmd..",
    ".dmmmd....dmmmd.",
    ".dddd......dddd.",
]
# A body on the floor, not a heap on it. The previous version was a rounded
# symmetric lump, and at the sizes it actually gets drawn that reads as a stain,
# a sack or a rock -- anything but the monster you just killed. Symmetry was the
# problem: a shape with no ends has no story. This one has a head at one end and
# a raised knee at the other, with a notch between head and shoulder, so even
# the 8x5 far band keeps a lopsided silhouette.
POSES["corpse"] = (["................"] * 17) + [
    "..dddd..........",
    ".dmeemdddd..dd..",
    "dmmmmmmmmmddmmd.",
    "dmmbbbbbbbmmmmmd",
    "dmmbbbbbbbbmmmd.",
    ".dmmmmmmmmmmd...",
    "..dddddddddd....",
]
# ---- pickups ----------------------------------------------------------------
# Both were invisible until now: four per level, collected by standing on the
# exact cell with no indication they were ever there. They have to be told apart
# at eight pixels tall and told apart from a HUSK, and one hue per band means
# colour is not available -- so it is all silhouette. The husk is tall and
# narrow; these are squat and wide, the medkit taller with a cross, the shells
# flatter with horizontal banding. Their occupied-row count is deliberately
# small: crop_rows() scales the sprite by it, so eight rows of art out of
# twenty-four makes a medkit a third the height of a husk -- a thing on the
# floor rather than a person.
POSES["medkit"] = (["................"] * 16) + [
    "...dddddddddd...",
    "..dmmmmmmmmmmd..",
    "..dmmmmeemmmmd..",
    "..dmmmmeemmmmd..",
    "..dmeeeeeeeemd..",
    "..dmmmmeemmmmd..",
    "..dmmmmmmmmmmd..",
    "...dddddddddd...",
]
POSES["shells"] = (["................"] * 18) + [
    "..dddddddddddd..",
    ".dmmmmmmmmmmmmd.",
    ".dmbbbbbbbbbbmd.",
    ".dmmmmmmmmmmmmd.",
    ".dmbbbbbbbbbbmd.",
    "..dddddddddddd..",
]

BAND_LUM = [                    # per band: dark, mid, bright, eye
    {'.': 0, 'd': 2, 'm': 9, 'b': 12, 'e': 15},
    {'.': 0, 'd': 1, 'm': 8, 'b': 11, 'e': 15},
    {'.': 0, 'd': 1, 'm': 8, 'b': 11, 'e': 14},
    {'.': 0, 'd': 1, 'm': 7, 'b': 10, 'e': 14},
    {'.': 0, 'd': 1, 'm': 7, 'b': 10, 'e': 14},
]
LUM = BAND_LUM[0]

SRC_W, SRC_H = 16, 24
POSE_ORDER = ['walk_a', 'walk_b', 'windup', 'corpse', 'medkit', 'shells']
# (height in buffer rows, width in pixels) per band, near -> far
BANDS = [(72, 20), (32, 13), (18, 8), (11, 5), (7, 3)]
VIEW_W = 80


def crop_rows(art):
    """First and last occupied row of a pose.

    The corpse is a flat heap: seven occupied rows at the bottom of a 24-row
    frame. Scaling the whole frame makes a 72-row sprite whose art is all in
    its last nine rows, which is both wasteful and -- once the wall-band clamp
    bites -- invisible. Cropping to the occupied rows makes the sprite as tall
    as the thing it draws.
    """
    occ = [y for y, row in enumerate(art) if any(c != '.' for c in row)]
    return occ[0], occ[-1]


def scale(art, dst_w, dst_h, lum=None):
    lum = lum or LUM
    r0, r1 = crop_rows(art)
    span = r1 - r0 + 1
    out = []
    for y in range(dst_h):
        sy = r0 + y * span // dst_h
        row = []
        for x in range(dst_w):
            sx = x * SRC_W // dst_w
            row.append(lum[art[sy][sx]])
        out.append(row)
    return out


data = bytearray()
frames = []                     # [pose][band] -> (offset, h, w)
for pose in POSE_ORDER:
  art = POSES[pose]
  assert len(art) == SRC_H, (pose, len(art))
  for bi, (h, w) in enumerate(BANDS):
    r0, r1 = crop_rows(art)
    h = max(1, h * (r1 - r0 + 1) // SRC_H)      # only as tall as its own art
    px = scale(art, w, h, BAND_LUM[bi])
    frame_off = len(data)
    rows = []
    for row in px:
        idx = [i for i, v in enumerate(row) if v]
        if not idx:
            rows.append((0, 0, []))
            continue
        lo, hi = min(idx), max(idx)
        # byte-align outward; a byte is two pixels and we cannot half-write one
        b0, b1 = lo // 2, hi // 2
        blob = []
        for b in range(b0, b1 + 1):
            p0 = row[b * 2] if b * 2 < len(row) else 0
            p1 = row[b * 2 + 1] if b * 2 + 1 < len(row) else 0
            if p0 == 0:         # fill an empty half from its neighbour rather
                p0 = p1         # than punching a black notch in the silhouette
            if p1 == 0:
                p1 = p0
            blob.append((p0 << 4) | p1)
        rows.append((b0, len(blob), blob))
    # Force the outermost pixel of every row to the band's DARK value, so the
    # silhouette reads against any background. Sprite luminances are absolute
    # constants drawn over a floor ramp that runs 1..13, and where they coincide
    # the sprite is a hole: a husk at 4 cells had 4 of its 18 rows dissolve into
    # the floor, which is also what made it measure LARGER at 6 cells than at 4.
    # Generator-only: no bytes and no cycles at runtime.
    dark = BAND_LUM[bi]['d']
    fixed = []
    first = next((k for k, r in enumerate(rows) if r[1]), None)
    for k, (st, n, blob) in enumerate(rows):
        if n:
            blob = list(blob)
            blob[0] = (dark << 4) | (blob[0] & 0x0F)
            blob[-1] = (blob[-1] & 0xF0) | dark
            if n == 1:
                blob[0] = (dark << 4) | dark
            # ...and the TOP row of the figure as well. Measured, 2-3 rows of a
            # husk still rendered invisible from 4 cells out -- 3 of 7 at 11
            # cells -- and it was the HEAD that dissolved, which is the part
            # you use to spot one.
            # ...but not on a frame only a few rows tall, where forcing the
            # top row AND both edges leaves nothing but rim: the far shell box
            # came out 100% dark and one distinct luminance -- a featureless
            # blob. Below five rows the silhouette is the whole sprite.
            if k == first and h >= 5:
                blob = [(dark << 4) | dark] * len(blob)
        fixed.append((st, n, blob))
    rows = fixed
    for (st, n, blob) in rows:
        data += bytes((st, n)) + bytes(blob)
    frames.append((frame_off, h, w))

open(OUT, 'wb').write(data)
with open(INC, 'w') as fh:
    fh.write('; GENERATED by tools/gensprites.py -- do not edit\n')
    fh.write('SPR_BANDS = %d\n' % len(BANDS))
    for i, (off, h, w) in enumerate(frames):
        fh.write('SPR%d_OFF = %d\n' % (i, off))
        fh.write('SPR%d_H   = %d\n' % (i, h))
        fh.write('SPR%d_WB  = %d\n' % (i, (w + 1) // 2))
    fh.write('SPRLEN = %d\n' % len(data))
    assert 0x0900 + len(data) <= 0x1A00, (
        'sprite frames are %d bytes at $0900 and would reach $%04X; title.asm '
        'orgs at $1A00. Two more poses would silently overwrite the title '
        'screen.' % (len(data), 0x0900 + len(data)))
    # (band tables live in sprtabs.asm, which carries its own org)

TAB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'sprtabs.asm')
with open(TAB, 'w') as fh:
    fh.write('; GENERATED by tools/gensprites.py -- do not edit\n')
    fh.write('        ert * > $A900, "sprites.asm code has grown into its own tables"\n')
    fh.write('        org $A900               ; inside the sprite module, past its code\n')
    fh.write('SPROFL\n        dta ' + ','.join('<(SPRITES+%d)' % f[0] for f in frames) + '\n')
    fh.write('SPROFH\n        dta ' + ','.join('>(SPRITES+%d)' % f[0] for f in frames) + '\n')
    fh.write('SPRH\n        dta ' + ','.join(str(f[1]) for f in frames) + '\n')
    fh.write('SPRWB\n        dta ' + ','.join(str((f[2] + 1) // 2) for f in frames) + '\n')
    # AC_FRAME -> pose. 0-3 walk (alternating), 4-6 telegraph/pain, 7+ down.
    posemap = [0,1,0,1, 2,2,2, 3,3,3,3,3, 3,3,3,3]
    # poses 4 and 5 are the pickups; they are selected by the item loop's own
    # type byte, not through POSEMAP, so nothing here maps to them.
    fh.write('POSEMAP\n        dta ' + ','.join(str(v) for v in posemap) + '\n')
    # Per-pose vertical scale. A sprite's height must be proportional to the
    # WALL height at its distance, not quantised to whichever of five bands it
    # happens to fall in -- measured, a husk was pixel-identical from 1.00 to
    # 1.75 cells and then jumped 45% in a single frame, and was actually LARGER
    # at 6 cells than at 4. Band 0's height corresponds to a full-screen wall
    # (96 rows), so scale = h0 * 256 / 96 and the renderer computes
    # height = ((96 - 2*ktop) * scale) >> 8.
    h0 = [frames[pose * len(BANDS)][1] for pose in range(len(POSE_ORDER))]
    fh.write('SPRSCALE\n        dta ' + ','.join(str(min(255, round(h * 256 / 96))) for h in h0) + '\n')
    fh.write('SPRSRCH\n        dta ' + ','.join(str(h) for h in h0) + '\n')
    # Guard the END of the block as well as the start. These tables grow when a
    # pose is added -- going from four poses to six pushed POSEMAP to $A987 and
    # silently ate the first eight bytes of the level-name table that had been
    # parked at $A980. A guard on what comes BEFORE a fixed org is only half of
    # the protection.
    fh.write('        ert * > $AA00, "sprite tables have grown into the level names at $AA00"\n')

print('sprites.bin %d bytes, %d bands %s' % (len(data), len(BANDS), [(h, w) for _, h, w in frames]))
