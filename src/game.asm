; ============================================================================
; ABYSS -- game layer
; The 3D view redraws at ~14fps. EVERYTHING the player feels -- input, weapon
; animation, screen kick, HUD -- runs in the 50Hz VBI, decoupled from the
; render rate. That decoupling is what makes a 14fps engine feel deliberate
; instead of broken.
;
; Movement is momentum-based (DOOM's friction model), not Wolf3D's constant
; velocity: v = (v>>1) + a, so top speed = 2a with a ~0.26s spin-up and coast.
; ============================================================================
SETVBV  = $E45C
XITVBV  = $E462
PORTA   = $D300         ; read the hardware directly: no OS shadow, no latency
TRIG0   = $D010
; ---- game ZP ($B0-$CF per the interface contract) --------------------------
        org $00B0
vx_lo   .ds 1                   ; velocity, 8.8 signed, cells per render tick
vx_hi   .ds 1
vy_lo   .ds 1
vy_hi   .ds 1
inp     .ds 1                   ; stick latch, sampled at 50Hz
trig    .ds 1                   ; trigger latch (1 = pressed this frame)
trigprv .ds 1
wstate  .ds 1                   ; weapon state: 0 idle, else frames remaining
wkick   .ds 1                   ; screen kick in scanlines, decays at 50Hz
bobph   .ds 1                   ; weapon bob phase
health  .ds 1
armour  .ds 1
ammo    .ds 1
gt0     .ds 1
gt1     .ds 1
gt2     .ds 1
gnx_lo  .ds 1
gnx_hi  .ds 1
; back to code space (ladders occupy $2400-$26FF; RAMTAB starts $3000)
        org $3800
; ============================================================================
game_init
        ; Clear the game-scratch page FIRST. Nothing else writes `levelno` at
        ; boot -- it is only ever inc'd -- and itmgot/wonall/wondone are set
        ; only by the death and descend paths. On this emulator RAM comes up
        ; zeroed and it never mattered; a real Atari does not, and every one of
        ; those bytes indexes something: the level name, the item table, the
        ; hue triple, and the test that decides you have already won.
        lda #0
        ldx #0
_gi_clr sta $7A00,x
        inx
        bne _gi_clr

        lda #100
        sta health
        sta lasthp
        lda #0
        sta painfl
        lda #0
        sta armour
        sta vx_lo
        sta vx_hi
        sta vy_lo
        sta vy_hi
        sta wstate
        sta wkick
        sta bobph
        sta trigprv
        lda #50
        sta ammo
        ; install the DEFERRED VBI (vector 7). Vector 6 is the IMMEDIATE one:
        ; taking that and exiting via XITVBV skips the OS's own vblank work,
        ; which blanks the display and freezes the shadow registers.
        lda #7
        ldx #>vbi_handler
        ldy #<vbi_handler
        jsr SETVBV
        jsr audio_init
        jsr actors_init
        jsr spawn_actors
        jsr hud_init
        jmp dli_init
; ============================================================================
; vbi_handler -- 50Hz. Input latch, weapon animation, kick decay.
; Must stay light: it runs every frame regardless of render progress.
; ============================================================================
vbi_handler
        lda #<dli_1             ; re-arm the DLI chain EVERY frame: a single
        sta VDSLST              ; slipped DLI would otherwise desync it forever
        lda #>dli_1
        sta VDSLST+1
        jsr apply_seam          ; move the hue seam, if the last render asked.
                                ; Here and nowhere else: no scanline is being
                                ; drawn, so the DLI chain cannot be caught
                                ; half-patched.
        lda PORTA
        and #$0F                ; joystick 0 = low nibble, 0 = pressed
        sta inp
        lda TRIG0               ; 0 = pressed
        bne _notrig
        lda trigprv
        bne _trigdone           ; already held: not a new press
        lda #1
        sta trig                ; rising edge only -- one shot per pull
        lda #1
        sta trigprv
        jmp _trigdone
_notrig
        lda #0
        sta trigprv
_trigdone
        jsr run_clock           ; body is in the RAMTAB gap: game.asm has 53
                                ; bytes to $4000 and the clock is ~70
        lda vx_lo               ; walking? advance the weapon bob. Any motion
        ora vx_hi               ; at all counts -- the velocity is 8.8 signed
        ora vy_lo               ; and we only care that it is non-zero.
        ora vy_hi
        beq _nobob
        inc bobph
_nobob
        jsr vbi_fire            ; trigger -> boom + kick THIS video frame
        ; ---- weapon state machine (frames count DOWN from 52)
        lda wstate
        beq _wpn_idle
        dec wstate
_wpn_idle
        ; ---- screen kick decays every frame: 6 -> 5 -> ... -> 0
        lda wkick
        beq _nokick
        sec                     ; NOT `lsr`. Halving ran 6->3->1->0 in three
        sbc #1                  ; frames, 60ms, against an 88ms render period,
        sta wkick               ; so the kick was usually gone before the world
                                ; was next drawn -- measured live at the first
                                ; post-shot render as 0 on seven shots of
                                ; twenty. A linear decay spans two renders.
_nokick
        ; ---- victory: the world turns to gold
        lda wonall
        beq _notwon
        lda #$14                ; NOT $1C. The low nibble is OR'd into every
                                ; pixel -- not a floor -- so the surviving
                                ; luminance count is 16>>popcount: $1C (%1100)
                                ; keeps 4, $14 (%0100) keeps 8. The world still
                                ; turns to gold and you can still see the room
                                ; you won in.
        sta hceil
        sta hwall
        sta hfloor
        sta COLBK
        sta COLBKH              ; and the hardware register: the shadow alone
        lda #$12                ; the panel follows the card, not the level you
        sta hudcol              ; happened to win on -- THE MAW's green under a
        jmp _fldone             ; gold end card looked like a mistake
_notwon
        ; ---- death: the whole world sinks into red
        lda ai_ph
        bne _notdead
        ; ...and the gun goes down with you. A red wash on its own was not
        ; reading as death: the view was the ordinary view with a filter over
        ; it and the shotgun still held level and ready, which is the pose of a
        ; player who is fine. The kick offset already pushes the gun down the
        ; screen and clips it at VIEW_H, so dying just drives that offset to the
        ; bottom, one scanline per 50 Hz frame -- about half a second to slide
        ; out of frame. Nothing new to draw and no new state in the renderer.
        ldx deathfr
        cpx #WPN_ROWS+8
        bcs _dkeep
        inx
        stx deathfr
_dkeep  stx wkick               ; overrides the decay above, which has already run
        lda #$30
        sta hceil
        sta hwall
        sta hfloor
        sta COLBK
        sta COLBKH              ; and the hardware register: the shadow alone
        jmp _fldone             ; lands a frame late and the ceiling lags
_notdead
        ; ---- pain flash: health dropped since last frame -> the screen bleeds
        lda ai_ph
        cmp lasthp
        bcs _nopain
        lda #6
        sta painfl
        lda #5                  ; the gun jolts when YOU are hit, not only when
        sta wkick               ; you fire -- same kick path, same decay
        lda #SND_PAIN
        jsr audio_play
_nopain
        lda ai_ph
        sta lasthp
        lda painfl
        beq _nopainf
        dec painfl
        lda #$32                ; red-orange, SINGLE-BIT low nibble. The low
                                ; nibble is OR'd into every pixel, so the
                                ; surviving luminance count is 16>>popcount:
                                ; $3A (%1010) and $36 (%0110) both keep only 4
                                ; of 16, for six frames, every time you are
                                ; hit. %0010 keeps 8 and the same hue.
        sta hceil
        sta hwall
        sta hfloor
        sta COLBK
        sta COLBKH              ; and the hardware register: the shadow alone
        jmp _fldone             ; lands a frame late and the ceiling lags
_nopainf
        ; ---- muzzle flash: the first 3 frames of the shotgun cycle
        lda wstate
        beq _noflash
        cmp #49
        bcc _noflash
        ; THE FLASH TRICK: in GTIA 9 the pixel nibble ORs into COLBK's LOW
        ; nibble, so a non-zero low nibble raises the luminance FLOOR of every
        ; pixel on screen -- a whole-screen brightness flash for 4 register
        ; writes, which this mode is not supposed to be able to do at all.
        ; Decays over 3 frames so it reads as a blast, not a strobe.
        ; wstate is decremented ABOVE, so the frame a shot was fired on reads
        ; 51 here, not 52.
        ;
        ; The low nibble is OR'd into every pixel -- NOT a floor, which is what
        ; an earlier version of this comment claimed. That matters, because OR
        ; DESTROYS levels: the surviving count is 16 >> popcount(nibble). So
        ; $1E (%1110) leaves 2 luminances and the picture ceases to exist, and
        ; $1A (%1010) and $16 (%0110) leave 4 -- three quarters of the tonal
        ; range gone. Single-bit nibbles are the ones to use: $18, $14 and $12
        ; are %1000, %0100 and %0010, so every frame of the blast keeps 8.
        ; The first version of this wrote ONE value to all three bands, so the
        ; whole screen -- ceiling, wall, floor, gun and enemy -- became a single
        ; flat gold. It read as a screen-clear glitch rather than a flash,
        ; because the thing that makes a room look LIT is that it is still
        ; recognisably the same room. So the bands keep their own hues and only
        ; the luminance bit changes, and the bit is graded from the floor
        ; upward: the blast comes from a gun held at the bottom of the screen,
        ; so the floor takes the most light and holds it longest, and the
        ; ceiling is first to go dark again.
        ldy #0                  ; Y = flash frame 0 (brightest), 1, 2
        cmp #51
        beq _fl_set
        iny
        cmp #50
        beq _fl_set
        iny
_fl_set
        ldx levelno
        lda LVHUEC,x
        ora FLCEIL,y
        sta hceil
        sta COLBK
        sta COLBKH              ; hardware too, else the ceiling blazes one
        lda LVHUEW,x            ; frame AFTER the walls have already faded
        ora FLWALL,y
        sta hwall
        lda LVHUEF,x
        ora FLFLOR,y
        sta hfloor
        jmp _fldone
_noflash
        ldx levelno             ; each level gets its own hue triple. Until now
        lda LVHUEC,x            ; all four shipped 9/2/1 and the ceiling and
        sta hceil               ; floor ramps are baked immediates, so THE RED
        sta COLBK               ; CISTERN looked exactly like THE VESTIBULE.
        sta COLBKH              ; symmetry matters more here than anywhere: a
                                ; flash frame wrote the hardware directly, so
                                ; restoring only the shadow would leave the
                                ; ceiling lit for one frame after the blast
        lda LVHUEW,x
        sta hwall
        lda LVHUEF,x
        sta hfloor
        lda LVHUEH,x
        sta hudcol
_fldone
        jsr audio_vbi           ; audio steps at 50Hz, not at the render rate
        jsr hud_update
        jmp XITVBV
; ============================================================================
; fire -- called from the main loop when the trigger latch is set.
; Starts the shotgun cycle: kick and flash land THIS 50Hz frame.
; ============================================================================
; called FROM THE VBI: everything the player feels happens this video frame
vbi_fire
        lda intitle             ; the press that dismisses the title is not a
        bne _nofire             ; shot -- it must not spend a shell or kick
        lda trig
        beq _nofire
        lda #0
        sta trig
        lda wstate
        bne _nofire             ; still cycling: refire not allowed yet
        lda ammo
        beq _nofire
        dec ammo
        lda #52                 ; the DOOM shotgun cycle, in 50Hz frames
        sta wstate
        lda #6                  ; screen kick, decays in the VBI
        sta wkick
        lda #SND_SHOTGUN
        jsr audio_play          ; boom on THIS video frame, not the next render
        lda #1
        sta firereq             ; actor damage is deferred: the main loop owns it
_nofire
        rts

; called from the MAIN loop: mutates actor state, so it must not run in the VBI
do_fire
        lda wonall              ; the game is OVER. Fire started a new one only
        beq _df_notwon          ; in theory: do_fire fell through to the exit
        lda firereq             ; branch, next_level refused because there was
        beq _df_no              ; no level 5, and the player was left in a gold
        lda #0                  ; room forever with the trigger spending ammo
        sta firereq             ; into nothing. Now it plays again.
        sta wonall
        sta wondone
        sta levelno
        ldx #0
        jsr load_level          ; level 1's map is gone; fetch it back
        jmp _rl_go2
_df_notwon
        lda wondone             ; standing on the exit: fire to descend
        beq _df_norm
        lda firereq
        beq _df_no
        lda #0
        sta firereq
        jmp next_level
_df_norm
        lda firereq
        beq _df_no
        lda #0
        sta firereq
        lda ai_ph
        bne _df_alive
        jmp restart_level
_df_alive
        lda #3                  ; the shot wakes anything within 3 cells
        jsr actors_alert
        jmp do_hitscan
_df_no  rts
; ============================================================================
; move_player -- once per RENDER tick. Momentum + per-axis collision so the
; player slides along walls instead of sticking to them.
; ============================================================================
ACCEL   = 32                    ; 8.8: 0.125 cells/tick accel -> 0.25 top speed
COLL_R  = 72                    ; collision radius, 8.8 (~0.28 cells). Without
                                ; this the camera presses flat against walls.
move_player
        lda ai_ph
        bne _mp_alive
        rts                     ; dead: the world keeps rendering, you do not move
_mp_alive
        ; ---- turn (still snappy: turning is not momentum-damped)
        lda inp
        and #4                  ; left
        bne _nol
        lda pang
        sec
        sbc #4
        sta pang
_nol
        lda inp
        and #8                  ; right
        bne _nor
        lda pang
        clc
        adc #4
        sta pang
_nor
        ; ---- thrust along the facing vector
        lda inp
        and #1                  ; up = forward
        beq _fwd
        lda inp
        and #2                  ; down = back
        beq _back
        jmp _friction
_fwd
        ldx pang
        lda RDX_LO,x
        sta gt0
        lda RDX_HI,x
        sta gt1
        jsr _accum_x
        ldx pang
        lda RDY_LO,x
        sta gt0
        lda RDY_HI,x
        sta gt1
        jsr _accum_y
        jmp _friction
_back
        ldx pang
        lda RDX_LO,x
        eor #$FF
        sta gt0
        lda RDX_HI,x
        eor #$FF
        sta gt1
        inc gt0
        bne _b1
        inc gt1
_b1     jsr _accum_x
        ldx pang
        lda RDY_LO,x
        eor #$FF
        sta gt0
        lda RDY_HI,x
        eor #$FF
        sta gt1
        inc gt0
        bne _b2
        inc gt1
_b2     jsr _accum_y
_friction
        ; v = v>>1 + a  (already added a above); halve to bleed speed
        lda vx_hi
        cmp #$80
        ror vx_hi
        ror vx_lo
        lda vy_hi
        cmp #$80
        ror vy_hi
        ror vy_lo
        ; ---- X axis, with collision
        lda px_lo
        clc
        adc vx_lo
        sta gnx_lo
        lda px_hi
        adc vx_hi
        sta gnx_hi
        lda vx_hi               ; probe a body-radius ahead, not the centre
        bmi _rxneg
        lda gnx_lo
        clc
        adc #COLL_R
        lda gnx_hi
        adc #0
        jmp _rxset
_rxneg
        lda gnx_lo
        sec
        sbc #COLL_R
        lda gnx_hi
        sbc #0
_rxset
        sta gt0                 ; probe cell x
        lda py_hi
        sta gt1                 ; current cell y
        jsr cell_solid
        jsr check_cell
        bne _blockx
        lda gnx_lo
        sta px_lo
        lda gnx_hi
        sta px_hi
        jmp _doy
_blockx
        lda #0                  ; kill the velocity component, keep the other
        sta vx_lo
        sta vx_hi
_doy
        lda py_lo
        clc
        adc vy_lo
        sta gnx_lo
        lda py_hi
        adc vy_hi
        sta gnx_hi
        lda px_hi
        sta gt0
        lda vy_hi               ; same body radius on the Y axis
        bmi _ryneg
        lda gnx_lo
        clc
        adc #COLL_R
        lda gnx_hi
        adc #0
        jmp _ryset
_ryneg
        lda gnx_lo
        sec
        sbc #COLL_R
        lda gnx_hi
        sbc #0
_ryset
        sta gt1
        jsr cell_solid
        jsr check_cell
        bne _blocky
        lda gnx_lo
        sta py_lo
        lda gnx_hi
        sta py_hi
        rts
_blocky
        lda #0
        sta vy_lo
        sta vy_hi
        rts
_accum_x
        lda gt0                 ; scale the unit vector to ACCEL and add to v
        jsr _scale
        lda vx_lo
        clc
        adc gt0
        sta vx_lo
        lda vx_hi
        adc gt1
        sta vx_hi
        rts
_accum_y
        lda gt0
        jsr _scale
        lda vy_lo
        clc
        adc gt0
        sta vy_lo
        lda vy_hi
        adc gt1
        sta vy_hi
        rts
; gt1:gt0 (8.8 unit vector) -> scaled by ACCEL/256 (i.e. >>3 for ACCEL=32)
_scale
        ldx #3
_scl    lda gt1
        cmp #$80
        ror gt1
        ror gt0
        dex
        bne _scl
        rts
; ---- cell_solid: gt0 = cell x, gt1 = cell y -> A != 0 if wall -------------
cell_solid
        lda gt1
        and #7
        asl
        asl
        asl
        asl
        asl
        sta gt2
        lda gt0
        and #31
        ora gt2
        tax
        lda gt1
        and #31
        lsr
        lsr
        lsr
        clc
        adc #>MAPBASE
        sta a:_cs_op+2
_cs_op
        lda MAPBASE,x
        rts

; open_last -- blank the cell cell_solid probed last. X must be untouched.
open_last
        lda _cs_op+2
        sta _op_st+2
        lda #0
_op_st  sta MAPBASE,x
        rts

; check_cell -- A = the probed material. Doors open on touch, the exit wins.
; Returns with Z SET if the player may enter. (The caller branches on Z, so
; every path must end with a compare against A -- an rts preserves flags from
; whatever compared last, which is how this first went wrong.)
check_cell
        cmp #$08                ; plain door
        beq _cc_door
        cmp #$0C                ; exit switch
        beq _cc_exit
        cmp #$09                ; $09/$0A/$0B are the red, blue and yellow
        bcc _cc_plain           ; doors. The levels have authored them since
        cmp #$0C                ; they were written and the compiler flattened
        bcs _cc_plain           ; them to plain doors because nothing here could
        sec                     ; tell one from a wall. It can now.
        sbc #$09                ; A = 0 red, 1 blue, 2 yellow.
        beq _cc_k0              ; X MUST SURVIVE: open_last writes the cell
        cmp #1                  ; through it, and it still holds the index
        beq _cc_k1              ; cell_solid left there. Indexing bitmask with
        lda #4                  ; `tax` here opened a cell in the far column of
        bne _cc_kt              ; the same row instead of the door -- silently,
_cc_k1  lda #2                  ; and the door stayed shut for ever.
        bne _cc_kt
_cc_k0  lda #1
_cc_kt  and keys
        bne _cc_door            ; carrying it: opens like any other door
        lda #SND_DOORCLK        ; refused -- the latch, not the hinge
        jsr audio_play
        lda #1                  ; ...and it still blocks
        cmp #0
        rts
_cc_plain
        cmp #0                  ; ordinary cell: Z set iff open
        rts
_cc_door
        jsr open_last           ; it opens, but still blocks THIS tick so
        lda #SND_DOOR           ; there is a beat before you walk through
        jsr audio_play
        lda #$08
        cmp #0
        rts
_cc_exit
        lda #1
        sta wondone
        lda #0
        cmp #0                  ; walk into it freely
        rts
; ---- weapon ZP ------------------------------------------------------------
; Stash the code PC across the zero-page block. It used to resume at a
; hard-coded $3B00, and the day check_cell grew nine bytes past it the
; assembler quietly laid draw_crosshair on top of _cc_exit -- the exit stopped
; working and behaved as a plain wall, with no error and no crash. Resuming at
; the address the code actually reached makes that impossible.
_code_resume = *
        org $00C2
wsrc    .ds 2
wdst    .ds 2
wcount  .ds 1
wrow    .ds 1
wleft   .ds 1
dliidx  .ds 1
hceil   .ds 1
hwall   .ds 1
hfloor  .ds 1
hn0     .ds 1                   ; VBI-ONLY scratch. hud_num runs in the
hn1     .ds 1                   ; VBI and preempts move_player, so it must
hn2     .ds 1
; HARD LIMIT: $B0-$CF is game.asm's entire ZP allocation. actors.asm owns
; $D0-$DF and sprites own $E0-$EF. Anything added past here silently
; corrupts another module -- this has bitten twice already.
        ert * > $D0, "game.asm ZP overflowed into actors.asm ($D0-$DF)"
; NOTE: $B0-$CF is FULL. actors.asm owns $D0-$DF, so the hitscan scratch
; below lives in absolute RAM -- it runs once per shot, not per frame.
        org _code_resume
; ============================================================================
; draw_weapon -- blit the shotgun into the bottom of the framebuffer.
; Each row is (start_byte, count, data...), so this is a straight copy with no
; per-pixel mask test. The vertical offset comes from the 50Hz kick, so the
; gun reacts on the next VIDEO frame even though the world redraws at ~14fps.
; ============================================================================
draw_crosshair                  ; a 5-pixel cross at the true view centre.
        ; Byte 19 low nibble + byte 20 high nibble straddle pixels 39/40, which
        ; IS the centre of 80. Drawn AFTER the weapon so the gun cannot cover it.
        ldx #47
        lda ROWLO,x
        sta wdst
        lda ROWHI,x
        clc
        adc bufpg
        sta wdst+1
        ldy #19
        lda (wdst),y
        and #$F0                ; keep the left pixel, light the right one
        ora #$0F
        sta (wdst),y
        iny
        lda (wdst),y
        and #$0F
        ora #$F0
        sta (wdst),y
        ; vertical ticks two rows above and below
        ldx #45
        jsr _xh_tick
        ldx #49
_xh_tick
        lda ROWLO,x
        sta wdst
        lda ROWHI,x
        clc
        adc bufpg
        sta wdst+1
        ldy #19                 ; both halves of the centre, exactly as the
        lda (wdst),y            ; horizontal bar does. Lighting only byte 19 put
        and #$F0                ; the ticks a whole pixel left of the bar, so
        ora #$0B                ; the cross leaned and the aim point was a lie.
        sta (wdst),y
        iny
        lda (wdst),y
        and #$0F
        ora #$B0
        sta (wdst),y
        rts

BOBTAB                          ; one slow rise and fall per sixteen half-frames
        dta 0,0,1,1,2,2,3,3,3,3,2,2,1,1,0,0

draw_weapon
        lda wstate
        beq _wnorm
        cmp #49                 ; first 3 frames of the cycle = muzzle flash
        bcc _wnorm
        lda #<WPN_FLASH
        sta wsrc
        lda #>WPN_FLASH
        sta wsrc+1
        jmp _wgo
_wnorm
        lda #<WPN_NORMAL
        sta wsrc
        lda #>WPN_NORMAL
        sta wsrc+1
_wgo
        lda bobph               ; the walk bob, at half the VBI rate
        lsr
        and #15
        tax
        lda BOBTAB,x
        clc
        adc #WPN_TOPROW
        clc
        adc wkick               ; kick pushes the gun DOWN the screen
        sta wrow
        lda #WPN_ROWS
        sta wleft
_wrowloop
        ldy #0
        lda (wsrc),y            ; start byte within the row
        sta wdst                ; stash briefly
        iny
        lda (wsrc),y            ; count
        sta wcount
        lda wsrc                ; step past the 2-byte header
        clc
        adc #2
        sta wsrc
        bcc _wh
        inc wsrc+1
_wh
        lda wrow
        cmp #VIEW_H
        bcs _wclip              ; kicked past the bottom: consume, draw nothing
        ldx wrow                ; dest = row base + start
        lda ROWLO,x
        clc
        adc wdst
        sta wdst
        lda ROWHI,x
        adc bufpg               ; blit into whichever buffer is the back one
        sta wdst+1
        ldy wcount
        beq _wadv
        dey
_wcopy
        lda (wsrc),y
        sta (wdst),y
        dey
        bpl _wcopy
        jmp _wadv
_wclip
        lda #0                  ; nothing drawn, but still consume the data
_wadv
        lda wsrc                ; step past this row's pixels
        clc
        adc wcount
        sta wsrc
        bcc _wa
        inc wsrc+1
_wa
        inc wrow
        dec wleft
        bne _wrowloop
        rts
; ============================================================================
; Per-band hue via DLI.
; In GTIA 9 the pixel nibble is LUMINANCE and COLBK supplies the HUE for the
; whole screen -- so a hue change costs one register write and no pixels.
; Three bands (ceiling / wall / floor) turn a grey corridor into a lit space.
; COLBK's low nibble MUST stay 0: pixel data ORs into it.
; ============================================================================
VDSLST  = $0200
NMIEN   = $D40E
WSYNC   = $D40A
COLBKH  = $D01A
; Hue is per SCANLINE BAND, never per column -- one COLBK. So a level's
; identity has to come from its three band hues, and they are the cheapest
; per-level art in the build: twelve bytes.
_name_resume = *
        org $AA00               ; game.asm's own region ends at the display
; The levels have names and the player never saw one. The status band is four
; text rows and only the second carries anything, so the name goes on the third
; -- 128 bytes of table for the only place in the game that says where you are.
LVNAME
        dta d'         THE VESTIBULE          '
        dta d'        THE RED CISTERN         '
        dta d'        SILENT COLONNADE        '
        dta d'            THE MAW             '

_lv_resume = *
        org $AA80               ; game.asm's own region ends at the display
; load_level -- decode the level at index X and put the player at its own
; spawn. All four levels are packed now, indexed by level number directly, so
; X is simply `levelno`: descending increments it first, restarting does not,
; and finishing the game resets it to zero and reloads level 1.
load_level
        stx rl_lvl
        lda LVSOL_LO,x          ; solid plane -> MAPBASE
        sta rl_src
        lda LVSOL_HI,x
        sta rl_src+1
        lda #<MAPBASE
        sta rl_dst
        lda #>MAPBASE
        sta rl_dst+1
        jsr rle_decode

        ldx rl_lvl
        lda LVATR_LO,x          ; attribute plane -> ATTRBASE
        sta rl_src
        lda LVATR_HI,x
        sta rl_src+1
        lda #<ATTRBASE
        sta rl_dst
        lda #>ATTRBASE
        sta rl_dst+1
        jsr rle_decode

        ldx rl_lvl
        lda #$80                ; spawn at this level's own start
        sta px_lo
        sta py_lo
        lda LVSPX,x
        sta px_hi
        lda LVSPY,x
        sta py_hi
        lda LVANG,x
        sta pang
        rts
        ert * > $AB00, "load_level has grown into the hue tables at $AB00"
        org _lv_resume          ; lists, so this lives past the level names

        org $AA00 + 128         ; (re-anchor: the ert above guards $B000)
        ert * > $B000, "the level names have grown into actors.asm at $B000"
        org _name_resume        ; lists, and 128 bytes of text would not fit

; Atari hue numbers, named for what they actually render as, not for what the
; level is called: 0 grey, 1 gold, 2 orange, 3 red-orange, 4 magenta,
; 5 purple, 7 blue, 9 teal.
; Chosen so that no two levels read as the same room, and checked in
; verify.py against the palette: >=60 RGB separation between a level's own
; ceiling and wall, >=30 between its wall and floor, >=50 between any two
; levels' walls. THE RED CISTERN and THE MAW previously failed all three --
; measured at 49 and 33 internally, with L1 and L2's walls only 19 apart.
;
; These live at $AB00 rather than inline. Adding the panel-tint and flash-grade
; rows tipped game.asm's code region past the display lists at $4000 and the
; guard fired -- which is what it is for. Twenty-five bytes of pure table is the
; cheapest thing in the module to move somewhere there is room.
_hue_resume = *
        org $AB00
LVHUEC  dta $90,$80,$70,$30     ; ceiling: teal, blue, blue, BURNING RED
LVHUEW  dta $20,$40,$00,$60     ; wall:    orange, magenta, GREY stone, violet
LVHUEF  dta $10,$30,$10,$10     ; floor:   gold, red-orange, gold, dull gold
; The status panel used to be a hard-coded $02 -- a near-black bar that stayed
; identical under a red level, a magenta one, a grey one and a green one, so it
; read as an overlay glued onto the frame rather than part of the room. It now
; takes the level's WALL hue at luminance 2. In ANTIC 2 the characters take
; COLPF2's HUE and COLPF1's LUMINANCE, so one byte tints the panel AND the text
; together, and level 3's grey stone still lands on the old $02 by construction.
LVHUEH  dta $22,$42,$02,$62
; Muzzle-flash luminance bits, one row per band, indexed by flash frame 0..2.
; SINGLE BITS ONLY: the nibble is OR'd into every pixel, not floored, so the
; surviving luminance count is 16 >> popcount. %1110 leaves 2 levels and the
; picture stops existing; a single bit always leaves 8.
;
; The wall band's sequence is NOT a plain 8/4/2 decay, and the reason is
; measured rather than aesthetic. OR does not brighten, it COLLAPSES: 3|8 and
; 11|8 are both 11, so which pairs of luminances merge depends entirely on which
; bit you pick. Counting the husk's silhouette pixels that become identical to
; the wall pixel beside them, out of 194:
;
;       no flash   5      bit 8   5      bit 4  11      bit 2  23
;
; Bit 8 -- the BRIGHTEST step -- costs nothing at all, and the dim tail of the
; decay is what hides the enemy. A plain 8/4/2 therefore goes from the best
; value to the worst over the three frames of the one effect whose job is to
; show you what you just shot. The wall and floor hold the top bit an extra
; frame instead; the ceiling, which never has an enemy in front of it, decays
; normally and carries the sense of the light dying away.
; The FLOOR ranks the bits the OTHER WAY ROUND, for the same reason and with the
; opposite answer. The floor's own luminances run 6-11, and OR 8 maps 6 and 7 up
; to 14 and 15 while leaving 8-11 alone -- which folds the held weapon's tones
; into the floor's. Counting the weapon region's surviving horizontal edges:
;
;       bit 2  100%      bit 4  100%      bit 8  81%
;
; So the wall band wants the top bit and the floor band must not have it. The
; blast is physically brightest at the floor and is drawn dimmest there, because
; the two things a player must not lose sight of while firing are the enemy and
; their own gun, and those two live in different bands with different answers.
FLCEIL  dta $04,$02,$00
FLWALL  dta $08,$08,$08
FLFLOR  dta $04,$04,$02
; Per-enemy-type stats, indexed by AC_TYPE (0 unused, 1 husk, 2 fireball
; placeholder, 3 gunner, 4 spitter, 5 hulk). They live in their own org at
; $AC20 -- adding them here tipped this block into the title strings at $ABA0
; and the guard fired, which is what it is for. The philosophy is in
; spawn_actors: HP steps are whole point-blank shots, never inflation.
_typ_resume = *
        org $AC20
THP     dta 0,60,0,32,60,120
TATK    dta 0,24,0,40,48,12     ; /256 chance per tick, with line of sight
TMELEE  dta 0,8,0,4,6,16
TBALL   dta 0,12,0,10,8,16
        ert * > $B000, "type tables have grown into actors.asm at $B000"
        org _typ_resume

; The four status-band strings. They used to sit inline in the code region,
; each one parked between an `rts` and the next label so execution stepped over
; it. That is 128 bytes of pure text in the module's tightest 2 KB, and it is
; what finally pushed game.asm past the display lists at $4000.
;
; Internal character codes, NOT ASCII: 'A'-'Z' and '0'-'9' are ascii-32 and a
; space is 0. Every one of these is copied by a `cpx #32` loop, so every one
; MUST be exactly 32 characters -- won_msg was 31, so the banner's last column
; was reading the first opcode byte of the routine that followed it and drawing
; it as a glyph. It had shipped that way, visible only in the couple of seconds
; between reaching an exit and the next level loading, which is why no
; screenshot ever caught it.
hud_labels
        dta d'HEALTH      AMMO        ABYSS   '
win2_msg
        dta d'  YOU ESCAPED THE ABYSS         '
won_msg                         ; The one waiting state in normal play that
                                ; did NOT say what it was waiting for. The
                                ; title says PRESS FIRE TO DESCEND, death says
                                ; FIRE TO RETRY, the end card says FIRE AGAIN --
                                ; and the floor-cleared banner, which every
                                ; player meets three times a run, said only
                                ; FLOOR CLEARED - KILLS 005 and then waited
                                ; forever. Tony walked onto the exit, read it,
                                ; and reasonably concluded the game was stuck.
                                ; Kills digits land on the last three columns.
        dta d'FIRE TO DESCEND      KILLS      '
dead_msg
        dta d'  YOU DIED - FIRE TO RETRY      '
        ert * > $ABA0, "game.asm's table block has run into title.asm's at $ABA0"
        org _hue_resume

HUE_CEIL  = $90                 ; cold blue-grey overhead (level 1; the
                                ; tables above are what the game actually uses,
                                ; these remain for the DLI's initial arm)
HUE_WALL  = $20                 ; warm orange-brown: the hell corridor
HUE_FLOOR = $10                 ; dull gold underfoot
dli_init
        lda #0
        sta dliidx
        lda #<dli_1
        sta VDSLST
        lda #>dli_1
        sta VDSLST+1
        lda #HUE_CEIL
        sta hceil
        sta COLBK               ; shadow: the OS re-arms the top band each frame
        lda #HUE_WALL
        sta hwall
        lda #HUE_FLOOR
        sta hfloor
        lda #$02                ; dli_3 reads hudcol on the very first frame,
        sta hudcol              ; before any VBI has run: seed it with the old
                                ; fixed value rather than whatever RAM holds
        lda #$C0
        sta NMIEN               ; enable DLI + VBI NMIs
        rts
dli_1                           ; entering the wall band
        pha
        lda hwall
        sta WSYNC
        sta COLBKH
        lda #<dli_2             ; chain to the next handler
        sta VDSLST
        lda #>dli_2
        sta VDSLST+1
        pla
        rti
dli_2                           ; entering the floor band
        pha
        lda hfloor
        sta WSYNC
        sta COLBKH
        lda #<dli_3             ; next: hand over to the status band
        sta VDSLST
        lda #>dli_3
        sta VDSLST+1
        pla
        rti
; ============================================================================
; Status bar. The 3D view is GTIA mode 9, but PRIOR is a SCREEN-GLOBAL
; register -- so a text band underneath needs a DLI to clear the GTIA bits for
; those scanlines, and the OS restores GPRIOR at vblank for the next frame.
; ============================================================================
HUDRAM  = $7900                 ; moved: actors.asm owns $7800-$78FF
PRIOR   = $D01B
COLPF1H = $D017
COLPF2H = $D018
hud_init
        ldx #0
        lda #0
_hclr   sta HUDRAM,x
        sta HUDRAM+40,x
        sta HUDRAM+80,x
        sta HUDRAM+120,x
        inx
        cpx #40
        bne _hclr
        ldx #0                  ; fixed length: internal code 0 IS space, so a
_hlbl   lda hud_labels,x        ; zero terminator would stop at the first gap
        sta HUDRAM+40,x
        inx
        cpx #32
        bne _hlbl
        ; ---- the level's name on the row below
        lda levelno             ; name index = level * 32
        asl
        asl
        asl
        asl
        asl
        sta hn0
        ldx #0
_hnam   txa
        clc
        adc hn0
        tay
        lda LVNAME,y
        sta HUDRAM+80,x
        inx
        cpx #32
        bne _hnam
        rts
; hud_update -- called from the VBI so the numbers track at 50Hz
hud_update
        lda intitle             ; the title screen writes its own text row
        beq _hu_go
        rts
_hu_go  lda wonall
        beq _hu_nw
        ldx #0
_hu_w   lda win2_msg,x
        sta HUDRAM+40,x
        inx
        cpx #32
        bne _hu_w
        rts
_hu_nw
        lda wondone
        beq _hu_notwon
        ldx #0
_hu_won lda won_msg,x
        sta HUDRAM+40,x
        inx
        cpx #32
        bne _hu_won
        lda kills               ; the intermission tells you what the floor
        ldx #27                 ; cost them: digits at columns 27-29
        jmp hud_num             ; (tail call; hud_num is VBI-safe by design)
_hu_notwon
        lda ai_ph
        bne _hu_alive
        ldx #0
_hu_dead
        lda dead_msg,x
        sta HUDRAM+40,x
        inx
        cpx #32
        bne _hu_dead
        rts
_hu_alive
        lda ai_ph               ; actors.asm owns player health
        ldx #7                  ; column of the health value
        jsr hud_num
        lda ammo
        ldx #19
        jsr hud_num
        rts
; A = value 0..255, X = column -> three digits at HUDRAM+40+X
hud_num
        stx hn2
        ldy #0                  ; hundreds
_h100   cmp #100
        bcc _h10d
        sbc #100
        iny
        bne _h100
_h10d
        sty hn0
        ldy #0
_h10    cmp #10
        bcc _h1d
        sbc #10
        iny
        bne _h10
_h1d
        sty hn1
        clc
        adc #16                 ; internal code for '0'
        ldx hn2
        sta HUDRAM+42,x
        lda hn1
        clc
        adc #16
        sta HUDRAM+41,x
        lda hn0
        clc
        adc #16
        sta HUDRAM+40,x
        rts
dli_3                           ; leaving the 3D view: hand the band to text
        pha
        txa
        pha
        lda #$00
        sta WSYNC
        sta PRIOR               ; GTIA off for the status band
        lda #$0E                ; bright text
        sta COLPF1H
        lda hudcol              ; the level's own hue at luminance 2 (LVHUEH)
        sta COLPF2H
        lda #<dli_1             ; re-arm for the next frame
        sta VDSLST
        lda #>dli_1
        sta VDSLST+1
        pla
        tax
        pla
        rti


; ============================================================================
; do_hitscan -- the shotgun's trace, run from the MAIN loop (never the VBI:
; it mutates actor state, which actors_update owns).
; A single trace with distance-banded damage: DOOM's spread is implied, not
; simulated. Point blank deletes a husk outright -- that reliability IS the
; shotgun's identity.
; ============================================================================
HIT_CONE = 12                   ; +/-12/256 of a turn ~ +/-17 degrees
hs_best  = $7A00
hs_bslot = $7A01
hs_slot  = $7A02
hs_r     = $7A03
firereq  = $7A04
lasthp   = $7A05
painfl   = $7A06
wondone  = $7A07                ; 1 once the exit has been reached
deathfr  = $7A51                ; frames since death, drives the weapon drop
kills    = $7A52                ; husks put down this run; the end card shows it
runtick  = $7A53                ; 50 Hz frames since the last whole second
rsec0    = $7A54                ; run time held as THREE DIGITS, units first.
rsec1    = $7A55                ; Counting this way means no divide anywhere --
rsec2    = $7A56                ; the end card reads the digits straight out.
exitph   = $7A57                ; phase of the exit's pulse
exitlum  = $7A58                ; ...and the luminance the renderer reads
keys     = $7A59                ; bit 0 red, 1 blue, 2 yellow. Cleared per RUN,
                                ; not per level: a key is a trophy of the floor
                                ; it was found on and the next floor has its own.
hudcol   = $7A50                ; status-panel colour, set per level from LVHUEH.
                                ; Absolute RAM, not ZP: $C2-$CF is full, and
                                ; game.asm's ZP block ends hard against the
                                ; actor module at $D0. Read by dli_3 every
                                ; frame, written once per VBI.
itmgot   = $7A12                ; bitmask of collected items this level
intitle  = $7A14                ; 1 while the title screen owns the text row
rl_lvl   = $7A15                ; load_level's index, across the decoder
wonall   = $7A13                ; 1 once the last level's exit is reached                ; bitmask of collected items this level                ; 1 once the exit has been reached
levelno  = $7A09                ; 1 once the exit has been reached

do_hitscan
        lda #$FF
        sta hs_best             ; nearest hit so far
        sta hs_bslot
        ldx #0
_hs_loop
        lda AC_TYPE,x
        jsr is_enemy            ; any living enemy class stops the shot
        bne _hs_next
        lda AC_STATE,x
        cmp #ST_DYING
        bcs _hs_next            ; already dying or dead

        ; ---- delta to the actor, signed 8.8
        lda AC_XLO,x
        sec
        sbc px_lo
        sta ai_dxl
        lda AC_XHI,x
        sbc px_hi
        sta ai_dxh
        lda AC_YLO,x
        sec
        sbc py_lo
        sta ai_dyl
        lda AC_YHI,x
        sbc py_hi
        sta ai_dyh

        ; ---- inside the aim cone?
        stx hs_slot
        jsr ai_atan2            ; A = angle to the actor
        sec
        sbc pang                ; signed difference, wrapping
        clc
        adc #HIT_CONE
        cmp #HIT_CONE*2
        bcs _hs_next2           ; outside the cone

        ; ---- crude range: max(|dx|,|dy|) in whole cells
        lda ai_dxh
        bpl _hs_px
        eor #$FF
_hs_px  sta hs_r
        lda ai_dyh
        bpl _hs_py
        eor #$FF
_hs_py  cmp hs_r
        bcc _hs_r1
        sta hs_r
_hs_r1
        lda hs_r
        cmp hs_best
        bcs _hs_next2           ; something nearer already
        sta hs_best
        lda hs_slot
        sta hs_bslot
_hs_next2
        ldx hs_slot
_hs_next
        inx
        cpx #6                  ; enemy slots only
        bne _hs_loop

        lda hs_bslot
        cmp #$FF
        beq _hs_done            ; clean miss

        ; ---- distance-banded damage
        ldx hs_best
        lda #60                 ; <=2 cells: a husk dies outright
        cpx #3
        bcc _hs_dmg
        lda #28                 ; 3-5 cells
        cpx #6
        bcc _hs_dmg
        lda #12                 ; beyond that, a peppering
_hs_dmg
        ldx hs_bslot
        jsr actor_damage
_hs_done
        rts


; ============================================================================
restart_level                   ; back from the dead
        ; Restart the level you died ON. This used to reset levelno to 0 while
        ; leaving the map alone, so dying on level 2, 3 or 4 kept that level's
        ; geometry but respawned you at level 1's (4,6) -- a cell that is SOLID
        ; in both THE RED CISTERN and SILENT COLONNADE, so the player was
        ; dropped inside a wall with the status bar naming the wrong level.
        ldx levelno             ; reload the level you died on, whichever it is
        jsr load_level
_rl_go2                         ; the victory restart joins here, having
        jsr actors_init         ; already reloaded level 1
        jsr spawn_actors
        lda #0
        sta itmgot
        sta wonall
        sta kills               ; a fresh run earns its own tally
        sta keys                ; ...and earns its own keys. This was cleared
                                ; only by the boot-time wipe of $7A00, so the
                                ; ring you found on THE RED CISTERN stayed on
                                ; your belt through death, through victory, and
                                ; into every later run of the same session --
                                ; the red and yellow doors simply stood open on
                                ; a game you had just started. Invisible to the
                                ; sweep, which boots a fresh machine per check.
        lda #100
        sta ai_ph
        sta lasthp
        lda #50
        sta ammo
        lda #0
        sta painfl
        sta wondone
        sta wstate
        sta wkick
        sta deathfr             ; else the gun starts the retry already on the floor
        sta vx_lo
        sta vx_hi
        sta vy_lo
        sta vy_hi
        jmp hud_init


; ============================================================================
; next_level -- copy the resident level-2 planes over the live map and respawn.
; Two 1KB copies; it happens once, so a simple loop is fine.
; ============================================================================
; next_level -- table-driven, RLE. Levels 2..4 live compressed in one blob
; because three uncompressed levels are 6 KB and there is nowhere to put them.
; ============================================================================
; indirect indexed needs ZERO-PAGE pointers; the weapon's are not live during
; a level change, so borrow them rather than spend two more scarce ZP bytes.
rl_src  = wsrc
rl_dst  = wdst
rl_n    = $7A10

rle_decode                      ; rl_src -> rl_dst until a $00 token
        ldy #0
_rl_tok
        lda (rl_src),y
        beq _rl_end
        bmi _rl_run
        sta rl_n                ; literal run of n bytes
        jsr _rl_bump1
        ldy #0
_rl_lit
        lda (rl_src),y
        sta (rl_dst),y
        iny
        cpy rl_n
        bne _rl_lit
        lda rl_n
        jsr _rl_adv_both
        ldy #0
        beq _rl_tok
_rl_run
        and #$7F
        sta rl_n                ; n copies of the next byte
        jsr _rl_bump1
        ldy #0
        lda (rl_src),y
        ldy rl_n
        dey
_rl_fill
        sta (rl_dst),y
        dey
        bpl _rl_fill
        lda #1
        jsr _rl_advsrc
        lda rl_n
        jsr _rl_advdst
        ldy #0
        beq _rl_tok
_rl_end
        rts

_rl_bump1                       ; src += 1
        lda #1
_rl_advsrc
        clc
        adc rl_src
        sta rl_src
        bcc _ra1
        inc rl_src+1
_ra1    rts
_rl_advdst                      ; dst += A
        clc
        adc rl_dst
        sta rl_dst
        bcc _ra2
        inc rl_dst+1
_ra2    rts
_rl_adv_both                    ; both += A
        pha
        jsr _rl_advsrc
        pla
        jmp _rl_advdst

next_level
        lda levelno
        cmp #NLEVELS-1
        bcs _nl_none            ; that was the last level: victory
        inc levelno
        ldx levelno
        jsr load_level
        lda #0
        sta wondone
        jsr actors_init
        jsr spawn_actors
        lda #0
        sta itmgot
        lda #50
        sta ammo
        jmp hud_init
_nl_none
        lda #1                  ; past the last level: you are out
        sta wonall
        rts


; ============================================================================
; spawn_actors -- populate the actor table from this level's spawn list.
; Written directly rather than through actors.asm so the AI module stays
; untouched; the field layout is the documented structure-of-arrays.
; ============================================================================
spawn_actors
        lda levelno             ; index = level * NSPAWN
        asl
        asl
        clc
        adc levelno             ; *5
        sta gt2
        ldx #0
_sa_loop
        txa
        clc
        adc gt2
        tay                     ; Y = table index
        lda SPWNX,y
        sta AC_XHI,x
        lda SPWNY,y
        sta AC_YHI,x
        lda #$80                ; cell centre
        sta AC_XLO,x
        sta AC_YLO,x
        lda SPWNT,y             ; the type the LEVEL DESIGNER wrote: husk,
        sta AC_TYPE,x           ; gunner, spitter or hulk
        tay                     ; Y was the spawn index; done with it, so it
        lda THP,y               ; becomes the type -> stat-table index.
        sta AC_HP,x             ; A husk is still 60 HP on every level, ON
                                ; PURPOSE: a point-blank blast does exactly 60,
                                ; and that reliable one-shot IS the shotgun's
                                ; identity. The hulk is 120 -- exactly two of
                                ; them -- which makes the one-shot on everything
                                ; else feel like the power it is.
        lda #0                  ; dormant until it sees you
        sta AC_STATE,x
        sta AC_FRAME,x
        inx
        cpx #NSPAWN
        bne _sa_loop
        rts


; ============================================================================
; check_floor -- the ground can hate you. Attribute bit 7 is HURT ("nukage" in
; MAPFORMAT.md), and THE RED CISTERN's glowing channel and THE MAW's causeway
; gutters have AUTHORED it since the levels were written -- 32 cells of lava
; the runtime never read. Now it does: ~4 HP a bite, a bite roughly every
; third render tick (gated on RTCLK low bits, so the rate follows wall clock,
; not frame rate). The pain flash, the sound and the new gun-jolt all come
; free through the lasthp path -- the VBI notices health fell and does the
; rest. Runs on the render tick, main loop only.
; ============================================================================
check_floor
        ldy py_hi
        lda MAPROW_LO,y         ; solid-plane row base (actors.asm tables)
        clc
        adc px_hi
        sta gt0
        lda MAPROW_HI,y
        adc #4                  ; the attr plane sits exactly $0400 above
        sta gt1
        ldy #0
        lda (gt0),y
        bpl _cf_ok              ; bit 7 = hurt
        lda RTCLK
        and #$0F
        bne _cf_ok
        lda ai_ph
        beq _cf_ok              ; already dead: the floor cannot kill you twice
        sec
        sbc #4
        bcs _cf_st
        lda #0
_cf_st  sta ai_ph
_cf_ok  rts
bitmask dta 1,2,4,8

; The game layer runs up against the display lists at $4000.
        ert * > $4000, "game.asm has grown into the display lists at $4000"

; ===========================================================================
; run_clock -- one second of run time, as three digits.
;
; In the gap between the RAMTAB tables and ladder set B, because game.asm is
; full to the display lists and its guard says so. Digits rather than a 16-bit
; count of seconds, so the end card needs no divide: three increments with a
; carry, on one frame in fifty.
;
; Every level has carried a par time since the levels were authored -- 90, 150,
; 180, 240 seconds -- and nothing read them until now.
; ===========================================================================
        org $32B0

; ============================================================================
; check_items -- walking over a pickup collects it. Called once per render
; tick from the main loop; four compares, so the cost is noise.
; ============================================================================
check_items
        lda levelno
        asl
        asl
        sta gt2                 ; level * NITEM
        ldx #0
_ci_loop
        lda bitmask,x
        and itmgot
        bne _ci_next            ; already taken
        txa
        clc
        adc gt2
        tay
        lda ITMX,y
        cmp px_hi
        bne _ci_next
        lda ITMY,y
        cmp py_hi
        bne _ci_next
        ; standing on it
        lda bitmask,x
        ora itmgot
        sta itmgot
        lda ITMT,y
        cmp #2                  ; 2/3/4 are the red, blue and yellow keys
        bcc _ci_supply
        sec
        sbc #2                  ; 0 red, 1 blue, 2 yellow.
        beq _ci_kr              ; X is the ITEM LOOP COUNTER here. `tax` to
        cmp #1                  ; index bitmask destroyed it and the loop never
        beq _ci_kb              ; terminated -- the whole game hung the instant
        lda #4                  ; you touched a key, which looked from outside
        bne _ci_kset            ; like the autoplayer refusing to walk. Second
_ci_kb  lda #2                  ; time this exact mistake bit today: open_last
        bne _ci_kset            ; carries the cell index in X as well.
_ci_kr  lda #1
_ci_kset
        ora keys
        sta keys
        jmp _ci_snd
_ci_supply
        lda ITMT,y
        beq _ci_med
        lda ammo                ; shells: +15, capped at 99
        clc
        adc #15
        cmp #100
        bcc _ci_ast
        lda #99
_ci_ast sta ammo
        jmp _ci_snd
_ci_med lda ai_ph               ; medkit: +25, capped at 100
        clc
        adc #25
        cmp #101
        bcc _ci_hst
        lda #100
_ci_hst sta ai_ph
        sta lasthp              ; do not read the gain as damage
_ci_snd
        txa                     ; audio_play does `tax` -- it takes the sound id
        pha                     ; in X and does not give it back. X is THIS
        lda #SND_PICKUP         ; loop's counter, so every pickup left it as 10
        jsr audio_play          ; and the loop ran on for ~250 iterations over
        pla                     ; garbage item records. Harmless-looking while
        tax                     ; a stray type could only ever mean "medkit" --
_ci_next                        ; then keys arrived and garbage started reading
                                ; as a yellow key you had never found.
        inx
        cpx #NITEM
        bne _ci_loop
        rts

run_clock
        ; ---- the exit breathes -------------------------------------------
        ; Nothing else in this world moves, which is exactly why this works:
        ; the eye finds it with no HUD, no arrow and no map, and it still says
        ; nothing about WHERE the exit is until you can already see it. Both
        ; nibbles must be filled -- one byte is two pixels.
        inc exitph
        lda exitph
        lsr @
        lsr @
        lsr @
        and #7
        tax
        lda EXITPULSE,x
        sta exitlum

        lda wonall              ; stops when you are out, so the card reports
        bne _rc_done            ; the run and not how long you admired it
        inc runtick
        lda runtick
        cmp #50
        bcc _rc_done
        lda #0
        sta runtick
        inc rsec0
        lda rsec0
        cmp #10
        bcc _rc_done
        lda #0
        sta rsec0
        inc rsec1
        lda rsec1
        cmp #10
        bcc _rc_done
        lda #0
        sta rsec1
        inc rsec2
        lda rsec2
        cmp #10
        bcc _rc_done
        lda #9                  ; 999 and holding: three digits is the budget
        sta rsec0
        sta rsec1
        sta rsec2
_rc_done
        rts
EXITPULSE                       ; A breath that never dips below the BRIGHTEST
                                ; stone. Measured, close stone reaches 10.9, and
                                ; a trough of 9 made the exit read DARKER than
                                ; the wall at two cells -- the one range where
                                ; it had been working. Floor of 12.
        dta $CC,$DD,$EE,$FF,$FF,$EE,$DD,$CC
        ert * > $3400, "run_clock has grown into ladder set B at $3400"
