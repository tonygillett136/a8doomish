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

## Round three — and this is the last one

Round one worked: the staircase came back clean, so a mid-scanline colour write
**does** split a line on real hardware and the edges are sharp.

Round two overreached. It asked for up to 40 NOPs of delay, which is far more
than a scanline can afford, so most of its steps overran into a second line and
the picture came out distorted — unreadable, and my fault.

That ceiling has since been **measured here, without the CRT**: a step that does
not fit takes two scanlines instead of one, which makes the whole band taller,
and scanline counts are something the emulator models exactly. The answer is
**12 NOPs fits, 14 does not.**

So this build stays inside it: **12 steps, one NOP (two cycles) apart, eight
scanlines each**, bracketed by the two purple marker bands. Nothing overruns.

## What to look for

**Every step should be the same height.** If one is double height, the budget
calculation was wrong and I want to know.

The measurement is where each step's colour change sits against the ruler. That
is the last unknown: how many pixels one CPU cycle buys. My reading of round one
said about 1.2 — which would put the reachable window at a third of the screen —
but modelling ANTIC's DMA says it could be two or three times that, which would
be most of the screen. Those give opposite answers on whether the whole idea is
worth building, so I would rather measure it than pick one.

`docs/calib_reference.png` is this build as the emulator draws it: same purple
bands, same ruler, but with the staircase collapsed into two flat blocks because
the emulator cannot draw a mid-line colour change at all.

**One photograph, straight on, whole screen in frame.** As before: it does not
play, and if you can move around you have loaded `abyss.xex`.
