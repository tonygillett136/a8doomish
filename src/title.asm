; ============================================================================
; title.asm -- the ABYSS wordmark.
;
; Four earlier attempts at a title screen destabilised the display and were
; reverted. Every one of them did the same thing wrong: they either drew from
; inside the main loop or pointed the display list somewhere else, and both
; disturb the DLI chain, which is the single most delicate thing in the build.
;
; This one changes nothing about the display. The game's own display list is
; already installed and its own DLIs are already running when we get here; all
; this does is paint the front buffer and decline to start the game until the
; trigger is pulled. There is no title-screen mode, no second display list and
; no extra work in the main loop -- which is exactly why it is stable.
;
; It lives in the gap between the sprite frames (which end at $19C3) and the
; engine at $2000.
; ============================================================================
        org $1A00

TRIG0T  = $D010

show_title
        lda #1
        sta intitle             ; tell the VBI to leave the text row alone
        jsr title_bg
        jsr title_blit
        ldx #0
_tm     lda title_msg,x
        sta HUDRAM+40,x
        lda title_sub,x         ; the third text row was still showing the level
        sta HUDRAM+80,x         ; name, which on a title screen reads as a
        inx                     ; leftover from the HUD rather than as a line
        cpx #32
        bne _tm
; Own edge detection, deliberately not the VBI's `trig` latch: do_fire would
; consume that latch and put a shot into the player's first frame.
_trel   lda TRIG0T
        beq _trel               ; held from boot? wait for the release first
_tprs   lda TRIG0T
        bne _tprs               ; now wait for a real press
; This poll sees the press BEFORE the VBI does, so simply clearing the latch is
; not enough -- the VBI would then find trigprv still 0, call it a fresh edge,
; and spend a shell on the keypress that started the game. Claim the edge here.
; Order matters: trigprv first while intitle still gates vbi_fire, intitle last.
        lda #1
        sta trigprv
        lda #0
        sta trig
        sta firereq
        sta intitle
        jsr hud_init            ; put the HEALTH/AMMO labels back: this screen
        rts                     ; wrote its own text over them

; ----------------------------------------------------------------------------
; title_bg -- a dim vertical gradient across the whole buffer.
;
; Painted rather than stored: a full-screen 96x40 image would be 3,840 bytes
; and there are only 1,536 free here. The ramp is one byte per eight rows and
; the DLI hue bands turn it into navy above, ember in the middle and dull gold
; below -- the same three-band space the game renders, empty.
; ----------------------------------------------------------------------------
title_bg
        ldx #0
_bgrow
        lda ROWLO,x
        sta wdst
        lda ROWHI,x             ; whichever buffer the caller selected: 0 at
        clc                     ; boot for the title, the DISPLAYED one for the
        adc bufpg               ; end card, which paints mid-game
        sta wdst+1
        txa
        lsr @
        lsr @
        lsr @                   ; row >> 3 -> one of twelve ramp steps
        tay
_vr     lda BGRAMP,y            ; operand patched by show_victory
        ldy #39                 ; both nibbles are set: in mode 9 one byte is
_bgfill sta (wdst),y            ; two pixels and a half-written byte stripes
        dey
        bpl _bgfill
        inx
        cpx #96
        bne _bgrow
        rts
; The ramp was symmetric -- dim at both ends, brightest in the middle -- which
; painted three flat bands and left the bottom third looking like unused space.
; It now falls monotonically from the top down and reaches black before the
; floor band, so the screen reads as light from above and nothing below: which
; is the one image the game is named after. Same twelve bytes.
BGRAMP  dta $33,$33,$22,$22,$11,$11,$11,$11,$11,$00,$00,$00

; ----------------------------------------------------------------------------
; title_blit -- the wordmark, as (start_byte, count, pixels...) row spans.
; Same format as the weapon, so this is a straight copy with no mask test.
; ----------------------------------------------------------------------------
title_blit
        lda #<TITLEDATA
        sta wsrc
        lda #>TITLEDATA
        sta wsrc+1
        lda #0
        sta wrow
_trow
        ldy #0
        lda (wsrc),y            ; start byte within the row
        sta wcount
        iny
        lda (wsrc),y            ; number of bytes
        sta wleft
        lda wsrc                ; step past the two-byte header
        clc
        adc #2
        sta wsrc
        bcc _th
        inc wsrc+1
_th
        ldx wrow
        lda ROWLO,x
        clc
        adc wcount
        sta wdst
        lda ROWHI,x
        adc bufpg
        sta wdst+1
        ldy wleft
        beq _tadv
        dey
_tcopy  lda (wsrc),y
        sta (wdst),y
        dey
        bpl _tcopy
_tadv
        lda wsrc                ; step past this row's pixels
        clc
        adc wleft
        sta wsrc
        bcc _tn
        inc wsrc+1
_tn
        inc wrow
        lda wrow
        cmp #96
        bne _trow
        rts

; ============================================================================
; show_victory -- the end card.
;
; Winning used to leave the raycast view of whatever wall the player happened
; to be facing, tinted gold: measured at 8 distinct colours against 34-39 for a
; gameplay frame, with 13 of 16 sampled rows a single colour across the whole
; width. The reward for four levels was horizontal stripes. It reuses the
; title's own painter, because the wordmark bookending the game is the cheapest
; ending that reads as one.
; ============================================================================
show_victory
        lda #1
        sta intitle             ; the VBI must not repaint the text row
        lda bufpg               ; flip_buffers leaves bufpg on the BACK buffer;
        eor #$10                ; the end card has to land on the visible one
        sta bufpg
        ldx #<VICRAMP           ; a brighter ramp than the title's: this is the
        stx _vr+1               ; way out, not the way in
        ldx #>VICRAMP
        stx _vr+2
        jsr title_bg
        jsr title_blit
        ; Finishing looked structurally identical to not having started: same
        ; wordmark, same layout, one different word in the text bar. What was
        ; missing was any sense that something had been ACHIEVED, so the card
        ; now reports the state you got out with. Both numbers already exist --
        ; this is a read, not a new counter.
        ldx #0
_vm     lda vstat_msg,x
        sta HUDRAM+40,x
        lda victory_msg,x
        sta HUDRAM+80,x
        inx
        cpx #32
        bne _vm
        lda ai_ph               ; health left, at columns 9-11
        ldx #9
        jsr hud_num
        lda kills               ; put down this run, at columns 20-22
        ldx #20
        jsr hud_num
        lda ammo                ; shells left, at columns 28-30
        ldx #28
        jsr hud_num
_vrel   lda TRIG0T              ; same edge discipline as the title
        beq _vrel
_vprs   lda TRIG0T
        bne _vprs
        lda #<BGRAMP            ; put the title's own ramp back
        sta _vr+1
        lda #>BGRAMP
        sta _vr+2
        lda bufpg               ; and hand the back buffer back to the renderer
        eor #$10
        sta bufpg
        lda #1
        sta trigprv             ; claim the edge before the VBI sees it
        lda #0
        sta trig
        sta firereq
        sta intitle
        sta wonall
        sta wondone
        sta levelno
        jmp restart_level       ; reloads level 1 and resets everything

; ...and the end card inverts it. The title falls into the dark; this one is
; lit from above and brightest at the top, so the two bookends are different
; PICTURES rather than the same picture in a different colour.
VICRAMP dta $88,$77,$66,$55,$44,$44,$33,$33,$22,$22,$11,$11

; The four text rows this file writes. They sit at $ABA0, immediately after
; game.asm's own table block, because title.asm has 1,112 bytes of wordmark
; between here and the engine at $2000 and only about seventy bytes to spare.
; Internal character codes, as elsewhere: 'A'-'Z' and '0'-'9' are ascii-32, and
; every one of these MUST be exactly 32 characters -- the copy loops are
; `cpx #32` and a short string reads whatever follows it into the last column.
_tstr_resume = *
        org $ABA0
title_msg
        dta d'      PRESS FIRE TO DESCEND     '
title_sub
        dta d'    FOUR FLOORS DOWN, NO WAY UP '
victory_msg
        dta d'  YOU ESCAPED - FIRE TO REPLAY  '
vstat_msg                       ; AMMO, not SHELLS: the status bar has called it
                                ; AMMO for four levels and the end card is the
                                ; wrong place to rename a stat
        dta d'  HEALTH      KILLS     AMMO    '
        ert * > $AC20, "title.asm's strings have overrun their block at $AC20"
        org _tstr_resume

TITLEDATA
        ins 'title.bin'

        ert * > $2000, "title.asm has grown into the engine at $2000"
