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

## The one thing that matters

The emulator cannot draw a mid-scanline colour change, so in the reference
picture the red appears as **solid horizontal bands running the full width**.

On real hardware, if a mid-line colour write works, that red region should
instead be a **staircase**: fifteen steps, each about six scanlines tall, each
one starting its red further to the left (or right) than the step below it — a
ragged diagonal edge down through the red, not a straight vertical one.

- **Staircase** → it works. Photograph it; the stripes give me the scale and I
  can read the delay→pixel mapping straight off the picture.
- **Flat bands, exactly like the reference** → real hardware does not do it
  either, and that is the end of the idea. One photo, no weekend lost.

Either way: **one photograph, straight on, whole screen in frame.** A slow
shutter (1/50s or slower) avoids catching a partial refresh, but do not worry
about it too much — two shots at different exposures covers it.
