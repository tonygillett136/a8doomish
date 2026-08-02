#!/usr/bin/env python3
"""genspawns.py -- enemy start positions, taken from the level design.

This file did not exist. `src/spawns.inc` carried a header naming it as its
generator, so the table was orphaned output that could not be reproduced. The
first version of it kept whatever positions were already in the table and moved
only the unreachable ones -- three enemies were sitting inside `sealed` monster
closets and one behind a `secret`, neither of which the engine can open, so
SILENT COLONNADE was quietly losing 40% of its opposition.

That fixed reachability and left a bigger thing untouched: the positions
themselves were arbitrary, while the four level files place 39 actors BY HAND,
at chokepoints, around corners, and in the rooms they are meant to guard. The
game was ignoring all of it. So the spawns now come from the level design.

The engine has six actor slots and spawns a fixed NSPAWN per level, so a level
that authors thirteen actors has to be cut down to five. Taking the first five
in file order clusters them wherever the designer happened to start writing, so
the choice is: the authored actor NEAREST the player's start, so there is always
an early encounter, and then farthest-point sampling over the rest, which spreads
the remaining four through the level instead of bunching them. Where a level
authors fewer than five reachable actors, the shortfall is filled from the old
table, relocated to reachable cells.

What this does NOT do is use the authored TYPES. The levels ask for gunners,
spitters, hulks and a boss; the engine has one enemy. Positions are the part of
the design the game can honour today.
"""
import os, re, sys
from collections import deque

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', 'src')
LEVELS = os.path.join(HERE, '..', 'levels')
INC = os.path.join(SRC, 'spawns.inc')
sys.path.insert(0, HERE)
import levels as L                                              # noqa: E402

MAPS = ['map0.bin', 'map2.bin', 'map3.bin', 'map4.bin']
NSPAWN = 5
# what the PLAYER can walk through: open, a plain door, the exit switch.
WALKABLE = {0x00, 0x08, 0x0C}


def player_spawn(level):
    if level == 0:
        return (4, 6)
    hdr = open(os.path.join(SRC, 'map%d.lev.bin' % (level + 1)), 'rb').read()
    return (hdr[4], hdr[5])


def reachable(grid, start):
    seen, q = {start}, deque([start])
    while q:
        x, y = q.popleft()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < 32 and 0 <= ny < 32 and (nx, ny) not in seen \
                    and grid[ny * 32 + nx] in WALKABLE:
                seen.add((nx, ny)); q.append((nx, ny))
    return seen


def nearest_reachable(reach, x, y, taken):
    return min((c for c in reach if c not in taken),
               key=lambda c: (c[0] - x) ** 2 + (c[1] - y) ** 2)


def d2(a, b):
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2


def pick(cands, start, n):
    """The one nearest the player's start, then farthest-point sampling."""
    out = []
    pool = list(cands)
    if not pool:
        return out
    first = min(pool, key=lambda c: d2(c, start))
    out.append(first); pool.remove(first)
    while pool and len(out) < n:
        nxt = max(pool, key=lambda c: min(d2(c, o) for o in out))
        out.append(nxt); pool.remove(nxt)
    return out


# the positions as they stand, used only to fill a shortfall
old = open(INC).read()
nums = lambda tag: [int(v) for blk in re.findall(tag + r'\n((?:\s*dta [\d,]+\n)+)', old)
                    for v in re.findall(r'\d+', blk)]
oldx, oldy = nums('SPWNX'), nums('SPWNY')

levs = L.load([os.path.join(LEVELS, f) for f in sorted(os.listdir(LEVELS))
               if f.endswith('.lev')])

# authored thing-id -> engine AC_TYPE. The maw ships as a hulk for now: the
# right stats exist, the boss BEHAVIOUR does not yet.
ENGTYPE = {0x10: 1, 0x11: 3, 0x12: 4, 0x13: 5, 0x1F: 5}

xs, ys, ts, authored, filled, moved = [], [], [], 0, 0, 0
report = []
for lvl in range(4):
    grid = open(os.path.join(SRC, MAPS[lvl]), 'rb').read()
    start = player_spawn(lvl)
    reach = reachable(grid, start)
    typeof, want = {}, []
    for x, y, t, a in levs[lvl].things:
        if t in L.ACTORS and (x, y) in reach:
            want.append((x, y))
            typeof.setdefault((x, y), ENGTYPE.get(t, 1))
    chosen = pick(want, start, NSPAWN)
    authored += len(chosen)
    taken = set(chosen)
    for i in range(len(chosen), NSPAWN):          # shortfall from the old table
        x, y = oldx[lvl * NSPAWN + i], oldy[lvl * NSPAWN + i]
        if (x, y) not in reach or (x, y) in taken:
            x, y = nearest_reachable(reach, x, y, taken)
            moved += 1
        taken.add((x, y)); chosen.append((x, y))
        typeof.setdefault((x, y), 1)          # fill-ins are plain husks
        filled += 1
    report.append('  %-22s %d of %d authored actors reachable, %d used, %d filled'
                  % (levs[lvl].name, len(want),
                     sum(1 for _, _, t, _ in levs[lvl].things if t in L.ACTORS),
                     min(len(want), NSPAWN), NSPAWN - min(len(want), NSPAWN)))
    xs += [c[0] for c in chosen]
    ys += [c[1] for c in chosen]
    ts += [typeof[c] for c in chosen]

with open(INC, 'w') as fh:
    fh.write('; GENERATED by tools/genspawns.py -- do not edit\n')
    fh.write('NSPAWN = %d\n' % NSPAWN)
    fh.write('\n        org $2B80               ; between the level blob and the level tables\n')
    for tag, vals in (('SPWNX', xs), ('SPWNY', ys), ('SPWNT', ts)):
        fh.write(tag + '\n')
        for lvl in range(4):
            fh.write('        dta ' + ','.join(str(v) for v in vals[lvl * NSPAWN:(lvl + 1) * NSPAWN]) + '\n')

    # PAR: seconds the designer allowed for each floor, written into every .lev
    # since the levels were authored and read by nothing until now. Header byte
    # 13 of the compiled container.
    pars = []
    for lvl in range(4):
        hdr = open(os.path.join(SRC, 'map%d.lev.bin' % (lvl + 1)), 'rb').read()
        pars.append(hdr[13])
    fh.write('LVPAR\n        dta ' + ','.join(str(v) for v in pars) + '\n')
    fh.write('PARTOTAL = %d           ; %s\n' % (sum(pars), ' + '.join(str(p) for p in pars)))
    fh.write('        ert * > $2BC0, "spawn tables have grown into the level tables at $2BC0"\n')

print('\n'.join(report))
print('spawns.inc: %d spawns -- %d from the level design, %d filled (%d relocated)'
      % (len(xs), authored, filled, moved))
