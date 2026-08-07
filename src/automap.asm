; ============================================================================
; automap.asm -- the map, and the fog that earns it.
;
; The fog is not a second system. It is the raycaster's own work, recorded:
; every column that lands on a wall writes that cell into VIS on its way past,
; so the map can only ever show geometry the player's eyes have actually
; touched. Nothing reveals itself at a distance, nothing is inferred from the
; cells around it, and walking into a hall with your back to half of it leaves
; that half black. A hall you have swept shows as its outline plus the pillars
; you looked at, which is exactly what you would have drawn yourself.
;
; VIS holds the FINISHED map byte per cell, not the material id. The lookup
; happens once, at the moment a cell is seen, which is the one moment we are
; already holding the material in a register -- and it turns drawing the map
; into a straight copy with no per-cell decisions at all.
;
; The secret walls are the reason MAPLUM is a table and not a comparison: a
; secret (material $0D) MUST come out of it byte-identical to stone, or the
; map hands over every secret in the game the first time you glance at a wall
; near one. That is one table entry, and it is the only entry that matters.
; ============================================================================

VIS     = $A500                 ; 32*32, one byte per cell. 0 = never seen.
                                ; Page-aligned so the low byte of a cell's map
                                ; address IS the low byte of its VIS address --
                                ; marking is one `adc` on mptr+1, the same trick
                                ; the attribute plane uses.
VISOFS  = >VIS - >MAPBASE       ; $35: MAPBASE $70xx -> VIS $A5xx
VISOFA  = >VIS - >ATTRBASE      ; $31: and the same trick from the attr plane,
                                ; which is where the light sample leaves the
                                ; pointer sitting on the open cell

MAPHUE  = $90                   ; one flat hue for the whole map screen
FOGFLOR = $44                   ; floor you know about. NOT $22: two luminance
                                ; steps above black is a difference you can
                                ; measure and not one you can see, and the
                                ; trail through a hall is the whole point

CONSOL  = $D01F                 ; START/SELECT/OPTION, 0 = pressed
RTCLOK  = $14                   ; OS jiffy counter, +1 every video frame

; Material -> map luminance. Both nibbles the same: one byte is two pixels.
;        open   stone  brick  metal  flesh  tech   rock   glow
MAPLUM  dta     $44,   $88,   $88,   $88,   $88,   $88,   $88,   $88
;        door   red    blue   yellow exit   SECRET bars   sealed
        dta     $BB,   $DD,   $DD,   $DD,   $FF,   $88,   $88,   $88
                                ; index $0D is the secret, and it reads $88 --
                                ; the same byte as stone at index $01. Change
                                ; that and the map becomes a cheat sheet.

; Which way the player is pointing, as a one-cell nose. Sector 0 is EAST:
; gentables.py builds the ray table with dx=cos, dy=sin, so angle 0 is +X and
; angle 64 is +Y, and +Y is DOWN the map because the grid is row-major.
NOSEDX  dta 1,1,0,$FF,$FF,$FF,0,1
NOSEDY  dta 0,1,1,1,0,$FF,$FF,$FF

; Buffer offset of each cell row: row * 3 * 40. A cell is THREE scanline rows
; tall and two pixels wide, and that is an aspect ratio, not a taste: a mode 9
; pixel is 2 colour clocks across and a buffer row is 2 scanlines, so on a 4:3
; screen one pixel is 1.6 times wider than it is tall. At 2x2 the map drew
; every square hall in this game as a landscape rectangle twice its real width
; -- a navigation aid lying about the shape of the room. 2 wide by 3 tall comes
; out at 1.07:1, and 32 rows of 3 is exactly the 96 the buffer has.
MROWLO  dta 0,120,240,104,224,88,208,72,192,56,176,40,160,24,144,8
        dta 128,248,112,232,96,216,80,200,64,184,48,168,32,152,16,136
MROWHI  dta 0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7
        dta 7,7,8,8,9,9,10,10,11,11,12,12,13,13,14,14

mapon   dta 0                   ; the map has the screen. Read by the VBI, which
                                ; owns the band hues and repaints all three of
                                ; them every frame -- see the top of the flash
                                ; chain in game.asm.
mapdst  dta 0                   ; high byte of the buffer being drawn into

; ----------------------------------------------------------------------------
; vis_clear -- a floor you have not walked is a floor you cannot see.
; Called from load_level, so it also fires on the retry after a death: dying
; resets the doors, the items and the kill tally, and it resets what you know
; about the floor too.
; ----------------------------------------------------------------------------
vis_clear
        lda #<VIS
        sta tmpp
        lda #>VIS
        sta tmpp+1
        ldx #4                  ; 4 pages = 1024 cells
        ldy #0
        tya
_vc_l   sta (tmpp),y
        iny
        bne _vc_l
        inc tmpp+1
        dex
        bne _vc_l
        rts

; ----------------------------------------------------------------------------
; fog_here -- mark the cell the player is standing in as walked.
; The ray marks only the WALLS it hits, which would leave every hall as a
; hollow outline; this lays the breadcrumb through the middle. Called once per
; frame from the main loop, and the player's cell is always open, so it can
; never dim a wall back down to floor.
; ----------------------------------------------------------------------------
fog_here
        lda py_hi               ; VIS + py*32 + px, exactly as the column loop
        and #7                  ; builds mptr, with a different base
        asl @
        asl @
        asl @
        asl @
        asl @
        sta t0
        lda px_hi
        and #31
        ora t0
        sta tmpp
        lda py_hi
        and #31
        lsr @
        lsr @
        lsr @
        clc
        adc #>VIS
        sta tmpp+1
        ldy #0
        lda #FOGFLOR
        sta (tmpp),y
        rts

; ----------------------------------------------------------------------------
; map_plot -- put cell (m0,m1) on screen in luminance m2, two pixels wide by
; three scanlines. Both the player blip and the facing nose come through here.
; ----------------------------------------------------------------------------
map_plot
        lda m1
        and #31
        tax
        lda m0
        and #31
        clc
        adc #4                  ; the map's left margin, in bytes. Folded in
                                ; BEFORE the row offset: 31+4 cannot carry, so
                                ; the only carry out of the next add is the one
                                ; the high byte is entitled to
        clc
        adc MROWLO,x
        sta tmpp
        lda MROWHI,x
        adc #0
        clc
        adc mapdst
        sta tmpp+1
        lda m2
        ldy #0
        sta (tmpp),y
        ldy #40                 ; a cell is three scanline rows tall
        sta (tmpp),y
        ldy #80
        sta (tmpp),y
        rts

; ----------------------------------------------------------------------------
; map_draw -- paint the whole map screen into the back buffer.
;
; A cell is 2 pixels wide, and in GTIA 9 two pixels IS one byte -- so a 32-cell
; row is 32 bytes, and at 3 scanlines tall (see MROWLO) the map is 32 bytes by
; 96 rows: the full height of the buffer, at byte 4 of 40. That makes the blit
; a plain copy of each VIS row into three consecutive screen rows, with no
; shifting and no masking.
;
; It costs about three frames. That is fine, and deliberate: it runs once when
; the key goes down, and the 3D view it replaces takes longer than that.
; ----------------------------------------------------------------------------
map_draw
        clc
        lda #>SCREEN
        adc bufpg               ; $00 = buffer A, $10 = buffer B
        sta mapdst
        sta tmpp+1
        lda #0
        sta tmpp
        ldx #15                 ; 40*96 = 3840 = 15 pages exactly
        ldy #0
        tya
_md_cl  sta (tmpp),y
        iny
        bne _md_cl
        inc tmpp+1
        dex
        bne _md_cl

        lda #<VIS
        sta mptr
        lda #>VIS
        sta mptr+1
        lda #4                  ; row 0, byte 4: the map's top-left corner. The
        sta tmpp                ; map is exactly as tall as the buffer -- 32
        lda mapdst              ; cell rows of 3 scanlines is 96 on the nose
        sta tmpp+1
        ldx #32                 ; cell rows. X is the row counter and Y is the
_md_row                         ; byte index, so the three scanlines of a cell
        ldy #31                 ; row are written out straight rather than
_md_c1  lda (mptr),y            ; looped -- there is no third register to count
        sta (tmpp),y            ; them with, and a memory counter here would
        dey                     ; cost more than the 14 bytes it saved
        bpl _md_c1
        jsr _md_down
        ldy #31
_md_c2  lda (mptr),y
        sta (tmpp),y
        dey
        bpl _md_c2
        jsr _md_down
        ldy #31
_md_c3  lda (mptr),y
        sta (tmpp),y
        dey
        bpl _md_c3
        jsr _md_down
        lda mptr                ; next VIS row
        clc
        adc #32
        sta mptr
        bcc _md_nc
        inc mptr+1
_md_nc  dex
        bne _md_row

        lda px_hi               ; you are here
        sta m0
        lda py_hi
        sta m1
        lda #$FF
        sta m2
        jsr map_plot

        lda pang                ; and this is the way you are facing
        clc
        adc #16                 ; half a sector, so they centre on the cardinals
        lsr @
        lsr @
        lsr @
        lsr @
        lsr @                   ; 0..7
        tax
        lda px_hi
        clc
        adc NOSEDX,x
        sta m0
        lda py_hi
        clc
        adc NOSEDY,x
        sta m1
        lda #$66
        sta m2
        jmp map_plot

_md_down                        ; one scanline down the buffer
        lda tmpp
        clc
        adc #40
        sta tmpp
        bcc _md_d1
        inc tmpp+1
_md_d1  rts

; ----------------------------------------------------------------------------
; map_mode -- hold START to look at the map.
;
; The world stops while you are reading it and the VBI does not, which is the
; whole of the cost: nothing can walk up to you, and the run clock never pauses.
; The map is free in blood and expensive in par, and par is the thing the game
; actually scores.
;
; The hue has to be flattened, and NOT from here. The 3D view is three colour
; bands -- the ceiling from COLBK, then hwall and hfloor planted by the seam
; DLIs -- and those DLIs go on firing over the map at whatever rows the last
; render left them. But the VBI rewrites all three band hues from the level
; tables every single frame, so `mapon` is a request the VBI honours rather
; than a colour this routine can set.
; ----------------------------------------------------------------------------
map_mode
        lda CONSOL
        and #1                  ; START
        beq _mm_on
        rts
_mm_on
        lda #1
        sta mapon               ; the VBI flattens the hue from the next frame
        jsr map_draw
        jsr flip_buffers
_mm_hold
        lda RTCLOK              ; wait out a whole video frame rather than
_mm_w   cmp RTCLOK              ; spinning: the main loop is not frame-locked,
        beq _mm_w               ; and a free-running poll here would burn the
                                ; machine flat for as long as the key is down
        lda CONSOL
        and #1
        beq _mm_hold
        lda #0
        sta mapon               ; released: the VBI puts the level's own
        rts                     ; colours back on the next frame
