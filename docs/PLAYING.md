# ABYSS — how to play

*Four floors down, no way up.*

You are somewhere under the world with a shotgun and no map. Four floors lie
below you. Each one has a way down, and the way down is the only way on.

Nothing here needs explaining twice. There is one weapon, one button, and one
direction — down.

---

## Controls

**On a real Atari** — joystick in **port 1**. That is the whole control scheme.

| | |
|---|---|
| **Push up** | walk forward |
| **Pull down** | walk backward |
| **Left / right** | turn |
| **Trigger** | fire |

**In a browser** — **arrow keys** or **WASD** to move, **SPACE** or **X** to
fire.

There is no strafe, no run key, no map key, no use key. Doors open because you
walked into them.

**The trigger is also the "carry on" button.** It starts the game from the
title, it clears the banner when you finish a floor, it restarts you when you
die, and it starts a new run from the end card. Whenever the game is waiting,
it is waiting for the trigger — and it says so on screen.

---

## The status bar

Two lines along the bottom. The top line is you, the bottom line is where you
are.

```
HEALTH 100  AMMO 050  ABYSS
        THE VESTIBULE
```

You start every run with **100 health** and **50 shells**.

That top line is also where the game talks to you. When it has something to
say — you have cleared the floor, you have died — the message replaces it, and
the floor name stays put underneath.

There is deliberately no clock, no compass, no automap and no key display. The
only instrument you get is your own memory of the corridor behind you.

---

## The shotgun

One barrel, about a second between shells, and it hurts far more up close than
it does across a room. This is the whole of the combat system, and it is worth
knowing exactly:

| How far away | What one shell does |
|---|---|
| **Two cells or less** | 60 damage |
| **Three to five cells** | 28 damage |
| **Further than that** | 12 damage — a peppering |

So the same shell is **five times deadlier at point-blank**. Backing away and
plinking is the slowest, most expensive way to kill anything in this game.
Walking into its face is the cheapest.

Two more things the shotgun does that are not on the screen:

- **It is loud.** Every shot wakes anything within three cells. Firing at one
  thing is how you meet the next one.
- **It has a cone**, about 17 degrees either side. You do not have to be
  perfectly lined up, but you cannot spray.

---

## What is down there

Five of them on every floor. Three kinds, and the difference between them is
how much they can take:

| | Takes | Point-blank | Mid range | Across a room |
|---|---|---|---|---|
| **Husk** — shambling, common | 60 | **1 shell** | 3 | 5 |
| **Gunner** — hangs back and shoots | 32 | **1 shell** | 2 | 3 |
| **Hulk** — slow, enormous, patient | 120 | **2 shells** | 5 | 10 |

The first floor is husks only. Gunners start appearing on the second. The hulk
is waiting at the bottom.

All of them will hurt you from a distance as well as up close, so standing
still in an open room is the worst thing you can do.

---

## Doors, keys and the way out

**Ordinary doors** open when you walk into them. There is a beat — the door
opens on the step that touches it, and you walk through on the next one. That
pause is deliberate, not a stutter.

**Locked doors** are coloured, and they need the matching key. You will hear
the difference: a locked door answers with a **latch click**, not the sound of
a door. That click means *"you need a key"*, not *"this is a wall"* — and the
key it wants is always somewhere on the floor you are already standing on. You
will never be sent back up for one, because you cannot go back up.

You pick a key up by walking over it, and there is nothing on the HUD to tell
you that you have. The door will tell you.

**The way out is a doorway that breathes.** Nothing else in this world moves
by itself, so once it is in front of you it is unmistakable: it swells and
fades, brighter than any stone around it, and it gets easier to pick out the
further away you are.

Walk onto it and the game stops and tells you what it cost you:

```
FIRE TO DESCEND      KILLS 005
        THE VESTIBULE
```

**Then pull the trigger to drop a floor.** The game is not stuck — it is
giving you a moment to read the tally before the floor opens.

---

## Dying

`YOU DIED - FIRE TO RETRY`.

The trigger puts you back at the start of **the floor you died on** — not back
to the beginning of the game. That floor is completely reset: the doors are
shut again, the medkits and shells are back where they were, your kill tally
starts over, and you begin with full health, 50 shells and **empty hands**.

If that floor's exit needed a key, the key is lying where you first found it.
You lose the progress, not the possibility.

---

## Supplies

| | |
|---|---|
| **Medkit** | +25 health, up to 100 |
| **Shells** | +15 shells, up to 99 |

Two medkits on every floor; one or two boxes of shells.

The important asymmetry: **health follows you down, ammunition does not.**
Clearing a floor gives you a fresh 50 shells whatever you had left — so the
last few shells on a floor are free, and hoarding them is throwing them away.
Your health is carried down exactly as you left it, and nothing heals you
between floors. A medkit you walk past on the first floor is health you do not
have on the fourth.

---

## The descent

| | Floor | Par |
|---|---|---|
| 1 | **THE VESTIBULE** | 1:30 |
| 2 | **THE RED CISTERN** — the red key is down here, and so is the door it opens | 2:30 |
| 3 | **SILENT COLONNADE** | 3:00 |
| 4 | **THE MAW** — the yellow key, and whatever is using it | 4:00 |
| | **The whole descent** | **11:00** |

A clock runs from the moment you leave the title screen until you climb out of
the bottom. You never see it while you play, and the game never shows you a
floor-by-floor split — the per-floor figures above are there so you can pace
yourself. What you are scored against is one number, shown once, at the end:

```
TIME      PAR      FIRE AGAIN
HEALTH      KILLS     AMMO
```

Par is generous the first time and mean once you know the floors. Finishing at
all is the achievement; finishing under 11 minutes is the game underneath the
game.

---

## Five things worth knowing

1. **Get close.** One shell at two cells beats five at eight. Every fight in
   this game is decided by whether you were willing to close the distance.
2. **Shoot only when you mean it.** Every shot wakes the neighbours.
3. **Spend your shells before you take the stairs.** The next floor gives you
   50 regardless.
4. **Don't walk past medkits.** Health is the only thing you carry down.
5. **A click means a key, not a wall.** If a door refuses you with a click,
   there is a key on this floor, and there is a way to reach it.

---

*ABYSS runs on a standard 64 KB Atari 800XL, PAL, no cartridge, no expansion.
It is 29 KB and it fits in the machine with room to spare. Full technical
write-up in the [README](../README.md); the whole build diary is in
[DEVLOG.md](../DEVLOG.md).*
