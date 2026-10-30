;******************************************************************************
; BOING.ASM - Amiga-style "Boing" balls for the Commander X16
;
; A red and a blue checkered ball bounce around the screen under gravity,
; spinning as they go, in front of the classic purple grid. When the balls
; meet they bounce off each other. Press any key to return to BASIC.
;
; Build:   make
;          (or: cl65 -t cx16 -C cx16-asm.cfg -u __EXEHDR__ -o BOING.PRG BOING.ASM)
;          cx16-asm.cfg is cc65's linker config for pure assembly programs and
;          -u __EXEHDR__ adds the "10 SYS 2061" BASIC line so RUN works.
; Run:     x16emu -prg BOING.PRG -run
;
; CPU: the X16 uses a 65C02, so this code uses a few 65C02-only instructions
; that the original 6502 lacks:
;   stz  - store zero          (instead of lda #0 / sta)
;   bra  - branch always       (instead of jmp for short hops)
;
;------------------------------------------------------------------------------
; HOW IT WORKS - the big picture
;------------------------------------------------------------------------------
; 1. The background grid is layer 1 of the VERA video chip, set up as a tile
;    map in which every tile is the same 16x16 grid square.
;
; 2. Each ball is a 32x32 hardware sprite. We never redraw them: moving a
;    ball is just a matter of writing a new X/Y position into its sprite's
;    attributes.
;
; 3. The spinning is done by PALETTE CYCLING. Each pixel of a ball points to
;    a palette entry that stands for one thin slice of the ball's surface
;    (see gen_ball.py). Each frame we recolour those entries red or white,
;    shifted by one slice, so the checkers seem to roll around the ball.
;    The blue ball is the same picture using a different set of 64 palette
;    entries, so it can be coloured and spun separately.
;
; 4. Gravity: each ball has a vertical speed (vel_y). Every frame we add a
;    small constant (GRAVITY) to that speed, then add the speed to the
;    position. Speed builds up as a ball falls and drains away as it rises,
;    which traces out a natural-looking parabola. When a ball reaches the
;    floor it bounces without losing any energy, so it keeps any height it
;    gained from a collision (see bounce_y).
;
; 5. Collisions: two balls touch when their centres are closer than one ball
;    width. When they touch, they swap speeds along the direction they hit
;    in. That is what happens when two equal balls collide (think of
;    snooker balls). See check_collision for the details.
;
; 6. Everything runs once per video frame (60 times a second). We wait for
;    the start of each frame by watching the KERNAL's jiffy clock, which the
;    KERNAL advances during the vertical blank interrupt.
;
;------------------------------------------------------------------------------
; FIXED POINT NUMBERS
;------------------------------------------------------------------------------
; The 65C02 has no floating point, but gravity needs fractions of a pixel
; (a speed of 0.09 pixels per frame, for example). We use "8.8 fixed point":
; a 16-bit number whose high byte is the whole number of pixels and whose low
; byte is the fraction in 256ths.
;
;     $0180  = 1 + $80/256 = 1.5 pixels
;     $0018  = $18/256     = 0.09375 pixels
;
; Adding two 8.8 numbers is ordinary 16-bit addition: add the low bytes, then
; add the high bytes plus the carry. Negative speeds are two's complement,
; e.g. -1.5 pixels = $10000 - $0180 = $FE80.
;
; The screen is 320 pixels wide, more than one byte can count to, so the X
; position has TWO bytes of whole pixels ("16.8 fixed point", 3 bytes).
;
;------------------------------------------------------------------------------
; ONE SET OF VARIABLES PER BALL
;------------------------------------------------------------------------------
; Rather than writing all the code twice, every per-ball variable is a small
; table with one byte per ball, and the X register says which ball we are
; working on:
;
;     lda pos_y,x         ; X = 0: the red ball's Y,  X = 1: the blue ball's
;
; The bytes of a multi-byte number are kept in separate tables
; (pos_y_frac for the fraction, pos_y for the whole pixels) so that one
; X value finds every part of it. Where the code only ever deals with
; balls 0 and 1 together, it uses "pos_y" for ball 0 and "pos_y+1" for
; ball 1: the assembler just adds 1 to the address.
;******************************************************************************

.include "INC/x16.inc"      ; X16 register names, KERNAL calls, VERA_SET_ADDR

;==============================================================================
; CONSTANTS
;==============================================================================

NUM_BALLS     = 2           ; ball 0 = red, ball 1 = blue

; ---- Where things live in video memory (VRAM) -------------------------------
; The X16 has 128KB of VRAM ($00000-$1FFFF) that belongs to the VERA chip.
; The KERNAL's text screen uses $1B000 upwards, so $10000-$12FFF is free.
BALL_SIZE     = 32                      ; (must match SIZE in gen_ball.py)
BALL_BYTES    = BALL_SIZE * BALL_SIZE   ; 8bpp: one byte per pixel = 1024

BALL0_VRAM    = $10000                  ; red ball's pixels
BALL1_VRAM    = BALL0_VRAM + BALL_BYTES ; blue ball's pixels ($10400)
TILE_VRAM     = $12000      ; the grid tile (16x16, 4bpp = 128 bytes)
                            ;   tile data must start on a 2KB boundary
MAP_VRAM      = $12800      ; tile map (32x32 entries * 2 bytes = 2KB)
                            ;   map data must start on a 512 byte boundary

; ---- Palette ----------------------------------------------------------------
; VERA has 256 palette entries. Each is 2 bytes: %GGGGBBBB, %0000RRRR.
; We leave entries 0-15 alone (BASIC's text colours) and use:
;   17       grid background (grey)
;   18       grid lines (purple)
;   32-95    the red ball:  4 shades * 16 slices (see gen_ball.py)
;   96-159   the blue ball: the same layout, 64 entries further on
GRID_PAL_OFFSET = 1         ; the tile uses palette block 1 (entries 16-31)
BALL_PAL_BASE   = 32        ; first ball entry  (must match gen_ball.py)
BALL_SLICES     = 16        ; slices per checker pair (must match gen_ball.py)
BALL_SHADES     = 4         ; lighting levels   (must match gen_ball.py)
BALL_PAL_SIZE   = BALL_SHADES * BALL_SLICES   ; 64 entries per ball

; ---- Screen and motion ------------------------------------------------------
; Screen mode 3 is 320x240 pixels, and sprite coordinates use that same size.
; A sprite's position is its TOP LEFT corner.
X_MIN         = 8                       ; left wall  (leftmost X of a sprite)
X_MAX         = 320 - BALL_SIZE - 8     ; right wall (= 280, needs 2 bytes)
Y_FLOOR       = 240 - BALL_SIZE - 4     ; Y where a ball touches the floor
Y_TOP         = 8                       ; ceiling, in case a ball gains a lot
                                        ;   of energy from collisions

; ---- Speeds: all 8.8 fixed point (see the header) ---------------------------
; $0100 = 1 pixel per frame, $0080 = half a pixel, $0180 = one and a half.
GRAVITY       = $0018       ; 0.09375 pixels per frame, added to vel_y each frame

; *** Change these to set each ball's speeds. ***
;
; SPEED_X:  sideways speed. Keep it below $0800 (8 pixels per frame), or a
;           ball could jump past the left wall and off the screen.
; BOUNCE:   each ball starts on the floor and is launched upwards at this
;           speed, which sets how high it bounces. A ball launched at speed v
;           against gravity g rises v*v / (2*g) pixels:
;           5.0 * 5.0 / (2 * 0.09375) = about 133 pixels.
;           Above $0600 the ball reaches the ceiling (the floor is 204 pixels
;           down) and bounces off it.
RED_SPEED_X   = $0140       ; $0140=1.25 pixels per frame
RED_BOUNCE    = $0500       ; $0500=5.0  -> bounces about 133 pixels high
BLUE_SPEED_X  = $00C0       ; $00C0=0.75 pixels per frame
BLUE_BOUNCE   = $0440       ; $0400=4.25 -> bounces about 96 pixels high
;
; These only set how the balls START. Collisions swap speeds between the
; balls (that's what equal balls do when they hit), passing energy from one
; to the other: after a side-on collision the red ball moves at the blue
; ball's sideways speed and vice versa, and a ball knocked upwards keeps
; bouncing higher until another collision changes it again. The total
; energy of the two balls never changes.

; Two balls touch when their centres are closer than this (two radii).
COLLIDE_DIST  = BALL_SIZE

; ---- KERNAL screen modes and PETSCII ----------------------------------------
MODE_40X30    = 3           ; 40x30 text, i.e. a 320x240 display
CLR_SCREEN    = $93         ; PETSCII "clear screen" character

; ---- Sprite attribute bits (VRAM_sprattr + 8*n, see "init_sprites") -------
SPR_8BPP      = %10000000   ; byte 1: 8 bits per pixel (else 4)
SPR_Z_FRONT   = %00001100   ; byte 6: Z depth 3 = in front of both layers
SPR_32X32     = %10100000   ; byte 7: height (bits 7-6) and width (bits 5-4)
                            ;   size codes: 0 = 8, 1 = 16, 2 = 32, 3 = 64 pixels

;==============================================================================
; VARIABLES - zero page
;==============================================================================
; The cx16 linker config places the ZEROPAGE segment at $22-$7F, which the
; KERNAL and BASIC leave free for us. Zero page is faster and is needed for
; the (pointer),Y addressing mode used in copy loops.
.segment "ZEROPAGE"

src_ptr:      .res 2        ; pointer used when copying data to VRAM
colour_shift: .res 1        ; added to each pixel by copy_ball_image

; ---- Per-ball tables: one byte for each ball, use with ",x" --------------
pos_x_frac:   .res NUM_BALLS  ; X position, 16.8 fixed point:  fraction
pos_x_lo:     .res NUM_BALLS  ;                                whole pixels, low
pos_x_hi:     .res NUM_BALLS  ;                                whole pixels, high
pos_y_frac:   .res NUM_BALLS  ; Y position, 8.8 fixed point:   fraction
pos_y:        .res NUM_BALLS  ;                                whole pixels
vel_x_frac:   .res NUM_BALLS  ; horizontal speed, 8.8 signed:  fraction
vel_x:        .res NUM_BALLS  ;                                whole pixels
vel_y_frac:   .res NUM_BALLS  ; vertical speed, 8.8 signed:    fraction
vel_y:        .res NUM_BALLS  ;   (positive = down)            whole pixels
spin_phase:   .res NUM_BALLS  ; 0-15: how far the checkers have rolled

; ---- Used by move_one_ball / bounce_y ---------------------------------------
old_y_frac:   .res 1        ; the ball's Y before this frame's move
old_y:        .res 1

; ---- Used by check_collision -----------------------------------------------
dx_lo:        .res 1        ; dx = ball 1's X - ball 0's X  (16-bit signed)
dx_hi:        .res 1
dy_lo:        .res 1        ; dy = ball 1's Y - ball 0's Y  (16-bit signed)
dy_hi:        .res 1
dist_x:       .res 1        ; |dx| (size without the sign)
dist_y:       .res 1        ; |dy|
dist_sq:      .res 2        ; dx*dx + dy*dy

; ---- Other ------------------------------------------------------------------
phase:        .res 1        ; used by spin_ball
last_jiffy:   .res 1        ; used by wait_frame
old_mode:     .res 1        ; screen mode to restore on exit
old_l1_config:   .res 1     ; layer 1 settings to restore on exit
old_l1_mapbase:  .res 1
old_l1_tilebase: .res 1

;==============================================================================
; PROGRAM
;==============================================================================
; Thanks to "-u __EXEHDR__" the linker puts a small BASIC line (10 SYS 2061) in
; front of the CODE segment, so typing RUN starts the program at "start".
.segment "CODE"

start:
    ; ---- Switch to a 320x240 screen ----------------------------------------
    ; SCREEN_MODE: with carry SET it returns the current mode in A,
    ; with carry CLEAR it switches to the mode in A.
    sec
    jsr SCREEN_MODE
    sta old_mode            ; remember it so we can put it back later

    lda #MODE_40X30
    clc
    jsr SCREEN_MODE

    ; Turn off interrupts while we set up VERA. The KERNAL's interrupt
    ; handler can use VERA too, and must not disturb us half way through.
    sei

    ; VERA_ctrl selects which register set appears at $9F29-$9F2C (DCSEL)
    ; and which address port is in use (ADDRSEL). Zero = the defaults we want.
    stz VERA_ctrl

    ; Save the KERNAL's layer 1 settings so we can restore them on exit.
    lda VERA_L1_config
    sta old_l1_config
    lda VERA_L1_mapbase
    sta old_l1_mapbase
    lda VERA_L1_tilebase
    sta old_l1_tilebase

    jsr init_palette
    jsr init_background
    jsr init_sprite_pixels
    jsr init_sprites
    jsr init_balls

    ; Turn sprites on: bit 6 of DC_VIDEO is "sprites enable".
    lda VERA_dc_video
    ora #%01000000
    sta VERA_dc_video

    cli                     ; interrupts back on

;------------------------------------------------------------------------------
; Main loop: once per frame, show the balls where they are, then work out
; where they will be next frame.
;------------------------------------------------------------------------------
main_loop:
    jsr wait_frame          ; sync to the display (60 times a second)

    ; Write to VERA straight after the vertical blank so the changes are in
    ; place before the next frame is drawn.
    jsr draw_balls          ; sprite positions
    jsr spin_balls          ; palette cycling

    jsr move_balls          ; physics for the next frame
    jsr check_collision     ; did they hit each other?

    jsr GETIN               ; A = key pressed, or 0 if none
    beq main_loop           ; no key: keep going

;------------------------------------------------------------------------------
; A key was pressed: put everything back the way BASIC expects it.
;------------------------------------------------------------------------------
    sei
    stz VERA_ctrl

    lda VERA_dc_video       ; sprites off
    and #%10111111
    sta VERA_dc_video

    lda old_l1_config       ; restore layer 1
    sta VERA_L1_config
    lda old_l1_mapbase
    sta VERA_L1_mapbase
    lda old_l1_tilebase
    sta VERA_L1_tilebase
    cli

    lda old_mode            ; restore the screen mode
    clc
    jsr SCREEN_MODE

    lda #CLR_SCREEN         ; and start with a clean screen
    jsr CHROUT
    rts                     ; back to BASIC

;==============================================================================
; wait_frame - wait until the next video frame begins.
;
; The KERNAL's interrupt handler runs at every vertical blank (the moment the
; display finishes a frame) and adds 1 to the "jiffy clock". RDTIM returns
; that clock, lowest byte in A. When it changes, a new frame has started.
;==============================================================================
wait_frame:
    jsr RDTIM
    sta last_jiffy
@wait:
    jsr RDTIM
    cmp last_jiffy
    beq @wait               ; still the same jiffy: keep waiting
    rts

;==============================================================================
; init_palette - set the colours of the grid.
;
; The palette lives in VRAM at $1FA00, 2 bytes per entry, so entry n is at
; $1FA00 + n*2. Entries 17 and 18 are next to each other, so we can
; write all 4 bytes in one go.
;==============================================================================
init_palette:
    ; VERA_SET_ADDR (from x16.inc) points VERA's address port 0 at a VRAM
    ; address. The second argument is the auto-increment: 1 means "after
    ; every read or write of VERA_data0, move on to the next byte".
    ; NOTE: the macro pastes its argument in as plain text, so an address
    ; that is a calculation must be wrapped in brackets.
    VERA_SET_ADDR (VRAM_palette + 17*2), 1

    ldx #0
@loop:
    lda static_colors,x
    sta VERA_data0          ; each write goes to the next VRAM byte
    inx
    cpx #4                  ; 2 colours * 2 bytes
    bne @loop
    rts

static_colors:
    ;      %GGGGBBBB  %0000RRRR
    .byte  $AA,       $0A   ; 17: grid background, grey   (R=A G=A B=A)
    .byte  $0A,       $0A   ; 18: grid lines, purple      (R=A G=0 B=A)

;==============================================================================
; init_background - build the purple grid on layer 1.
;
; A tile layer is made of two parts:
;   * tile data: little pictures (here just one: a 16x16 grid square)
;   * a map: a grid of entries saying which tile goes where on screen
; Every map entry points to the same tile, so the squares repeat and form
; one big grid.
;==============================================================================
init_background:
    ; ---- The tile: 16x16 pixels at 4 bits per pixel ------------------------
    ; Two pixels per byte, left pixel in the high nibble. That makes each row
    ; of 16 pixels 8 bytes long. Pixel value 1 = background, 2 = line.
    ; Because the map selects palette block 1 (see below) these become
    ; palette entries 16+1 = 17 and 16+2 = 18.
    ;
    ; The square has a line along its top and its left edge; its neighbours
    ; supply the bottom and right edges.
    VERA_SET_ADDR TILE_VRAM, 1

    lda #$22                ; top row: 16 line pixels = 8 bytes of $22
    ldx #8
@top_row:
    sta VERA_data0
    dex
    bne @top_row

    ldy #15                 ; the remaining 15 rows
@row:
    lda #$21                ; first two pixels: line, background
    sta VERA_data0
    lda #$11                ; other 14 pixels: background
    ldx #7
@row_bytes:
    sta VERA_data0
    dex
    bne @row_bytes
    dey
    bne @row

    ; ---- The map: 32x32 entries, 2 bytes each ------------------------------
    ; byte 0: tile number (bits 7-0)          -> 0, our only tile
    ; byte 1: palette offset in bits 7-4, plus flip bits and tile number
    ;         bits 9-8                         -> palette block 1
    ; 32x32 = 1024 entries: X counts 256 entries, Y counts 4 rounds.
    VERA_SET_ADDR MAP_VRAM, 1

    ldy #4
    ldx #0
@map:
    stz VERA_data0                      ; tile 0
    lda #(GRID_PAL_OFFSET << 4)
    sta VERA_data0                      ; palette block 1
    inx
    bne @map                            ; inner 256 entries
    dey
    bne @map                            ; 4 times round

    ; ---- Point layer 1 at our tile and map ---------------------------------
    ; L1_CONFIG:   bits 7-6 map height  (0 = 32 tiles)
    ;              bits 5-4 map width   (0 = 32 tiles)
    ;              bit 3 / bit 2: 256-colour text / bitmap mode (both off)
    ;              bits 1-0 colour depth (2 = 4 bits per pixel)
    lda #%00000010
    sta VERA_L1_config

    ; L1_MAPBASE:  bits 16-9 of the map address
    lda #<(MAP_VRAM >> 9)
    sta VERA_L1_mapbase

    ; L1_TILEBASE: bits 7-2 hold bits 16-11 of the tile address,
    ;              bit 1 = tiles 16 high, bit 0 = tiles 16 wide
    lda #<((TILE_VRAM >> 11) << 2) | %11
    sta VERA_L1_tilebase

    ; No scrolling.
    stz VERA_L1_hscroll_l
    stz VERA_L1_hscroll_h
    stz VERA_L1_vscroll_l
    stz VERA_L1_vscroll_h
    rts

;==============================================================================
; init_sprite_pixels - put both ball images into VRAM.
;
; There is only one ball picture (ball_pixels). The red ball gets it as it
; is. For the blue ball we add BALL_PAL_SIZE (64) to every non-transparent
; pixel, so it uses palette entries 96-159 instead of 32-95, and spin_balls
; can colour those entries blue.
;==============================================================================
init_sprite_pixels:
    VERA_SET_ADDR BALL0_VRAM, 1
    stz colour_shift        ; red ball: unchanged
    jsr copy_ball_image

    VERA_SET_ADDR BALL1_VRAM, 1
    lda #BALL_PAL_SIZE      ; blue ball: 64 palette entries further on
    sta colour_shift
    jsr copy_ball_image
    rts

;------------------------------------------------------------------------------
; copy_ball_image - copy ball_pixels to VRAM (at the address already set),
; adding colour_shift to every pixel except 0 (transparent).
;
; ball_pixels (in BALL_DATA.INC) is 1024 bytes = 4 "pages" of 256 bytes.
; We copy a page at a time using indirect indexed addressing: (src_ptr),Y
; reads from the address held in src_ptr plus Y. Y runs 0-255 over a page;
; then we add 1 to the high byte of src_ptr to move to the next page.
;------------------------------------------------------------------------------
copy_ball_image:
    lda #<ball_pixels
    sta src_ptr
    lda #>ball_pixels
    sta src_ptr+1

    ldx #(BALL_BYTES / 256) ; number of pages (4)
    ldy #0
@loop:
    lda (src_ptr),y
    beq @store              ; transparent: leave it as 0
    clc
    adc colour_shift
@store:
    sta VERA_data0
    iny
    bne @loop               ; until Y wraps from 255 back to 0
    inc src_ptr+1           ; next page
    dex
    bne @loop
    rts

;==============================================================================
; init_sprites - fill in the attributes of sprites 0 and 1 (the balls).
;
; Each sprite has 8 bytes of attributes at $1FC00 + 8*sprite number:
;   0: image address bits 12-5
;   1: bit 7 = colour mode (1 = 8bpp), bits 3-0 = image address bits 16-13
;   2: X position bits 7-0          3: X position bits 9-8
;   4: Y position bits 7-0          5: Y position bits 9-8
;   6: collision mask, Z depth (bits 3-2), V flip, H flip
;   7: height (bits 7-6), width (bits 5-4), palette offset (bits 3-0)
; The image address is stored divided by 32, so sprite images must start on
; a 32 byte boundary.
;
; Sprite 1's attributes follow straight on from sprite 0's, so we can write
; all 16 bytes without moving the VRAM address.
;==============================================================================
init_sprites:
    VERA_SET_ADDR VRAM_sprattr, 1

    ldx #0                  ; X = ball / sprite number
@loop:
    lda sprite_image_lo,x
    sta VERA_data0
    lda sprite_image_hi,x
    sta VERA_data0
    stz VERA_data0          ; X and Y: draw_balls sets them every frame
    stz VERA_data0
    stz VERA_data0
    stz VERA_data0
    lda #SPR_Z_FRONT
    sta VERA_data0
    lda #SPR_32X32
    sta VERA_data0
    inx
    cpx #NUM_BALLS
    bne @loop
    rts

; Attribute bytes 0 and 1 for each ball: image address / 32, plus 8bpp mode.
sprite_image_lo: .byte <(BALL0_VRAM >> 5),            <(BALL1_VRAM >> 5)
sprite_image_hi: .byte >(BALL0_VRAM >> 5) | SPR_8BPP, >(BALL1_VRAM >> 5) | SPR_8BPP

;==============================================================================
; init_balls - starting positions and speeds, from the tables below.
; Both balls start on the floor, the red one on the left heading right and
; the blue one on the right heading left, each launched upwards at its own
; BOUNCE speed. Different speeds put them at different heights when they meet.
;==============================================================================
init_balls:
    ldx #0
@loop:
    stz pos_x_frac,x
    lda start_x_lo,x
    sta pos_x_lo,x
    lda start_x_hi,x
    sta pos_x_hi,x

    stz pos_y_frac,x        ; on the floor
    lda #Y_FLOOR
    sta pos_y,x

    lda start_vx_frac,x
    sta vel_x_frac,x
    lda start_vx,x
    sta vel_x,x

    lda start_vy_frac,x     ; launched upwards
    sta vel_y_frac,x
    lda start_vy,x
    sta vel_y,x

    stz spin_phase,x

    inx
    cpx #NUM_BALLS
    bne @loop
    rts

;                    red ball            blue ball
start_x_lo:    .byte <X_MIN,             <X_MAX
start_x_hi:    .byte >X_MIN,             >X_MAX
; The blue ball heads left, so its speed is negative: 0 - BLUE_SPEED_X.
start_vx_frac: .byte <RED_SPEED_X,       <($10000 - BLUE_SPEED_X)
start_vx:      .byte >RED_SPEED_X,       >($10000 - BLUE_SPEED_X)
; Upwards is negative, so these are 0 - BOUNCE.
start_vy_frac: .byte <($10000 - RED_BOUNCE), <($10000 - BLUE_BOUNCE)
start_vy:      .byte >($10000 - RED_BOUNCE), >($10000 - BLUE_BOUNCE)

;==============================================================================
; draw_balls - copy each ball's position into its sprite (attribute bytes 2-5).
;
; Sprite n's attributes are at $1FC00 + n*8, so its X position (byte 2) is at
; $1FC00 + n*8 + 2. The top two bytes of that address are the same for both
; sprites, so only the low byte has to be worked out: n*8 + 2.
;
; Only the whole-pixel bytes are used: the fractions are for the physics.
; Y never exceeds 255, so its high byte (attribute byte 5) is zero.
;==============================================================================
draw_balls:
    ldx #0
@loop:
    lda #((^VRAM_sprattr) | $10)    ; bank bit + auto-increment 1
    sta VERA_addr_bank
    lda #>VRAM_sprattr
    sta VERA_addr_high
    txa
    asl                     ; three shifts left = multiply by 8
    asl
    asl
    clc
    adc #<(VRAM_sprattr + 2)
    sta VERA_addr_low

    lda pos_x_lo,x
    sta VERA_data0          ; X low
    lda pos_x_hi,x
    sta VERA_data0          ; X high (0 or 1, as X goes up to 280)
    lda pos_y,x
    sta VERA_data0          ; Y low
    stz VERA_data0          ; Y high

    inx
    cpx #NUM_BALLS
    bne @loop
    rts

;==============================================================================
; spin_balls - palette cycling. Recolour both balls' palette entries.
;
; Each ball's 64 entries are laid out as  base + shade*16 + slice,
; and the blue ball's 64 come straight after the red ball's, so we can write
; all 128 entries (256 bytes) in one pass. That is 8 rows of 16 slices:
; rows 0-3 are the red ball's shades, rows 4-7 the blue ball's. X counts the
; rows and also picks the colour from the tables below.
;
; For each slice we work out
;
;       (slice - spin_phase) AND 15
;
; If that is 0-7 the slice is coloured, if 8-15 it is white. When spin_phase
; goes up by 1, every boundary moves one slice to the right, so the checkers
; roll to the right. When it goes down they roll left.
; ("AND 15" wraps the result into 0-15, just like going around the ball.)
;==============================================================================
spin_balls:
    VERA_SET_ADDR (VRAM_palette + BALL_PAL_BASE*2), 1

    ldx #0                  ; X = row = ball*4 + shade
@row_loop:
    txa                     ; which ball is this row for?
    lsr                     ; row / 4 (two shifts right) = ball number
    lsr
    tay
    lda spin_phase,y        ; that ball's phase
    sta phase

    ldy #0                  ; Y = slice
@slice_loop:
    tya
    sec
    sbc phase
    and #(BALL_SLICES - 1)
    cmp #(BALL_SLICES / 2)
    bcs @white              ; 8-15: white

    lda check_colors_gb,x   ; 0-7: red or blue, in this shade
    sta VERA_data0
    lda check_colors_r,x
    sta VERA_data0
    bra @next

@white:
    lda white_colors_gb,x
    sta VERA_data0
    lda white_colors_r,x
    sta VERA_data0

@next:
    iny
    cpy #BALL_SLICES
    bne @slice_loop
    inx
    cpx #(BALL_SHADES * NUM_BALLS)
    bne @row_loop
    rts

; The colours for each row (ball*4 + shade, brightest first), split into the
; two palette bytes: %GGGGBBBB and %0000RRRR.
;                       shade:  0    1    2    3
check_colors_gb: .byte $00, $00, $00, $00   ; red ball:  no green or blue
                 .byte $4F, $3C, $29, $16   ; blue ball: blue with a little green
check_colors_r:  .byte $0F, $0C, $09, $06   ; red ball:  red F, C, 9, 6
                 .byte $00, $00, $00, $00   ; blue ball: no red
white_colors_gb: .byte $FF, $CC, $99, $66   ; white (both balls):
                 .byte $FF, $CC, $99, $66   ;   grey levels F, C, 9, 6
white_colors_r:  .byte $0F, $0C, $09, $06
                 .byte $0F, $0C, $09, $06

;==============================================================================
; move_balls - run the physics for each ball in turn.
;==============================================================================
move_balls:
    ldx #0
@loop:
    jsr move_one_ball       ; uses X to pick the ball, and leaves X alone
    inx
    cpx #NUM_BALLS
    bne @loop
    rts

;------------------------------------------------------------------------------
; move_one_ball - update spin, X and Y of ball X for the next frame.
;------------------------------------------------------------------------------
move_one_ball:
    ; ---- Spin ---------------------------------------------------------------
    ; Roll the checkers the way the ball is travelling: phase up when moving
    ; right, down when moving left. The sign of vel_x is bit 7 of its whole
    ; byte, which BMI ("branch if minus") tests.
    lda vel_x,x
    bmi @spin_left
    inc spin_phase,x
    bra @spin_wrap
@spin_left:
    dec spin_phase,x
@spin_wrap:
    lda spin_phase,x
    and #(BALL_SLICES - 1)  ; keep it 0-15 (so 0 - 1 = $FF becomes 15)
    sta spin_phase,x

    ; ---- Horizontal: pos_x = pos_x + vel_x (24-bit add) --------------------
    ; pos_x is 3 bytes but vel_x only 2, so vel_x needs a third byte too.
    ; "Sign extension": a positive number gets $00 on top, a negative one $FF
    ; (e.g. -1.25 = $FEC0 becomes $FFFEC0). We compute that byte into Y.
    ldy #$00
    lda vel_x,x
    bpl @positive           ; bit 7 clear: positive
    ldy #$FF
@positive:
    clc
    lda pos_x_frac,x
    adc vel_x_frac,x        ; fractions first...
    sta pos_x_frac,x
    lda pos_x_lo,x
    adc vel_x,x             ; ...then whole pixels plus any carry...
    sta pos_x_lo,x
    tya                     ; (TYA does not change the carry)
    adc pos_x_hi,x          ; ...then the high byte plus any carry
    sta pos_x_hi,x

    ; ---- Walls --------------------------------------------------------------
    ; Only check the wall we are moving towards.
    ;
    ; Comparing 16-bit numbers: CMP the low bytes, then SBC the high bytes.
    ; Only the carry flag matters: SET means pos >= wall, CLEAR means pos < wall.
    lda vel_x,x
    bmi @moving_left

    lda pos_x_lo,x          ; moving right: past the right wall?
    cmp #<X_MAX
    lda pos_x_hi,x
    sbc #>X_MAX
    bcc @x_done             ; pos < X_MAX: not yet
    stz pos_x_frac,x        ; put the ball exactly on the wall...
    lda #<X_MAX
    sta pos_x_lo,x
    lda #>X_MAX
    sta pos_x_hi,x
    jsr reverse_x           ; ...and send it back
    bra @x_done

@moving_left:
    lda pos_x_lo,x          ; moving left: past the left wall?
    cmp #<X_MIN
    lda pos_x_hi,x
    sbc #>X_MIN
    bcs @x_done             ; pos >= X_MIN: still inside
    stz pos_x_frac,x
    lda #<X_MIN
    sta pos_x_lo,x
    lda #>X_MIN
    sta pos_x_hi,x
    jsr reverse_x
@x_done:

    ; ---- Remember where we are, in case we have to bounce ------------------
    lda pos_y_frac,x
    sta old_y_frac
    lda pos_y,x
    sta old_y

    ; ---- Gravity: vel_y = vel_y + GRAVITY ----------------------------------
    ; Going down vel_y is positive and grows. Going up it is negative and
    ; shrinks towards zero (the top of the bounce), then turns positive.
    clc
    lda vel_y_frac,x
    adc #<GRAVITY
    sta vel_y_frac,x
    lda vel_y,x
    adc #>GRAVITY
    sta vel_y,x

    ; ---- pos_y = pos_y + vel_y ---------------------------------------------
    clc
    lda pos_y_frac,x
    adc vel_y_frac,x
    sta pos_y_frac,x
    lda pos_y,x
    adc vel_y,x
    sta pos_y,x

    ; ---- Floor and ceiling --------------------------------------------------
    ; Only check the one we are moving towards.
    lda vel_y,x
    bmi @going_up

    lda pos_y,x             ; going down: below the floor?
    cmp #(Y_FLOOR + 1)
    bcc @y_done             ; pos <= Y_FLOOR: not yet
    jmp bounce_y            ; (bounce_y's RTS returns for us)

@going_up:
    lda pos_y,x             ; going up: above the ceiling?
    cmp #Y_TOP
    bcs @y_done             ; pos >= Y_TOP: not yet
    jmp bounce_y
@y_done:
    rts

;------------------------------------------------------------------------------
; bounce_y - bounce ball X off the floor or ceiling WITHOUT losing energy.
;
; The obvious way to bounce is to put the ball back on the floor and flip
; vel_y. But by the time we notice, the ball has already sunk a little way
; into the floor, and lifting it out gives it a little extra height for
; free (or loses some, depending on how you do it). The error is different
; every bounce, so the height slowly drifts.
;
; Instead we run time backwards. This frame's move is undone, and the speed
; the ball had BEFORE this frame is reversed and applied:
;
;     vel_y = -(vel_y - GRAVITY)      (the old speed, reversed)
;     pos_y = old_y + vel_y           (from where it was, the other way)
;
; Frame by frame, the ball then passes back through exactly the positions it
; fell through, at exactly the same speeds, just going the other way. That
; follows from how move_one_ball adds gravity and speed; try it on paper with
; small numbers. So it climbs back to exactly the height it fell from:
; nothing is gained or lost, even after thousands of bounces. All the energy
; a ball picks up in a collision stays with it until the next collision.
;
; The cost: the ball turns around up to one frame's movement (a few pixels)
; above the floor instead of touching it exactly. At 60 frames a second
; that is hard to see.
;------------------------------------------------------------------------------
bounce_y:
    sec                     ; take this frame's gravity back off
    lda vel_y_frac,x
    sbc #<GRAVITY
    sta vel_y_frac,x
    lda vel_y,x
    sbc #>GRAVITY
    sta vel_y,x

    sec                     ; reverse it: vel_y = 0 - vel_y
    lda #0
    sbc vel_y_frac,x
    sta vel_y_frac,x
    lda #0
    sbc vel_y,x
    sta vel_y,x

    clc                     ; pos_y = old_y + vel_y
    lda old_y_frac
    adc vel_y_frac,x
    sta pos_y_frac,x
    lda old_y
    adc vel_y,x
    sta pos_y,x
    rts

;------------------------------------------------------------------------------
; reverse_x - bounce ball X off a wall: negate its vel_x.
; Negating a two's complement number is 0 - number.
;------------------------------------------------------------------------------
reverse_x:
    sec
    lda #0
    sbc vel_x_frac,x
    sta vel_x_frac,x
    lda #0
    sbc vel_x,x             ; the borrow carries over from the low byte
    sta vel_x,x
    rts

;==============================================================================
; check_collision - make the two balls bounce off each other.
;
; 1. DETECT. The balls touch when the distance between their centres is less
;    than COLLIDE_DIST (32). By Pythagoras that distance is
;    sqrt(dx*dx + dy*dy), but square roots are slow, so we compare the
;    squares instead:   dx*dx + dy*dy < 32*32
;    The squares come from a lookup table, so no multiplying is needed.
;    (Comparing top left corners gives the same dx and dy as comparing the
;    centres, because both sprites are the same size.)
;
; 2. RESPOND. When two equal balls collide they swap their speeds along the
;    line joining their centres; speeds across that line don't change.
;    Doing that exactly needs multiplication, so we use a simpler version
;    that looks right: we look at the angle of the hit and
;      - mostly side by side  (|dx| > 2*|dy|): swap the X speeds
;      - mostly one above the other (|dy| > 2*|dx|): swap the Y speeds
;      - roughly diagonal: swap both
;    and on each axis we only swap if the balls are moving TOWARDS each other
;    along it. That last check stops them sticking together: once they have
;    swapped speeds they are moving apart, so they won't swap back on the
;    next frame while they are still overlapping.
;
; This routine works on balls 0 and 1, so it uses "name" for ball 0 and
; "name+1" for ball 1 rather than the X register.
;==============================================================================
check_collision:
    ; ---- dx = ball 1's X - ball 0's X (16-bit) -----------------------------
    sec
    lda pos_x_lo+1
    sbc pos_x_lo
    sta dx_lo
    lda pos_x_hi+1
    sbc pos_x_hi
    sta dx_hi               ; bit 7 = sign: set if ball 1 is left of ball 0

    ; ---- dy = ball 1's Y - ball 0's Y (16-bit) -----------------------------
    ; Y fits in one byte, but the difference can be -204 to +204, which
    ; doesn't, so we make it 16 bits by subtracting the (zero) high bytes.
    sec
    lda pos_y+1
    sbc pos_y
    sta dy_lo
    lda #0
    sbc #0                  ; 0 - 0 - borrow: $FF if negative, $00 if not
    sta dy_hi

    ; ---- Quick rejection: if |dx| or |dy| alone is 32 or more, they can't
    ;      be touching. This also keeps both small enough for the table. -----
    lda dx_lo
    ldy dx_hi
    jsr small_abs
    bcs @no_hit
    sta dist_x

    lda dy_lo
    ldy dy_hi
    jsr small_abs
    bcs @no_hit
    sta dist_y

    ; ---- dist_sq = dist_x squared + dist_y squared (16-bit) -----------------
    ldx dist_x
    ldy dist_y
    clc
    lda square_lo,x
    adc square_lo,y
    sta dist_sq
    lda square_hi,x
    adc square_hi,y
    sta dist_sq+1

    ; ---- Touching if dist_sq < COLLIDE_DIST squared (16-bit compare) -------
    lda dist_sq
    cmp #<(COLLIDE_DIST * COLLIDE_DIST)
    lda dist_sq+1
    sbc #>(COLLIDE_DIST * COLLIDE_DIST)
    bcs @no_hit             ; carry set: dist_sq >= limit, not touching

    ; ==== They are touching. ====

    ; ---- Swap X speeds? Not if they are mostly one above the other,
    ;      i.e. only if 2*|dx| >= |dy|. ----------------------------------------
    lda dist_x
    asl                     ; 2*|dx| (at most 62, so it fits)
    cmp dist_y
    bcc @try_y              ; 2*|dx| < |dy|: skip X

    ; Are they approaching along X? Ball 1's speed relative to ball 0 is
    ; vel_x+1 - vel_x. They are approaching if that has the OPPOSITE sign to
    ; dx (e.g. ball 1 is to the right and moving left relative to ball 0).
    ; EOR of the two high bytes sets bit 7 exactly when the signs differ.
    sec
    lda vel_x_frac+1        ; low bytes: we only need the borrow
    sbc vel_x_frac
    lda vel_x+1
    sbc vel_x               ; A = high byte of the relative speed
    eor dx_hi
    bpl @try_y              ; same sign: moving apart, leave them be

    ; Swap: A and Y hold the two values while we cross them over.
    lda vel_x_frac
    ldy vel_x_frac+1
    sta vel_x_frac+1
    sty vel_x_frac
    lda vel_x
    ldy vel_x+1
    sta vel_x+1
    sty vel_x

@try_y:
    ; ---- Swap Y speeds? Only if 2*|dy| >= |dx|. ---------------------------
    lda dist_y
    asl
    cmp dist_x
    bcc @no_hit

    sec                     ; approaching along Y? (as for X)
    lda vel_y_frac+1
    sbc vel_y_frac
    lda vel_y+1
    sbc vel_y
    eor dy_hi
    bpl @no_hit

    lda vel_y_frac
    ldy vel_y_frac+1
    sta vel_y_frac+1
    sty vel_y_frac
    lda vel_y
    ldy vel_y+1
    sta vel_y+1
    sty vel_y

@no_hit:
    rts

;------------------------------------------------------------------------------
; small_abs - size of a signed 16-bit number, if it is under COLLIDE_DIST.
;
; In:  A = low byte, Y = high byte
; Out: carry CLEAR and A = |number|  if |number| < COLLIDE_DIST
;      carry SET                     otherwise (too far apart)
;
; A two's complement number is made positive by flipping every bit and
; adding 1. A small negative number has a high byte of $FF, and after
; negating its high byte would be 0, so we only need to work on the low byte.
;------------------------------------------------------------------------------
small_abs:
    cpy #0
    beq @compare            ; 0 to 255: already positive
    cpy #$FF
    bne @too_far            ; 256 or more away (either direction)
    eor #$FF                ; -256 to -1: negate the low byte
    clc
    adc #1
    beq @too_far            ; it was -256, which came out as 0
@compare:
    cmp #COLLIDE_DIST       ; carry set if A >= COLLIDE_DIST
    rts
@too_far:
    sec
    rts

;------------------------------------------------------------------------------
; Table of squares 0*0 ... 31*31, built by the assembler (.repeat runs the
; line once for each value of i). Squares up to 961 need two bytes, so the
; low and high bytes are in separate tables, indexed by the same number.
;------------------------------------------------------------------------------
square_lo:
    .repeat COLLIDE_DIST, i
        .byte <(i * i)
    .endrepeat
square_hi:
    .repeat COLLIDE_DIST, i
        .byte >(i * i)
    .endrepeat

;==============================================================================
; DATA - the ball image, generated by gen_ball.py
;==============================================================================
.segment "RODATA"
.include "BALL_DATA.INC"
