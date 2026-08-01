#!/usr/bin/env python3
"""levels.py -- ABYSS level definition, compiler, validator and previewer.

Levels are authored as readable ASCII (`levels/*.lev`) and compiled to the
binary form the engine loads.  Style follows tools/gentables.py: everything
that would cost the 6502 work at runtime is precomputed here.

  levels.py build   [FILE...]        compile -> src/mapN.bin, mapN.attr.bin, mapN.lev.bin
  levels.py check   [FILE...]        validate (reachability with keys/doors)
  levels.py view    [FILE...]        top-down ASCII preview
  levels.py png     [FILE...]        top-down PNG preview -> /tmp/abyss_preview/
  levels.py install N                copy src/mapN.bin over src/map0.bin (what main.asm INSs)
  levels.py all                      build + check + view + png for every level

With no FILE arguments every levels/*.lev is processed.

--------------------------------------------------------------------------
BINARY FORMAT  (full spec in docs/MAPFORMAT.md)
--------------------------------------------------------------------------
SOLID plane  1024 B -> $7000   0 = open, else wall material id  (unchanged;
                               byte-compatible with today's renderer)
ATTR  plane  1024 B -> $7400   bit0-2 light, bit3 trig, bit4 block,
                               bit5 secret, bit6 nospawn, bit7 hurt
Container `mapN.lev.bin` carries a 16-byte header, the RLE'd planes and the
thing / trigger / door lists (all records 4 bytes).
"""
import os, sys, zlib, struct, glob, collections

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..'))
SRC = os.path.join(ROOT, 'src')
LEVDIR = os.path.join(ROOT, 'levels')
PNGDIR = '/tmp/abyss_preview'

W = H = 32                      # map is 32x32, one byte per cell, both planes

# ---------------------------------------------------------------- materials --
# Value lands straight in the SOLID plane.  0 must stay 0: the renderer's DDA
# is `lda (mptr),y : bne hit`, so ANY non-zero byte is a wall.
MAT = {
    'open':        0x00,
    'stone':       0x01,   # baseline wall
    'brick':       0x02,   # a shade darker
    'metal':       0x03,   # pale, reads bright
    'flesh':       0x04,
    'tech':        0x05,   # panelling, bright
    'rock':        0x06,   # cavern, dark
    'glow':        0x07,   # brightest -- landmark / light source
    'door':        0x08,   # unlocked door, closed
    'door_red':    0x09,
    'door_blue':   0x0A,
    'door_yellow': 0x0B,
    'exitsw':      0x0C,   # exit switch face
    'secret':      0x0D,   # renders as stone, opens on use
    'bars':        0x0E,
    'sealed':      0x0F,   # renders as stone; ONLY a trigger removes it (closets)
}
MATNAME = {v: k for k, v in MAT.items()}
LOCKED = {MAT['door_red']: 'red', MAT['door_blue']: 'blue', MAT['door_yellow']: 'yellow'}
DOORISH = {MAT['door'], MAT['door_red'], MAT['door_blue'], MAT['door_yellow'],
           MAT['secret'], MAT['sealed']}

# Suggested per-material bias added to the shade index (apparent distance).
# Costs the renderer one table lookup + one ADC; not consumed yet.
MATBIAS = {0x00: 0, 0x01: 0, 0x02: 16, 0x03: -16, 0x04: 8, 0x05: -24,
           0x06: 32, 0x07: -48, 0x08: -16, 0x09: -32, 0x0A: -32, 0x0B: -32,
           0x0C: -48, 0x0D: 0, 0x0E: 8, 0x0F: 0}

# --------------------------------------------------------------- attr flags --
A_LIGHT = 0x07      # bits 0-2, 0 = pitch black .. 7 = full bright
A_TRIG = 0x08      # entering fires the trigger record with this x,y
A_BLOCK = 0x10      # blocks actors, invisible to the renderer (ledge / closet lip)
A_SECRET = 0x20      # counts as a secret the first time it is entered
A_NOSPAWN = 0x40      # AI hint: do not wander here
A_HURT = 0x80      # damaging floor

# ------------------------------------------------------------------- things --
THING = {
    'start':     0x01,
    'husk':      0x10,   # shambler, melee
    'gunner':    0x11,   # hitscan
    'spitter':   0x12,   # projectile
    'hulk':      0x13,   # tanky
    'maw':       0x1F,   # boss
    'shells':    0x20,
    'shellbox':  0x21,
    'stim':      0x22,
    'medkit':    0x23,
    'armour':    0x24,
    'shotgun':   0x30,
    'autogun':   0x31,
    'key_red':   0x40,
    'key_blue':  0x41,
    'key_yellow': 0x42,
    'barrel':    0x50,
    'torch':     0x60,
}
THINGNAME = {v: k for k, v in THING.items()}
ACTORS = {v for k, v in THING.items() if 0x10 <= v < 0x20}
KEYS = {THING['key_red']: 'red', THING['key_blue']: 'blue',
        THING['key_yellow']: 'yellow'}
# actor arg bits
T_GROUP = 0x0F      # group id 0-15 (0 = ungrouped)
T_AMBUSH = 0x10      # deaf: wakes on sight only
T_ASLEEP = 0x20      # closet sleeper: wakes only on a WAKE / AMBUSH trigger
T_HIDDEN = 0x40      # not spawned until a trigger says so

# ----------------------------------------------------------------- triggers --
ACT = {'door_open': 0x01, 'door_close': 0x02, 'wake': 0x03,
       'exit': 0x04, 'message': 0x05, 'ambush': 0x06}
ACTNAME = {v: k for k, v in ACT.items()}

# ------------------------------------------------------------ default legend --
DEFAULT_LEGEND = {
    '.': 'open', ' ': 'open',
    '#': 'wall stone', '=': 'wall brick', '%': 'wall rock', ':': 'wall metal',
    '+': 'wall tech', '~': 'wall flesh', '*': 'wall glow', 'S': 'wall sealed',
    'D': 'door', 'R': 'door red', 'B': 'door blue', 'Y': 'door yellow',
    '@': 'spawn',
    'X': 'trig exit',
    '^': 'open hurt',
    'r': 'thing key_red', 'b': 'thing key_blue', 'y': 'thing key_yellow',
    'g': 'thing shotgun', 'a': 'thing autogun',
    'h': 'thing husk', 'u': 'thing gunner', 'p': 'thing spitter',
    'H': 'thing hulk', 'W': 'thing maw',
    's': 'thing shells', 'z': 'thing shellbox',
    'm': 'thing stim', 'M': 'thing medkit', 'A': 'thing armour',
    'o': 'thing barrel', 't': 'thing torch',
}

DIRS = {'e': 0, 'east': 0, 'ne': 224, 'n': 192, 'north': 192, 'nw': 160,
        'w': 128, 'west': 128, 'sw': 96, 's': 64, 'south': 64, 'se': 32}
# NOTE angles: 0..255 = full circle, 0 = +x (east).  Screen y grows SOUTH, and
# the ray tables use +y = sin(theta), so theta=64 walks +y = south.


class LevelError(Exception):
    pass


# ============================================================== cell record ==
class Cell:
    __slots__ = ('mat', 'light', 'flags', 'group', 'things', 'trig')

    def __init__(self):
        self.mat = 0
        self.light = None
        self.flags = 0
        self.group = 0
        self.things = []        # (type, arg)
        self.trig = None        # (action, arg)


# ================================================================== parsing ==
def parse_spec(spec, cell, where):
    """Apply one legend spec string to a Cell."""
    toks = spec.replace(',', ' ').split()
    i = 0
    while i < len(toks):
        t = toks[i].lower()
        if t == 'open':
            cell.mat = 0
        elif t == 'wall':
            i += 1
            name = toks[i].lower()
            if name not in MAT:
                raise LevelError('%s: unknown material %r' % (where, name))
            cell.mat = MAT[name]
        elif t == 'door':
            nxt = toks[i + 1].lower() if i + 1 < len(toks) else ''
            if nxt in ('red', 'blue', 'yellow'):
                cell.mat = MAT['door_' + nxt]
                i += 1
            else:
                cell.mat = MAT['door']
        elif t == 'sealed':
            cell.mat = MAT['sealed']
        elif t == 'spawn':
            cell.mat = 0
            cell.things.append((THING['start'], 0))
        elif t == 'thing':
            i += 1
            name = toks[i].lower()
            if name not in THING:
                raise LevelError('%s: unknown thing %r' % (where, name))
            cell.things.append([THING[name], 0])
        elif t == 'trig':
            i += 1
            name = toks[i].lower()
            if name not in ACT:
                raise LevelError('%s: unknown trigger action %r' % (where, name))
            cell.trig = [ACT[name], 0]
            cell.flags |= A_TRIG
        elif t == 'ambush':
            if cell.things:
                cell.things[-1][1] |= T_AMBUSH
        elif t == 'asleep':
            if cell.things:
                cell.things[-1][1] |= T_ASLEEP
        elif t == 'hidden':
            if cell.things:
                cell.things[-1][1] |= T_HIDDEN
        elif t == 'hurt':
            cell.flags |= A_HURT
        elif t == 'secret':
            cell.flags |= A_SECRET
        elif t == 'block':
            cell.flags |= A_BLOCK
        elif t == 'nospawn':
            cell.flags |= A_NOSPAWN
        elif t.startswith('light='):
            cell.light = int(t.split('=')[1], 0) & 7
        elif t.startswith('group='):
            g = int(t.split('=')[1], 0) & 15
            cell.group = g
            if cell.trig is not None:
                cell.trig[1] = g
            if cell.things:
                cell.things[-1][1] = (cell.things[-1][1] & ~T_GROUP) | g
        elif t.startswith('arg='):
            v = int(t.split('=')[1], 0) & 255
            if cell.trig is not None:
                cell.trig[1] = v
            elif cell.things:
                cell.things[-1][1] = v
        elif t.startswith('n='):
            if cell.things:
                cell.things[-1][1] = int(t.split('=')[1], 0) & 255
        else:
            raise LevelError('%s: unknown token %r in spec %r' % (where, t, spec))
        i += 1


class Level:
    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        self.number = 0
        self.spawn = None                  # (x, y, ang)
        self.par = 0
        self.default_light = 4
        self.legend = dict(DEFAULT_LEGEND)
        self.rows = []
        self.lightcmds = []
        self.lightmap = None
        self.extra_things = []             # (x, y, type, arg)
        self.extra_trigs = []              # (x, y, action, arg)
        self.notes = []
        self.cells = [[Cell() for _ in range(W)] for _ in range(H)]
        self.doors = []                    # (x, y, group, mat)
        self.things = []                   # (x, y, type, arg)
        self.trigs = []                    # (x, y, action, arg)
        self._read()
        self._bake()

    # ---------------------------------------------------------------- read --
    def _read(self):
        with open(self.path) as fh:
            lines = fh.read().split('\n')
        sect = None
        for ln, raw in enumerate(lines, 1):
            where = '%s:%d' % (os.path.basename(self.path), ln)
            line = raw.rstrip('\n')
            if sect not in ('map', 'lightmap', 'notes'):
                s = line.split(';')[0].strip()
                if not s:
                    continue
            else:
                s = line
            if sect in ('map', 'lightmap'):
                if s.strip() == 'end':
                    sect = None
                    continue
                if not s.strip():
                    continue
                if sect == 'map':
                    self.rows.append(s)
                else:
                    self.lightmap = self.lightmap or []
                    self.lightmap.append(s)
                continue
            if sect == 'notes':
                if s.strip() == 'end':
                    sect = None
                    continue
                self.notes.append(s.rstrip())
                continue
            head = s.split(':', 1)
            if len(head) == 2 and head[0].strip() and ' ' not in head[0].strip() \
                    and head[0].strip().lower() in (
                    'name', 'level', 'spawn', 'par', 'default_light', 'legend',
                    'map', 'light', 'lightmap', 'things', 'triggers', 'notes'):
                key, rest = head[0].strip().lower(), head[1].strip()
                if key in ('legend', 'map', 'lightmap', 'light', 'things',
                           'triggers', 'notes') and not rest:
                    sect = key
                    continue
                sect = None
                self._scalar(key, rest, where)
                continue
            if s.strip() == 'end':
                sect = None
                continue
            if sect == 'legend':
                if len(s.strip()) < 2 and s.strip() != '':
                    raise LevelError('%s: bad legend line' % where)
                body = s.rstrip()
                lead = len(body) - len(body.lstrip())
                ch = body[lead]
                spec = body[lead + 1:].strip()
                if not spec:
                    raise LevelError('%s: legend char %r has no spec' % (where, ch))
                self.legend[ch] = spec
            elif sect == 'light':
                self.lightcmds.append((s.strip(), where))
            elif sect == 'things':
                p = s.replace(',', ' ').split()
                x, y = int(p[0]), int(p[1])
                self.extra_things.append((x, y, ' '.join(p[2:]), where))
            elif sect == 'triggers':
                p = s.replace(',', ' ').split()
                x, y = int(p[0]), int(p[1])
                self.extra_trigs.append((x, y, ' '.join(p[2:]), where))
            else:
                raise LevelError('%s: stray line %r' % (where, s.strip()))

    def _scalar(self, key, rest, where):
        if key == 'name':
            self.name = rest
        elif key == 'level':
            self.number = int(rest, 0)
        elif key == 'par':
            self.par = int(rest, 0)
        elif key == 'default_light':
            self.default_light = int(rest, 0) & 7
        elif key == 'spawn':
            p = rest.replace(',', ' ').split()
            ang = 0
            if len(p) > 2:
                a = p[2].lower()
                ang = DIRS[a] if a in DIRS else int(a, 0) & 255
            self.spawn = (int(p[0]), int(p[1]), ang)
        else:
            raise LevelError('%s: unexpected key %r' % (where, key))

    # ---------------------------------------------------------------- bake --
    def _bake(self):
        if len(self.rows) != H:
            raise LevelError('%s: map has %d rows, need %d'
                             % (self.name, len(self.rows), H))
        for y, row in enumerate(self.rows):
            if len(row) < W:
                row = row + '.' * (W - len(row))
            if len(row) > W:
                raise LevelError('%s: row %d is %d chars, need %d'
                                 % (self.name, y, len(row), W))
            for x, ch in enumerate(row):
                if ch not in self.legend:
                    raise LevelError('%s: row %d col %d: char %r not in legend'
                                     % (self.name, y, x, ch))
                c = self.cells[y][x]
                parse_spec(self.legend[ch], c, '%s (%d,%d)' % (self.name, x, y))
                if c.things and c.things[0][0] == THING['start'] and self.spawn is None:
                    self.spawn = (x, y, 0)

        # light: default -> rect/cell commands -> explicit lightmap grid
        for y in range(H):
            for x in range(W):
                if self.cells[y][x].light is None:
                    self.cells[y][x].light = self.default_light
        for cmd, where in self.lightcmds:
            p = cmd.replace(',', ' ').split()
            kind = p[0].lower()
            if kind == 'rect':
                x0, y0, w, h, lv = (int(v, 0) for v in p[1:6])
                for y in range(y0, min(H, y0 + h)):
                    for x in range(x0, min(W, x0 + w)):
                        self.cells[y][x].light = lv & 7
            elif kind == 'cell':
                x, y, lv = (int(v, 0) for v in p[1:4])
                self.cells[y][x].light = lv & 7
            else:
                raise LevelError('%s: unknown light command %r' % (where, kind))
        if self.lightmap:
            if len(self.lightmap) != H:
                raise LevelError('%s: lightmap has %d rows' % (self.name, len(self.lightmap)))
            for y, row in enumerate(self.lightmap):
                for x, ch in enumerate(row[:W]):
                    if ch in '. ':
                        continue
                    self.cells[y][x].light = int(ch, 16) & 7

        # extra things / triggers from the list sections
        for x, y, spec, where in self.extra_things:
            parse_spec('thing ' + spec if not spec.split()[0] in
                       ('thing', 'trig') else spec, self.cells[y][x], where)
        for x, y, spec, where in self.extra_trigs:
            parse_spec('trig ' + spec if not spec.split()[0] == 'trig' else spec,
                       self.cells[y][x], where)

        # flatten into the record lists
        for y in range(H):
            for x in range(W):
                c = self.cells[y][x]
                for t, a in c.things:
                    if t == THING['start']:
                        continue
                    self.things.append((x, y, t, a & 255))
                if c.trig is not None:
                    self.trigs.append((x, y, c.trig[0], c.trig[1] & 255))
                    c.flags |= A_TRIG
                if c.mat in DOORISH:
                    self.doors.append((x, y, c.group, c.mat))
        if self.spawn is None:
            raise LevelError('%s: no spawn (`spawn:` key or `@` in the map)' % self.name)
        self.exit = None
        for x, y, a, arg in self.trigs:
            if a == ACT['exit']:
                self.exit = (x, y)
                break

    # -------------------------------------------------------------- planes --
    def solid(self):
        """The solid plane as the ENGINE will read it.

        Two compile-time adjustments, both because the runtime is simpler than
        the map format:

        * the exit is authored as a trigger, but the engine's only end-of-level
          mechanism is `check_cell` seeing `$0C` in this plane -- so stamp it;
        * keys are not implemented, so a locked door is indistinguishable from
          solid wall at runtime. Compile them as plain doors rather than ship
          levels whose exits cannot be reached.
        """
        out = [self.cells[y][x].mat for y in range(H) for x in range(W)]
        for i, m in enumerate(out):
            if m in (MAT['door_red'], MAT['door_blue'], MAT['door_yellow']):
                out[i] = MAT['door']
        if self.exit:
            ex, ey = self.exit
            out[ey * W + ex] = MAT['exitsw']
        return bytes(out)

    def attr(self):
        return bytes((self.cells[y][x].light & 7) | (self.cells[y][x].flags & 0xF8)
                     for y in range(H) for x in range(W))


# ====================================================================== RLE ==
def rle(data):
    """ctrl $00 = end; $01-$7F = that many literals; $80-$FF = run of
    (ctrl-$7F) copies of the next byte (1..128)."""
    out = bytearray()
    i, n = 0, len(data)

    def runlen(p):
        q = p
        while q < n and data[q] == data[p] and q - p < 128:
            q += 1
        return q - p

    while i < n:
        r = runlen(i)
        if r >= 3:                      # 3 bytes as a run costs 2, always a win
            out.append(0x7F + r)
            out.append(data[i])
            i += r
            continue
        lit = bytearray()
        while i < n and len(lit) < 127 and runlen(i) < 3:
            lit.append(data[i])
            i += 1
        out.append(len(lit))
        out += lit
    out.append(0)
    return bytes(out)


def unrle(s):
    out = bytearray()
    i = 0
    while i < len(s):
        c = s[i]
        i += 1
        if c == 0:
            break
        if c < 0x80:
            out += s[i:i + c]
            i += c
        else:
            out += bytes([s[i]]) * (c - 0x7F)
            i += 1
    return bytes(out)


# ================================================================== compile ==
def compile_level(lv):
    solid, attr = lv.solid(), lv.attr()
    rs, ra = rle(solid), rle(attr)
    assert unrle(rs) == solid and unrle(ra) == attr, 'RLE round-trip failed'
    nm = lv.name.encode('ascii', 'replace')[:16].ljust(16, b'\0')
    sx, sy, sa = lv.spawn
    ex, ey = lv.exit if lv.exit else (0, 0)
    body = bytearray()
    body += nm                          # FIXED 16 bytes: no length prefix needed
    body += struct.pack('<H', len(rs)) + rs
    body += struct.pack('<H', len(ra)) + ra
    for x, y, t, a in lv.things:
        body += bytes((x, y, t, a))
    for x, y, t, a in lv.trigs:
        body += bytes((x, y, t, a))
    for x, y, g, m in lv.doors:
        body += bytes((x, y, g, m))
    total = 16 + len(body)              # 16 header + 16 name + planes + lists
    hdr = bytes((0x41, 0x4C, 1, lv.number, sx, sy, sa, ex, ey,
                 len(lv.things), len(lv.trigs), len(lv.doors),
                 lv.default_light, lv.par, total & 255, total >> 8))
    return solid, attr, bytes(hdr) + bytes(body)


# ================================================================ validator ==
def neighbours(x, y):
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nx, ny = x + dx, y + dy
        if 0 <= nx < W and 0 <= ny < H:
            yield nx, ny


def validate(lv):
    errs, warns, info = [], [], []
    cells = lv.cells

    # --- the DDA has NO bounds check and steps mptr by +-1 / +-32: a ray that
    # escapes the map reads whatever follows $7000.  Border MUST be solid.
    for x in range(W):
        if cells[0][x].mat == 0 or cells[H - 1][x].mat == 0:
            errs.append('border hole at column %d (top/bottom row must be solid)' % x)
    for y in range(H):
        if cells[y][0].mat == 0 or cells[y][W - 1].mat == 0:
            errs.append('border hole at row %d (left/right column must be solid)' % y)

    sx, sy, sa = lv.spawn
    if cells[sy][sx].mat != 0:
        errs.append('spawn (%d,%d) is inside solid material %s'
                    % (sx, sy, MATNAME[cells[sy][sx].mat]))
    if lv.exit is None:
        errs.append('no exit trigger (`X` in the map, or a `trig exit`)')

    for x, y, t, a in lv.things:
        if cells[y][x].mat != 0:
            errs.append('thing %s at (%d,%d) is inside wall %s'
                        % (THINGNAME.get(t, hex(t)), x, y, MATNAME[cells[y][x].mat]))
        if cells[y][x].flags & A_BLOCK:
            warns.append('thing %s at (%d,%d) sits on a BLOCK cell'
                         % (THINGNAME.get(t, hex(t)), x, y))

    # --- locked doors need their key; sealed cells need a trigger to open ---
    door_groups = collections.defaultdict(list)
    for x, y, g, m in lv.doors:
        door_groups[g].append((x, y, m))
    trig_groups = collections.defaultdict(list)
    for x, y, act, arg in lv.trigs:
        if act in (ACT['door_open'], ACT['ambush'], ACT['door_close'], ACT['wake']):
            trig_groups[arg].append((x, y, act))
    for x, y, g, m in lv.doors:
        if m == MAT['sealed'] and g == 0:
            errs.append('sealed cell (%d,%d) has no group -- nothing can open it' % (x, y))
        elif m == MAT['sealed'] and not any(
                a in (ACT['door_open'], ACT['ambush']) for _, _, a in trig_groups[g]):
            errs.append('sealed group %d has no door_open/ambush trigger' % g)

    keys_present = {KEYS[t] for _, _, t, _ in lv.things if t in KEYS}
    for x, y, g, m in lv.doors:
        if m in LOCKED and LOCKED[m] not in keys_present:
            errs.append('locked %s door at (%d,%d) but no %s key on the level'
                        % (LOCKED[m], x, y, LOCKED[m]))

    # --- key/door reachability fixpoint --------------------------------------
    def flood(have):
        seen = set()
        q = collections.deque([(sx, sy)])
        seen.add((sx, sy))
        while q:
            x, y = q.popleft()
            for nx, ny in neighbours(x, y):
                if (nx, ny) in seen:
                    continue
                c = cells[ny][nx]
                if c.flags & A_BLOCK:
                    continue
                m = c.mat
                if m == 0 or m == MAT['door'] or m == MAT['secret']:
                    pass
                elif m in LOCKED:
                    if LOCKED[m] not in have:
                        continue
                else:
                    continue        # solid wall / sealed
                seen.add((nx, ny))
                q.append((nx, ny))
        return seen

    have = set()
    for _ in range(8):
        reach = flood(have)
        got = {KEYS[t] for x, y, t, _ in lv.things if t in KEYS and (x, y) in reach}
        if got <= have:
            break
        have |= got
    reach = flood(have)

    if lv.exit and lv.exit not in reach:
        errs.append('EXIT at %s is NOT reachable from spawn (keys held: %s)'
                    % (str(lv.exit), sorted(have) or 'none'))

    # keys that gate something must themselves be reachable
    for x, y, t, a in lv.things:
        if t in KEYS and (x, y) not in reach:
            errs.append('%s key at (%d,%d) is unreachable' % (KEYS[t], x, y))
        elif t in (THING['shotgun'], THING['autogun']) and (x, y) not in reach:
            errs.append('weapon %s at (%d,%d) is unreachable' % (THINGNAME[t], x, y))
        elif (x, y) not in reach and t not in ACTORS:
            warns.append('%s at (%d,%d) is unreachable (island pickup?)'
                         % (THINGNAME.get(t, hex(t)), x, y))

    # monsters in sealed closets are expected to be unreachable; others aren't
    for x, y, t, a in lv.things:
        if t in ACTORS and (x, y) not in reach and not (a & (T_ASLEEP | T_HIDDEN)):
            warns.append('%s at (%d,%d) is walled off and not marked asleep'
                         % (THINGNAME[t], x, y))

    # --- renderer sanity ------------------------------------------------------
    for y in range(H):
        run = 0
        for x in range(W):
            run = run + 1 if cells[y][x].mat == 0 else 0
            if run == 21:
                warns.append('open run of >20 cells on row %d -- beyond the DDA '
                             'step budget, the far end renders as void' % y)
    for x in range(W):
        run = 0
        for y in range(H):
            run = run + 1 if cells[y][x].mat == 0 else 0
            if run == 21:
                warns.append('open run of >20 cells in column %d -- beyond the DDA '
                             'step budget' % x)

    # trigger bit and record must agree
    for y in range(H):
        for x in range(W):
            c = cells[y][x]
            if (c.flags & A_TRIG) and c.trig is None:
                errs.append('TRIG attr bit at (%d,%d) with no trigger record' % (x, y))

    # a monster/door group that opens or wakes nothing is dead authoring
    actor_groups = {a & T_GROUP for _, _, t, a in lv.things if t in ACTORS}
    for x, y, act, arg in lv.trigs:
        if act in (ACT['wake'], ACT['ambush']) and arg not in actor_groups:
            warns.append('trigger at (%d,%d) wakes group %d -- no actor is in that group'
                         % (x, y, arg))
        if act in (ACT['door_open'], ACT['door_close'], ACT['ambush']) \
                and act != ACT['wake'] and arg not in door_groups:
            warns.append('trigger at (%d,%d) opens door group %d -- no door has it'
                         % (x, y, arg))

    open_set = {(x, y) for y in range(H) for x in range(W) if cells[y][x].mat == 0}
    open_cells = len(open_set)
    reach &= open_set                   # door cells are traversed, not "space"
    info.append('open cells %d / %d (%.0f%% of the grid is playable space)'
                % (open_cells, W * H, 100.0 * open_cells / (W * H)))
    info.append('reachable  %d of %d open cells' % (len(reach), open_cells))
    info.append('keys required %s; keys placed %s'
                % (sorted({LOCKED[m] for _, _, _, m in lv.doors if m in LOCKED}) or [],
                   sorted(keys_present) or []))
    info.append('things %d (%d actors, %d pickups)  triggers %d  doors %d'
                % (len(lv.things), sum(1 for t in lv.things if t[2] in ACTORS),
                   sum(1 for t in lv.things if t[2] >= 0x20), len(lv.trigs),
                   len(lv.doors)))
    unreached = open_cells - len(reach)
    if unreached:
        info.append('%d open cells are sealed off (monster closets etc.)' % unreached)
    return errs, warns, info, reach


# ================================================================= previews ==
SHADE = ' .:-=+*#%@'


def ascii_view(lv, reach=None):
    out = []
    out.append('%s  (level %d)  %dx%d' % (lv.name, lv.number, W, H))
    out.append('    ' + ''.join(str(x % 10) for x in range(W)))
    for y in range(H):
        row = []
        for x in range(W):
            c = lv.cells[y][x]
            if c.mat:
                ch = {1: '#', 2: '=', 3: ':', 4: '~', 5: '+', 6: '%', 7: '*',
                      8: 'D', 9: 'R', 10: 'B', 11: 'Y', 12: 'X', 13: 'Z',
                      14: 'I', 15: 'S'}.get(c.mat, '?')
            else:
                ch = None
                for t, a in c.things:
                    ch = {THING['start']: '@', THING['husk']: 'h',
                          THING['gunner']: 'u', THING['spitter']: 'p',
                          THING['hulk']: 'H', THING['maw']: 'W',
                          THING['key_red']: 'r', THING['key_blue']: 'b',
                          THING['key_yellow']: 'y', THING['shotgun']: 'g',
                          THING['autogun']: 'a', THING['medkit']: 'M',
                          THING['stim']: 'm', THING['armour']: 'A',
                          THING['shells']: 's', THING['shellbox']: 'z',
                          THING['barrel']: 'o', THING['torch']: 't'}.get(t, '?')
                if ch is None and c.trig is not None:
                    ch = {ACT['exit']: 'E'}.get(c.trig[0], 'T')
                if ch is None:
                    ch = '^' if c.flags & A_HURT else '01234567'[c.light]
            row.append(ch)
        out.append('%3d ' % y + ''.join(row))
    out.append('    ' + ''.join(str(x % 10) for x in range(W)))
    out.append('walls  # stone  = brick  : metal  ~ flesh  + tech  % rock  * glow')
    out.append('doors  D open  R/B/Y locked  S sealed(closet)  I bars  Z secret wall')
    out.append('floor   0..7 = the cell LIGHT level    ^ = hurt floor')
    out.append('things @spawn E exit  h husk u gunner p spitter H hulk W boss')
    out.append('       r/b/y keys  g shotgun a autogun  s/z ammo m/M heal A armour')
    out.append('       o barrel t torch  ^ hurt floor  T trigger')
    return '\n'.join(out)


def write_png(path, pix, w, h):
    raw = b''.join(b'\x00' + bytes(pix[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload
                + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff))
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))
    open(path, 'wb').write(png)


MATRGB = {1: (150, 145, 135), 2: (140, 95, 80), 3: (170, 180, 195),
          4: (170, 90, 95), 5: (110, 160, 170), 6: (105, 100, 95),
          7: (255, 210, 120), 8: (120, 200, 120), 9: (230, 70, 70),
          10: (80, 120, 240), 11: (240, 220, 70), 12: (255, 255, 255),
          13: (150, 145, 135), 14: (90, 110, 120), 15: (150, 145, 135)}
THINGRGB = {THING['husk']: (220, 60, 60), THING['gunner']: (255, 130, 40),
            THING['spitter']: (200, 60, 200), THING['hulk']: (150, 30, 30),
            THING['maw']: (255, 0, 0),
            THING['key_red']: (255, 40, 40), THING['key_blue']: (60, 90, 255),
            THING['key_yellow']: (255, 235, 60),
            THING['shotgun']: (90, 220, 90), THING['autogun']: (60, 255, 180),
            THING['shells']: (200, 190, 110), THING['shellbox']: (220, 205, 90),
            THING['stim']: (255, 160, 200), THING['medkit']: (255, 90, 150),
            THING['armour']: (90, 200, 255), THING['barrel']: (190, 130, 40),
            THING['torch']: (255, 200, 90)}


def png_view(lv, path, scale=12, reach=None):
    w, h = W * scale, H * scale
    pix = bytearray(w * h * 3)

    def put(px, py, rgb):
        if 0 <= px < w and 0 <= py < h:
            o = (py * w + px) * 3
            pix[o:o + 3] = bytes(rgb)

    for y in range(H):
        for x in range(W):
            c = lv.cells[y][x]
            if c.mat:
                r, g, b = MATRGB.get(c.mat, (255, 0, 255))
                # N/S faces render darker in the engine; hint that on the map
                base = (int(r * .85), int(g * .85), int(b * .85))
            else:
                lv7 = c.light / 7.0
                v = int(18 + 60 * lv7)
                base = (v, v, int(v * 1.12))
                if c.flags & A_HURT:
                    base = (int(30 + 50 * lv7), int(60 + 70 * lv7), 25)
                if c.flags & A_SECRET:
                    base = (base[0], base[1], min(255, base[2] + 50))
                if reach is not None and (x, y) not in reach:
                    base = (min(255, base[0] + 45), base[1], base[2])
            for py in range(y * scale, y * scale + scale):
                for px in range(x * scale, x * scale + scale):
                    put(px, py, base)
            if c.mat:
                for k in range(scale):
                    put(x * scale + k, y * scale, tuple(min(255, v + 45) for v in base))
                    put(x * scale, y * scale + k, tuple(min(255, v + 45) for v in base))
            if c.flags & A_TRIG:
                for k in range(scale):
                    put(x * scale + k, y * scale + scale - 1, (255, 255, 0))
                    put(x * scale + scale - 1, y * scale + k, (255, 255, 0))
            for t, a in c.things:
                rgb = THINGRGB.get(t, (255, 255, 255))
                if t == THING['start']:
                    rgb = (255, 255, 255)
                cx, cy = x * scale + scale // 2, y * scale + scale // 2
                rad = scale // 3
                for py in range(-rad, rad + 1):
                    for px in range(-rad, rad + 1):
                        if px * px + py * py <= rad * rad:
                            put(cx + px, cy + py, rgb)
    # spawn facing tick
    sx, sy, sa = lv.spawn
    import math
    th = sa / 256.0 * 2 * math.pi
    cx, cy = sx * scale + scale // 2, sy * scale + scale // 2
    for k in range(scale):
        put(int(cx + math.cos(th) * k), int(cy + math.sin(th) * k), (255, 60, 60))
    write_png(path, pix, w, h)
    return path


# ====================================================================== CLI ==
def load(paths):
    if not paths:
        paths = sorted(glob.glob(os.path.join(LEVDIR, '*.lev')))
    return [Level(p) for p in paths]


def do_build(levs):
    tot = 0
    print('%-22s %6s %6s %6s %6s %6s' % ('level', 'solid', 'attr', 'lists', 'file', 'raw'))
    for lv in levs:
        solid, attr, blob = compile_level(lv)
        n = lv.number
        open(os.path.join(SRC, 'map%d.bin' % n), 'wb').write(solid)
        open(os.path.join(SRC, 'map%d.attr.bin' % n), 'wb').write(attr)
        open(os.path.join(SRC, 'map%d.lev.bin' % n), 'wb').write(blob)
        lists = 4 * (len(lv.things) + len(lv.trigs) + len(lv.doors))
        print('%-22s %6d %6d %6d %6d %6d'
              % (lv.name[:22], len(rle(solid)), len(rle(attr)), lists, len(blob), 2048 + lists))
        tot += len(blob)
    print('%-22s %6s %6s %6s %6d' % ('TOTAL (in the XEX)', '', '', '', tot))
    return tot


def do_check(levs):
    bad = 0
    for lv in levs:
        errs, warns, info, reach = validate(lv)
        print('=== %s  (level %d, %s)' % (lv.name, lv.number, os.path.basename(lv.path)))
        for i in info:
            print('    .  ' + i)
        for w in warns:
            print('    ?  WARN ' + w)
        for e in errs:
            print('    !  FAIL ' + e)
        print('    => %s' % ('COMPLETABLE' if not errs else 'BROKEN'))
        bad += bool(errs)
    return bad


def main(argv):
    cmd = argv[1] if len(argv) > 1 else 'all'
    rest = argv[2:]
    if cmd == 'install':
        n = int(rest[0])
        src = os.path.join(SRC, 'map%d.bin' % n)
        open(os.path.join(SRC, 'map0.bin'), 'wb').write(open(src, 'rb').read())
        print('installed %s -> src/map0.bin' % os.path.basename(src))
        return 0
    levs = load(rest)
    if not levs:
        print('no levels found in %s' % LEVDIR)
        return 1
    if cmd in ('build', 'all'):
        do_build(levs)
    rc = 0
    if cmd in ('check', 'all'):
        rc = do_check(levs)
    if cmd in ('view', 'all'):
        for lv in levs:
            errs, warns, info, reach = validate(lv)
            print()
            print(ascii_view(lv, reach))
    if cmd in ('png', 'all'):
        os.makedirs(PNGDIR, exist_ok=True)
        for lv in levs:
            errs, warns, info, reach = validate(lv)
            p = png_view(lv, os.path.join(PNGDIR, 'map%d.png' % lv.number), reach=reach)
            print('preview:', p)
    if cmd not in ('build', 'check', 'view', 'png', 'all'):
        print(__doc__)
        return 1
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv))
