; ============================================================================
; ABYSS -- billboard sprites
; Actors are drawn as pre-scaled frames (no runtime scaling) stored as
; HORIZONTAL row spans, so each row is a straight copy along consecutive
; bytes. Depth is resolved against COLDIST, the per-column wall distance the
; raycaster already produces: the visible column range is computed once per
; sprite and every row is clipped to it, so a husk is correctly cut off by a
; wall edge without a per-pixel depth test.
; ============================================================================

; ---- sprite ZP ($E0-$EF per the interface contract) ------------------------
        org $00E0
sp_src  .ds 2                   ; span data pointer
sp_dst  .ds 2                   ; framebuffer pointer
sp_col  .ds 1                   ; centre column
sp_l    .ds 1                   ; leftmost byte column
sp_wb   .ds 1                   ; width in bytes
sp_top  .ds 1                   ; first buffer row
sp_h    .ds 1                   ; height in rows
sp_d    .ds 1                   ; depth index (1/16 cell units)
sp_vl   .ds 1                   ; visible column range, inclusive
sp_vr   .ds 1
sp_row  .ds 1
sp_n    .ds 1
sp_st   .ds 1
sp_i    .ds 1

sp_cc   = $7A20                 ; ZP $E0-$EF is exactly full
sp_pose = $7A21                 ; which pose the billboard body should draw
it_i    = $7A22                 ; item loop index
it_base = $7A23                 ; this level's first item record
sp_key  = $7A24                 ; 8 -- sort key: rough distance to each actor
sp_ord  = $7A2C                 ; 8 -- actor slots, ordered far to near
sp_cnt  = $7A34                 ; how many of them are live
sp_ii   = $7A35                 ; insertion-sort scratch
sp_bk   = $7A36
sp_bo   = $7A37
sp_slot = $7A38                 ; the actor slot currently being drawn
sp_srch = $7A39                 ; source rows in the art, before scaling
sp_err  = $7A3A                 ; Bresenham accumulator
sp_hdr  = $7A3B                 ; 2 -- where this source row's header sits, so
                                ;      a row can be drawn again when scaling up
sp_ktop = $7A3D                 ; wall top row at this sprite's distance
sp_ax   = $7A3E                 ; 2 -- |dx| and |dy| in 8.8, for the distance
sp_ay   = $7A40                 ; 2

        org $A000

; ============================================================================
; draw_sprites -- call after the wall pass, before the buffer flip.
; ============================================================================
draw_sprites
; ---- order the actors far to near --------------------------------------------
; Without this the draw order is SLOT order, so a distant husk paints on top of
; a near one. Measured: two husks in the same column, slots swapped, 94 pixels
; of difference -- the picture depended on which table entry each one happened
; to occupy. At most eight entries, sorted once a frame.
        ldx #0
        ldy #0
_so_scan
        lda AC_TYPE,x
        beq _so_next
        lda AC_XHI,x            ; |dx| + |dy| in whole cells. Only the ORDER
        sec                     ; matters, so the cheapest norm will do.
        sbc px_hi
        bpl _so_xp
        eor #$FF
        clc
        adc #1
_so_xp  sta sp_st
        lda AC_YHI,x
        sec
        sbc py_hi
        bpl _so_yp
        eor #$FF
        clc
        adc #1
_so_yp  clc
        adc sp_st
        bcc _so_ok
        lda #$FF                ; saturate rather than wrap
_so_ok  sta sp_key,y
        txa
        sta sp_ord,y
        iny
_so_next
        inx
        cpx #8
        bne _so_scan
        sty sp_cnt

        lda #1                  ; insertion sort, descending
        sta sp_ii
_is_out
        lda sp_ii
        cmp sp_cnt
        bcs _is_done
        tax
        lda sp_key,x
        sta sp_bk
        lda sp_ord,x
        sta sp_bo
_is_in
        cpx #0
        beq _is_place
        dex
        lda sp_key,x
        cmp sp_bk
        bcs _is_after           ; already >= : this one belongs at x+1
        lda sp_key,x            ; else shift it up and keep looking
        sta sp_key+1,x
        lda sp_ord,x
        sta sp_ord+1,x
        jmp _is_in
_is_after
        inx
_is_place
        lda sp_bk
        sta sp_key,x
        lda sp_bo
        sta sp_ord,x
        inc sp_ii
        jmp _is_out
_is_done

        lda #0
        sta sp_i
_sl_next
        lda sp_i
        cmp sp_cnt
        bcs _sl_alldone
        ldy sp_i
        ldx sp_ord,y            ; the slot, in far-to-near order
        stx sp_slot

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

        ldx sp_slot             ; animation frame -> pose
        lda AC_FRAME,x
        and #15
        tax
        lda POSEMAP,x
        sta sp_pose
        jsr sp_billboard
        inc sp_i
        jmp _sl_next
_sl_alldone
        ; fall through to the pickups

; ============================================================================
; draw_items -- the four pickups for this level.
;
; They were invisible: collected by standing on the exact cell, with nothing
; on screen to say they were ever there. They are billboards like everything
; else, so this loop only has to produce a delta and a pose and hand over to
; the shared body below.
; ============================================================================
draw_items
        lda levelno
        asl
        asl                     ; four items per level
        sta it_base
        lda #0
        sta it_i
_it_next
        ldx it_i
        lda bitmask,x
        and itmgot
        bne _it_skip            ; already collected
        txa
        clc
        adc it_base
        tax                     ; X = record index

        lda #$80                ; the item sits at the CENTRE of its cell
        sec
        sbc px_lo
        sta ai_dxl
        lda ITMX,x
        sbc px_hi
        sta ai_dxh
        lda #$80
        sec
        sbc py_lo
        sta ai_dyl
        lda ITMY,x
        sbc py_hi
        sta ai_dyh

        lda ITMT,x              ; 0 medkit, 1 shells -> poses 4 and 5
        clc
        adc #4
        sta sp_pose
        jsr sp_billboard
_it_skip
        inc it_i
        lda it_i
        cmp #4
        bne _it_next
        rts

; ============================================================================
; sp_billboard -- draw one billboard.
;   in: ai_dxl/ai_dxh/ai_dyl/ai_dyh = signed 8.8 delta from the player
;       sp_pose                     = which pose
; Shared by the actor loop and the item loop; everything below works from
; sp_* locals only, which is why the two callers can differ entirely.
; ============================================================================
sp_billboard
        ; ---- bearing relative to the view direction
        jsr ai_atan2
        sec
        sbc pang                ; signed, wraps correctly
        sta sp_col
        clc
        adc #22
        cmp #44
        bcc _sl_infov
        rts                     ; outside the field of view
_sl_infov

        ; screen column: 40 columns spanning ~43 angle units, so the ratio is
        ; near enough 1:1 for a billboard's placement.
        lda sp_col
        clc
        adc #20
        sta sp_col

        ; ---- distance: octagonal norm |max| + |min|/2, in SIXTEENTHS of a
        ; cell. Taking the high bytes alone gave WHOLE cells, and since the
        ; height lookup is indexed by this, every sprite's size was quantised
        ; to one step per cell: a husk stayed exactly the same size across a
        ; whole cell of approach and then jumped 40% in a single frame.
        lda ai_dxl              ; |dx| -> sp_ax
        ldy ai_dxh
        bpl _sl_axp
        eor #$FF
        clc
        adc #1
        sta sp_ax
        tya
        eor #$FF
        adc #0
        sta sp_ax+1
        jmp _sl_ady
_sl_axp sta sp_ax
        sty sp_ax+1
_sl_ady
        lda ai_dyl              ; |dy| -> sp_ay
        ldy ai_dyh
        bpl _sl_ayp
        eor #$FF
        clc
        adc #1
        sta sp_ay
        tya
        eor #$FF
        adc #0
        sta sp_ay+1
        jmp _sl_dcmp
_sl_ayp sta sp_ay
        sty sp_ay+1
_sl_dcmp
        lda sp_ax+1             ; make sp_ax the LARGER of the two
        cmp sp_ay+1
        bcc _sl_dswp
        bne _sl_dnos
        lda sp_ax
        cmp sp_ay
        bcs _sl_dnos
_sl_dswp
        lda sp_ax
        ldy sp_ay
        sty sp_ax
        sta sp_ay
        lda sp_ax+1
        ldy sp_ay+1
        sty sp_ax+1
        sta sp_ay+1
_sl_dnos
        lsr sp_ay+1             ; smaller / 2
        ror sp_ay
        lda sp_ax               ; max + min/2, still 8.8
        clc
        adc sp_ay
        sta sp_ax
        lda sp_ax+1
        adc sp_ay+1
        sta sp_ax+1

        cmp #16                 ; -> sixteenths, saturating at 16 cells
        bcs _sl_dfar
        asl
        asl
        asl
        asl
        sta sp_d
        lda sp_ax
        lsr
        lsr
        lsr
        lsr
        clc
        adc sp_d
        sta sp_d
        jmp _sl_dok
_sl_dfar
        rts                     ; too far to bother drawing
_sl_dok

        ; ---- pick the size band (from whole cells)
        ldy #0
        lda sp_d
        cmp #2*16
        bcc _sl_band
        iny
        cmp #4*16
        bcc _sl_band
        iny
        cmp #7*16
        bcc _sl_band
        iny
        cmp #11*16
        bcc _sl_band
        iny
_sl_band
        ; entry = pose*5 + band
        sty sp_st               ; band
        lda sp_pose
        asl
        asl                     ; pose*4
        clc
        adc sp_pose             ; + pose = pose*5
        clc
        adc sp_st               ; + band
        tay
        lda SPROFL,y
        sta sp_src
        lda SPROFH,y
        sta sp_src+1
        lda SPRH,y
        sta sp_h
        lda SPRWB,y
        sta sp_wb

        ; (sp_d is already in 1/16-cell units, ready for COLDIST and HTAB0)

        ; ---- vertical placement: feet on the floor line for this distance.
        ; The floor line at distance d is where a wall of the same height ends.
        lda sp_h
        sta sp_srch             ; the art's own row count, for the Bresenham
        ldx sp_d
        lda HTAB0,x             ; wall top row at this distance
        sta sp_ktop

        ; ---- height, CONTINUOUS ------------------------------------------
        ; Height tracks the wall height at this distance rather than the depth
        ; BAND the sprite falls in. Banded, a husk measured pixel-identical
        ; from 1.00 to 1.75 cells, then jumped 45% in one frame, and was LARGER
        ; at 6 cells than at 4. Band 0's art corresponds to a full-screen
        ; 96-row wall, so height = (wall height here) * SPRSCALE[pose] / 256.
        asl                     ; 2 * ktop
        sta mulb
        lda #VIEW_H
        sec
        sbc mulb                ; 96 - 2*ktop = the wall height here
        sta mula
        ldx sp_pose
        lda SPRSCALE,x
        sta mulb
        jsr mul8
        lda mulr_h
        bne _sh_nz
        lda #1                  ; a visible sprite never rounds away to nothing
_sh_nz  cmp #VIEW_H
        bcc _sh_ok
        lda #VIEW_H-1
_sh_ok  sta sp_h
        ; ---- the HULK is a head-and-shoulders taller --------------------
        ; Same art, a quarter more height. Guarded by POSE, not just slot:
        ; this path also draws pickups (poses 4-5) with a STALE sp_slot, so
        ; the pose test is what keeps a medkit from towering.
        lda sp_pose
        cmp #4
        bcs _sh_nohulk
        ldx sp_slot
        cpx #6
        bcs _sh_nohulk
        lda AC_TYPE,x
        cmp #TY_HULK
        bne _sh_nohulk
        lda sp_h
        lsr
        lsr                     ; +25%
        clc
        adc sp_h
        cmp #VIEW_H
        bcc _sh_hk
        lda #VIEW_H-1
_sh_hk  sta sp_h
_sh_nohulk

        lda #VIEW_H
        sec
        sbc sp_ktop             ; = floor line (bottom of a wall)
        sec
        sbc sp_h                ; ... minus the height = the sprite's top
        bcs _sl_topok
        lda #0
_sl_topok
        sta sp_top

        ; ---- horizontal extent
        lda sp_wb
        lsr
        sta sp_n
        lda sp_col
        sec
        sbc sp_n
        bcs _sl_lok
        lda #0
_sl_lok sta sp_l

        ; ---- visible column range: scan COLDIST once for this sprite
        lda #$FF
        sta sp_vl
        sta sp_vr
        ldx sp_l
        ldy sp_wb
_sl_vis
        cpx #NCOLS
        bcs _sl_visd
        lda sp_d
        cmp COLDIST,x           ; sprite nearer than the wall in this column?
        bcs _sl_visn            ; no: occluded
        lda sp_vl
        cmp #$FF
        bne _sl_vr
        stx sp_vl
_sl_vr  stx sp_vr
_sl_visn
        inx
        dey
        bne _sl_vis
_sl_visd
        lda sp_vl
        cmp #$FF
        bne _sl_vok
        rts                     ; entirely behind a wall
_sl_vok

        ; ================= draw the rows =================
        lda sp_top
        sta sp_row
        lda sp_h
        sta sp_n
        lda #0
        sta sp_err
_sl_row
        lda sp_src              ; remember this source row's header so it can
        sta sp_hdr              ; be drawn again if the sprite is scaled up
        lda sp_src+1
        sta sp_hdr+1
        ldy #0
        lda (sp_src),y
        sta sp_st               ; span start, relative to the sprite's left
        iny
        lda (sp_src),y
        sta sp_wb               ; span length in bytes (reusing sp_wb)
        lda sp_src
        clc
        adc #2
        sta sp_src
        bcc _sl_h
        inc sp_src+1
_sl_h
        lda sp_row
        cmp #VIEW_H             ; the real bottom of the view. Clamping this to
        bcs _sl_adv             ; row 66 -- the wall hue band -- meant NOTHING in
                                ; the game stood on the floor: at one cell a
                                ; medkit's feet sat 30 rows above its own floor
                                ; line, a third of the viewport, and a corpse
                                ; was pixel-identical at two and three cells
                                ; because the clamp pinned it. Objects in the
                                ; room beat objects pinned to the horizon; a
                                ; near sprite's feet taking the floor hue is
                                ; where the floor actually is.

        ; absolute start column of this row's span
        lda sp_l
        clc
        adc sp_st
        sta sp_st

        ldx sp_row
        lda ROWLO,x
        clc
        adc sp_st
        sta sp_dst
        lda ROWHI,x
        adc bufpg               ; the back buffer
        sta sp_dst+1

        ; copy the span, skipping transparent bytes and columns the wall hides
        ldy #0
        ldx sp_wb
        beq _sl_adv
        lda sp_st
        sta sp_cc               ; running absolute column
        lda sp_row
        cmp #VIEW_H-1           ; the view's last row. If the sprite still has
        bne _sl_cp              ; rows queued below it, this is where it gets
        lda sp_n                ; sliced -- and a hard horizontal cut across a
        cmp #2                  ; body reads as a saw line. Draw the cut row at
        bcc _sl_cp              ; rim luminance so it reads as the figure
        jmp _sl_cut             ; sinking into shadow instead.
_sl_cp
        lda sp_cc
        cmp sp_vl
        bcc _sl_cpn             ; left of the visible range
        cmp sp_vr
        beq _sl_cpy
        bcs _sl_cpn             ; right of it
_sl_cpy
        lda (sp_src),y
        beq _sl_cpn             ; fully transparent byte
        sta (sp_dst),y
_sl_cpn
        inc sp_cc
        iny
        dex
        bne _sl_cp
_sl_adv
        lda sp_src              ; step past this row's pixels
        clc
        adc sp_wb
        sta sp_src
        bcc _sl_a2
        inc sp_src+1
_sl_a2
        ; Bresenham. sp_src now points at the NEXT source row. Advance the
        ; source only as often as the accumulator says: one source row can
        ; cover several output rows when the sprite is near, and several
        ; collapse into one when it is far.
        lda sp_err
        clc
        adc sp_srch
        sta sp_err
        cmp sp_h
        bcc _sl_again           ; not yet: draw the same source row over
_sl_step
        sec
        sbc sp_h
        sta sp_err
        cmp sp_h
        bcc _sl_bdone           ; exactly one source row: keep the pointer
        ldy #1                  ; more than one: skip a whole row (2 + count)
        lda (sp_src),y
        clc
        adc #2
        clc
        adc sp_src
        sta sp_src
        bcc _sl_s2
        inc sp_src+1
_sl_s2
        lda sp_err
        jmp _sl_step
_sl_again
        lda sp_hdr              ; rewind and draw this source row again
        sta sp_src
        lda sp_hdr+1
        sta sp_src+1
_sl_bdone
        inc sp_row
        dec sp_n
        beq _sl_rowend          ; the Bresenham above put _sl_row out of branch
        jmp _sl_row             ; range; two cycles a row beats a jsr/rts
_sl_rowend
        rts

; Out of line and PAST THE RTS: this runs at most once per sprite. Leaving it
; inside the row loop pushed that loop's backward branch out of range, and
; parking it just before _sl_skip put it directly on the loop's fall-through
; path, where it ran on garbage and stopped every sprite from being drawn.
_sl_cut
        lda sp_cc               ; same visibility test, constant luminance
        cmp sp_vl
        bcc _sl_cutn
        cmp sp_vr
        beq _sl_cuty
        bcs _sl_cutn
_sl_cuty
        lda (sp_src),y          ; still respect the silhouette
        beq _sl_cutn
        lda #$11
        sta (sp_dst),y
_sl_cutn
        inc sp_cc
        iny
        dex
        bne _sl_cut
        jmp _sl_adv

        icl 'sprtabs.asm'
