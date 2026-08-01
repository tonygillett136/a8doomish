#!/usr/bin/env python3
"""
a8.py — headless Atari 8-bit harness over libatari800 (the A8 'ALE').

Runs a XEX/ATR/CAS headless (PAL by default — the user's real hardware is PAL),
injects joystick/console/keyboard input on chosen frames, captures PNG
screenshots Claude can see, and dumps live memory (including walking the
ACTUAL display list out of RAM — beats static analysis on packed games).

Usage examples:
  a8.py game.xex -o /tmp/shot --shots 100,300,600
  a8.py game.xex --shots 300 --input "120:start 130:none 200:trig 260:left"
  a8.py game.xex --frames 400 --dump-dl --peek 0x22F,0x230,0x231,0xD40E
  a8.py game.atr --frames 600 -o /tmp/d

Input script tokens (frame:action, applied AT that frame and held until changed):
  start select option trig  up down left right  (combine with + e.g. up+trig)
  none (release everything)   key=<char> (type a character)

IMPORTANT (lesson from ALE): kill leftover processes after use; this harness
exits cleanly on completion but pkill python if a run wedges.
"""
import sys, os, argparse, zlib, struct, ctypes as C

TOOLS = os.path.dirname(os.path.abspath(__file__))

class InputTemplate(C.Structure):
    _fields_ = [(n, C.c_ubyte) for n in (
        'keychar','keycode','special','shift','control','start','select',
        'option','joy0','trig0','joy1','trig1','joy2','trig2','joy3','trig3',
        'mousex','mousey','mouse_buttons','mouse_mode')]

# joy bits are INVERTED vs PORTA: 0 = centre, set bit = pushed
JOY = {'up':0x01,'down':0x02,'left':0x04,'right':0x08}

SCREEN_W, SCREEN_H = 384, 240
VISIBLE_X, VISIBLE_W = 24, 336   # trim hblank borders for shots

def _find_libatari800():
    """Locate the headless atari800 core.

    It is a third-party GPL binary and is deliberately NOT committed to this
    repository, so it has to be found rather than assumed. In order:

      1. $A8_LIBATARI800, if you keep it somewhere of your own
      2. next to this file
      3. ../../tools, where it lives in the wider atari400-800 workspace

    See the README for how to build one.
    """
    names = ('libatari800.dylib', 'libatari800.so')
    cands = []
    env = os.environ.get('A8_LIBATARI800')
    if env:
        cands.append(env)
    for d in (TOOLS, os.path.join(TOOLS, '..', '..', 'tools')):
        cands += [os.path.join(d, n) for n in names]
    for c in cands:
        if os.path.exists(c):
            return c
    raise RuntimeError(
        'libatari800 not found. Build it from the atari800 source with '
        '--target=libatari800 and either put it next to a8.py or set '
        '$A8_LIBATARI800. Tried: ' + ', '.join(cands))


class A8:
    def __init__(self, extra_args=(), pal=True):
        self.lib = C.CDLL(_find_libatari800())
        self.lib.libatari800_get_main_memory_ptr.restype = C.POINTER(C.c_ubyte)
        self.lib.libatari800_get_screen_ptr.restype = C.POINTER(C.c_ubyte)
        self.lib.libatari800_error_message.restype = C.c_char_p
        args = ['atari800']
        args += ['-pal'] if pal else ['-ntsc']
        args += list(extra_args)
        argv = (C.c_char_p * len(args))(*[a.encode() for a in args])
        if not self.lib.libatari800_init(len(args), argv):
            raise RuntimeError('libatari800_init failed: %s'
                               % self.lib.libatari800_error_message())
        self.inp = InputTemplate()
        self.lib.libatari800_clear_input_array(C.byref(self.inp))
        self.palette = self._read_palette()

    def _read_palette(self):
        tab = (C.c_int * 256).in_dll(self.lib, 'Colours_table')
        return [((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in tab]

    def boot(self, path):
        if not self.lib.libatari800_reboot_with_file(path.encode()):
            raise RuntimeError('could not boot %s: %s'
                               % (path, self.lib.libatari800_error_message()))

    def frame(self, n=1):
        for _ in range(n):
            self.lib.libatari800_next_frame(C.byref(self.inp))

    def set_input(self, spec):
        i = self.inp
        i.start = i.select = i.option = i.trig0 = 0
        i.joy0 = 0; i.keychar = 0
        for tok in spec.split('+'):
            tok = tok.strip().lower()
            if not tok or tok == 'none': continue
            if tok in JOY: i.joy0 |= JOY[tok]
            elif tok == 'trig': i.trig0 = 1
            elif tok == 'start': i.start = 1
            elif tok == 'select': i.select = 1
            elif tok == 'option': i.option = 1
            elif tok.startswith('key='): i.keychar = ord(tok[4:5])
            else: raise ValueError('unknown input token: ' + tok)

    def screen_rgb(self):
        p = self.lib.libatari800_get_screen_ptr()
        buf = C.string_at(p, SCREEN_W * SCREEN_H)
        return buf

    def memory(self):
        p = self.lib.libatari800_get_main_memory_ptr()
        return C.string_at(p, 65536)

    def save_png(self, path, scale=2):
        idx = self.screen_rgb()
        pal = self.palette
        w = VISIBLE_W * scale
        rows = []
        for y in range(SCREEN_H):
            row = bytearray()
            base = y * SCREEN_W
            for x in range(VISIBLE_X, VISIBLE_X + VISIBLE_W):
                r, g, b = pal[idx[base + x]]
                row += bytes((r, g, b)) * scale
            for _ in range(scale):
                rows.append(b'\x00' + bytes(row))
        raw = b''.join(rows)
        def chunk(tag, payload):
            c = struct.pack('>I', len(payload)) + tag + payload
            return c + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff)
        png = (b'\x89PNG\r\n\x1a\n'
               + chunk(b'IHDR', struct.pack('>IIBBBBB', w, SCREEN_H*scale, 8, 2, 0, 0, 0))
               + chunk(b'IDAT', zlib.compress(raw, 6))
               + chunk(b'IEND', b''))
        with open(path, 'wb') as f: f.write(png)

def dump_display_list(mem):
    """Walk the live display list pointed to by SDLSTL/H shadow."""
    dl = mem[0x230] | (mem[0x231] << 8)
    out = [f'display list @ ${dl:04X} (SDLSTL/H)']
    a, scan = dl, 0
    for _ in range(220):
        b = mem[a]
        low = b & 0x0F
        if low == 0:
            n = ((b >> 4) & 7) + 1; scan += n
            dli = ' [D]' if b & 0x80 else ''
            out.append(f'  {a:04X}: {b:02X}  blank {n}{dli}'); a += 1
        elif low == 1:
            tgt = mem[a+1] | (mem[a+2] << 8)
            kind = 'JVB' if b & 0x40 else 'JMP'
            out.append(f'  {a:04X}: {b:02X}  {kind} ${tgt:04X}')
            if b & 0x40 or tgt == dl: break
            a = tgt
        else:
            per = {2:8,3:10,4:8,5:16,6:8,7:16,8:8,9:4,0xA:4,0xB:2,
                   0xC:1,0xD:2,0xE:1,0xF:1}[low]
            scan += per
            flags = ''.join(f for f, m in (('D',0x80),('L',0x40),('V',0x20),('H',0x10)) if b & m)
            if b & 0x40:
                lms = mem[a+1] | (mem[a+2] << 8)
                out.append(f'  {a:04X}: {b:02X}  mode {low:X} [{flags}] LMS ${lms:04X}')
                a += 3
            else:
                out.append(f'  {a:04X}: {b:02X}  mode {low:X} [{flags}]')
                a += 1
    out.append(f'  total visible scan lines: {scan}')
    return '\n'.join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('image', help='XEX/ATR/CAS/CAR file')
    ap.add_argument('-o', '--out', default='/tmp/a8', help='screenshot prefix')
    ap.add_argument('--shots', default='', help='comma list of frame numbers')
    ap.add_argument('--frames', type=int, default=0, help='extra frames after last shot')
    ap.add_argument('--input', default='', help='frame:action tokens, space separated')
    ap.add_argument('--dump-dl', action='store_true')
    ap.add_argument('--peek', default='', help='comma list of addresses to print at end')
    ap.add_argument('--dump-mem', default='', help='write 64K memory image to file at end')
    ap.add_argument('--ntsc', action='store_true')
    ap.add_argument('--machine', default='', help='extra atari800 args, e.g. "-xl"')
    args = ap.parse_args()

    extra = args.machine.split() if args.machine else []
    a8 = A8(extra_args=extra, pal=not args.ntsc)
    a8.boot(args.image)

    shots = sorted(int(s) for s in args.shots.split(',') if s.strip())
    script = {}
    for tok in args.input.split():
        fr, _, act = tok.partition(':')
        script[int(fr)] = act
    end = max(shots[-1] if shots else 0, args.frames,
              max(script) + 1 if script else 0, 60)
    si = 0
    for f in range(end + 1):
        if f in script: a8.set_input(script[f])
        a8.frame()
        if si < len(shots) and f == shots[si]:
            p = f'{args.out}_{f:05d}.png'
            a8.save_png(p)
            print('shot:', p)
            si += 1
    if not shots:
        p = f'{args.out}_{end:05d}.png'
        a8.save_png(p)
        print('shot:', p)
    mem = a8.memory()
    if args.dump_dl:
        print(dump_display_list(mem))
    if args.peek:
        for s in args.peek.split(','):
            ad = int(s, 0)
            print(f'  ${ad:04X} = ${mem[ad]:02X} ({mem[ad]})')
    if args.dump_mem:
        with open(args.dump_mem, 'wb') as fh: fh.write(mem)
        print('memory image:', args.dump_mem)

if __name__ == '__main__':
    main()
