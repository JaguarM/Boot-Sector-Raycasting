; ============================================================================
; BOOT SECTOR RAYCASTER - a textured 3D maze in 512 bytes
; Rewrite of Boot-Sector-Raycasting.asm (same 16x16 map, same idea: integer
; maths only, no floating point), now in VGA mode 13h (320x200, 256 colours).
;
;   Left / Right  turn          Up / Down  walk (you can't walk through walls)
;
; Every frame:
;   1. wait for the next timer tick (~58 per second)
;   2. read the keyboard, turn or walk
;   3. for each of the 320 screen columns: cast a ray, find the wall it hits,
;      then draw that column: ceiling, brick wall, stone floor
;   4. copy the finished picture to the screen in one go (no tearing)
;
; Units
;   position   16 bits per axis, 4096 units = 1 map cell (the top 4 bits are
;              the cell number 0..15, the low 12 bits the place inside it)
;   direction  32-bit 16.16 fixed point; the high word is the view direction,
;              200 units long (= one "coarse" ray step of 1/20 cell)
;   distance   counted in ray steps of 1/8 of a coarse step (~1/164 cell),
;              measured along the view direction (so no fish-eye)
; ============================================================================
        bits 16
        cpu 386
%ifidn __OUTPUT_FORMAT__, bin
        org 0x7C00
%endif

; Variables are addressed as [bp+name] (3-byte instructions); bp = vars.
; The ones with a start value are stored at the end of the code; the scratch
; ones (PX16..SY) are overwritten before use, so they can sit in the zero
; padding, on the boot signature or just past it.
MAP     equ map - vars
PX      equ px - vars           ; player x
PY      equ py - vars           ; player y
DIRY    equ diry - vars         ; view direction y (dword, 16.16)
DIRX    equ 0                   ; view direction x (dword, the "dd 0" at vars)
PX16    equ 4                   ; dword: px*16, py*16 (for the floor texture)
N       equ 8                   ; distance to the wall of this column
U       equ 10                  ; wall texture column (bit 7: darker side)
SX      equ 12                  ; ray step of this column (x, y)
SY      equ 14

start:
        mov ax, 0x13
        int 0x10                ; video mode 13h: 320x200, 1 byte per pixel
        push 0xA000
        pop es                  ; es = screen
        mov ah, 0x10
        mov gs, ax              ; gs = 256x256 texture   (segment 0x10xx)
        mov ah, 0x20
        mov fs, ax              ; fs = picture being drawn (segment 0x20xx)
        mov bp, vars

        xor ax, ax
        out 0x40, al            ; timer: 1193182 / 0x5000 = ~58 ticks per second
        mov dx, 0x3C8
        out dx, al              ; start writing colour 0
        inc dx                  ; 0x3C9 takes red, green, blue (0..63) in turn
        mov al, 0x50
        out 0x40, al

        ; ---- palette: 4 ramps of 64 shades, colour = ramp*64 + shade ---------
        ;      0 floor, 1 and 2 walls (top and bottom half), 3 ceiling
        mov si, tints
        xor bx, bx              ; bl = shade*4
.shade: mov cl, 3
.rgb:   lodsb                   ; tint of this ramp (red, green, blue)
        mul bl                  ; ah = tint * shade / 64
        mov al, ah
        add al, 8               ; + a dark blue fog (2,4,6) instead of black
        sub al, cl
        sub al, cl
        out dx, al
        loop .rgb
        add bl, 4
        jz .next                ; after 64 shades go on to the next ramp's tints
        sub si, 3               ; otherwise the same tints again
.next:  cmp si, bp              ; the tints are the last bytes before vars
        jb .shade

        ; ---- texture: bricks, brightness 0..63 --------------------------------
        ;      bl = u (across), bh = v (down). Each brick is 32x32 texels, every
        ;      other row shifted by half a brick. The right half (u >= 128) is a
        ;      darker copy, used for the walls facing the other way. bx = 0 here.
.tex:   imul dx, dx, 0x4E35     ; dx = dx * 20021 + 1: pseudo random numbers
        inc dx
        mov ax, bx
        test ah, 32             ; odd brick row?
        jz .even
        add al, 16              ; shift it by half a brick
.even:  and ax, 0x1F1F          ; position inside the brick (0..31, 0..31)
        sub ax, 0x0302          ; negative near the left or top edge...
        or al, ah               ; ...so the sign bit says "mortar"
        mov al, 14              ; mortar: dark
        js .mortar
        shr ah, 1
        mov al, 50
        sub al, ah              ; brick: lighter at the top, darker below
.mortar:
        mov cl, dh
        and cl, 7
        add al, cl              ; a little noise
        test bl, bl
        jns .light
        sub al, 12              ; darker copy for u >= 128
.light: mov [gs:bx], al
        inc bx
        jnz .tex

; ============================================================================
frame:
        mov ax, [0x046C]        ; BIOS timer tick counter
.tick:  cmp ax, [0x046C]
        je .tick                ; wait until it changes

        ; ---- keyboard: the last scancode from the keyboard controller --------
        in al, 0x60
        sub al, 0x4C            ; left -1, right +1, up -4, down +4
        mov si, bp              ; si -> dir x
        lea di, [bp+DIRY]       ; di -> dir y
        cmp al, 1
        je .turn
        xchg si, di             ; left turn = the exact reverse of a right turn
        cmp al, -1
        jne .walk
.turn:  mov ecx, [di]           ; rotate the direction (Minsky's circle trick):
        sar ecx, 5              ;   a = a - b/32
        sub [si], ecx
        mov ecx, [si]           ;   b = b + a/32
        sar ecx, 5
        add [di], ecx
.walk:  mov si, [bp+DIRX+2]     ; step = view direction
        mov dx, [bp+DIRY+2]
        cmp al, -4
        je .go
        neg si                  ; down: step backwards
        neg dx
        cmp al, 4
        jne .stand
.go:    push si
        push dx
        call march              ; how far is the next wall that way?
        pop dx
        pop si
        cmp cx, 4*8             ; closer than 4 steps: don't move
        jb .stand
        add [bp+PX], si
        add [bp+PY], dx
.stand: mov eax, [bp+PX]        ; px*16 and py*16 (the low 4 bits of the y half
        shl eax, 4              ; get px's top bits: harmless for the floor)
        mov [bp+PX16], eax

        ; ---- one ray per screen column ----------------------------------------
        mov cx, -160            ; cx = column - 160
column: push cx
        mov ax, cx              ; ray = dir + perpendicular(dir) * cx/256
        imul word [bp+DIRY+2]   ; (the perpendicular of (x,y) is (-y,x);
        sar ax, 8               ;  cx/256 goes -0.625..0.625: a 64 degree view)
        mov si, [bp+DIRX+2]
        sub si, ax
        mov ax, cx
        imul word [bp+DIRX+2]
        sar ax, 8
        add ax, [bp+DIRY+2]
        xchg ax, dx             ; ray step = (si, dx)
        mov [bp+SX], si
        mov [bp+SY], dx
        call march              ; cx = distance, (bx, di) = point in the wall
        mov [bp+N], cx
        lea ax, [bx+di]         ; texture column = position along the wall:
        shr ax, 4               ;   on a wall facing x, x hardly changes, so x+y
        mov cx, bx              ;   works for both kinds of wall
        sub cx, si
        xor cx, bx
        cmp ch, 16              ; did the last step change the x cell? CF=1: no,
        rcr al, 1               ; so it hit a wall facing y: use the darker half
        mov [bp+U], al

        ; ---- draw the column in pairs of rows, from the top/bottom edges in ---
        ;      Row 99-j and row 100+j are the same distance from the middle.
        ;      cx = 2*j+1 = "h". A row pair is wall while h * distance < 32768.
        pop di
        push di
        add di, 160 + 199*320   ; di = bottom row
        lea si, [di - 199*320]  ; si = top row
        mov cx, 199
        mov dl, 255             ; light for walls that fill the whole column
.pair:  mov ax, cx
        imul ax, [bp+N]         ; overflow (CF) = too far from the middle: floor
        jc .flat
        or ah, 0x80             ; texture row: 128..255 going down
        mov al, [bp+U]
        xchg ax, bx             ; bx = texel address (row, column)
        mov dh, 128             ; ramp 2 (bottom half), ramp 1 (top half)
        jmp .tail               ; dl is still the light of the floor next to
                                ; the wall's foot, so walls fade like the floor
.flat:  xor ax, ax              ; floor and ceiling:
        cwd
        inc dx                  ; dx:ax = 65536
        div cx                  ; floor distance = 65536 / h
        push ax
        imul word [bp+SX]       ; floor point = player + ray * distance
        add ax, [bp+PX16]       ; (only the part inside the cell matters)
        mov bl, ah
        shr bl, 2               ; floor slabs: twice the brick size
        pop ax
        imul word [bp+SY]
        add ax, [bp+PX16+2]
        shr ah, 1
        mov bh, ah              ; bx = texel address
        mov dx, cx              ; dh = 0: ramp 0 floor, ramp 3 ceiling
        add dl, dl              ; light = min(255, 2*h): fades with distance
        jnc .tail
        mov dl, 255
.tail:  mov al, [gs:bx]
        mul dl                  ; texel * light / 256
        add ah, dh              ; + ramp
        mov [fs:di], ah         ; bottom pixel
        not bh                  ; mirrored texture row for the top half
        sub dh, 64              ; and the ramp below it
        mov al, [gs:bx]
        mul dl
        add ah, dh
        mov [fs:si], ah         ; top pixel
        sub di, 320
        add si, 320
        sub cx, 2
        jg .pair

        pop cx
        inc cx
        cmp cx, 160
        jl column

        mov si, di              ; copy the finished picture to the screen:
        mov ch, cl              ; cx >= 32768 words, so it wraps round the whole
        fs rep movsw            ; 64K segment; any start offset works if si = di
        jmp frame

; ============================================================================
; march: walk a ray from the player until it is inside a wall.
;   in:  (si, dx) = coarse step (one view direction length)
;   out: cx = distance in 1/8 steps, (bx, di) = first point inside the wall
; First in coarse steps, then back one step and on in 1/8 steps: fast and exact.
march:  mov bx, [bp+PX]
        mov di, [bp+PY]
        xor cx, cx
        call .steps             ; coarse steps until inside a wall
        sub bx, si              ; one step back
        sub di, dx
        dec cx
        shl cx, 3               ; count in 1/8 steps from now on
        sar si, 3
        sar dx, 3               ; fall through: fine steps, then return
.steps: inc cx
        add bx, si
        add di, dx
        mov ax, di
        shr ax, 12              ; ax = cell y
        shld ax, bx, 4          ; ax = cell y * 16 + cell x
        bt [bp+MAP], ax         ; CF = wall bit
        jnc .steps
        ret

; ---- the original 16x16 map: one word per row, bit x = wall at column x ----
map:    dw 65535, 36865, 36929, 40897, 33281, 33281, 36927, 32801
        dw 65057, 34833, 34817, 32769, 45695, 41489, 41473, 65535

px:     dw 14*4096+2048         ; start in the middle of cell (14,13)...
py:     dw 13*4096+2048
diry:   dd -200 << 16           ; ...looking north, down a long corridor

tints:  db 32, 28, 26           ; ramp 0: floor, grey stone
        db 61, 28, 14           ; ramp 1: walls (top half), brick
        db 61, 28, 14           ; ramp 2: walls (bottom half)
        db  0, 10, 16           ; ramp 3: ceiling, dark blue
vars:   dd 0                    ; view direction x (starts at 0); after it come
                                ; the scratch variables, in the zero padding

        times 510 - ($ - $$) db 0
        dw 0xAA55               ; boot signature
