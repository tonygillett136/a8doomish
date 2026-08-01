; ============================================================================
; ABYSS -- raycaster core (M0b)
; GTIA mode 9 (ANTIC F + PRIOR $40). STRIPED display: 96 buffer rows, each
; shown as one mode-F line + one blank line = 192 scanlines. Halves playfield
; DMA (24,772 -> ~28,300 free cycles/frame) and halves the fill cost.
;
; Per column: table-driven DDA walking an incremental map pointer (no address
; maths per step; the two exits know which face was hit, so no side flag per
; step), then three suffix-ladder dispatches painting ceiling/wall/floor in
; EXACTLY 96 stores at 5 cycles each with zero overdraw.
;
; RENDERS ($0600) counts completed 3D frames so the harness computes real fps.
; ============================================================================
        icl 'tables.inc'

; ============================================================================
; THE FIRST SEGMENT IN THE FILE, and it exists for one reason: on a real
; 800XL/XE, $A000-$BFFF is the BASIC ROM unless something turns it off.
;
; This build puts the sprite renderer at $A000, its frame tables at $A900, the
; level names at $AA00, load_level at $AA80, the hue and flash tables at $AB00,
; the title strings at $ABA0, the whole actor AI at $B000 and the whole audio
; engine at $BB00. Every one of those is inside the BASIC window. With BASIC
; enabled, reads from there return ROM, so every `jsr` into any of them executes
; BASIC. The machine loads the file, corrupts immediately and the picture rolls.
;
; It never showed up in 130+ emulator runs because atari800 defaults to BASIC
; DISABLED, so the harness had been testing a machine configuration the hardware
; does not boot into. Reproduced afterwards by passing `-basic`: 0 world frames
; rendered and the player dead on arrival, against 55 frames and full health
; without it. tools/verify.py now runs the whole sweep BOTH ways so this class
; of divergence cannot hide again.
;
; PORTB bit 1: 0 = BASIC ROM enabled, 1 = RAM. Read-modify-write, because the
; same register holds the OS ROM enable and the self-test bank and getting
; those wrong is worse than BASIC.
;
; It has to be an INIT segment rather than something `start` does, and it has to
; be FIRST: a loader writing to $A000-$BFFF while the ROM is enabled cannot be
; relied on to reach the RAM underneath, so the window must be RAM before the
; segments that target it are read off the card.
        org $0600               ; page 6, free, and reused as RENDERS afterwards
_basic_off
        lda $D301
        ora #$02
        sta $D301
        rts
        ini _basic_off

SCREEN  = $8000                 ; buffer A: 40*96 = 3840 -> $8000..$8EFF
SCREENB = $9000                 ; buffer B, exactly $1000 above A
DLISTB  = $4400
LADOFS  = $08                   ; ladder set B sits $0800 above set A
DLIST   = $4000
TABLES  = $5000
MAPBASE = $7000
ATTRBASE = $7400                ; +$0400: attr byte is one adc off mptr
RAMTAB  = $3000

CEIL_LUM  = $22                 ; both nibbles: one byte is TWO pixels
FLOOR_LUM = $55                 ; floor brighter than ceiling, as DOOM

SDLSTL  = $0230
SDMCTL  = $022F
COLBK   = $02C8
GPRIOR  = $026F
STICK0  = $0278

RENDERS = $0600
ALIVE   = $0601

WADR_LO = RAMTAB+0
WADR_HI = RAMTAB+64
RADR_LO = RAMTAB+128
RADR_HI = RAMTAB+192
FADR_LO = RAMTAB+256
FADR_HI = RAMTAB+320
COLHI   = RAMTAB+384
COLDIST = RAMTAB+448            ; 40: per-column wall dist (sprite depth test)

; ---- zero page -------------------------------------------------------------
        org $0080
px_lo   .ds 1
px_hi   .ds 1
py_lo   .ds 1
py_hi   .ds 1
pang    .ds 1
col     .ds 1
sdx_lo  .ds 1
sdx_hi  .ds 1
sdy_lo  .ds 1
sdy_hi  .ds 1
ddx_l   .ds 1
ddx_h   .ds 1
ddy_l   .ds 1
ddy_h   .ds 1
spxl    .ds 1
spxh    .ds 1
spyl    .ds 1
spyh    .ds 1
mptr    .ds 2
dist    .ds 1
ktop    .ds 1
wlum    .ds 1                   ; wall luminance, bright course
wlum2   .ds 1                   ; darker course. MUST be zero page: the ladder
                                ; entry offsets assume `lda` is 2 bytes.
mula    .ds 1
mulb    .ds 1
mulr_l  .ds 1
mulr_h  .ds 1
m0      .ds 1
m1      .ds 1
m2      .ds 1
t0      .ds 1
t1      .ds 1
tmpp    .ds 2
bufhi   .ds 1                   ; $00 = ladders A, $06 = ladders B
bufpg   .ds 1                   ; $00 = buffer A,  $10 = buffer B
backbuf .ds 1
side    .ds 1                   ; face the ray hit: 0 = E/W, 1 = N/S
matid   .ds 1                   ; material of the wall cell we hit
lastcel .ds 1                   ; previous column's hit cell (edge detection)
dist0   .ds 1                   ; the TRUE distance. `dist` gets the light and
                                ; material offsets folded into it, which is a
                                ; SHADING trick -- feeding that to the height
                                ; lookup made a wall's height depend on how
                                ; brightly the level designer lit it and what
                                ; stone it was made of, and drew every wall in
                                ; the game at about a quarter of its size.

; ============================================================================
        org $2000
start
        sei
        cld
        lda $D301               ; belt and braces: the INIT segment above has
        ora #$02                ; already done this, but a loader that ignores
        sta $D301               ; INIT vectors would otherwise run us into ROM
        lda #0
        sta SDMCTL
        sta $D400

        jsr build_ramtabs
        jsr build_dlist
        jsr clear_screen
        jsr init_player

        lda #$40                ; GTIA 16-luminance mode
        sta GPRIOR
        sta $D01B
        lda #$00                ; hue<<4; low nibble MUST be 0 in GTIA 9
        sta COLBK
        sta $D01A

        lda #<DLIST
        sta SDLSTL
        lda #>DLIST
        sta SDLSTL+1
        lda #$22                ; NORMAL playfield = 40 bytes/line. $21 is NARROW
                                ; (32B): ANTIC discarded 8 of the 40 rendered
                                ; columns and pushed the view off-centre.
        sta SDMCTL
        sta $D400

        lda #0
        sta RENDERS
        sta ALIVE
        sta backbuf
        sta bufhi
        sta bufpg
        cli
        jsr game_init
        jsr show_title          ; paints the front buffer and waits for FIRE.
                                ; Deliberately here and not in the loop: it
                                ; borrows the running display rather than
                                ; installing one of its own.

main_loop
        lda wonall              ; the run is over: show the end card, which
        beq _ml_play            ; waits for FIRE and starts a fresh game
        jsr show_victory
_ml_play
        inc ALIVE
        jsr do_fire             ; consume the 50Hz trigger latch
        jsr move_player         ; momentum + per-axis collision
        jsr check_items         ; walk over a pickup to take it
        jsr actors_update       ; enemy state machines (render tick)
        jsr render_view
        jsr draw_sprites        ; billboards, depth-clipped against COLDIST
        jsr draw_weapon
        jsr draw_crosshair      ; after the weapon, so the gun cannot cover it
        jsr flip_buffers
        inc RENDERS
        jmp main_loop

; ============================================================================
; flip_buffers -- show the buffer we just finished, draw into the other.
; Writing the SDLSTL shadow means the OS VBI installs it at vertical blank,
; so the swap is beam-synced for free and never tears.
; ============================================================================
flip_buffers
        lda backbuf
        bne _fl_b
        lda #<DLIST             ; just finished A: display A
        sta SDLSTL
        lda #>DLIST
        sta SDLSTL+1
        lda #1
        sta backbuf
        lda #LADOFS             ; next frame draws into B
        sta bufhi
        lda #$10
        sta bufpg
        rts
_fl_b
        lda #<DLISTB
        sta SDLSTL
        lda #>DLISTB
        sta SDLSTL+1
        lda #0
        sta backbuf
        sta bufhi
        sta bufpg
        rts

; ============================================================================
render_view
        lda #0
        sta col

_colloop
        ldx col
        lda COL_ANG,x
        clc
        adc pang
        tax                     ; X = absolute ray angle

        lda DDX_LO,x
        sta ddx_l
        lda DDX_HI,x
        sta ddx_h
        lda DDY_LO,x
        sta ddy_l
        lda DDY_HI,x
        sta ddy_h
        lda STPXL,x
        sta spxl
        lda STPXH,x
        sta spxh
        lda STPYL,x
        sta spyl
        lda STPYH,x
        sta spyh

        ; ---- map pointer = MAPBASE + py*32 + px
        lda py_hi
        and #7
        asl
        asl
        asl
        asl
        asl
        sta t0
        lda px_hi
        and #31
        ora t0
        sta mptr
        lda py_hi
        and #31
        lsr
        lsr
        lsr
        clc
        adc #>MAPBASE
        sta mptr+1

        ; ---- seed sideDistX
        lda spxh                ; $00 = +1, $FF = -1
        bne _sdx_neg
        lda #0
        sec
        sbc px_lo
        jmp _sdx_go
_sdx_neg
        lda px_lo
_sdx_go
        jsr mul_frac_ddx
        lda mulr_l
        sta sdx_lo
        lda mulr_h
        sta sdx_hi

        ; ---- seed sideDistY
        lda spyh
        bne _sdy_neg
        lda #0
        sec
        sbc py_lo
        jmp _sdy_go
_sdy_neg
        lda py_lo
_sdy_go
        jsr mul_frac_ddy
        lda mulr_l
        sta sdy_lo
        lda mulr_h
        sta sdy_hi

        ; ==================== DDA ====================
        ldy #0                  ; held at 0 for (mptr),y throughout
        ldx #20                 ; step budget
_dda
        lda sdx_hi
        cmp sdy_hi
        bcc _sx
        bne _sy
        lda sdx_lo
        cmp sdy_lo
        bcc _sx
_sy
        lda sdy_lo
        clc
        adc ddy_l
        sta sdy_lo
        lda sdy_hi
        adc ddy_h
        sta sdy_hi
        lda mptr
        clc
        adc spyl
        sta mptr
        lda mptr+1
        adc spyh
        sta mptr+1
        lda (mptr),y
        sta matid
        bne _hity
        dex
        bne _dda
        beq _toofar
_sx
        lda sdx_lo
        clc
        adc ddx_l
        sta sdx_lo
        lda sdx_hi
        adc ddx_h
        sta sdx_hi
        lda mptr
        clc
        adc spxl
        sta mptr
        lda mptr+1
        adc spxh
        sta mptr+1
        lda (mptr),y
        sta matid
        bne _hitx
        dex
        bne _dda

_toofar
        lda #$FF
        sta dist
        sta dist0
        tax
        lda SHADE_NS,x
        sta wlum
        jmp _height

_hitx                           ; E/W face
        lda sdx_lo
        sec
        sbc ddx_l
        sta t0
        lda sdx_hi
        sbc ddx_h
        sta t1
        jsr quantise
        lda #0
        sta side
        jmp _shade

_hity                           ; N/S face -- darker: the cheapest depth cue
        lda sdy_lo
        sec
        sbc ddy_l
        sta t0
        lda sdy_hi
        sbc ddy_h
        sta t1
        jsr quantise
        lda #1
        sta side

; ---- shared shading: per-cell light, then the face --------------------------
_shade
        lda dist                ; keep the true distance before the shading
        sta dist0               ; offsets below are folded into it

        ; Light comes from the OPEN cell the ray was in when it hit, not from
        ; the wall cell itself. The level compiler paints light onto open space
        ; -- walls are 95% one light value on every level -- so sampling the
        ; wall threw the entire authored lighting design away. It is also the
        ; more truthful of the two: a wall is lit by the room in front of it.
        ; Undo the step the DDA just took; `side` says which one it was.
        lda side
        bne _bky
        lda mptr
        sec
        sbc spxl
        sta tmpp
        lda mptr+1
        sbc spxh
        jmp _bkdone
_bky
        lda mptr
        sec
        sbc spyl
        sta tmpp
        lda mptr+1
        sbc spyh
_bkdone
        clc                     ; the attribute plane is exactly $0400 above
        adc #$04                ; the solid plane
        sta tmpp+1
        ldy #0
        lda (tmpp),y
        and #7
        tax
        lda LIGHTOFS,x          ; light expressed as APPARENT DISTANCE, which
        clc                     ; reuses the shade ramp unchanged
        adc dist
        bcc _lgok
        lda #$FF                ; saturate: pitch dark
_lgok   sta dist
        lda matid               ; material bias, same trick: different wall
        and #15                 ; types read differently at the same distance.
        tax                     ; MATBIAS is 16 bytes and SHADE_EW follows it,
        lda MATBIAS,x           ; so an out-of-range id would read a shade value
        clc
        adc dist
        bcc _mbok
        lda #$FF
_mbok   sta dist

        ; (cell-boundary edge lines tried and reverted: along a RECEDING wall
        ;  every column hits a different cell, so nearly every column reads as
        ;  an edge. Doing this properly needs the fractional hit coordinate,
        ;  which costs a multiply per column.)
        ldx dist
        lda side
        beq _lum_ew
        lda SHADE_NS,x
        jmp _lum_st
_lum_ew lda SHADE_EW,x
_lum_st sta wlum
        pha                     ; the course contrast FADES with distance. The
        lda dist0               ; courses themselves are baked into the ladder at
        lsr                     ; a fixed screen pitch and cannot recede, but a
        lsr                     ; far wall showing no masonry at all is both more
        lsr                     ; truthful and much less of a grating.
        tax
        pla
        sec
        sbc CRSTAB,x
        bcs _lum_c2
        lda #$11
_lum_c2 sta wlum2

_height
        ldx col
        lda COLHI,x             ; HTAB page for this column (fisheye baked in)
        sta _hlook+2
        ldx dist0               ; GEOMETRY uses the true distance, never the
_hlook                          ; light/material-biased shading index
        lda HTAB0,x             ; -> wall TOP ROW
        sta ktop
        lda dist0
        ldx col
        sta COLDIST,x           ; depth buffer for the sprite pass

        ; ============ paint: ceiling, floor, wall ============
        ldx col                 ; every ladder indexes on X
        ldy ktop
        beq _nocap              ; wall fills the column: skip ceiling+floor

        lda RADR_LO,y
        sta _jr+1
        lda RADR_HI,y
        clc
        adc bufhi
        sta _jr+2
_jr     jsr $FFFF   ; ceiling ladder carries its own gradient

        ldy ktop
        lda FADR_LO,y
        sta _jf+1
        lda FADR_HI,y
        clc
        adc bufhi
        sta _jf+2
_jf     jsr $FFFF   ; floor ladder carries its own gradient

        ldy ktop
_nocap
        lda WADR_LO,y
        sta _jw+1
        lda WADR_HI,y
        clc
        adc bufhi
        sta _jw+2
        lda wlum
_jw     jsr $FFFF

        inc col
        lda col
        cmp #NCOLS
        beq _done
        jmp _colloop
_done
        rts

; --- t1:t0 (8.8 cells) -> dist index in 1/16-cell units, clamped ----------
quantise
        lda t1
        cmp #16
        bcs _q_far
        asl
        asl
        asl
        asl
        sta dist
        lda t0
        lsr
        lsr
        lsr
        lsr
        ora dist
        sta dist
        rts
_q_far
        lda #$FF
        sta dist
        rts

; ============================================================================
mul_frac_ddx
        sta m2
        sta mula
        lda ddx_l
        sta mulb
        jsr mul8
        lda mulr_h
        sta m0
        lda m2
        sta mula
        lda ddx_h
        sta mulb
        jsr mul8
        lda mulr_l
        clc
        adc m0
        sta mulr_l
        lda mulr_h
        adc #0
        sta mulr_h
        rts

mul_frac_ddy
        sta m2
        sta mula
        lda ddy_l
        sta mulb
        jsr mul8
        lda mulr_h
        sta m0
        lda m2
        sta mula
        lda ddy_h
        sta mulb
        jsr mul8
        lda mulr_l
        clc
        adc m0
        sta mulr_l
        lda mulr_h
        adc #0
        sta mulr_h
        rts

mul8                            ; quarter-square: mula*mulb -> mulr
        clc
        lda mula
        adc mulb
        tax
        bcs _mhi
        lda SQ_LO,x
        sta m1
        lda SQ_HI,x
        sta mulr_h
        jmp _mdiff
_mhi
        lda SQ_LO+256,x
        sta m1
        lda SQ_HI+256,x
        sta mulr_h
_mdiff
        lda mula
        sec
        sbc mulb
        bcs _mpos
        eor #$FF
        clc
        adc #1
_mpos
        tax
        lda m1
        sec
        sbc SQ_LO,x
        sta mulr_l
        lda mulr_h
        sbc SQ_HI,x
        sta mulr_h
        rts

; ============================================================================
; (read_input/move_* removed -- game.asm owns input and movement)

init_player                     ; spawn per THE VESTIBULE's level header
        lda #$80
        sta px_lo
        sta py_lo
        lda #4
        sta px_hi
        lda #6
        sta py_hi
        lda #0
        sta pang
        rts

; ============================================================================
build_ramtabs
        ldx #0
_brw
        lda WOFF_LO,x
        clc
        adc #<LADW_A
        sta WADR_LO,x
        lda WOFF_HI,x
        adc #>LADW_A
        sta WADR_HI,x

        lda RFOFF_LO,x
        clc
        adc #<LADR_A
        sta RADR_LO,x
        lda RFOFF_HI,x
        adc #>LADR_A
        sta RADR_HI,x

        lda RFOFF_LO,x
        clc
        adc #<LADF_A
        sta FADR_LO,x
        lda RFOFF_HI,x
        adc #>LADF_A
        sta FADR_HI,x

        inx
        cpx #49
        bne _brw

        ldx #0
_bch
        lda GRPTAB,x            ; 0..3; the HTABs are 256B apart, so +1 page each
        clc
        adc #>HTAB0
        sta COLHI,x
        inx
        cpx #NCOLS
        bne _bch
        rts

; ============================================================================
build_dlist                     ; build both display lists, one per buffer
        lda #<DLIST
        sta tmpp
        lda #>DLIST
        sta tmpp+1
        lda #<SCREEN
        sta t0
        lda #>SCREEN
        sta t1
        jsr _mkdl
        lda #<DLISTB
        sta tmpp
        lda #>DLISTB
        sta tmpp+1
        lda #<SCREENB
        sta t0
        lda #>SCREENB
        sta t1
_mkdl
        ldy #0
        lda #$70
        sta (tmpp),y
        iny
        sta (tmpp),y
        iny
        sta (tmpp),y
        lda tmpp
        clc
        adc #3
        sta tmpp
        bcc _mk1
        inc tmpp+1
_mk1
        ldx #96
_dlrow
        ldy #0
        lda #$4F                ; first copy of the row: never carries the DLI
        sta (tmpp),y
        iny
        lda t0
        sta (tmpp),y
        iny
        lda t1
        sta (tmpp),y
        iny
        lda #$4F                ; SAME row again: 96 buffer rows -> 192 scanlines
        cpx #67                 ; rows count DOWN from 96: 67 -> buffer row 29
        beq _dlint
        cpx #31                 ; -> buffer row 65
        beq _dlint
        cpx #1                  ; last 3D row: hand over to the status band
        bne _dlno
_dlint
        lda #$CF                ; The DLI belongs on the SECOND copy. ANTIC runs
_dlno                           ; the handler at the END of the line carrying the
        sta (tmpp),y            ; bit, so putting it on the first copy applied
        iny                     ; the new colours to this row's own second
                                ; scanline -- one line early at both hue seams,
                                ; and on the last row it handed over to the
                                ; status band's mode and colours while row 95
                                ; was still being displayed. That was a bright
                                ; dashed line across the bottom of every frame.
        lda t0
        sta (tmpp),y
        iny
        lda t1
        sta (tmpp),y

        lda tmpp
        clc
        adc #6
        sta tmpp
        bcc _dl1
        inc tmpp+1
_dl1
        lda t0
        clc
        adc #40
        sta t0
        bcc _dl2
        inc t1
_dl2
        dex
        bne _dlrow

        ; TWO rows of ANTIC 2 text = 16 scanlines, and the count is not a style
        ; choice -- it is the difference between a picture that locks and one
        ; that rolls.
        ;
        ; ANTIC displays scanlines 8..247 and begins vertical blank at 248, so a
        ; display list may ask for at most 240 scanlines. This one asked for
        ; 248: 24 blank + 96 rows shown twice (192) + FOUR text rows (32). The
        ; last text row was still doing playfield DMA while ANTIC should have
        ; been generating sync, and on a real 800XL the picture rolled. It never
        ; showed up in the emulator because atari800 renders a fixed 240-line
        ; window and does not model a CRT losing lock -- it simply clipped the
        ; overflow and drew a stable frame.
        ;
        ; Two of the four rows were blank anyway: only HUDRAM+40 (health and
        ; ammo) and HUDRAM+80 (the level name) ever carry text. Starting at +40
        ; and drawing two costs nothing visible and brings the list to 232
        ; scanlines, eight inside the limit rather than eight outside it.
        ldx #2
        lda #<[HUDRAM+40]
        sta t0
        lda #>[HUDRAM+40]
        sta t1
_hudrow
        ldy #0
        lda #$42                ; LMS + ANTIC 2
        sta (tmpp),y
        iny
        lda t0
        sta (tmpp),y
        iny
        lda t1
        sta (tmpp),y
        lda tmpp
        clc
        adc #3
        sta tmpp
        bcc _hr1
        inc tmpp+1
_hr1
        lda t0
        clc
        adc #40
        sta t0
        bcc _hr2
        inc t1
_hr2
        dex
        bne _hudrow

        ldy #0
        lda #$41                ; JVB back to the top of THIS display list
        sta (tmpp),y
        iny
        lda tmpp+1              ; which DL are we finishing?
        cmp #>DLISTB
        bcs _jvb_b
        lda #<DLIST
        sta (tmpp),y
        iny
        lda #>DLIST
        sta (tmpp),y
        rts
_jvb_b
        lda #<DLISTB
        sta (tmpp),y
        iny
        lda #>DLISTB
        sta (tmpp),y
        rts

clear_screen
        lda #<SCREEN
        sta tmpp
        lda #>SCREEN
        sta tmpp+1
        ldx #31                 ; both buffers back to back: $8000..$9EFF
        lda #0
        ldy #0
_cs     sta (tmpp),y
        iny
        bne _cs
        inc tmpp+1
        dex
        bne _cs
        rts

; ============================================================================
; The engine's own code ends here. Everything from $2500 up is DATA at fixed
; addresses, and the assembler will happily lay data on top of code without a
; word of complaint -- that failure has cost this project three separate
; debugging sessions, most recently when check_cell grew nine bytes and the
; exit silently stopped working. One assertion per boundary, checked at
; assembly time, is the only thing that makes the class of bug impossible.
ENGINE_END = *
        ert ENGINE_END > $2B40, "engine code has grown into the item table at $2B40"

        icl 'weapon.inc'
        icl 'sprites.inc'
        icl 'levels.inc'
        icl 'spawns.inc'
        icl 'items.inc'
        ert * > $2C00, "the small tables below ladder A have overrun it at $2C00"

        icl 'game.asm'

        icl 'sprites.asm'
        icl 'actors.asm'
        ert * > $BB00, "actors.asm has grown into the audio engine at $BB00"
        icl 'audio.asm'
        ert * > $C000, "audio.asm has grown past the top of usable RAM"


        icl 'title.asm'
        icl 'ladders.asm'

        org $7B00
WEAPON
        ins 'weapon.bin'
        ert * > $7FF0, "weapon.bin has grown into framebuffer A"

        org $0900               ; low RAM: 4291B of poses, ends $19C3
SPRITES
        ins 'sprites.bin'

        org MAPBASE
        ins 'map0.bin'

        org ATTRBASE
        ins 'attr0.bin'


        org TABLES
        ins 'tables.bin'

        run start
