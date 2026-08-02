# The calibration image — what to load, and what you should see

**Load `calib.xex`. NOT `abyss.xex`.**

    /Volumes/SSD1/code/retro_computing/atari400-800/abyss/calib.xex

## How to tell instantly which one booted

`calib.xex` **does not play**. There is no title screen, no "PRESS FIRE", no
HUD, no gun, no game at all — it never reaches the game loop. If you can move
around, you have loaded `abyss.xex` and the test has not run.

What `calib.xex` looks like — `docs/calib_reference.png` is this exact image as
the emulator draws it:

- a **teal screen**
- **ten vertical pale-blue stripes**, evenly spaced (a ruler, every 8 pixels)
- a **black notch** in the middle of the screen, marking centre
- **red horizontal banding** across the middle third

…and nothing else. It sits there unchanging. That is the whole program.

## Round two — what changed

Round one worked: the staircase came back clean off the CRT, so a mid-scanline
colour write **does** split a line, and the edges are sharp. What it did not
settle is how far RIGHT the switch can be pushed before the per-line cycle
budget runs out.

So this build asks for far more delay than a scanline can afford, on purpose.

- **20 steps** instead of 15, each **four cycles** apart instead of two
- solid **purple marker bands** immediately above and below the staircase, so
  its steps can be counted from either end (round one's top marker was the same
  hue as the screen above it, and so invisible)

## What to look for

The steps that fit inside a scanline are all the **same height**. The moment a
step needs more time than a line has, it takes two scanlines instead of one and
comes out **double height**.

**The first tall step is the answer.** Everything above it is reachable; nothing
below is. Together with the ruler that gives me the slope, the reachable window
and the cliff edge in one picture.

`docs/calib_reference.png` is this build as the emulator draws it — same layout,
same marker bands, but with the staircase collapsed into flat horizontal
stripes, because the emulator cannot draw a mid-line colour change at all.

**One photograph, straight on, whole screen in frame.** As before: it does not
play, and if you can move around you have loaded `abyss.xex`.
