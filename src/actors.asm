; ============================================================================
; ABYSS -- actors.asm : enemy AI + actor state machine  (the HUSK)
;
; Owns ZP $00D0-$00DF (persistent) and $00F0-$00FF (scratch, caller-saves).
; Actor table at AC_BASE ($7800-$786F), module vars $7870-$787F,
; constant tables $7880-$78E9.  Move all three with AC_BASE alone.
;
; actors_update is called ONCE PER RENDER TICK (~15 Hz).  All state timers are
; measured in 50 Hz VBLANK frames and are decremented by the number of frames
; that actually elapsed since the previous call (read from RTCLOK+2, $14).
; That decouples every gameplay duration from the render rate: the 20-frame
; telegraph is 0.40 s of wall clock whatever the frame rate does.
; ============================================================================

RTCLK   = $14                   ; OS RTCLOK LSB, +1 every VBLANK (50 Hz PAL)
VCOUNT  = $D40B                 ; 1 unit = 2 scanlines = 228 machine cycles

; ---- actor table: structure of arrays, 8 slots, one byte per slot ----------
; Slot 0..5 = enemies, slot 6..7 = projectiles.
ACTMAX  = 8
AC_BASE = $7800                 ; << the ONE address to move the table
AC_VARS = AC_BASE+$78           ; module variables that do not need ZP
AC_TABS = AC_BASE+$90           ; constant tables (loaded from the XEX)
AC_XLO  = AC_BASE+$00           ; world X, 8.8 fixed, low  (fraction)
AC_XHI  = AC_BASE+$08           ; world X, high = map cell column
AC_YLO  = AC_BASE+$10           ; world Y, low
AC_YHI  = AC_BASE+$18           ; world Y, high = map cell row
AC_TYPE = AC_BASE+$20           ; 0 empty, 1 HUSK, 2 FIREBALL
AC_FRAME= AC_BASE+$28           ; sprite pose index (see FR_* below)
AC_STATE= AC_BASE+$30           ; ST_*
AC_TIMER= AC_BASE+$38           ; state timer, 50 Hz frames, counts down to 0
AC_HP   = AC_BASE+$40           ; health
AC_FACE = AC_BASE+$48           ; facing, 0..255 = full circle (engine angles)
AC_TGT  = AC_BASE+$50           ; enemy: $FF = player, 0..5 = actor (infight)
                                ; fireball: OWNER slot ($FF = player weapon)
AC_TGTT = AC_BASE+$58           ; infight countdown, in RENDER ticks
AC_ANIM = AC_BASE+$60           ; walk-cycle pacing / telegraph start stamp
AC_LOS  = AC_BASE+$68           ; cached line-of-sight to player (0/1)
AC_CLK  = AC_BASE+$70           ; RTCLOK at this actor's last update

; ---- types ----------------------------------------------------------------
TY_NONE = 0
TY_HUSK = 1
TY_BALL = 2

; ---- states ---------------------------------------------------------------
ST_DORMANT = 0
ST_CHASE   = 1
ST_TELEG   = 2
ST_ATTACK  = 3
ST_RECOVER = 4
ST_PAIN    = 5
ST_MELEE   = 6
ST_DYING   = 7
ST_DEAD    = 8
ST_FLY     = 9

; ---- sprite poses (contract with the sprite renderer) ---------------------
FR_WALK0 = 0                    ; 0..3 walk cycle
FR_WIND  = 4                    ; telegraph windup
FR_FIRE  = 5                    ; attack release
FR_PAIN  = 6
FR_DIE0  = 7                    ; 7..11 = five death poses
FR_CORPSE= 12                   ; persistent, no collision
FR_GIB0  = 13                   ; 13..14 gib anim
FR_GIBS  = 15                   ; persistent gib pile

; ---- tunables (frames = 50 Hz) -------------------------------------------
HUSK_HP    = 60
TG_FRAMES  = 20                 ; NEVER below 18: the fairness contract
ATK_FRAMES = 6
REC_FRAMES = 12
PAIN_FRAMES= 6
MEL_FRAMES = 12
DIE_FRAMES = 40                 ; 5 poses x 8 frames
GIB_FRAMES = 12
PAIN_CHANCE= 200                ; /256
ATK_CHANCE = 24                 ; /256 per render tick, when LOS
BALL_DMG   = 12
MELEE_DMG  = 8
INFIGHT_T  = 125                ; render ticks
BALL_LIFE  = 250                ; RENDER ticks (safety net only)
WALK_PACE  = 6                  ; frames per walk-cycle step
SPD_HUSK   = 5                  ; 8.8 units per 50 Hz frame = 0.977 cell/s
ACT_R      = 64                 ; collision radius, 0.25 cell
MELEE_R    = 192                ; 0.75 cell
HIT_R      = 96                 ; fireball hit box half-width, 0.375 cell
DEADZ      = 40                 ; per-axis dead zone before an actor commits

; ---- debug / instrumentation counters -------------------------------------
DBG_AWAKE  = $0602
DBG_PHP    = $0603
DBG_A0ST   = $0604
DBG_A0TM   = $0605
DBG_A0HP   = $0606
DBG_TGLEN  = $0607              ; measured length of last telegraph, frames
DBG_BALLS  = $0608
DBG_PHIT   = $0609
DBG_A0FR   = $060A
DBG_TICK   = $060B
DBG_DT     = $060C
DBG_PAINS  = $060D
DBG_DEATH  = $060E
DBG_GIBS   = $060F
DBG_INF    = $0610
DBG_A0X    = $0611
DBG_A0Y    = $0612
DBG_A0LOS  = $0613
DBG_A6TY   = $0614
DBG_A6X    = $0615
DBG_A6Y    = $0616
DBG_A1ST   = $0617
DBG_MELEE  = $0618
DBG_A0TGT  = $0619
DBG_VC     = $061A              ; worst-case VCOUNT delta over actors_update
DBG_A0XL   = $061B
DBG_A0YL   = $061C
DBG_BLOCK  = $061D              ; wall collisions rejected (slide proof)
DBG_A6ST   = $061E
DBG_INWALL = $061F              ; MUST stay 0: actor centre inside a wall
DBG_VCMIN  = $0620              ; best-case (NMI-free) update time

; ---- zero page: 16 bytes only, $00D0-$00DF --------------------------------
; The frozen interface gives $00D0-$00EF to "sprites/actors".  The AI takes
; the low half; $00E0-$00EF is left for the sprite renderer.  ($00B0-$00CF is
; the game layer's -- game.asm already occupies $B0-$C8.)
        org $00D0
ai_dt       .ds 1               ; 50 Hz frames since last update (1..8)
ai_i        .ds 1               ; current actor index
ai_step     .ds 1               ; husk move step this tick
ai_step10   .ds 1               ; fireball move step this tick
ai_dxl      .ds 1               ; target - actor, signed 8.8
ai_dxh      .ds 1
ai_dyl      .ds 1
ai_dyh      .ds 1
ai_sx       .ds 1               ; 8-way heading, -1 / 0 / +1
ai_sy       .ds 1
ai_txl      .ds 1               ; resolved target position
ai_txh      .ds 1
ai_tyl      .ds 1
ai_tyh      .ds 1
ai_awake    .ds 1
ai_t0       .ds 1

; scratch, $F0-$FF
zmula    = $F0
zmulb    = $F1
zmrl     = $F2
zmrh     = $F3
zmtmp    = $F4
mp      = $F5                   ; +$F6
gx      = $F7                   ; map query cell x
gy      = $F8                   ; map query cell y
s0      = $F9
s1      = $FA
s2      = $FB
s3      = $FC
s4      = $FD
s5      = $FE
s6      = $FF

        .ifndef TESTMODE
TESTMODE = 0
        .endif
        .ifndef DEBUG           ; -d:DEBUG=0 drops the $0602+ counter block
DEBUG = 1
        .endif

; ===========================================================================
        org $B000               ; relocated: needs 2.6KB, clear of buffer B

; ---------------------------------------------------------------------------
actors_init
        lda #0
        ldx #ACTMAX-1
ai_clr
        sta AC_TYPE,x
        sta AC_STATE,x
        sta AC_TIMER,x
        sta AC_FRAME,x
        sta AC_ANIM,x
        sta AC_LOS,x
        sta AC_HP,x
        sta AC_TGTT,x
        sta AC_XLO,x
        sta AC_YLO,x
        sta AC_CLK,x
        dex
        bpl ai_clr
        lda #$FF
        ldx #ACTMAX-1
ai_clr2 sta AC_TGT,x
        dex
        bpl ai_clr2

        ldx #$20                ; wipe the debug block
        lda #0
ai_clr3 sta $0602,x
        dex
        bpl ai_clr3
        lda #255
        sta DBG_VCMIN

        lda #100
        sta ai_ph
        lda #$5A
        sta ai_seed
        lda #0
        sta ai_rr
        sta ai_awake
        lda #$FF
        sta ai_attacker
        lda RTCLK
        sta ai_lastclk
        jmp spawn_level

; ---------------------------------------------------------------------------
; spawn_husk: A = cell x, Y = cell y.  Uses the first free slot in 0..5.
spawn_husk
        sta ai_t0
        sty ai_t1
        ldx #0
sh_find
        lda AC_TYPE,x
        beq sh_got
        inx
        cpx #6
        bne sh_find
        rts
sh_got
        lda #TY_HUSK
        sta AC_TYPE,x
        lda #ST_DORMANT
        sta AC_STATE,x
        lda #HUSK_HP
        sta AC_HP,x
        lda #0
        sta AC_TIMER,x
        sta AC_FRAME,x
        sta AC_ANIM,x
        sta AC_LOS,x
        sta AC_TGTT,x
        lda #$80                ; centre of the cell
        sta AC_XLO,x
        sta AC_YLO,x
        lda ai_t0
        sta AC_XHI,x
        lda ai_t1
        sta AC_YHI,x
        lda #$FF
        sta AC_TGT,x
        lda #128                ; facing west by default
        sta AC_FACE,x
        lda RTCLK
        sta AC_CLK,x
        rts

; ---------------------------------------------------------------------------
; actors_update -- one call per render tick.
actors_update
        lda VCOUNT
        sta ai_vc0

        lda RTCLK               ; ---- elapsed 50 Hz frames, clamped 1..8
        sec
        sbc ai_lastclk
        bne au_dt1
        lda #1
au_dt1  cmp #9
        bcc au_dt2
        lda #8
au_dt2  sta DBG_DT
        lda RTCLK
        sta ai_lastclk

        asl DBG_DT              ; projectiles move every tick: step10 = dt*10
        lda DBG_DT
        asl
        asl
        clc
        adc DBG_DT
        sta ai_step10
        lsr DBG_DT

        jsr los_round_robin

        lda #0
        sta ai_awake
        ; ---- enemies are staggered: half the slots per tick.  Each carries
        ; its own RTCLOK stamp, so a skipped tick costs nothing in accuracy --
        ; the next update just sees twice the elapsed frames.
        lda ai_phase
        eor #1
        sta ai_phase
        tax
au_eloop
        stx ai_i
        lda AC_TYPE,x
        beq au_enext
        jsr husk_tick
au_enext
        ldx ai_i
        inx
        inx
        cpx #6
        bcc au_eloop

        ldx #6                  ; ---- projectiles: every tick, no stagger
au_ploop
        stx ai_i
        lda AC_TYPE,x
        beq au_pnext
        jsr ball_tick
au_pnext
        ldx ai_i
        inx
        cpx #ACTMAX
        bne au_ploop

        jsr count_awake

        inc DBG_TICK
        .if TESTMODE > 0
        jsr test_hook
        .endif
        .if DEBUG > 0
        jsr dbg_write
        .endif

        lda VCOUNT              ; elapsed real time over the whole update
        sec
        sbc ai_vc0
        bcs au_vc1
        clc
        adc #156                ; PAL VCOUNT wraps at 156
au_vc1  cmp DBG_VC
        bcc au_vc2
        sta DBG_VC
au_vc2  cmp DBG_VCMIN
        bcs au_vc3
        sta DBG_VCMIN
au_vc3  rts

; ---------------------------------------------------------------------------
count_awake                     ; live enemies that are neither dormant nor dead
        ldy #0
        ldx #5
ca_l    lda AC_TYPE,x
        cmp #TY_HUSK
        bne ca_n
        lda AC_STATE,x
        beq ca_n
        cmp #ST_DEAD
        beq ca_n
        iny
ca_n    dex
        bpl ca_l
        sty ai_awake
        rts

; ---------------------------------------------------------------------------
        .if DEBUG > 0
dbg_write
        lda ai_awake
        sta DBG_AWAKE
        lda ai_ph
        sta DBG_PHP
        lda AC_STATE+0
        sta DBG_A0ST
        lda AC_TIMER+0
        sta DBG_A0TM
        lda AC_HP+0
        sta DBG_A0HP
        lda AC_FRAME+0
        sta DBG_A0FR
        lda AC_XHI+0
        sta DBG_A0X
        lda AC_YHI+0
        sta DBG_A0Y
        lda AC_XLO+0
        sta DBG_A0XL
        lda AC_YLO+0
        sta DBG_A0YL
        lda AC_LOS+0
        sta DBG_A0LOS
        lda AC_TGT+0
        sta DBG_A0TGT
        lda AC_STATE+1
        sta DBG_A1ST
        lda AC_TYPE+6
        sta DBG_A6TY
        lda AC_XHI+6
        sta DBG_A6X
        lda AC_YHI+6
        sta DBG_A6Y
        lda AC_STATE+6
        sta DBG_A6ST
        rts
        .endif

; ---------------------------------------------------------------------------
; HUSK state machine.  X = slot.
husk_tick
        lda AC_STATE,x
        cmp #ST_DEAD
        bne ht_live
ht_rts0 rts
ht_live cmp #ST_DORMANT
        bne ht_awake
        jmp ht_dormant
ht_awake

        .if TESTMODE > 0 && TESTMODE < 9
        lda AC_XHI,x            ; assertion: an actor is never inside a wall
        and #31
        sta gx
        lda AC_YHI,x
        and #31
        sta gy
        jsr map_get
        beq ht_nw
        inc DBG_INWALL
ht_nw
        .endif

        lda RTCLK               ; ---- this actor's own elapsed frames
        sec
        sbc AC_CLK,x
        bne ht_dt1
        lda #1
ht_dt1  cmp #17
        bcc ht_dt2
        lda #16
ht_dt2  sta ai_dt
        lda RTCLK
        sta AC_CLK,x
        lda ai_dt               ; step = dt * 5  (1.0 cell/s at 50 Hz)
        asl
        asl
        clc
        adc ai_dt
        sta ai_step

        lda AC_TIMER,x          ; ---- age the state timer by real frames
        beq ht_t0
        sec
        sbc ai_dt
        bcs ht_t1
        lda #0
ht_t1   sta AC_TIMER,x
ht_t0
        lda AC_TGTT,x           ; ---- infight lease
        beq ht_disp
        dec AC_TGTT,x
        bne ht_disp
        lda #$FF
        sta AC_TGT,x

ht_disp
        lda AC_STATE,x
        cmp #ST_CHASE
        bne hd1
        jmp ht_chase
hd1     cmp #ST_TELEG
        bne hd2
        jmp ht_teleg
hd2     cmp #ST_RECOVER
        beq ht_timed
        cmp #ST_PAIN
        beq ht_timed
        cmp #ST_ATTACK
        beq ht_attack
        cmp #ST_MELEE
        bne hd3
        jmp ht_melee
hd3     cmp #ST_DYING
        bne ht_rts
        jmp ht_dying
ht_rts  rts

; ---- DORMANT: wake on cached line of sight --------------------------------
ht_dormant
        lda AC_LOS,x
        beq ht_rts
wake_x
        lda #ST_CHASE
        sta AC_STATE,x
        lda #0
        sta AC_TIMER,x
        sta AC_FRAME,x
        lda #WALK_PACE
        sta AC_ANIM,x
        rts

; ---- RECOVER / PAIN: run out then chase -----------------------------------
ht_timed
        lda AC_TIMER,x
        bne ht_rts
        jmp wake_x

; ---- ATTACK: the release pose, then recover -------------------------------
ht_attack
        lda AC_TIMER,x
        bne ht_rts
        lda #ST_RECOVER
        sta AC_STATE,x
        lda #REC_FRAMES
        sta AC_TIMER,x
        lda #FR_WALK0
        sta AC_FRAME,x
        rts

; ---- TELEGRAPH: fixed 20 frames, then spawn the fireball ------------------
ht_teleg
        lda AC_TIMER,x
        bne ht_rts
        lda RTCLK               ; measure what the telegraph actually cost
        sec
        sbc AC_ANIM,x
        sta DBG_TGLEN
        lda #ST_ATTACK
        sta AC_STATE,x
        lda #ATK_FRAMES
        sta AC_TIMER,x
        lda #FR_FIRE
        sta AC_FRAME,x
        jsr calc_delta
        jmp spawn_ball

; ---- MELEE: short telegraph then a claw -----------------------------------
ht_melee
        lda AC_TIMER,x
        bne ht_rts
        jsr calc_delta
        jsr in_melee
        bne ht_mel_miss
        lda ai_ph
        sec
        sbc #MELEE_DMG
        bcs ht_mel1
        lda #0
ht_mel1 sta ai_ph
        inc DBG_MELEE
ht_mel_miss
        lda #ST_RECOVER
        sta AC_STATE,x
        lda #REC_FRAMES
        sta AC_TIMER,x
        lda #FR_WALK0
        sta AC_FRAME,x
        rts

; ---- DYING: pose from the timer, then a persistent corpse -----------------
ht_rts2 rts
ht_dying
        lda AC_FRAME,x
        cmp #FR_GIB0
        bcs ht_gibbing
        lda #DIE_FRAMES         ; pose = (40 - timer) / 8, clamp 4
        sec
        sbc AC_TIMER,x
        lsr
        lsr
        lsr
        cmp #5
        bcc ht_d1
        lda #4
ht_d1   clc
        adc #FR_DIE0
        sta AC_FRAME,x
        lda AC_TIMER,x
        bne ht_rts2
        lda #FR_CORPSE
        sta AC_FRAME,x
        jmp ht_dead
ht_gibbing
        lda #GIB_FRAMES         ; pose = (12 - timer) / 8, clamp 1
        sec
        sbc AC_TIMER,x
        lsr
        lsr
        lsr
        cmp #2
        bcc ht_g1
        lda #1
ht_g1   clc
        adc #FR_GIB0
        sta AC_FRAME,x
        lda AC_TIMER,x
        bne ht_rts2
        lda #FR_GIBS
        sta AC_FRAME,x
ht_dead
        lda #ST_DEAD
        sta AC_STATE,x
        lda #$FF
        sta AC_TGT,x
        lda #0
        sta AC_TGTT,x
        sta AC_LOS,x
        rts

; ---- CHASE ----------------------------------------------------------------
ht_chase
        lda AC_ANIM,x           ; walk cycle
        sec
        sbc ai_dt
        bcs ht_c1
        lda AC_FRAME,x
        clc
        adc #1
        and #3
        sta AC_FRAME,x
        lda #WALK_PACE
ht_c1   sta AC_ANIM,x

        jsr calc_delta
        jsr in_melee
        bne ht_c_ranged
        lda #ST_MELEE           ; close enough to claw
        sta AC_STATE,x
        lda #MEL_FRAMES
        sta AC_TIMER,x
        lda #FR_WIND
        sta AC_FRAME,x
        rts
ht_c_ranged
        lda AC_TGT,x            ; only shoot at the player, and only in sight
        bpl ht_move
        lda AC_LOS,x
        beq ht_move
        jsr rnd8
        cmp #ATK_CHANCE
        bcs ht_move
        lda #ST_TELEG
        sta AC_STATE,x
        lda #TG_FRAMES
        sta AC_TIMER,x
        lda #FR_WIND
        sta AC_FRAME,x
        lda RTCLK
        sta AC_ANIM,x           ; stamp for the telegraph-length measurement
        rts
ht_move
        ; fall through to husk_move

; ---------------------------------------------------------------------------
; 8-way move toward the target, axis-separated so a blocked axis SLIDES.
husk_move
        lda ai_step
        ldy ai_sx
        beq hm_nodiag
        ldy ai_sy
        beq hm_nodiag
        lsr                     ; diagonal: 3/4 step, keeps the speed sane
        lsr
        sta s4
        lda ai_step
        sec
        sbc s4
hm_nodiag
        sta s4                  ; s4 = step for this tick

        lda ai_sx               ; ================= X axis
        beq hm_yaxis
        bmi hm_xneg
        lda AC_XLO,x
        clc
        adc s4
        sta s0
        lda AC_XHI,x
        adc #0
        sta s1
        lda s0
        clc
        adc #ACT_R
        lda s1
        adc #0
        jmp hm_xprobe
hm_xneg
        lda AC_XLO,x
        sec
        sbc s4
        sta s0
        lda AC_XHI,x
        sbc #0
        sta s1
        lda s0
        sec
        sbc #ACT_R
        lda s1
        sbc #0
hm_xprobe
        and #31
        sta gx
        lda AC_YHI,x
        and #31
        sta gy
        jsr map_get
        beq hm_xok
        inc DBG_BLOCK
        jmp hm_yaxis
hm_xok
        lda s0
        sta AC_XLO,x
        lda s1
        sta AC_XHI,x

hm_yaxis
        lda ai_sy               ; ================= Y axis
        beq hm_face
        bmi hm_yneg
        lda AC_YLO,x
        clc
        adc s4
        sta s0
        lda AC_YHI,x
        adc #0
        sta s1
        lda s0
        clc
        adc #ACT_R
        lda s1
        adc #0
        jmp hm_yprobe
hm_yneg
        lda AC_YLO,x
        sec
        sbc s4
        sta s0
        lda AC_YHI,x
        sbc #0
        sta s1
        lda s0
        sec
        sbc #ACT_R
        lda s1
        sbc #0
hm_yprobe
        and #31
        sta gy
        lda AC_XHI,x
        and #31
        sta gx
        jsr map_get
        beq hm_yok
        inc DBG_BLOCK
        jmp hm_face
hm_yok
        lda s0
        sta AC_YLO,x
        lda s1
        sta AC_YHI,x

hm_face                         ; facing = the 8-way heading actually chosen
        lda ai_sy               ; index = (sy+1)*3 + (sx+1)
        clc
        adc #1
        sta s5
        asl
        clc
        adc s5
        sta s5
        lda ai_sx
        clc
        adc #1                  ; $FF+1 = 0, which is exactly what we want
        clc
        adc s5
        tay
        lda FACE8,y
        bmi hm_rts              ; $FF = standing still, keep the old facing
        sta AC_FACE,x
hm_rts  rts

; ---------------------------------------------------------------------------
; calc_delta: X = slot -> ai_dx*/ai_dy* (target - actor, signed 8.8)
;             plus ai_sx/ai_sy in {-1,0,+1} with a dead zone.
calc_delta
        jsr get_target
        lda ai_txl
        sec
        sbc AC_XLO,x
        sta ai_dxl
        lda ai_txh
        sbc AC_XHI,x
        sta ai_dxh
        lda ai_tyl
        sec
        sbc AC_YLO,x
        sta ai_dyl
        lda ai_tyh
        sbc AC_YHI,x
        sta ai_dyh

        lda ai_dxl
        sta s0
        lda ai_dxh
        sta s1
        jsr sign_of
        sta ai_sx
        lda ai_dyl
        sta s0
        lda ai_dyh
        sta s1
        jsr sign_of
        sta ai_sy
        rts

; s1:s0 signed 8.8 -> A = -1/0/+1 with a DEADZ dead zone.  X preserved.
sign_of
        lda s1
        bmi so_neg
        bne so_pos
        lda s0
        cmp #DEADZ
        bcc so_zero
so_pos  lda #1
        rts
so_neg
        cmp #$FF
        bne so_negf
        lda s0
        cmp #256-DEADZ
        bcs so_zero
so_negf lda #$FF
        rts
so_zero lda #0
        rts

; ---------------------------------------------------------------------------
; get_target: X = slot -> ai_tx*/ai_ty*.  Falls back to the player if the
; infight target has died or the slot was recycled.
get_target
        lda AC_TGT,x
        bmi gt_player
        tay
        lda AC_TYPE,y
        cmp #TY_HUSK
        bne gt_revert
        lda AC_STATE,y
        cmp #ST_DYING
        bcs gt_revert
        lda AC_XLO,y
        sta ai_txl
        lda AC_XHI,y
        sta ai_txh
        lda AC_YLO,y
        sta ai_tyl
        lda AC_YHI,y
        sta ai_tyh
        rts
gt_revert
        lda #$FF
        sta AC_TGT,x
        lda #0
        sta AC_TGTT,x
gt_player
        lda px_lo
        sta ai_txl
        lda px_hi
        sta ai_txh
        lda py_lo
        sta ai_tyl
        lda py_hi
        sta ai_tyh
        rts

; ---------------------------------------------------------------------------
; in_melee: uses ai_dx*/ai_dy*.  Returns Z=1 (A=0) when inside MELEE_R.
in_melee
        lda ai_dxl
        sta s0
        lda ai_dxh
        sta s1
        lda #MELEE_R
        sta s2
        jsr absless
        bne im_out
        lda ai_dyl
        sta s0
        lda ai_dyh
        sta s1
        lda #MELEE_R
        sta s2
        jmp absless
im_out  rts

; |s1:s0| < s2 ?  A=0/Z=1 yes, A=1 no.  X and Y preserved.
absless
        lda s1
        beq al_pos
        cmp #$FF
        bne al_out
        lda #0
        sec
        sbc s0                  ; 256 - lo  =  |v|  for the $FFxx range
        beq al_out
        jmp al_cmp
al_pos  lda s0
al_cmp  cmp s2
        bcc al_in
al_out  lda #1
        rts
al_in   lda #0
        rts

; ---------------------------------------------------------------------------
; map_get: gx/gy (already masked 0..31) -> A = map cell, Z=1 when open.
; X preserved, Y clobbered.
map_get
        ldy gy
        lda MAPROW_LO,y
        sta mp
        lda MAPROW_HI,y
        sta mp+1
        ldy gx
        lda (mp),y
        rts

; ---------------------------------------------------------------------------
; rnd8: 8-bit LFSR.  Deterministic, so traces are reproducible.
rnd8
        lda ai_seed
        asl
        bcc rn1
        eor #$1D
rn1     sta ai_seed
        rts

; ---------------------------------------------------------------------------
; LOS, staggered: exactly ONE actor is tested per render tick, round robin.
; A full test costs up to ~700 cycles; six of them would blow the whole
; budget, so the cache is up to 8 ticks (~0.5 s) stale.  Fireballs collide
; with walls, so a shot released just after cover is regained dies on the
; wall -- the staleness is self-correcting rather than unfair.
los_round_robin
        ldx ai_rr
        inx
        cpx #6
        bcc lrr1
        ldx #0
lrr1    stx ai_rr
        lda AC_TYPE,x
        cmp #TY_HUSK
        bne lrr_rts
        lda AC_STATE,x
        cmp #ST_DYING
        bcs lrr_rts
        jsr los_test
        ldx ai_rr
        sta AC_LOS,x
lrr_rts rts

; los_test: X = slot -> A = 1 if the player is visible.  Bresenham over cells.
los_test
        lda AC_XHI,x
        and #31
        sta ai_lx
        lda AC_YHI,x
        and #31
        sta ai_ly

        lda px_hi               ; dx = |px - x0|, sx
        and #31
        sec
        sbc ai_lx
        bcs lt_xp
        eor #$FF
        clc
        adc #1
        ldy #$FF
        sty ai_lsx
        jmp lt_xs
lt_xp   ldy #1
        sty ai_lsx
lt_xs   sta ai_ldx

        lda py_hi               ; dy = |py - y0|, sy
        and #31
        sec
        sbc ai_ly
        bcs lt_yp
        eor #$FF
        clc
        adc #1
        ldy #$FF
        sty ai_lsy
        jmp lt_ys
lt_yp   ldy #1
        sty ai_lsy
lt_ys   sta ai_ldy

        lda ai_ldx
        sec
        sbc ai_ldy
        sta ai_err
        lda #16
        sta ai_cnt

lt_loop
        lda ai_lx
        cmp px_hi
        bne lt_step
        lda ai_ly
        cmp py_hi
        bne lt_step
        lda #1                  ; reached the player's cell: visible
        rts
lt_step
        lda ai_err              ; e2 = 2*err   (|err| <= 31 so this fits)
        asl
        sta ai_t0

        clc                     ; if e2 > -dy  ->  step x
        adc ai_ldy
        bmi lt_noxs
        beq lt_noxs
        lda ai_err
        sec
        sbc ai_ldy
        sta ai_err
        lda ai_lx
        clc
        adc ai_lsx
        and #31
        sta ai_lx
lt_noxs
        lda ai_t0               ; if e2 < dx  ->  step y
        sec
        sbc ai_ldx
        bpl lt_noys
        lda ai_err
        clc
        adc ai_ldx
        sta ai_err
        lda ai_ly
        clc
        adc ai_lsy
        and #31
        sta ai_ly
lt_noys
        lda ai_lx
        sta gx
        lda ai_ly
        sta gy
        jsr map_get
        bne lt_blocked
        dec ai_cnt
        bne lt_loop
lt_blocked
        lda #0
        rts

; ---------------------------------------------------------------------------
; actors_alert: A = radius in cells.  Wakes every DORMANT husk whose cell is
; within that Chebyshev radius of the player.  Call it when the player fires
; (radius 3) or when a door opens (radius ~8).
actors_alert
        sta s5
        ldx #0
aa_loop
        lda AC_TYPE,x
        cmp #TY_HUSK
        bne aa_next
        lda AC_STATE,x
        bne aa_next             ; only DORMANT
        lda AC_XHI,x
        sec
        sbc px_hi
        bpl aa_x1
        eor #$FF
        clc
        adc #1
aa_x1   cmp s5
        beq aa_x2
        bcs aa_next
aa_x2   lda AC_YHI,x
        sec
        sbc py_hi
        bpl aa_y1
        eor #$FF
        clc
        adc #1
aa_y1   cmp s5
        beq aa_y2
        bcs aa_next
aa_y2   jsr wake_x
aa_next
        inx
        cpx #6
        bne aa_loop
        rts

; ---------------------------------------------------------------------------
; actor_damage: X = actor slot, A = damage.
; ai_attacker selects the source: $FF = the player (default), 0..5 = an actor,
; which triggers the infight retarget.  Reset to $FF on exit.
actor_damage
        sta s5
        lda AC_TYPE,x
        cmp #TY_HUSK
        bne ad_out2
        lda AC_STATE,x
        cmp #ST_DYING
        bcc ad_go
ad_out2 rts
ad_go

        lda ai_attacker         ; ---- INFIGHT: whoever hurt me is now the enemy
        bmi ad_nofi
        cpx ai_attacker
        beq ad_nofi
        sta AC_TGT,x
        lda #INFIGHT_T
        sta AC_TGTT,x
        inc DBG_INF
ad_nofi
        lda AC_STATE,x          ; being shot wakes you up
        bne ad_awake
        jsr wake_x
ad_awake
        lda AC_HP,x
        sta s6                  ; health before the hit
        sec
        sbc s5
        bcs ad_hp
        lda #0
ad_hp   sta AC_HP,x
        bne ad_alive

        lda s6                  ; ---- dead.  GIB if the hit beat hp+30
        clc
        adc #30
        bcs ad_normal           ; hp+30 wrapped: nothing can exceed it
        cmp s5
        bcs ad_normal
        lda #GIB_FRAMES
        sta AC_TIMER,x
        lda #FR_GIB0
        sta AC_FRAME,x
        inc DBG_GIBS
        jmp ad_die
ad_normal
        lda #DIE_FRAMES
        sta AC_TIMER,x
        lda #FR_DIE0
        sta AC_FRAME,x
        inc DBG_DEATH
ad_die
        lda #ST_DYING
        sta AC_STATE,x
        jmp ad_end

ad_alive                        ; ---- PAIN: cancels telegraph and attack
        jsr rnd8
        cmp #PAIN_CHANCE
        bcs ad_end
        lda #ST_PAIN
        sta AC_STATE,x
        lda #PAIN_FRAMES
        sta AC_TIMER,x
        lda #FR_PAIN
        sta AC_FRAME,x
        inc DBG_PAINS
ad_end
        lda #$FF
        sta ai_attacker
ad_out  rts

; ---------------------------------------------------------------------------
; spawn_ball: X = shooter.  ai_dx*/ai_dy* must already point at the target.
spawn_ball
        jsr ai_atan2
        sta ai_t2
        ldy #6
        lda AC_TYPE+6
        beq sb_got
        ldy #7
        lda AC_TYPE+7
        beq sb_got
        rts
sb_got
        lda #TY_BALL
        sta AC_TYPE,y
        lda #ST_FLY
        sta AC_STATE,y
        lda #BALL_LIFE
        sta AC_TIMER,y
        lda #0
        sta AC_FRAME,y
        sta AC_HP,y
        sta AC_TGTT,y
        sta AC_ANIM,y
        sta AC_LOS,y
        lda ai_t2
        sta AC_FACE,y
        txa
        sta AC_TGT,y            ; owner
        lda AC_XLO,x
        sta AC_XLO,y
        lda AC_XHI,x
        sta AC_XHI,y
        lda AC_YLO,x
        sta AC_YLO,y
        lda AC_YHI,x
        sta AC_YHI,y
        inc DBG_BALLS
        rts

; ---------------------------------------------------------------------------
; ball_tick: X = slot.
bt_kill_j
        jmp bt_kill
ball_tick
        dec AC_TIMER,x
        beq bt_kill_j
        lda AC_FRAME,x
        eor #1
        sta AC_FRAME,x

        ldy AC_FACE,x           ; ---- advance along the launch angle
        lda RDX_LO,y
        sta s0
        lda RDX_HI,y
        sta s1
        lda ai_step10
        sta s2
        jsr ai_scale
        lda AC_XLO,x
        clc
        adc s3
        sta AC_XLO,x
        lda AC_XHI,x
        adc s4
        sta AC_XHI,x

        ldy AC_FACE,x
        lda RDY_LO,y
        sta s0
        lda RDY_HI,y
        sta s1
        lda ai_step10
        sta s2
        jsr ai_scale
        lda AC_YLO,x
        clc
        adc s3
        sta AC_YLO,x
        lda AC_YHI,x
        adc s4
        sta AC_YHI,x

        lda AC_XHI,x            ; ---- walls
        and #31
        sta gx
        lda AC_YHI,x
        and #31
        sta gy
        jsr map_get
        beq bt_wallok
        jmp bt_kill
bt_wallok
        lda px_lo               ; ---- the player
        sec
        sbc AC_XLO,x
        sta s0
        lda px_hi
        sbc AC_XHI,x
        sta s1
        lda #HIT_R
        sta s2
        jsr absless
        bne bt_actors
        lda py_lo
        sec
        sbc AC_YLO,x
        sta s0
        lda py_hi
        sbc AC_YHI,x
        sta s1
        lda #HIT_R
        sta s2
        jsr absless
        bne bt_actors
        lda AC_TGT,x            ; the player's own shots do not hurt him
        bpl bt_hitp
        jmp bt_kill
bt_hitp
        lda ai_ph
        sec
        sbc #BALL_DMG
        bcs bt_p1
        lda #0
bt_p1   sta ai_ph
        inc DBG_PHIT
        jmp bt_kill

bt_actors                       ; ---- other actors (this is the infight path)
        ldy #0
bt_a_loop
        sty s5
        lda AC_TGT,x            ; never hit the shooter
        cmp s5
        beq bt_a_next
        lda AC_TYPE,y
        cmp #TY_HUSK
        bne bt_a_next
        lda AC_STATE,y
        cmp #ST_DYING
        bcs bt_a_next
        lda AC_XLO,y
        sec
        sbc AC_XLO,x
        sta s0
        lda AC_XHI,y
        sbc AC_XHI,x
        sta s1
        lda #HIT_R
        sta s2
        jsr absless
        bne bt_a_next
        ldy s5
        lda AC_YLO,y
        sec
        sbc AC_YLO,x
        sta s0
        lda AC_YHI,y
        sbc AC_YHI,x
        sta s1
        lda #HIT_R
        sta s2
        jsr absless
        bne bt_a_next
        lda AC_TGT,x            ; the shooter becomes the victim's new enemy
        sta ai_attacker
        lda #0
        sta AC_TYPE,x           ; consume the fireball before the callback
        sta AC_STATE,x
        ldx s5
        lda #BALL_DMG
        jsr actor_damage
        ldx ai_i
        rts
bt_a_next
        ldy s5
        iny
        cpy #6
        bne bt_a_loop
        rts

bt_kill
        lda #0
        sta AC_TYPE,x
        sta AC_STATE,x
        rts

; ---------------------------------------------------------------------------
; ai_scale: s1:s0 = signed 8.8 unit vector component, s2 = scale (<=127).
;           -> s3 = signed delta, s4 = sign extension.  X preserved.
ai_scale
        lda s1
        bpl as_pos
        lda s0
        eor #$FF
        clc
        adc #1
        sta s0
        lda s1
        eor #$FF
        adc #0
        sta s1
        lda #$FF
        sta s5
        jmp as_go
as_pos  lda #0
        sta s5
as_go
        lda s1                  ; a unit vector's high byte is 0 or 1
        beq as_b0
        lda s2
        jmp as_b1
as_b0   lda #0
as_b1   sta s6
        lda s0
        sta zmula
        lda s2
        sta zmulb
        jsr ai_mul8
        lda zmrh                 ; (lo * scale) >> 8
        clc
        adc s6
        cmp #0
        beq as_zero
        ldy s5
        beq as_zero
        eor #$FF
        clc
        adc #1
        sta s3
        lda #$FF
        sta s4
        rts
as_zero sta s3
        lda #0
        sta s4
        rts

; ai_mul8: zmula * zmulb -> zmrh:zmrl, quarter-square via the engine's SQ tables.
; X preserved, Y clobbered.
ai_mul8
        clc
        lda zmula
        adc zmulb
        tay
        bcs am_hi
        lda SQ_LO,y
        sta zmtmp
        lda SQ_HI,y
        sta zmrh
        jmp am_diff
am_hi
        lda SQ_LO+256,y
        sta zmtmp
        lda SQ_HI+256,y
        sta zmrh
am_diff
        lda zmula
        sec
        sbc zmulb
        bcs am_pos
        eor #$FF
        clc
        adc #1
am_pos  tay
        lda zmtmp
        sec
        sbc SQ_LO,y
        sta zmrl
        lda zmrh
        sbc SQ_HI,y
        sta zmrh
        rts

; ---------------------------------------------------------------------------
; ai_atan2: ai_dx*/ai_dy* (signed 8.8) -> A = engine angle 0..255.
; X preserved.
ai_atan2
        lda #0
        sta s4                  ; bit0 = dx<0, bit1 = dy<0, bit2 = swapped
        lda ai_dxl
        sta s0
        lda ai_dxh
        sta s1
        bpl at_ax
        lda #1
        sta s4
        lda s0
        eor #$FF
        clc
        adc #1
        sta s0
        lda s1
        eor #$FF
        adc #0
        sta s1
at_ax
        lda ai_dyl
        sta s2
        lda ai_dyh
        sta s3
        bpl at_ay
        lda s4
        ora #2
        sta s4
        lda s2
        eor #$FF
        clc
        adc #1
        sta s2
        lda s3
        eor #$FF
        adc #0
        sta s3
at_ay
        lda s1                  ; swap so s1:s0 holds the larger magnitude
        cmp s3
        bcc at_swap
        bne at_nosw
        lda s0
        cmp s2
        bcs at_nosw
at_swap
        lda s4
        ora #4
        sta s4
        lda s0
        ldy s2
        sty s0
        sta s2
        lda s1
        ldy s3
        sty s1
        sta s3
at_nosw
at_red                          ; reduce both until the larger fits in 8 bits
        lda s1
        beq at_red_done
        lsr s1
        ror s0
        lsr s3
        ror s2
        jmp at_red
at_red_done
        lda s0
        bne at_div
        lda #0                  ; zero-length vector
        jmp at_fold
at_div
        lda s2                  ; dividend = ay << 5
        sta s5
        lda #0
        sta s6
        ldy #5
at_shl  asl s5
        rol s6
        dey
        bne at_shl
        ldy #8                  ; s6:s5 / s0 -> quotient in s5
at_dv   asl s5
        rol s6
        bcs at_sub
        lda s6
        cmp s0
        bcc at_nsub
at_sub  lda s6
        sec
        sbc s0
        sta s6
        inc s5
at_nsub dey
        bne at_dv
        lda s5
        cmp #33
        bcc at_look
        lda #32
at_look tay
        lda ATAN32,y
at_fold
        sta s5
        lda s4
        and #4
        beq at_f1
        lda #64
        sec
        sbc s5
        sta s5
at_f1   lda s4
        and #2
        beq at_f2
        lda #0
        sec
        sbc s5
        sta s5
at_f2   lda s4
        and #1
        beq at_f3
        lda #128
        sec
        sbc s5
        sta s5
at_f3   lda s5
        rts

; ===========================================================================
; test scaffolding
; ===========================================================================
        .if TESTMODE > 0
        icl 'actest.asm'
        .else
spawn_level
        lda #10
        ldy #5
        jsr spawn_husk
        lda #22
        ldy #10
        jsr spawn_husk
        lda #10
        ldy #22
        jsr spawn_husk
        rts
        .endif

; ===========================================================================
; constant tables
; ===========================================================================
        org AC_VARS
ai_ph       .ds 1               ; player health
ai_lastclk  .ds 1
ai_seed     .ds 1               ; PRNG
ai_rr       .ds 1               ; LOS round-robin cursor
ai_attacker .ds 1               ; damage source: $FF player, 0..5 actor
ai_vc0      .ds 1
ai_lx       .ds 1               ; LOS Bresenham walker
ai_ly       .ds 1
ai_ldx      .ds 1
ai_ldy      .ds 1
ai_lsx      .ds 1
ai_lsy      .ds 1
ai_err      .ds 1
ai_cnt      .ds 1
ai_t1       .ds 1
ai_t2       .ds 1
ai_phase    .ds 1               ; which half of the enemy slots runs this tick

        org AC_TABS
MAPROW_LO
        :32 dta <(MAPBASE + #*32)
MAPROW_HI
        :32 dta >(MAPBASE + #*32)
FACE8                           ; index (sy+1)*3 + (sx+1) -> engine angle
        dta 160,192,224
        dta 128,$FF,0
        dta 96,64,32
ATAN32
        dta 0,1,3,4,5,6,8,9,10,11,12,13,15,16,17,18
        dta 19,20,21,22,23,24,25,25,26,27,28,29,29,30,31,31
        dta 32
