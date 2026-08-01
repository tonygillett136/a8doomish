# The way of working — what ABYSS teaches that isn't about raycasting

This game went from empty directory to hardware-confirmed, publicly playable,
four-release product in roughly thirty hours of elapsed time, with a 64-point
acceptance sweep, two real-hardware bugs found and fixed, and fourteen rounds of
adversarial review. None of the transferable lessons are about the 6502. They
are about how verified work compounds — and every one below was *earned* here,
with the receipt stated, because a principle without the failure that taught it
is a poster.

---

## 1. Open with a kill criterion

The project's first act was a disqualifying test: **≥10 fps measured, or stop.**
The first spike measured 7.7 and the response was diagnosis, not hope.

*Commercially:* define what would make you kill the project before you start it,
as a measurement, not a mood. Most doomed initiatives were never given a number
they had to hit.

## 2. Put everything the customer feels on the fast path

The world renders at ~11 fps. The game feels responsive because input, the
weapon, the kick, the sound and the HUD run at 50 Hz and never wait for the
renderer. That decoupling — not the renderer — is why 11 fps reads as
deliberate rather than broken.

*Commercially:* perceived quality lives in feedback latency, not completion
latency. An order confirmation in 100 ms with fulfilment in a day beats
fulfilment in an hour with silence for ten minutes.

## 3. Verify at the surface the customer sees

The checks here read *pixels out of the screen buffer* — outline pixels of the
gun, silhouette pixels of an enemy lost to a flash — because "a variable moving
proves nothing reached the screen." Every serious rendering defect was found by
counting what was actually displayed.

*Commercially:* internal metrics are proxies. Verify the email as received, the
invoice as printed, the page as loaded on a real phone — the artefact, not the
report of the artefact.

## 4. A test that builds its own precondition tests only what runs after it

Forty-four checks were green on a build in which **no level contained an
exit** — the game literally could not be finished — because the victory check
poked an exit into the map before walking into it. Later, its sequel: the
enemy-type system shipped types that were *born* correct and could neither
fight nor die, past sixty green checks, because every check proved spawning and
none proved functioning. **Spawning is not functioning.**

*Commercially:* launch checklists that verify configuration exists rather than
that the feature works end-to-end; demo environments seeded with the data whose
existence the test was meant to prove. Ask of every green check: *what would
this still do if the feature were entirely absent?* If the answer is "pass",
it tests the setup.

## 5. A report names a symptom; the cause is yours to measure

A reviewer said the muzzle flash hid the enemy and implied it was too bright.
Measurement showed the *brightest* step cost nothing and the **dim tail of the
decay** was what erased the target — the obvious fix was exactly backwards. The
same measurement run on a different band gave the *opposite* ranking, so the
fix for one region was the bug for another.

*Commercially:* customer complaints and expert reviews arrive with confident
wrong causes attached. Act on the symptom, measure for the cause — and never
copy a fix between contexts without re-measuring, because the same lever can
point opposite ways in two markets.

## 6. Fresh eyes are structurally different from more eyes

Nine review rounds by parties who knew the code converged on nothing. Round
ten — given only screenshots, forbidden the source — found three defects that
had been in every frame all along. Later, *blind identification* ("what is this
object?" with no context) settled in one answer what four knowledgeable critics
had argued about.

*Commercially:* a reviewer who knows how it works stops seeing what it looks
like. Usability answers come from people who don't know what it's supposed to
be; an expert panel is the wrong instrument for that question.

## 7. Individually true readings can compose into a false picture

Every screenshot was real, correctly labelled, and asserted against game state —
and three independent reviewers concluded from the set that the game was "one
room re-lit," because every level was photographed from its start square, and
every level starts in a corridor. No per-reading rigour could catch it. The
question that did: *what do all these readings have in common?*

*Commercially:* a KPI dashboard where every number is right can still tell a
story that is wrong, because of what the sample shares — same segment, same
season, same funnel stage. Audit the sampling, not just the figures. And when
several observers agree, check whether they're looking at the same evidence
before counting it as corroboration.

## 8. Your environment's defaults are not the world's

Two hardware failures, invisible to 130+ green emulator runs, for two different
reasons: the emulator *booted a configuration the real machine doesn't* (BASIC
ROM off vs on), and the emulator *structurally cannot show* a CRT losing sync —
it clips an overlong frame and renders it stable. The standing question ever
since: **what can this harness not see, even in principle?** Both answers
became permanent assertions.

*Commercially:* staging differs from production in defaults nobody wrote down,
and some failures — real devices, real payment rails, real network weather —
cannot be observed pre-production at all. Enumerate what your test environment
is blind to; that list, not your pass rate, is your actual risk.

## 9. A control that has never fired is a comment

Every memory boundary here carries an assertion on *both* sides, and each one
was deliberately broken once to prove it fires — because the one assertion
added without that ritual was aimed at the wrong address and **certified a live
bug as safe**. Related: a build step that doesn't regenerate its inputs shipped
a discarded draft with a plausible timestamp.

*Commercially:* alerts, reconciliations and approval gates that have never
triggered are decoration until you've watched them trigger. Test the control,
not just the process it guards. And any derived artefact a pipeline doesn't
rebuild — price sheets, config exports — is quietly becoming fiction.

## 10. Bank value in verified slices, and release the proven thing first

When hardware confirmed the build, **v1.0 was tagged from that exact commit
before any new code was written.** Each subsequent feature landed as its own
cycle — implement, measure, full sweep, commit, deploy — so when the hard
deadline arrived, the stop was a *plan*, not a crash: the last risky idea was
abandoned cleanly rather than shipped half-done.

*Commercially:* cut releases from the tested commit; never bundle "one more
thing" into a proven artefact. Under a deadline, work in slices small enough
that the whistle always finds you with everything banked.

## 11. Scout in parallel, change in series

The multi-agent pattern that actually paid: fan out readers to gather *verified
facts* — every reference to a symbol, every free memory region, what a draw
path really does — while one thread makes the change, then adversarial review.
The scouts found the bulletproof-statue bug and the fireball-drawn-as-enemy bug
in minutes; sixty green checks had found neither.

*Commercially:* parallelise research and due diligence; serialise the edit.
Multiple hands in one change-set costs more in merge friction than the
parallelism returns, but multiple eyes on *facts* is nearly free.

## 12. Read what you already own

The level files had authored enemy types, hand-placed pickups, and thirty-two
cells of damaging floor **for the game's entire life** — compiled, shipped, and
never read by the runtime. Three of this project's best features were not
built; they were *found*, by honouring data someone had already authored.

*Commercially:* organisations sit on authored-but-unread assets — spec fields
nobody renders, telemetry nobody queries, CRM data nobody joins. The cheapest
line on any roadmap is the one where the work is already done and unread.

## 13. Log the wrong turns, and sell honestly

The DEVLOG records every failure with its cause, because "a rejected approach
with a known cause is worth more than an untried one" — six weapon redraws each
failed *differently*, and the seventh built on knowing why. The public README
leads its limitations section with: *stated plainly, because a prototype that
oversells itself is worse than one that doesn't.*

*Commercially:* decision logs and honest release notes are compounding assets.
The wrong turns are where the reusable knowledge is; hiding them discards the
most expensive thing you bought.

---

*Written in the last ten minutes of the sprint it describes, 1 August 2026 —
which is itself lesson 10 in practice.*
