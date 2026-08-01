; ============================================================================
; ABYSS -- AUDIO ENGINE (POKEY, VBI-driven, frame-stepped, priority-arbitrated)
;
; Architecture
; ------------
; The 3D view renders at ~14 fps.  Audio DOES NOT live there.  This module is
; stepped once per 50 Hz VBlank; a trigger read in the VBI produces its first
; POKEY write in the SAME VBI (zero added latency, never "next render tick").
;
; POKEY is presented to the game as THREE VOICES, not four channels:
;
;   VOICE A = ch1+ch2 joined 16-bit (AUDCTL bit4) with ch1 clocked at 1.79 MHz
;             (AUDCTL bit6).  AUDCTL = $50, set ONCE at init and never touched
;             again -- switching AUDCTL per-sound (Dropzone's idiom) would
;             glitch the other voices, and we gain nothing since the pair is
;             permanently allocated.  AUDF1 = low byte, AUDF2 = high byte,
;             output volume/distortion from AUDC2, AUDC1 held at 0.
;             Big low-end: SHOTGUN BOOM, door grind, fireball impact -- and the
;             ambient drone as its IDLE FLOOR (see below).
;   VOICE B = ch3, 8-bit, 64 kHz clock.  Mechanical / UI: pump click, door
;             clatter, item pickup.
;   VOICE C = ch4, 8-bit, 64 kHz clock.  Actors: growl, pain yelp, death
;             scream, fireball launch, player pain grunt.
;
; THE DRONE COSTS NO CHANNEL.  It is not a fourth voice -- it is voice A's
; resting state.  Whenever voice A falls idle the engine restarts SND_DRONE
; (priority 0), so the low hum runs forever under everything; the instant the
; shotgun (or a door, or an impact) fires, it seizes the pair and the drone
; ducks out completely.  That is not a compromise, it is the effect you want:
; the boom swallows the room.  16-bit @1.79 MHz is also the only mode on this
; chip with fine enough resolution to hold a stable ~110 Hz sub-bass, so the
; drone is on the RIGHT hardware, not a leftover one.
;
; PAL clock arithmetic used to pick every AUDF in this file:
;   16-bit, 1.79 MHz  : f = 1773447 / (2 * (N + 7)),  N = AUDF2*256 + AUDF1
;   8-bit,  64 kHz    : f = 63337 / (2 * (AUDF + 1))
; For a noise distortion these give the POLY SAMPLING RATE (the "colour" of
; the noise), not a pitch: bigger AUDF = coarser/lower = the boom falling.
;
; Volume law (De Re Atari ch7): sum of the four AUDC volumes must stay <= 32.
; Worst simultaneous case in the shipped set: 15 (shotgun) + 8 (pump) + 9
; (loudest actor sound) = 32 exactly.  Voice A costs one volume, not two,
; because AUDC1 is held at 0.
;
; Distortion values, straight from the De Re table:
;   $0 = 5-bit then 17-bit poly ..... air / steam .......... fireball whoosh
;   $4 = 5-bit then 4-bit poly ...... "missing engine" ..... player grunt, rattle
;   $8 = 17-bit poly ................ crashes / explosions . boom, growl, scream
;   $A = pure tone .................. music .................. drone, pickup
;   $C = 4-bit poly ................. motor / razor ......... mechanical clicks
;
; ============================================================================
; SOUND DATA FORMAT
; ============================================================================
; Every sound is (a) one row in eleven parallel descriptor arrays, indexed by
; sound id, and (b) a stream of fixed-width rows, one row per envelope step.
;
;   descriptor           meaning
;   ------------------   -------------------------------------------------
;   SND_PTRL/SND_PTRH    address of the row stream
;   SND_LEN              number of rows
;   SND_HOLD             frames each row is held (1 = one row per 50 Hz frame)
;                        row 0 is loaded on the frame audio_play was called,
;                        so total duration = LEN * HOLD frames
;   SND_VOICE            0 = A (ch1+ch2 16-bit), 1 = B (ch3), 2 = C (ch4)
;   SND_PRIO             0..255.  A new sound takes the voice iff the voice is
;                        idle OR new PRIO >= the PRIO of what is playing.
;                        Equal priority retriggers (2nd shotgun blast restarts).
;   SND_F1D/SND_F1I      follow-up 1: fire sound F1I after F1D frames (0 = none)
;   SND_F2D/SND_F2I      follow-up 2: ditto.  This is how the shotgun schedules
;                        its two pump clicks at +12 and +20 frames, and how the
;                        door layers its second voice.
;
;   row stream, VOICE A (3 bytes per row):  AUDF_LO, AUDF_HI, AUDC2
;   row stream, VOICE B/C (2 bytes per row): AUDF, AUDC
;
; RELEASE-ROW CONVENTION (load-bearing).  The LAST row of every sound is its
; release and must carry volume 0 -- the player does not silence a channel
; itself.  This is not laziness, it is the only way the last row can actually
; be heard: an "end of sound -> write vol 0" in the player fires on the same
; frame the last row is loaded and mutes it (which is exactly the bug that ate
; the second frame of the pump click during bring-up).  Expressing the release
; as data costs one row, costs zero code and zero state, and lets a sound end
; on a deliberate value rather than a hard cut.  The DRONE is the one
; exception: it has no release row because voice A restarts it the moment it
; runs out, so it loops seamlessly.  tools/audtrace.py --audit asserts this
; over the shipped tables read back out of RAM.
;
; AUDC is the raw hardware byte: distortion in bits 7-5, volume in bits 3-0.
; Keeping them fused (rather than a separate volume column) is deliberate --
; it lets an envelope change TIMBRE mid-sound for free, which the death scream
; uses (17-bit noise scream decaying into a 5-then-4-bit poly death rattle).
;
; ============================================================================
; PUBLIC ENTRY POINTS
; ============================================================================
;   audio_init            once, at boot, from the mainline.  Programs AUDCTL /
;                         SKCTL, clears state, starts the drone.
;   audio_vbi             once per 50 Hz VBI.  Steps every voice, ticks the
;                         deferred-trigger queue, commits all 8 POKEY audio
;                         registers.  Preserves nothing (call it from a VBI
;                         that honours the VVBLKI push contract), but it does
;                         save/restore $F0-$F3 -- see below.
;   audio_play            A = sound id.  Starts it subject to priority.
;                         Clobbers A/X/Y.  Call it from the VBI, immediately
;                         BEFORE audio_vbi, so the sound is audible on the
;                         very same frame the trigger was read.
;   audio_drone_on        1 byte flag; 0 disables the ambient drone (title /
;                         menu screens), 1 (default) enables it.
;
; ZERO PAGE:  the module owns NOTHING permanently.  audio_vbi borrows $F0-$F3
; and RESTORES them before returning.  $F0-$FF is documented as "shared
; scratch, caller-saves" -- but an interrupt is not a caller, so clobbering it
; asynchronously would be a real bug the day another module keeps a value
; there across two instructions.  24 cycles of insurance.
; audio_play and audio_init use no zero page at all.
; ============================================================================

AUDF1   = $D200
AUDC1   = $D201
AUDF2   = $D202
AUDC2   = $D203
AUDF3   = $D204
AUDC3   = $D205
AUDF4   = $D206
AUDC4   = $D207
AUDCTL  = $D208
SKCTL   = $D20F

AUDCTL_MODE = $50               ; bit6 ch1 @1.79MHz + bit4 join ch1+ch2

; ---- sound ids -------------------------------------------------------------
SND_SHOTGUN   = 0
SND_PUMP      = 1
SND_GROWL     = 2
SND_YELP      = 3
SND_DEATH     = 4
SND_FBLAUNCH  = 5
SND_FBHIT     = 6
SND_DOOR      = 7
SND_DOORCLK   = 8
SND_PAIN      = 9
SND_PICKUP    = 10
SND_DRONE     = 11
NSOUNDS       = 12

    .ifndef AUDIO_TRACE
AUDIO_TRACE = 0
    .endif

; ============================================================================
; MODULE RAM  ($9F00-$9EFF, ours)
; ============================================================================
        org $9F00
; per-voice state, parallel arrays indexed 0=A 1=B 2=C
v_ptr_lo    .ds 3               ; -> next row
v_ptr_hi    .ds 3
v_cnt       .ds 3               ; rows remaining; 0 = idle  (ARM/DISARM byte)
v_prio      .ds 3               ; priority of what is playing
v_hold      .ds 3               ; frames left on the current row
v_hrel      .ds 3               ; hold reload value
v_id        .ds 3               ; sound id playing (debug/trace)
; deferred trigger queue -- 4 slots
dq_time     .ds 4               ; frames until fire; 0 = slot free
dq_id       .ds 4
dq_sav      .ds 1
; POKEY shadow, in hardware order  AUDF1,AUDC1,AUDF2,AUDC2,AUDF3,AUDC3,AUDF4,AUDC4
audshad     .ds 8
audio_drone_on .ds 1
ap_tmp      .ds 2
zsave       .ds 4
    .if AUDIO_TRACE > 0
trace_rec   .ds 1
    .endif

TRACEBUF    = $B400             ; debug build only: 128 records x 16 bytes.
                                ; $B400-$BBFF: above our code (ends ~$B3E0) and
                                ; BELOW the OS's default screen/DL at $BC20 --
                                ; parking it at $B800 silently ate the OS
                                ; display list and changed the DMA load.

; ============================================================================
        org $BB00               ; relocated: actors.asm owns $B000-$BA23
; ============================================================================
; audio_init -- boot-time.  Mainline only, not the VBI.
; ============================================================================
audio_init
        lda #0
        ldx #(zsave+4-v_ptr_lo)-1
_ai_clr sta v_ptr_lo,x
        dex
        bpl _ai_clr

        lda #AUDCTL_MODE
        sta AUDCTL
        lda #3                  ; POKEY housekeeping; MUST be redone after any SIO
        sta SKCTL

        lda #0                  ; all four channels silent
        sta AUDF1
        sta AUDC1
        sta AUDF2
        sta AUDC2
        sta AUDF3
        sta AUDC3
        sta AUDF4
        sta AUDC4

    .if AUDIO_TRACE > 0
        lda #0
        sta trace_rec
    .endif

        lda #1
        sta audio_drone_on
        lda #SND_DRONE          ; voice A's resting state
        jmp audio_play

    .if AUDIO_TRACE > 0
audio_trace_reset
        lda #0
        sta trace_rec
        rts
    .endif

; ============================================================================
; audio_play -- A = sound id.  Clobbers A,X,Y.  No zero page.
;
; Interrupt discipline: v_cnt is the arm/disarm byte and audio_vbi only looks
; at a voice when v_cnt != 0.  We zero it FIRST, rewrite the voice, and set it
; LAST -- so a VBI landing anywhere inside this routine sees either the old
; sound (impossible, we zeroed it) or silence, never a half-written pointer.
; ============================================================================
audio_play
        cmp #NSOUNDS
        bcs _ap_ret             ; out of range -> ignore
        tax                     ; X = id
        ldy SND_VOICE,x         ; Y = voice
        lda v_cnt,y
        beq _ap_take            ; voice idle -> free
        lda SND_PRIO,x
        cmp v_prio,y
        bcc _ap_ret             ; new < current -> REJECTED (boom survives)
_ap_take
        lda #0
        sta v_cnt,y             ; DISARM before touching anything else
        lda SND_PTRL,x
        sta v_ptr_lo,y
        lda SND_PTRH,x
        sta v_ptr_hi,y
        lda SND_PRIO,x
        sta v_prio,y
        lda SND_HOLD,x
        sta v_hrel,y
        lda #1
        sta v_hold,y            ; row 0 loads on the very next audio_vbi
        txa
        sta v_id,y
        lda SND_LEN,x
        sta v_cnt,y             ; ARMED
        ; ---- schedule follow-ups ----
        lda SND_F1D,x
        beq _ap_f2
        sta ap_tmp
        lda SND_F1I,x
        sta ap_tmp+1
        jsr _ap_enq
_ap_f2
        lda SND_F2D,x
        beq _ap_ret
        sta ap_tmp
        lda SND_F2I,x
        sta ap_tmp+1
        jsr _ap_enq
_ap_ret rts

_ap_enq                         ; ap_tmp = delay, ap_tmp+1 = id.  X preserved.
        ldy #3
_ape    lda dq_time,y
        beq _apef
        dey
        bpl _ape
        rts                     ; queue full -> drop the follow-up
_apef   lda ap_tmp+1
        sta dq_id,y
        lda ap_tmp
        clc
        adc #1                  ; +1: this same audio_vbi will tick the slot
        sta dq_time,y           ; arm last (max usable delay = 254)
        rts

; ============================================================================
; audio_vbi -- call once per 50 Hz VBI.
; ============================================================================
audio_vbi
        lda $F0
        sta zsave
        lda $F1
        sta zsave+1
        lda $F2
        sta zsave+2
        lda $F3
        sta zsave+3

; ---- deferred trigger queue -----------------------------------------------
        ldx #3
_dq     lda dq_time,x
        beq _dqn
        dec dq_time,x
        bne _dqn
        lda dq_id,x
        stx dq_sav
        jsr audio_play
        ldx dq_sav
_dqn    dex
        bpl _dq

; ---- VOICE A : ch1+ch2, 16-bit pair, 3-byte rows ---------------------------
        lda v_cnt+0
        beq _va_done
        dec v_hold+0
        bne _va_done            ; row still held: registers stay put
        lda v_ptr_lo+0
        sta $F0
        lda v_ptr_hi+0
        sta $F1
        ldy #0
        lda ($F0),y
        sta audshad+0           ; AUDF1 = N low
        iny
        lda ($F0),y
        sta audshad+2           ; AUDF2 = N high
        iny
        lda ($F0),y
        sta audshad+3           ; AUDC2 = distortion|volume
        lda $F0
        clc
        adc #3
        sta v_ptr_lo+0
        lda $F1
        adc #0
        sta v_ptr_hi+0
        lda v_hrel+0
        sta v_hold+0
        dec v_cnt+0
        bne _va_done
        ; sound finished -> fall back to the drone (or silence)
        lda audio_drone_on
        beq _va_sil
        lda #SND_DRONE
        jsr audio_play
        jmp _va_done
_va_sil lda #0
        sta audshad+3
_va_done

; ---- VOICE B : ch3, 8-bit, 2-byte rows -------------------------------------
        lda v_cnt+1
        beq _vb_done
        dec v_hold+1
        bne _vb_done
        lda v_ptr_lo+1
        sta $F0
        lda v_ptr_hi+1
        sta $F1
        ldy #0
        lda ($F0),y
        sta audshad+4           ; AUDF3
        iny
        lda ($F0),y
        sta audshad+5           ; AUDC3
        lda $F0
        clc
        adc #2
        sta v_ptr_lo+1
        lda $F1
        adc #0
        sta v_ptr_hi+1
        lda v_hrel+1
        sta v_hold+1
        dec v_cnt+1             ; last row is the RELEASE row (vol 0) -- see
_vb_done                        ; the release-row convention in the header

; ---- VOICE C : ch4, 8-bit, 2-byte rows -------------------------------------
        lda v_cnt+2
        beq _vc_done
        dec v_hold+2
        bne _vc_done
        lda v_ptr_lo+2
        sta $F0
        lda v_ptr_hi+2
        sta $F1
        ldy #0
        lda ($F0),y
        sta audshad+6           ; AUDF4
        iny
        lda ($F0),y
        sta audshad+7           ; AUDC4
        lda $F0
        clc
        adc #2
        sta v_ptr_lo+2
        lda $F1
        adc #0
        sta v_ptr_hi+2
        lda v_hrel+2
        sta v_hold+2
        dec v_cnt+2             ; last row is the RELEASE row (vol 0)
_vc_done

; ---- commit the shadow to POKEY, unrolled ---------------------------------
        lda audshad+0
        sta AUDF1
        lda audshad+1
        sta AUDC1
        lda audshad+2
        sta AUDF2
        lda audshad+3
        sta AUDC2
        lda audshad+4
        sta AUDF3
        lda audshad+5
        sta AUDC3
        lda audshad+6
        sta AUDF4
        lda audshad+7
        sta AUDC4

    .if AUDIO_TRACE > 0
; ---- debug ring: 128 records x 16 bytes at TRACEBUF ------------------------
; Freezes when full so a headless run yields a clean linear log of the first
; 128 VBI frames; audio_trace_reset re-arms it.
        lda trace_rec
        bmi _tr_done            ; bit7 set = full, stop recording
        lda trace_rec
        asl
        asl
        asl
        asl
        sta $F2
        lda trace_rec
        lsr
        lsr
        lsr
        lsr
        clc
        adc #>TRACEBUF
        sta $F3
        ldy #7
_tr1    lda audshad,y
        sta ($F2),y
        dey
        bpl _tr1
        ldy #8
        lda v_id+0
        sta ($F2),y
        iny
        lda v_id+1
        sta ($F2),y
        iny
        lda v_id+2
        sta ($F2),y
        iny
        lda v_cnt+0
        sta ($F2),y
        iny
        lda v_cnt+1
        sta ($F2),y
        iny
        lda v_cnt+2
        sta ($F2),y
        iny
        lda dq_time+3
        sta ($F2),y
        iny
        lda dq_time+2
        sta ($F2),y
        inc trace_rec
_tr_done
    .endif

        lda zsave
        sta $F0
        lda zsave+1
        sta $F1
        lda zsave+2
        sta $F2
        lda zsave+3
        sta $F3
        rts

; ============================================================================
; DESCRIPTOR TABLES -- parallel arrays, indexed by sound id
; ============================================================================
SND_PTRL
        dta b(<e_shotgun), b(<e_pump),  b(<e_growl),  b(<e_yelp)
        dta b(<e_death),   b(<e_fbl),   b(<e_fbhit),  b(<e_door)
        dta b(<e_doorclk), b(<e_pain),  b(<e_pickup), b(<e_drone)
SND_PTRH
        dta b(>e_shotgun), b(>e_pump),  b(>e_growl),  b(>e_yelp)
        dta b(>e_death),   b(>e_fbl),   b(>e_fbhit),  b(>e_door)
        dta b(>e_doorclk), b(>e_pain),  b(>e_pickup), b(>e_drone)
SND_LEN
        dta b(10), b(3),  b(11), b(6)
        dta b(16), b(8),  b(8),  b(12)
        dta b(12), b(6),  b(6),  b(16)
SND_HOLD
        dta b(1),  b(1),  b(1),  b(1)
        dta b(2),  b(1),  b(1),  b(1)
        dta b(1),  b(1),  b(1),  b(8)
SND_VOICE
        dta b(0),  b(1),  b(2),  b(2)
        dta b(2),  b(2),  b(0),  b(0)
        dta b(1),  b(2),  b(1),  b(0)
SND_PRIO
        dta b(200), b(100), b(60),  b(80)
        dta b(120), b(70),  b(140), b(160)
        dta b(120), b(200), b(90),  b(0)
SND_F1D
        dta b(12), b(0),  b(0),  b(0)
        dta b(0),  b(0),  b(0),  b(1)
        dta b(0),  b(0),  b(0),  b(0)
SND_F1I
        dta b(SND_PUMP), b(0), b(0), b(0)
        dta b(0), b(0), b(0), b(SND_DOORCLK)
        dta b(0), b(0), b(0), b(0)
SND_F2D
        dta b(20), b(0),  b(0),  b(0)
        dta b(0),  b(0),  b(0),  b(0)
        dta b(0),  b(0),  b(0),  b(0)
SND_F2I
        dta b(SND_PUMP), b(0), b(0), b(0)
        dta b(0), b(0), b(0), b(0)
        dta b(0), b(0), b(0), b(0)

; ============================================================================
; ENVELOPE STREAMS
; ============================================================================
; ---- 1. SHOTGUN BOOM -- voice A, 10 frames (200 ms), the hero sound --------
; 17-bit poly noise ($8) on the 16-bit pair.  N runs 120 -> 6814, i.e. the
; noise sampling rate falls 6982 Hz -> 130 Hz: an instantaneous bright CRACK
; that collapses into a low rumbling body.  Volume 15 -> 0, roughly exponential.
;                 N       lo    hi   AUDC   noise rate   vol
e_shotgun
        dta b($78),b($00),b($8F)   ; N=120    6982.1Hz  vol 15 17poly(explode)
        dta b($BE),b($00),b($8E)   ; N=190    4501.1Hz  vol 14 17poly(explode)
        dta b($36),b($01),b($8C)   ; N=310    2797.2Hz  vol 12 17poly(explode)
        dta b($E6),b($01),b($8A)   ; N=486    1798.6Hz  vol 10 17poly(explode)
        dta b($FC),b($02),b($88)   ; N=764    1150.1Hz  vol 8  17poly(explode)
        dta b($97),b($04),b($86)   ; N=1175    750.2Hz  vol 6  17poly(explode)
        dta b($30),b($07),b($84)   ; N=1840    480.1Hz  vol 4  17poly(explode)
        dta b($25),b($0B),b($83)   ; N=2853    310.0Hz  vol 3  17poly(explode)
        dta b($4B),b($11),b($82)   ; N=4427    200.0Hz  vol 2  17poly(explode)
        dta b($9E),b($1A),b($80)   ; N=6814    130.0Hz  vol 0  17poly(explode)

; ---- 2. PUMP CLICK -- voice B, 2 frames, high, mechanical ------------------
; 4-bit poly ($C) = "motor / electric razor": a hard metallic tick, not a beep.
; Fired twice by the shotgun's follow-up slots at +12 and +20 frames.
e_pump
        dta b($0A),b($C8)   ;  2879.0Hz  vol 8  4poly(razor)
        dta b($14),b($C4)   ;  1508.0Hz  vol 4  4poly(razor)
        dta b($14),b($C0)   ;  1508.0Hz  vol 0  4poly(razor)  release

; ---- 3. HUSK GROWL (wake) -- voice C, 10 frames ----------------------------
; 17-bit poly, coarse (high AUDF) = throaty.  Rate 487 -> 192 Hz, volume swells
; then dies: the sound of something noticing you.
e_growl
        dta b($40),b($84)   ;   487.2Hz  vol 4  17poly(explode)
        dta b($48),b($87)   ;   433.8Hz  vol 7  17poly(explode)
        dta b($52),b($89)   ;   381.6Hz  vol 9  17poly(explode)
        dta b($5C),b($89)   ;   340.5Hz  vol 9  17poly(explode)
        dta b($66),b($88)   ;   307.5Hz  vol 8  17poly(explode)
        dta b($72),b($88)   ;   275.4Hz  vol 8  17poly(explode)
        dta b($7E),b($87)   ;   249.4Hz  vol 7  17poly(explode)
        dta b($8A),b($86)   ;   227.8Hz  vol 6  17poly(explode)
        dta b($96),b($84)   ;   209.7Hz  vol 4  17poly(explode)
        dta b($A4),b($82)   ;   191.9Hz  vol 2  17poly(explode)
        dta b($A4),b($80)   ;   191.9Hz  vol 0  17poly(explode)  release
; ---- 4. PAIN YELP -- voice C, 6 frames (120 ms), a short bark --------------
e_yelp
        dta b($18),b($89)   ;  1266.7Hz  vol 9  17poly(explode)
        dta b($20),b($89)   ;   959.7Hz  vol 9  17poly(explode)
        dta b($2A),b($87)   ;   736.5Hz  vol 7  17poly(explode)
        dta b($34),b($85)   ;   597.5Hz  vol 5  17poly(explode)
        dta b($3E),b($83)   ;   502.7Hz  vol 3  17poly(explode)
        dta b($48),b($80)   ;   433.8Hz  vol 0  17poly(explode)

; ---- 5. DEATH SCREAM -- voice C, 16 rows x HOLD 2 = 32 frames (640 ms) -----
; Long fall.  Starts as a 17-bit-poly scream ($8) and, at row 10, switches
; distortion to $4 (5-bit then 4-bit poly, De Re's "missing engine") for the
; death rattle.  Timbre change costs nothing because AUDC is one byte.
e_death
        dta b($10),b($89)   ;  1862.9Hz  vol 9  17poly(explode)
        dta b($14),b($89)   ;  1508.0Hz  vol 9  17poly(explode)
        dta b($18),b($88)   ;  1266.7Hz  vol 8  17poly(explode)
        dta b($1E),b($88)   ;  1021.6Hz  vol 8  17poly(explode)
        dta b($24),b($88)   ;   855.9Hz  vol 8  17poly(explode)
        dta b($2C),b($87)   ;   703.7Hz  vol 7  17poly(explode)
        dta b($34),b($87)   ;   597.5Hz  vol 7  17poly(explode)
        dta b($3E),b($86)   ;   502.7Hz  vol 6  17poly(explode)
        dta b($4A),b($86)   ;   422.2Hz  vol 6  17poly(explode)
        dta b($58),b($85)   ;   355.8Hz  vol 5  17poly(explode)
        dta b($68),b($45)   ;   301.6Hz  vol 5  5+4poly(engine)  <- rattle timbre
        dta b($7A),b($44)   ;   257.5Hz  vol 4  5+4poly(engine)
        dta b($8E),b($43)   ;   221.5Hz  vol 3  5+4poly(engine)
        dta b($A4),b($42)   ;   191.9Hz  vol 2  5+4poly(engine)
        dta b($C0),b($41)   ;   164.1Hz  vol 1  5+4poly(engine)
        dta b($E0),b($40)   ;   140.7Hz  vol 0  5+4poly(engine)

; ---- 6. FIREBALL LAUNCH (whoosh) -- voice C, 8 frames ----------------------
; Distortion $0 (5-bit then 17-bit) is De Re's literal "air / steam" setting.
; Rate RISES 646 -> 2111 Hz as the thing accelerates away from you.
e_fbl
        dta b($30),b($03)   ;   646.3Hz  vol 3  5+17poly(air)
        dta b($28),b($06)   ;   772.4Hz  vol 6  5+17poly(air)
        dta b($22),b($08)   ;   904.8Hz  vol 8  5+17poly(air)
        dta b($1C),b($08)   ;  1092.0Hz  vol 8  5+17poly(air)
        dta b($16),b($07)   ;  1376.9Hz  vol 7  5+17poly(air)
        dta b($12),b($05)   ;  1666.8Hz  vol 5  5+17poly(air)
        dta b($0E),b($03)   ;  2111.2Hz  vol 3  5+17poly(air)
        dta b($08),b($00)   ;  3518.7Hz  vol 0  5+17poly(air)

; ---- 7. FIREBALL IMPACT -- voice A, 8 frames -------------------------------
; The shotgun's little brother: same 16-bit noise architecture, lower peak,
; faster collapse.  N 300 -> 8000 = rate 2888 -> 111 Hz.
e_fbhit
        dta b($2C),b($01),b($8C)   ; N=300    2888.4Hz  vol 12 17poly(explode)
        dta b($E0),b($01),b($8B)   ; N=480    1820.8Hz  vol 11 17poly(explode)
        dta b($F8),b($02),b($89)   ; N=760    1156.1Hz  vol 9  17poly(explode)
        dta b($B0),b($04),b($87)   ; N=1200    734.7Hz  vol 7  17poly(explode)
        dta b($6C),b($07),b($85)   ; N=1900    465.0Hz  vol 5  17poly(explode)
        dta b($B8),b($0B),b($84)   ; N=3000    294.9Hz  vol 4  17poly(explode)
        dta b($C0),b($12),b($82)   ; N=4800    184.5Hz  vol 2  17poly(explode)
        dta b($40),b($1F),b($80)   ; N=8000    110.7Hz  vol 0  17poly(explode)

; ---- 8. DOOR OPEN STINGER -- 12 frames, TWO voices -------------------------
; Voice A: hydraulic grind.  4-bit poly ($C) on the 16-bit pair, N falling
; 6000 -> 1200 so the motor SPEEDS UP (148 -> 735 Hz) as the door lifts.
; Voice B is layered on top by follow-up slot 1 with a 1-frame delay: the
; rumble leads by 20 ms, the clatter lands on it.  That is the layered attack,
; and it deliberately leaves voice C free -- doors in this game open onto
; monsters that growl the instant they see you.
e_door
        dta b($70),b($17),b($C4)   ; N=6000    147.6Hz  vol 4  4poly(razor)
        dta b($50),b($14),b($C7)   ; N=5200    170.3Hz  vol 7  4poly(razor)
        dta b($30),b($11),b($C9)   ; N=4400    201.2Hz  vol 9  4poly(razor)
        dta b($74),b($0E),b($CA)   ; N=3700    239.2Hz  vol 10 4poly(razor)
        dta b($1C),b($0C),b($CA)   ; N=3100    285.4Hz  vol 10 4poly(razor)
        dta b($28),b($0A),b($CA)   ; N=2600    340.1Hz  vol 10 4poly(razor)
        dta b($98),b($08),b($C9)   ; N=2200    401.8Hz  vol 9  4poly(razor)
        dta b($3A),b($07),b($C9)   ; N=1850    477.5Hz  vol 9  4poly(razor)
        dta b($40),b($06),b($C8)   ; N=1600    551.8Hz  vol 8  4poly(razor)
        dta b($78),b($05),b($C7)   ; N=1400    630.2Hz  vol 7  4poly(razor)
        dta b($E2),b($04),b($C5)   ; N=1250    705.4Hz  vol 5  4poly(razor)
        dta b($B0),b($04),b($C0)   ; N=1200    734.7Hz  vol 0  4poly(razor)

; Voice B half of the door: a ratchet.  AUDF alternates hard between a high
; tick and a low knock so the ear hears a mechanism turning, not a tone.
e_doorclk
        dta b($0C),b($C6)   ;  2436.1Hz  vol 6  4poly(razor)
        dta b($60),b($C3)   ;   326.5Hz  vol 3  4poly(razor)
        dta b($0E),b($C6)   ;  2111.2Hz  vol 6  4poly(razor)
        dta b($58),b($C3)   ;   355.8Hz  vol 3  4poly(razor)
        dta b($10),b($C6)   ;  1862.9Hz  vol 6  4poly(razor)
        dta b($50),b($C3)   ;   391.0Hz  vol 3  4poly(razor)
        dta b($12),b($C5)   ;  1666.8Hz  vol 5  4poly(razor)
        dta b($48),b($C3)   ;   433.8Hz  vol 3  4poly(razor)
        dta b($14),b($C4)   ;  1508.0Hz  vol 4  4poly(razor)
        dta b($40),b($C2)   ;   487.2Hz  vol 2  4poly(razor)
        dta b($16),b($C3)   ;  1376.9Hz  vol 3  4poly(razor)
        dta b($00),b($C0)   ; 31668.7Hz  vol 0  4poly(razor)

; ---- 9. PLAYER PAIN GRUNT -- voice C, 6 frames -----------------------------
; Distortion $4 (5-then-4-bit poly, "missing engine") is a gritty rasp that is
; texturally distinct from every enemy sound, so you always know it is YOU.
; Priority 200 = top of voice C: your own pain always cuts through.
e_pain
        dta b($50),b($49)   ;   391.0Hz  vol 9  5+4poly(engine)
        dta b($5C),b($49)   ;   340.5Hz  vol 9  5+4poly(engine)
        dta b($6A),b($47)   ;   296.0Hz  vol 7  5+4poly(engine)
        dta b($78),b($45)   ;   261.7Hz  vol 5  5+4poly(engine)
        dta b($88),b($43)   ;   231.2Hz  vol 3  5+4poly(engine)
        dta b($9A),b($40)   ;   204.3Hz  vol 0  5+4poly(engine)

; ---- 10. ITEM PICKUP -- voice B, 5 frames, a clean two-note blip -----------
e_pickup
        dta b($20),b($A8)   ;   959.7Hz  vol 8  PURE TONE
        dta b($20),b($A8)   ;   959.7Hz  vol 8  PURE TONE
        dta b($10),b($A8)   ;  1862.9Hz  vol 8  PURE TONE
        dta b($10),b($A6)   ;  1862.9Hz  vol 6  PURE TONE
        dta b($10),b($A3)   ;  1862.9Hz  vol 3  PURE TONE
        dta b($10),b($A0)   ;  1862.9Hz  vol 0  PURE TONE  release

; ---- 11. AMBIENT DRONE -- voice A, 16 rows x HOLD 8 = 128 frames (2.56 s) --
; Pure tone on the 16-bit pair at volume 3, N breathing 8600 -> 7220 -> 8700,
; i.e. 103 -> 123 -> 102 Hz.  A slow sub-bass that never resolves.  It is
; restarted automatically by audio_vbi every time voice A falls idle, so it
; loops forever and it costs ZERO dedicated channels.  Pitched at ~110 Hz
; rather than the ~55 Hz the 16-bit mode can reach because a TV speaker rolls
; off below that -- see the hardware-verification list.
e_drone
        dta b($98),b($21),b($A3)   ; N=8600    103.0Hz  vol 3  PURE TONE
        dta b($D0),b($20),b($A3)   ; N=8400    105.5Hz  vol 3  PURE TONE
        dta b($D6),b($1F),b($A3)   ; N=8150    108.7Hz  vol 3  PURE TONE
        dta b($DC),b($1E),b($A3)   ; N=7900    112.1Hz  vol 3  PURE TONE
        dta b($00),b($1E),b($A3)   ; N=7680    115.4Hz  vol 3  PURE TONE
        dta b($38),b($1D),b($A3)   ; N=7480    118.4Hz  vol 3  PURE TONE
        dta b($98),b($1C),b($A3)   ; N=7320    121.0Hz  vol 3  PURE TONE
        dta b($34),b($1C),b($A3)   ; N=7220    122.7Hz  vol 3  PURE TONE
        dta b($98),b($1C),b($A3)   ; N=7320    121.0Hz  vol 3  PURE TONE
        dta b($38),b($1D),b($A3)   ; N=7480    118.4Hz  vol 3  PURE TONE
        dta b($00),b($1E),b($A3)   ; N=7680    115.4Hz  vol 3  PURE TONE
        dta b($DC),b($1E),b($A3)   ; N=7900    112.1Hz  vol 3  PURE TONE
        dta b($D6),b($1F),b($A3)   ; N=8150    108.7Hz  vol 3  PURE TONE
        dta b($D0),b($20),b($A3)   ; N=8400    105.5Hz  vol 3  PURE TONE
        dta b($98),b($21),b($A3)   ; N=8600    103.0Hz  vol 3  PURE TONE
        dta b($FC),b($21),b($A3)   ; N=8700    101.8Hz  vol 3  PURE TONE
audio_end
