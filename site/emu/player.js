/* ABYSS in-browser player.
 *
 * This is tools/a8.py ported to JavaScript: the same libatari800 C API the
 * project's whole test harness drives in-process, compiled to WebAssembly and
 * driven from requestAnimationFrame instead of a Python loop. Single-threaded,
 * so no SharedArrayBuffer and no COOP/COEP headers — the lesson learned the
 * hard way on the Scopa site.
 *
 * Input template struct (20 bytes, all u8):
 *   0 keychar, 1 keycode, 2 special, 3 shift, 4 control, 5 start, 6 select,
 *   7 option, 8 joy0, 9 trig0, ... joystick bits are INVERTED vs PORTA:
 *   0 = centre, set bit = pushed (up 1, down 2, left 4, right 8); trig 1 = fire.
 */
(function () {
  'use strict';

  const VISIBLE_X = 24, VISIBLE_W = 336, H = 240, SCREEN_W = 384;
  const PAL_FPS = 49.86;
  const OFF_START = 5, OFF_JOY0 = 8, OFF_TRIG0 = 9;

  const canvas = document.getElementById('screen');
  const ctx2d = canvas.getContext('2d');
  const gate = document.getElementById('gate');

  let core = null, inputPtr = 0, imageData = null, pix32 = null, pal32 = null;
  let audio = null, gain = null, muted = false;
  let ring = new Float32Array(32768), ringR = 0, ringW = 0;
  let sndPtrFn = null, sndLenFn = null, sampleSize = 2;
  let joyMask = 0, fireHeld = false, fireLatch = 0, mapHeld = false;
  let last = 0, acc = 0, running = false;

  // ---- input --------------------------------------------------------------
  const KEYJOY = {
    ArrowUp: 1, KeyW: 1, ArrowDown: 2, KeyS: 2,
    ArrowLeft: 4, KeyA: 4, ArrowRight: 8, KeyD: 8,
  };
  const KEYFIRE = new Set(['Space', 'KeyX', 'KeyZ', 'ControlLeft', 'ControlRight']);
  // The console START key. On a real 800XL it is on the case beside the
  // keyboard; here it is Tab, which is the nearest thing to a key you can
  // hold with your left hand while the right one stays on the arrows.
  const KEYMAP = new Set(['Tab', 'KeyM']);

  window.addEventListener('keydown', (e) => {
    if (!running) return;
    if (KEYJOY[e.code]) { joyMask |= KEYJOY[e.code]; e.preventDefault(); }
    if (KEYFIRE.has(e.code)) {
      if (!e.repeat) fireLatch = 6;      // a tap must span several 50 Hz frames
      fireHeld = true;
      e.preventDefault();
    }
    if (KEYMAP.has(e.code)) { mapHeld = true; e.preventDefault(); }
  });
  window.addEventListener('keyup', (e) => {
    if (KEYJOY[e.code]) joyMask &= ~KEYJOY[e.code];
    if (KEYFIRE.has(e.code)) fireHeld = false;
    if (KEYMAP.has(e.code)) { mapHeld = false; e.preventDefault(); }
  });

  // touch pad
  document.querySelectorAll('#touch .pad div[data-j]').forEach((el) => {
    const bit = +el.dataset.j;
    el.addEventListener('pointerdown', (e) => { joyMask |= bit; e.preventDefault(); });
    el.addEventListener('pointerup', () => { joyMask &= ~bit; });
    el.addEventListener('pointerleave', () => { joyMask &= ~bit; });
  });
  const mapBtn = document.getElementById('mapBtn');
  if (mapBtn) {
    mapBtn.addEventListener('pointerdown', (e) => { mapHeld = true; e.preventDefault(); });
    mapBtn.addEventListener('pointerup', () => { mapHeld = false; });
    mapBtn.addEventListener('pointerleave', () => { mapHeld = false; });
  }
  const fireBtn = document.getElementById('fireBtn');
  if (fireBtn) {
    fireBtn.addEventListener('pointerdown', (e) => { fireLatch = 6; fireHeld = true; e.preventDefault(); });
    fireBtn.addEventListener('pointerup', () => { fireHeld = false; });
  }

  // ---- audio --------------------------------------------------------------
  function startAudio() {
    audio = new (window.AudioContext || window.webkitAudioContext)();
    gain = audio.createGain();
    gain.connect(audio.destination);
    const node = audio.createScriptProcessor(2048, 0, 1);
    node.onaudioprocess = (e) => {
      const out = e.outputBuffer.getChannelData(0);
      for (let i = 0; i < out.length; i++) {
        out[i] = ringR !== ringW ? ring[ringR++ & 32767] : 0;
        ringR &= 32767;
      }
    };
    node.connect(gain);
  }

  function pumpAudio() {
    if (!audio || muted) return;
    const n = sndLenFn();
    if (!n) return;
    const p = sndPtrFn();
    if (sampleSize === 2) {
      const s16 = new Int16Array(core.HEAPU8.buffer, p, n >> 1);
      for (let i = 0; i < s16.length; i++) { ring[ringW++ & 32767] = s16[i] / 32768; ringW &= 32767; }
    } else {
      for (let i = 0; i < n; i++) { ring[ringW++ & 32767] = (core.HEAPU8[p + i] - 128) / 128; ringW &= 32767; }
    }
  }

  // ---- boot ---------------------------------------------------------------
  async function boot() {
    gate.classList.add('loading');
    gate.querySelector('b').textContent = 'DESCENDING…';
    startAudio();                              // first, so the sample rate is known
    core = await createA8Core();

    const xex = new Uint8Array(await (await fetch('emu/abyss.xex')).arrayBuffer());
    core.FS.writeFile('/abyss.xex', xex);

    // argv, built by hand the way a8.py builds it
    const args = ['atari800', '-pal', '-sound',
                  '-dsprate', String(Math.round(audio.sampleRate))];
    const ptrs = args.map((a) => {
      const n = core.lengthBytesUTF8(a) + 1;
      const p = core._malloc(n);
      core.stringToUTF8(a, p, n);
      return p;
    });
    const argv = core._malloc(ptrs.length * 4);
    ptrs.forEach((p, i) => core.HEAP32[(argv >> 2) + i] = p);
    if (!core.ccall('libatari800_init', 'number', ['number', 'number'], [args.length, argv]))
      throw new Error('libatari800_init failed');

    sndPtrFn = core.cwrap('libatari800_get_sound_buffer', 'number', []);
    sndLenFn = core.cwrap('libatari800_get_sound_buffer_len', 'number', []);
    sampleSize = core.ccall('libatari800_get_sound_sample_size', 'number', [], []);

    inputPtr = core._malloc(32);
    core.ccall('libatari800_clear_input_array', null, ['number'], [inputPtr]);

    // palette -> little-endian ABGR words for putImageData
    const palPtr = core.ccall('a8_colours', 'number', [], []);
    pal32 = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
      const v = core.HEAP32[(palPtr >> 2) + i];
      pal32[i] = 0xff000000 | ((v & 255) << 16) | (v & 0xff00) | ((v >> 16) & 255);
    }
    imageData = ctx2d.createImageData(VISIBLE_W, H);
    pix32 = new Uint32Array(imageData.data.buffer);

    core.ccall('libatari800_reboot_with_file', 'number', ['string'], ['/abyss.xex']);

    running = true;
    gate.style.display = 'none';
    last = performance.now();
    requestAnimationFrame(tick);
  }

  // ---- frame loop ---------------------------------------------------------
  function emuFrame() {
    core.HEAPU8.fill(0, inputPtr, inputPtr + 32);
    core.HEAPU8[inputPtr + OFF_JOY0] = joyMask;
    core.HEAPU8[inputPtr + OFF_TRIG0] = (fireHeld || fireLatch > 0) ? 1 : 0;
    core.HEAPU8[inputPtr + OFF_START] = mapHeld ? 1 : 0;
    if (fireLatch > 0) fireLatch--;
    core.ccall('libatari800_next_frame', 'number', ['number'], [inputPtr]);
    pumpAudio();
  }

  function blit() {
    const sp = core.ccall('libatari800_get_screen_ptr', 'number', [], []);
    const src = core.HEAPU8;
    let d = 0;
    for (let y = 0; y < H; y++) {
      let s = sp + y * SCREEN_W + VISIBLE_X;
      for (let x = 0; x < VISIBLE_W; x++) pix32[d++] = pal32[src[s++]];
    }
    ctx2d.putImageData(imageData, 0, 0);
  }

  function tick(now) {
    if (!running) return;
    acc += Math.min(now - last, 100);
    last = now;
    const step = 1000 / PAL_FPS;
    let ran = 0;
    while (acc >= step && ran < 3) { emuFrame(); acc -= step; ran++; }
    if (ran) blit();
    requestAnimationFrame(tick);
  }

  // ---- chrome -------------------------------------------------------------
  gate.addEventListener('click', () => {
    if (!running) boot().catch((e) => {
      gate.querySelector('b').textContent = 'FAILED TO LOAD';
      gate.querySelector('span').textContent = String(e);
    });
  });
  document.getElementById('muteBtn').addEventListener('click', (e) => {
    muted = !muted;
    if (gain) gain.gain.value = muted ? 0 : 1;
    e.target.textContent = muted ? 'SOUND: OFF' : 'SOUND: ON';
  });
  document.getElementById('resetBtn').addEventListener('click', () => {
    if (core) core.ccall('libatari800_reboot_with_file', 'number', ['string'], ['/abyss.xex']);
  });
  document.getElementById('fsBtn').addEventListener('click', () => {
    document.querySelector('.emu-shell').requestFullscreen?.();
  });

  // expose a little state for the test harness — the Scopa rule: an embed you
  // cannot verify headless is an embed you cannot ship
  window.__abyss = {
    running: () => running,
    frame: () => core ? core.ccall('libatari800_next_frame', 'number', ['number'], [inputPtr]) : -1,
    peek: (addr) => {
      if (!core) return -1;
      const p = core.ccall('libatari800_get_main_memory_ptr', 'number', [], []);
      return core.HEAPU8[p + addr];
    },
  };
})();
