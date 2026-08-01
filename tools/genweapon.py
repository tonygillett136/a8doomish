#!/usr/bin/env python3
"""genweapon.py — the shotgun, drawn as horizontal spans.

A weapon sprite is mostly empty screen with one solid silhouette per row, so
storing (start, count, bytes) per row makes the blit a straight copy at 5
cycles/byte with no per-pixel mask test. Format per row:
    start_byte, count, <count bytes of pixel data>
count 0 = empty row. Rows are stored top to bottom; the table is preceded by
a row count. Pixel bytes are mode 9: two 4-bit luminances per byte.
"""
import os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'weapon.bin')
INC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'src', 'weapon.inc')

W_PX = 80          # framebuffer is 80 px wide (40 bytes)
ROWS = 26          # A 24-row version was cut to 20 because it covered 25% of
                   # the view and hid 90% of a corpse one cell ahead. That was
                   # true while the gun sat at the bottom-CENTRE. It now lives in
                   # the bottom-right corner, so the centre of the floor -- where
                   # a corpse one cell ahead actually lies -- is clear, and the
                   # height can go back up. It buys the one thing the gun needed
                   # most: a barrel long enough to read as a barrel.
                   #
                   #
                   # CROSSING THE HUE SEAM: TRIED TWICE, ABANDONED. The DLI seam
                   # is at buffer row 66 and everything below it is drawn in the
                   # floor's hue, so a 26-row gun lives entirely inside the floor
                   # band, in the floor's own colour -- which is exactly why a
                   # reviewer who HAD found it still called it "an object lying
                   # on the ground". Nothing in the world can span two hue bands,
                   # so a gun that did would be unmistakably in front of it.
                   #
                   # At 34 rows the barrel reaches row 62. Drawn in mid-tones it
                   # merged into the wall and read as a PILLAR. Redrawn as a
                   # near-black tube with a bright bevel -- dark against a lit
                   # wall, bright-edged against a dark one -- it read as a
                   # DOORWAY EDGE instead.
                   #
                   # The reason is not tone, which is why fixing the tone did not
                   # help. The wall band's own content IS thin vertical elements:
                   # corridor edges, column faces, the dark seams between wall
                   # segments. A vertical barrel up there is camouflaged BY
                   # CATEGORY. To cross the seam legibly the barrel would have to
                   # stop being a vertical bar -- angled across the seam, or wide
                   # enough to read as a mass -- which is a different gun, not a
                   # different shade. Left at 26 rows.

# Luminance key: 0 transparent, and we shade the gun so it reads as metal
# lit from the muzzle flash side. Higher = brighter.
#   .  transparent
#   d  dark edge   (2)
#   m  mid metal   (5)
#   b  lit metal   (9)
#   h  highlight   (13)
#   w  wood/stock  (4)
# Measured on the first version: 96.4% of the gun's pixels sat at luminance 4
# or below out of 15, and exactly TWO were above 6. Against a floor ramp that
# reaches 13 that is a silhouette with no interior. Rewriting a redraw was
# tried and abandoned -- a 16-row version read as a diagonal sliver and a
# widening-bands version reproduced the same pyramid at a smaller size. The
# recognisable shape was already here; what it needed was light and a shift.
# Raising the whole palette into the floor's own range (6-11) was tried and
# reverted: it did not make the gun read as an object, it made it read as an
# OUTLINE DRAWING, because the interior then matched the floor and only the ring
# showed. The floor occupies 6-11, so the gun has to live outside that band --
# and dark is the honest choice for a weapon held below the light. Highlights
# reach 13-14 and are what give it form.
LUM = {'.': None, 'd': 2, 'm': 5, 'b': 9, 'h': 13, 'w': 4, 'k': 1}

# 40 px wide art, centred; drawn at 1 char = 1 pixel. Barrel top, receiver,
# then the stock/hands sweeping to the bottom-right as in DOOM's shotgun.
#
# THIRD version of this shape. The first was a bilaterally symmetric pyramid --
# a solid blob with no interior. The second fixed the symmetry (left edge
# vertical, stock sweeping down-right) but rendered over the floor it read as a
# dark bird's head: a rounded lump with a bright spot in it that the eye takes
# for an eye, and a diagonal wedge behind. Neither had the one feature that
# makes a gun read as a gun at any resolution -- A STRAIGHT VERTICAL BARREL
# above everything else. That is the whole silhouette; the rest is texture.
#
# So: a barrel rising vertically with a highlight down it, a wooden fore-end, a
# receiver with the ejection port punched black through it, and the stock
# sweeping down and right to the corner. Held slightly right of centre.
#
# Three further variants were drawn, previewed against a real floor ramp, and
# thrown away, which is worth recording because each failed for its own reason:
#   * WIDER, with a fatter body -- the extra mass made the dark wedge dominate
#     and the whole thing read as a table lamp.
#   * INTERIOR RAISED into the floor's own 6-11 range so the gun would read as a
#     lit object rather than a silhouette -- it read as an OUTLINE DRAWING
#     instead, because once the interior matches the floor only the ring shows.
#     The floor owns 6-11, so the gun has to live outside it.
#   * HANDS gripping the fore-end and the grip, which is the strongest "a person
#     is holding this" cue there is at higher resolutions -- at 40x20 the two
#     hands came out as a pair of pale square pads and read as a machine with
#     two buttons.
# The version below is not a photograph of a shotgun. It is the one that reads
# as a held weapon at 40x20 pixels in one hue, which is a different problem.
ART = [r.ljust(40, '.')[:40] for r in [
    # A SOLID tube, not a striped one. The barrel used to be `dbmhmbd` -- dark,
    # bright, mid, highlight, mid, bright, dark -- and a blind identification
    # test came back with "three dark vertical bars in a cream frame", guessing
    # a barred window or a set of teeth. Alternating luminances across seven
    # pixels is a GRILLE. The interior is uniform now and the bevel pass puts a
    # single bright line down the lit edge, which is what a metal tube looks
    # like. Eleven rows of it, so it reads as long.
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    "........dmmmmmd",
    ".......ddmmmmmdd",
    ".......dwwwwwwwd",              # fore-end, wood
    ".......dwwwwwwwwd",
    "......ddmmmmmmmmdd",
    "......dmmbbbbbbmmmd",           # receiver
    ".....ddmmbkkkkbbmmmmdd",        # ejection port punched through
    ".....dmmbkkkkkkbbbmmmmmd",
    "....ddmmbbbbbbbbbbmmmmmmmdd",
    "....dmmbbbbbbbbbbwwwwwwwwwwwdd",
    "...ddmmbbbbbbbbwwwwwwwwwwwwwwwwd",
    "...dmmmbbbbbbwwwwwwwwwwwwwwwwwwwwww",     # stock, running off the corner
    "..ddmmmbbbbwwwwwwwwwwwwwwwwwwwwwwwwww",
    "..dmmmmbbwwwwwwwwwwwwwwwwwwwwwwwwwwwwww",
    "..dmmmmwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww",
    "..dmmmwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww",
    "..dmmwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww",
]]
assert all(len(r) == 40 for r in ART), [len(r) for r in ART]
assert len(ART) == ROWS, len(ART)

# CLIPPED BY THE FRAME, which is the thing every previous version got wrong.
#
# Two independent reviewers, one of them told explicitly to go and judge the
# redrawn shotgun, looked at the same screenshots and reported that there was no
# weapon on screen at all -- one of them described what they saw as "a small
# symmetric floor structure, a dais or a threshold". They were looking straight
# at it. A complete, fully-visible object sitting at the bottom-centre of the
# view is not read as something held; it is read as something standing on the
# floor a few feet away, because that is what a whole object at the bottom of a
# corridor is. Every FPS weapon since Wolfenstein runs off the bottom and the
# side of the frame, and being CUT OFF is what says "this is attached to you".
#
# So the art now fills the bottom-right corner and runs past both edges, and
# X_OFF puts its right-hand column on the last pixel of the buffer.
X_OFF = W_PX - 40               # rightmost art column lands ON pixel 79, the
                                # last pixel of the view, and the outline that
                                # would sit beyond it is suppressed -- so the
                                # stock's mass runs into the frame edge with
                                # no line closing it off


def outlined():
    """Grow a one-pixel luminance-1 ring around the gun's silhouette.

    The gun is drawn INSIDE the floor's hue band, so the only thing separating
    it from the floor is luminance -- and measured against a real frame the two
    histograms sat on top of each other: the floor ran 6-11 and the bulk of the
    gun ran 6-11 too. The lower-left of the stock fused with the floor and only
    a highlight edge kept the silhouette legible.

    Darkening the gun's body is NOT the fix and was already tried and reverted:
    the first version had 96.4% of its pixels at luminance 4 or below and read
    as a silhouette with no interior. What separates a HUD weapon from the world
    in every game that does this well is a hard outline, so that is what this
    is -- the interior keeps its lit metal, and a near-black ring guarantees a
    step of at least 5 luminances against any floor tone the ramp can produce.

    The ring is added on the sides only. The top row of the art is against the
    wall band and the bottom row IS screen row 95, so there is nowhere to put
    one there and nothing behind it if there were.
    """
    pad = ['.' * (len(ART[0]) + 2)] + ['.' + r + '.' for r in ART]
    out = []
    for y in range(1, len(pad)):
        row = []
        for x in range(len(pad[0])):
            if pad[y][x] != '.':
                row.append(pad[y][x])
                continue
            near = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < len(pad) and 0 <= xx < len(pad[0]) \
                       and pad[yy][xx] not in '.o':
                        near = True
            row.append('o' if near else '.')
        out.append(''.join(row))
    return out


def bevelled(art):
    """Light the top-left edge of the silhouette from inside.

    The outline solved separation and left a new problem: the gun's mass lives
    at luminance 2-5 against a floor at 6-11, so it reads as a SHADOW at the
    bottom of the corridor -- and the bottom of the corridor is where the
    perspective lines converge and the picture is darkest anyway. A reviewer
    hunting specifically for the weapon reported there wasn't one.

    A dark object reads as an object, rather than as a hole, when it catches
    light on the edges facing the light. So every opaque pixel with nothing
    above it or nothing to its left becomes a highlight. Done programmatically
    rather than painted by hand, so it stays consistent if the shape changes
    again -- which it has, four times.
    """
    out = []
    for y, row in enumerate(art):
        line = []
        for x, ch in enumerate(row):
            if ch in '.o':
                line.append(ch)
                continue
            up = art[y - 1][x] if y > 0 else '.'
            left = row[x - 1] if x > 0 else '.'
            line.append('h' if (up in '.o' or left in '.o') else ch)
        out.append(''.join(line))
    return out


ART_O = bevelled(outlined())
OUTLINE_LUM = 1                 # never boosted: the ring must stay the darkest
                                # thing on screen even in the flash frame


# The muzzle-flash frame used to be the whole gun with +3 added to every pixel.
# Measured against the flash frame it is drawn in, that made things worse, not
# better: the band flash already ORs a luminance bit into every pixel on screen,
# so adding a uniform boost on top pushed the gun's mid-tones into the floor's
# range and its distinct luminances in the weapon region fell from 12 to 8, with
# the dark outline gone entirely (the darkest pixel went from 1 to 8).
#
# A blast catches the LIT surfaces of a gun and leaves its shadows dark. So the
# flash frame raises only the highlight and the bright metal, and leaves the
# outline, the shadow and the wood exactly where they are. More contrast, not
# less -- which is what an explosion two inches from the barrel actually does.
FLASH_MAP = {'h': 15, 'b': 13}


def build(flash=False):
    data = bytearray()
    offsets = []
    for row in ART_O:
        px = [None] * W_PX
        for i, ch in enumerate(row):
            if ch == 'o':
                # ...but NOT on the last column of the view. The whole point of
                # running the stock off the corner is that the frame cuts it,
                # and a dark ring drawn along the frame edge closes the shape
                # again -- it says "the object stops here", which is exactly the
                # reading the corner placement exists to prevent. A reviewer who
                # had found the gun still described it as sitting on the floor a
                # few tiles away rather than being held.
                if X_OFF - 1 + i < W_PX - 1:
                    px[X_OFF - 1 + i] = OUTLINE_LUM
                continue
            v = FLASH_MAP.get(ch, LUM[ch]) if flash else LUM[ch]
            if v is not None:
                px[X_OFF - 1 + i] = v
        # find the opaque span, byte-aligned (a byte is 2 px and we cannot
        # partially write one without a read-modify-write, so round outward
        # and fill the odd edge pixel with the neighbouring shade)
        idx = [i for i, v in enumerate(px) if v is not None]
        offsets.append(len(data))
        if not idx:
            data += bytes((0, 0))
            continue
        lo, hi = min(idx), max(idx)
        b0, b1 = lo // 2, hi // 2
        cnt = b1 - b0 + 1
        data += bytes((b0, cnt))
        for b in range(b0, b1 + 1):
            p0 = px[b * 2]
            p1 = px[b * 2 + 1]
            if p0 is None:
                p0 = p1 if p1 is not None else 0
            if p1 is None:
                p1 = p0
            data += bytes(((p0 << 4) | p1,))
    return data, offsets


normal, offs = build(False)
flash, _ = build(True)          # muzzle-flash frame: highlights only, see above

with open(OUT, 'wb') as fh:
    fh.write(normal)
    fh.write(flash)

with open(INC, 'w') as fh:
    fh.write('; GENERATED by tools/genweapon.py -- do not edit\n')
    fh.write('WPN_ROWS   = %d\n' % ROWS)
    fh.write('WPN_TOPROW = %d\n' % (96 - ROWS))
    fh.write('WPN_NORMAL = WEAPON+0\n')
    fh.write('WPN_FLASH  = WEAPON+%d\n' % len(normal))
    fh.write('WPN_LEN    = %d\n' % (len(normal) * 2))
    # (the blitter walks the spans sequentially; no offset table needed)

print('weapon.bin %d bytes (%d rows, normal+flash)' % (len(normal) * 2, ROWS))
