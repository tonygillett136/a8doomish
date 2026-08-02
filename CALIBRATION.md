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

## Round four — four big blocks, and why

Round one proved it works. Round two overreached and distorted. Round three was
correct but **too fine to read**: twelve steps a few pixels apart is more than a
photograph of a CRT can resolve, and my estimates of the slope from it ranged
over a factor of three. That is on me, not on the pictures.

What your round-three photos *did* settle: the transition marches off the LEFT
edge well before the twelve steps are used up. So the range **overshoots** the
screen width rather than falling short of it, the reachable window is most or
all of the width, and the idea is worth building. My earlier pessimism was an
artefact of measuring the on-screen part of a range that runs off the edge.

So this build asks for something a phone cannot get wrong: **four blocks, each
24 scanlines tall, eight cycles apart** — 12, 8, 4 and 0 NOPs of delay, top to
bottom. Four big regions, each with one obvious vertical edge.

- the **gaps** between the four edges give me the slope
- their **positions** give me the offset
- and if an edge is missing, that block's transition is off-screen, which is
  equally informative

Purple marker bands still bracket the whole thing.

## What to look for

Four broad horizontal blocks between the purple bands, each split left-to-right
into blue and dark, with the split at a **different, clearly different** place in
each block. That is all. No counting of thin stripes.

`docs/calib_reference.png` is this build as the emulator draws it — the emulator
cannot draw a mid-line colour change, so its four blocks come out as flat bands
with no vertical edge at all.

**One photograph, straight on, whole screen in frame.** It does not play; if you
can move around you have loaded `abyss.xex`.
