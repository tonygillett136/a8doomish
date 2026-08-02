; ===========================================================================
; calib.asm -- the mid-scanline colour calibration image.   BUILD: -dCALIB=1
;
; Assembled only into the calibration build. It answers, from ONE photograph of
; a real CRT, the three things this emulator cannot show at all (measured: it
; renders one colour-register value per scanline, in both graphics modes, for
; both COLBK and COLPF2, in the cycle-exact build as well):
;
;   1. does a mid-scanline COLBK write split a line in GTIA mode 9 at all?
;   2. is the edge CLEAN, or does GTIA smear it across its 4-hi-res-pixel cell?
;   3. what is the delay -> pixel mapping, so the real kernel can be written
;      against measured constants instead of guesses?
;
; The picture is a staircase. Sixty scanlines, in fifteen steps of four lines;
; each step waits two cycles longer than the one below it before switching from
; hue A to hue B. Under the staircase is a ruler drawn in LUMINANCE, which is
; independent of the hue being switched -- so the photograph carries its own
; scale and needs no measuring by hand.
;
; It borrows the game's display: same display list (232 scanlines, well inside
; ANTIC's 240), same GTIA mode 9, same BASIC-off INIT stub. Nothing here has to
; be right about setting up a screen, which is the part that went wrong twice
; when this was attempted standalone.
; ===========================================================================
CALIB_A = $90                   ; hue A -- low nibble MUST be 0 in GTIA 9
CALIB_B = $30                   ; hue B
CB_TOP  = 40                    ; scanlines skipped from the top of the frame
CB_LINES = 90                   ; 15 steps of 6 scanlines
; VCOUNT and WSYNC already come from game.asm's DLI section

; Placement, learned the hard way: buffer B is NOT free. It looks unused in this
; build (nothing flips pages) but init calls clear_screen, which zeroes 31 pages
; from $8000 -- so code parked at $9400 was wiped between load and entry, and
; the jump landed in zeros. The code goes in the 442-byte gap between DLISTB's
; end ($4645) and LEVELDATA ($4800); the table goes at $9F00, one page above
; where clear_screen stops.
CTAB    = $9F00                 ; 64 bytes, built at run time
        org $4660

calib_main
        sei
        lda #0
        sta NMIEN               ; we own the beam. No VBI, no DLI: the ONLY
                                ; writes to COLBK in this build are ours.
        lda SDLSTL              ; ...which also means nothing will copy the
        sta $D402               ; display-list shadow across any more, so put it
        lda SDLSTL+1            ; into ANTIC by hand. Getting this wrong is what
        sta $D403               ; left the standalone attempt showing the boot
                                ; screen while every register read back correct.
        lda #CALIB_A
        sta COLBK
        sta COLBKH
        jsr calib_fill
        ldx #0                  ; blank the game's HUD: the photograph should
        lda #0                  ; carry the test and nothing else
_kal_hud
        sta HUDRAM,x
        sta HUDRAM+40,x
        sta HUDRAM+80,x
        sta HUDRAM+120,x
        inx
        cpx #40
        bne _kal_hud
        ldx #0                  ; six scanlines per step, fifteen steps: each
        lda #<CSLIDE            ; step waits two cycles longer than the one below
_kal_step
        ldy #6
_kal_rep
        sta CTAB,x
        inx
        dey
        bne _kal_rep
        clc
        adc #1
        cpx #CB_LINES
        bne _kal_step
_kal_fever
        jsr calib_band
        jmp _kal_fever

; --- the ruler ------------------------------------------------------------
; Luminance 4 background, a luminance-14 tick every 8 pixels (every 4th byte),
; and a black notch at the centre pair. Hue is what the staircase switches, so
; a luminance pattern survives it and gives the photograph its scale.
calib_fill
        lda #<SCREEN
        sta tmpp
        lda #>SCREEN
        sta tmpp+1
        ldx #96                 ; buffer rows
_kal_row
        ldy #0
_kal_col
        tya                     ; NOT `lda #$44` first: tya clobbers it, and the
        and #3                  ; background came out as the column index
        beq _kal_tick
        lda #$44                ; background
        bne _kal_st             ; always taken
_kal_tick
        lda #$EE                ; tick, every 4th byte = every 8 pixels
_kal_st  cpy #19
        bcc _kal_put
        cpy #21
        bcs _kal_put
        lda #$00                ; centre notch: bytes 19 and 20
_kal_put
        sta (tmpp),y
        iny
        cpy #40
        bne _kal_col
        lda tmpp
        clc
        adc #40
        sta tmpp
        bcc _kal_nc
        inc tmpp+1
_kal_nc  dex
        bne _kal_row
        rts

; --- the staircase --------------------------------------------------------
; The per-line body MUST fit inside one scanline. There are about 62 free CPU
; cycles a line on this display (measured: 10.40 fps with the screen on against
; 14.80 with it off, so ANTIC takes ~30%), and this body spends 21 before the
; slide and 13 after, which is why the entry point is READ FROM A TABLE rather
; than computed: computing it cost 23 cycles, the body spilled into a second
; line, and the result was whole lines flipping hue instead of splitting.
calib_band
        lda VCOUNT
        bne calib_band          ; anchor to the top of the frame
        ldx #CB_TOP
_kal_skip
        sta WSYNC
        dex
        bne _kal_skip
        ldx #0
_kal_line
        sta WSYNC               ; every line STARTS in hue A...
        lda #CALIB_A
        sta COLBKH
        lda CTAB,x
        sta _kal_j+1
_kal_j    jmp CSLIDE
CSLIDE
        .rept 14                ; 14 and not more: the body is 32 cycles plus
        nop                     ; two per NOP, against ~62 free in a scanline.
        .endr                   ; Overrun shows as a step that does not split.
        lda #CALIB_B            ; ...and switches to hue B here
        sta COLBKH
        inx
        cpx #CB_LINES
        bne _kal_line
        lda #CALIB_A            ; leave the rest of the frame in hue A
        sta COLBKH
        rts
        ert * > $4800, "calib has overrun into LEVELDATA at $4800"
