; glyph - pure x86_64 asm TTF rasterizer
;
; Two build modes (selected by `GLYPH_LIB` preprocessor define):
;   default        -> CLI tool, includes _start + PGM output to stdout
;                     `nasm -f elf64 glyph.asm -o glyph.o && ld glyph.o -o glyph`
;   GLYPH_LIB set  -> engine only (no _start, no PGM, no argv parsing)
;                     intended for %include from other CHasm tools (e.g. glass)
;                     via the thin glyph.inc shim.
;
; Public engine API (always available):
;   glyph_load_font(rdi=path)              -> rax=0 ok / 1..6 error
;   glyph_set_weight(rdi=weight)           -> sets variation weight
;   glyph_render_to_alpha(rdi=cp, rsi=size)
;       -> rax=0 ok / 1=missing / 3=oversize
;          rcx=W rdx=H r8=bearing_x r9=bearing_y r10=advance
;          alpha mask in output_buf (W*H bytes, 0..255)

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_FSTAT       5
%define SYS_MMAP        9
%define SYS_MUNMAP      11
%define SYS_EXIT        60

%define O_RDONLY        0
%define PROT_READ       1
%define MAP_PRIVATE     2

%define STDOUT          1
%define STDERR          2

%define ST_SIZE_OFF     48      ; struct stat.st_size byte offset

; ---------------------------------------------------------------------
section .data

%ifndef GLYPH_LIB
usage_msg:      db "usage: glyph FONT.ttf CODEPOINT SIZE [WEIGHT]", 10
                db "       glyph FONT.ttf STRING SIZE [WEIGHT]", 10
                db "       (WEIGHT only meaningful for variable fonts; default = fvar default, e.g. 400)", 10
usage_len       equ $ - usage_msg

err_open:       db "glyph: open failed", 10
err_open_len    equ $ - err_open

err_fstat:      db "glyph: fstat failed", 10
err_fstat_len   equ $ - err_fstat

err_mmap:       db "glyph: mmap failed", 10
err_mmap_len    equ $ - err_mmap

err_sfnt:       db "glyph: not a TTF/SFNT file", 10
err_sfnt_len    equ $ - err_sfnt

err_table:      db "glyph: required table missing", 10
err_table_len   equ $ - err_table

err_cmap:       db "glyph: no usable cmap subtable (need format 4)", 10
err_cmap_len    equ $ - err_cmap

err_glyph:      db "glyph: codepoint not in font", 10
err_glyph_len   equ $ - err_glyph

err_compos:     db "glyph: composite glyphs not supported in v0", 10
err_compos_len  equ $ - err_compos

err_too_many:   db "glyph: outline too large for static buffers", 10
err_too_many_len equ $ - err_too_many

err_too_big:    db "glyph: rasterized image exceeds buffer", 10
err_too_big_len equ $ - err_too_big

err_edges:      db "glyph: too many edges", 10
err_edges_len   equ $ - err_edges

err_str_long:   db "glyph: string too long (max 256 chars)", 10
err_str_long_len equ $ - err_str_long

pgm_magic:      db "P5", 10
pgm_magic_len   equ $ - pgm_magic

dump_dim_lbl:   db "image: W="
dump_dim_lbl_len equ $ - dump_dim_lbl
dump_h_lbl:     db ", H="
dump_h_lbl_len  equ $ - dump_h_lbl
dump_bigw_lbl:  db ", bigW="
dump_bigw_lbl_len equ $ - dump_bigw_lbl
dump_bigh_lbl:  db ", bigH="
dump_bigh_lbl_len equ $ - dump_bigh_lbl
dump_edges_lbl: db ", edges="
dump_edges_lbl_len equ $ - dump_edges_lbl

edge_lbl_y:     db ": y["
edge_lbl_y_len  equ $ - edge_lbl_y
edge_lbl_x0:    db ") x0="
edge_lbl_x0_len equ $ - edge_lbl_x0
edge_lbl_dir:   db " dir="
edge_lbl_dir_len equ $ - edge_lbl_dir

dump_outline_lbl:  db "outline: numContours="
dump_outline_lbl_len equ $ - dump_outline_lbl
dump_npts_lbl:     db ", numPoints="
dump_npts_lbl_len  equ $ - dump_npts_lbl
dump_bbox_lbl:     db ", bbox=["
dump_bbox_lbl_len  equ $ - dump_bbox_lbl
dump_comma:        db ","
dump_close:        db "]", 10
dump_close_len     equ $ - dump_close

dump_head_lbl:  db "head: unitsPerEm="
dump_head_lbl_len equ $ - dump_head_lbl
dump_maxp_lbl:  db ", numGlyphs="
dump_maxp_lbl_len equ $ - dump_maxp_lbl
dump_hhea_lbl:  db ", ascent="
dump_hhea_lbl_len equ $ - dump_hhea_lbl
dump_desc_lbl:  db ", descent="
dump_desc_lbl_len equ $ - dump_desc_lbl
dump_lf_lbl:    db ", locFormat="
dump_lf_lbl_len equ $ - dump_lf_lbl

dump_glyph_lbl: db "glyph_id="
dump_glyph_lbl_len equ $ - dump_glyph_lbl
dump_off_lbl:   db ", glyf_off="
dump_off_lbl_len equ $ - dump_off_lbl
dump_glen_lbl:  db ", glyf_len="
dump_glen_lbl_len equ $ - dump_glen_lbl

dump_hdr:       db "SFNT tables:", 10
dump_hdr_len    equ $ - dump_hdr

space_str:      db " "
nl_str:         db 10
%endif  ; !GLYPH_LIB

; required tables (4-char ASCII tags, big-endian on disk so stored as-is)
tag_head:       db "head"
tag_maxp:       db "maxp"
tag_hhea:       db "hhea"
tag_hmtx:       db "hmtx"
tag_cmap:       db "cmap"
tag_loca:       db "loca"
tag_glyf:       db "glyf"
; optional (variable fonts only)
tag_fvar:       db "fvar"
tag_gvar:       db "gvar"
tag_avar:       db "avar"
; variation axis tags
tag_wght:       db "wght"

; ---------------------------------------------------------------------
; Gamma LUT — coverage-bin (0..16, since SS=4 → 16 samples per pixel) to
; perceptual alpha (0..255). Maps linear coverage through gamma γ ≈ 1.43
; (alpha = 255·cov^0.7), matching FreeType's default "stem darkening"
; correction for sRGB displays. Without it, mid-coverage (8/16) maps to
; alpha 128 — which a 2.2-gamma monitor displays at ~22% perceived
; brightness, making anti-aliased text look thin and pale. With
; γ-correction, 50%-cov pixels emit alpha 148 → ~31% perceived → bolder,
; closer to what FreeType+XRender produces for kitty.
gamma_lut:      db 0, 35, 56, 74, 91, 106, 120, 134, 148, 161, 174, 186, 199, 211, 222, 234, 255

; ---------------------------------------------------------------------
section .bss

stat_buf:       resb 144

; ---- per-render arguments (re-set on every call; NOT part of the
;      multi-font snapshot block below) ----
arg_font_path:  resq 1          ; pointer
arg_codepoint:  resq 1          ; parsed integer
arg_size:       resq 1          ; parsed integer (pixel size)
arg_weight:     resq 1          ; user-requested weight (0 = default)
norm_coord_q:   resq 1          ; normalized weight in F2DOT14
oblique_mode:   resb 1          ; 1 = apply 12° shear post-rasterise
synthetic_bold_mode: resb 1     ; 1 = horizontal alpha-dilation by 1px
alignb 8

; ──────────────────────────────────────────────────────────────────
; PER-FONT STATE — contiguous block, save/restored as a single
; memcpy via glyph_save_pf_state / glyph_restore_pf_state. Glass
; loads N fonts (regular / italic / bold / bold-italic / emoji /
; …), saves each one's parsed state into a slot, and swaps slots
; before each render. Adding fields here automatically makes them
; per-font; per-render scratch must live OUTSIDE this block.
; ──────────────────────────────────────────────────────────────────
glyph_pf_state:

; mmap state
font_fd:        resq 1
font_base:      resq 1          ; mmap base address
font_size:      resq 1          ; mmap length

; per-table base+length (offset from font_base, length in bytes)
tbl_head_off:   resq 1
tbl_head_len:   resq 1
tbl_maxp_off:   resq 1
tbl_maxp_len:   resq 1
tbl_hhea_off:   resq 1
tbl_hhea_len:   resq 1
tbl_hmtx_off:   resq 1
tbl_hmtx_len:   resq 1
tbl_cmap_off:   resq 1
tbl_cmap_len:   resq 1
tbl_loca_off:   resq 1
tbl_loca_len:   resq 1
tbl_glyf_off:   resq 1
tbl_glyf_len:   resq 1
tbl_fvar_off:   resq 1
tbl_fvar_len:   resq 1
tbl_gvar_off:   resq 1
tbl_gvar_len:   resq 1
tbl_avar_off:   resq 1
tbl_avar_len:   resq 1

; ---- variable-font state (zero unless fvar present) ----
fvar_axis_count:        resq 1
fvar_wght_default:      resq 1          ; in user units (e.g. 400)
fvar_wght_min:          resq 1
fvar_wght_max:          resq 1

; ---- gvar parsed state ----
gvar_axis_count:        resq 1
gvar_shared_count:      resq 1
gvar_shared_ptr:        resq 1          ; absolute pointer to shared tuples
gvar_glyph_count:       resq 1
gvar_flags:             resq 1
gvar_data_array_ptr:    resq 1          ; absolute pointer to data array
gvar_offsets_ptr:       resq 1          ; absolute pointer to offset array

; ---- parsed head ----
head_unitsPerEm:        resq 1          ; u16, unsigned
head_locFormat:         resq 1          ; 0 = short, 1 = long
head_xMin:              resq 1          ; signed
head_yMin:              resq 1
head_xMax:              resq 1
head_yMax:              resq 1

; ---- parsed maxp ----
maxp_numGlyphs:         resq 1          ; u16

; ---- parsed hhea ----
hhea_ascent:            resq 1          ; signed
hhea_descent:           resq 1
hhea_lineGap:           resq 1
hhea_numLongMetrics:    resq 1          ; u16

; ---- cmap ----
cmap_subtable_ptr:      resq 1          ; absolute pointer to chosen subtable
cmap_segCount:          resq 1
cmap_endCode_ptr:       resq 1
cmap_startCode_ptr:     resq 1
cmap_idDelta_ptr:       resq 1
cmap_idRangeOffset_ptr: resq 1

glyph_pf_state_end:
GLYPH_PF_STATE_SIZE equ glyph_pf_state_end - glyph_pf_state

; small scratch buffers (per-render, NOT part of the per-font block)
hex_buf:        resb 32
dec_buf:        resb 32

; ---- per-codepoint resolution (per-render) ----
glyph_id:               resq 1
glyf_off:               resq 1          ; absolute file offset of this glyph's glyf entry
glyf_len:               resq 1          ; bytes (0 = empty glyph)

%ifndef GLYPH_LIB
; ---- string mode (CLI only) ----
%define MAX_STR_GLYPHS  256
str_mode:               resq 1
str_len:                resq 1
str_total_W:            resq 1
str_glyph_ids:          resd MAX_STR_GLYPHS
str_pen_x_fix:          resd MAX_STR_GLYPHS
str_baseline_fix:       resq 1
%endif

; ---- parse_simple_into transient state (single-call only — no recursion) ----
_ps_nc:                 resq 1
_ps_npts:               resq 1

; ---- parsed outline (simple glyph) ----
%define MAX_POINTS      2048
%define MAX_CONTOURS    64

out_numContours:        resq 1
out_numPoints:          resq 1
out_xMin:               resq 1
out_yMin:               resq 1
out_xMax:               resq 1
out_yMax:               resq 1

contour_end:            resd MAX_CONTOURS       ; u16-ish, but stored as u32 for simplicity
pt_x:                   resd MAX_POINTS         ; signed font units
pt_y:                   resd MAX_POINTS
pt_flags:               resb MAX_POINTS         ; original TTF flag byte (need only ON_CURVE bit)

; ---- gvar transient state (single-glyph pass) ----
%define MAX_GVAR_PTS    (MAX_POINTS + 4)        ; outline + 4 phantom points
_gv_walk:               resq 1
_gv_data_end:           resq 1
_gv_data_block:         resq 1
_gv_npts_glyph:         resq 1
_gv_shared_n:           resq 1
_gv_shared_all:         resq 1
_gv_shared:             resw MAX_GVAR_PTS
_gv_pts_n:              resq 1
_gv_pts:                resw MAX_GVAR_PTS
_gv_x_deltas:           resw MAX_GVAR_PTS
_gv_y_deltas:           resw MAX_GVAR_PTS
_gv_peak:               resw 4
_gv_int_start:          resw 4
_gv_int_end:            resw 4
_gv_have_intermediate:  resq 1
_gv_scalar_q:           resq 1
_gv_size_tmp:           resq 1
_ag_start_contours:     resq 1          ; first contour index for current apply call

; ---- IUP (Interpolation of Untouched Points) per-tuple state ----
_gv_dx_dense:           resd MAX_POINTS         ; dense per-point i32 X delta
_gv_dy_dense:           resd MAX_POINTS         ; dense per-point i32 Y delta
_gv_touched:            resb MAX_POINTS         ; 1 if explicit, 0 if inferred

; ---- rasterizer state ----
%define SS              4                       ; supersample factor
%define MAX_OUT_DIM     512                     ; max output W or H
%define MAX_BIG_DIM     (MAX_OUT_DIM * SS)
%define MAX_EDGES       8192
%define BEZIER_SUBDIV   8                       ; quadratic flatten steps
%define FLATTEN_TOL     32                      ; recursive Bezier flatness threshold (16.16)

img_W:                  resq 1                  ; output pixel width
img_H:                  resq 1                  ; output pixel height
img_bigW:               resq 1                  ; SS*W
img_bigH:               resq 1                  ; SS*H
img_scaleFix:           resq 1                  ; (pixelSize * SS * 65536) / unitsPerEm

; transformed (in 16.16 fixed, big-pixel space, Y flipped)
big_x:                  resd MAX_POINTS
big_y:                  resd MAX_POINTS

; edge list — five parallel arrays
e_ymin:                 resd MAX_EDGES          ; integer scanline (inclusive)
e_ymax:                 resd MAX_EDGES          ; integer scanline (exclusive)
e_x0:                   resd MAX_EDGES          ; x at top scanline center, 16.16
e_dx:                   resd MAX_EDGES          ; dx per +1y scanline, 16.16
e_dir:                  resb MAX_EDGES          ; +1 or -1
e_count:                resq 1

; supersample buffer (1 byte per big-pixel; 0 or 1)
big_buffer:             resb (MAX_BIG_DIM * MAX_BIG_DIM)

; output greyscale buffer
output_buf:             resb (MAX_OUT_DIM * MAX_OUT_DIM)
; Scratch row buffer for in-place shear (one row × MAX_OUT_DIM bytes).
post_row_tmp:           resb MAX_OUT_DIM

%ifndef GLYPH_LIB
; PGM header scratch (CLI only)
pgm_hdr:                resb 64
%endif

; ---------------------------------------------------------------------
section .text

%ifndef GLYPH_LIB
global _start

_start:
        mov     rbp, rsp                ; for argv access
        mov     rax, [rbp]              ; argc
        cmp     rax, 4
        jl      .usage
        cmp     rax, 5
        jg      .usage
        ; If 5 args, the 5th is the weight (variable fonts).
        cmp     rax, 5
        jne     .no_weight
        mov     rdi, [rbp + 40]
        call    parse_decimal
        mov     [arg_weight], rax
        jmp     .have_weight
.no_weight:
        mov     qword [arg_weight], 0   ; 0 = use fvar default (or N/A)
.have_weight:

        mov     rdi, [rbp + 16]         ; argv[1] = font path
        mov     [arg_font_path], rdi

        mov     rdi, [rbp + 32]         ; argv[3] = size (always last)
        call    parse_decimal
        mov     [arg_size], rax

        ; Decide string vs single-CP mode by argv[2][0]: digit -> CP, else string.
        mov     rdi, [rbp + 24]
        movzx   eax, byte [rdi]
        sub     eax, '0'
        cmp     eax, 9
        ja      .string_mode

        ; --- single-codepoint mode (legacy CLI) ---
        mov     qword [str_mode], 0
        call    parse_decimal
        mov     [arg_codepoint], rax
        jmp     .have_args
.string_mode:
        mov     qword [str_mode], 1
.have_args:

        ; --- load + parse the font (single API call) ---
        mov     rdi, [arg_font_path]
        call    glyph_load_font
        test    rax, rax
        jz      .loaded
        cmp     rax, 1
        je      .err_open
        cmp     rax, 2
        je      .err_fstat
        cmp     rax, 3
        je      .err_mmap
        cmp     rax, 4
        je      .err_sfnt
        cmp     rax, 5
        je      .err_table
        cmp     rax, 6
        je      .err_cmap
.loaded:
        ; weight already passed to arg_weight; recompute norm coord (load did
        ; it once with the value we set before; re-do in case arg_weight was 0
        ; and the font's fvar default differs)
        mov     rdi, [arg_weight]
        call    glyph_set_weight

        cmp     qword [str_mode], 0
        jne     .render_string

        ; ===== single-codepoint mode =====
        mov     rdi, [arg_codepoint]
        mov     rsi, [arg_size]
        call    glyph_render_to_alpha
        cmp     eax, 1
        je      .err_glyph
        cmp     eax, 3
        je      .err_too_big

        ; Empty glyph (no outline, e.g. space) — emit a placeholder PGM.
        cmp     qword [img_W], 0
        je      .empty_glyph

        call    emit_pgm
        xor     edi, edi
        jmp     .exit

.empty_glyph:
        call    emit_empty_pgm
        xor     edi, edi
        jmp     .exit

.render_string:
        ; ===== string mode =====
        mov     rdi, [rbp + 24]          ; argv[2]
        call    string_prepass           ; fills str_glyph_ids[], str_pen_x_fix[], str_total_W, str_len
        cmp     rax, 1
        je      .err_str_long

        ; Compute image H = (ascent - descent) * arg_size / unitsPerEm
        ; (descent stored as signed negative)
        mov     rax, [hhea_ascent]
        sub     rax, [hhea_descent]
        mov     rcx, [arg_size]
        imul    rax, rcx
        mov     rcx, [head_unitsPerEm]
        add     rax, rcx
        dec     rax
        xor     edx, edx
        div     rcx
        mov     [img_H], rax

        mov     rax, [str_total_W]
        mov     [img_W], rax

        cmp     qword [img_W], MAX_OUT_DIM
        ja      .err_too_big
        cmp     qword [img_H], MAX_OUT_DIM
        ja      .err_too_big

        mov     rax, [img_W]
        shl     rax, 2
        mov     [img_bigW], rax
        mov     rax, [img_H]
        shl     rax, 2
        mov     [img_bigH], rax

        ; scaleFix
        mov     rax, [arg_size]
        shl     rax, 2
        shl     rax, 16
        xor     edx, edx
        div     qword [head_unitsPerEm]
        mov     [img_scaleFix], rax

        mov     qword [e_count], 0
        call    clear_big_buffer

        ; baseline_fix = ascent * scaleFix (in big-pixel 16.16)
        mov     rax, [hhea_ascent]
        imul    rax, [img_scaleFix]
        mov     [str_baseline_fix], rax

        ; iterate string: parse outline + transform + accumulate edges
        xor     rbx, rbx
.s_loop:
        cmp     rbx, [str_len]
        jge     .s_done
        movsxd  rax, dword [str_glyph_ids + rbx*4]
        test    rax, rax
        jz      .s_skip_glyph            ; missing glyph -> blank
        mov     rdi, rax
        call    loca_lookup
        mov     [glyf_off], rax
        mov     [glyf_len], rdx
        cmp     qword [glyf_len], 0
        je      .s_skip_glyph
        push    rbx
        call    parse_glyf
        pop     rbx
        cmp     eax, 2
        je      .err_too_many

        ; gvar for simple outer glyph (composites handled inside
        ; parse_composite_into, per component)
        mov     rdi, [glyf_off]
        push    rbx
        call    be_i16
        pop     rbx
        test    rax, rax
        js      .s_no_gvar
        movsxd  rax, dword [str_glyph_ids + rbx*4]
        mov     rdi, rax
        push    rbx
        xor     rsi, rsi                  ; start_pts = 0
        xor     rdx, rdx                  ; start_contours = 0
        call    apply_gvar_to_simple
        pop     rbx
.s_no_gvar:

        ; transform with this glyph's pen_x_fix and the shared baseline.
        movsxd  rax, dword [str_pen_x_fix + rbx*4]
        mov     rdi, rax                 ; pen_x_fix arg
        mov     rsi, [str_baseline_fix]
        push    rbx
        call    transform_points
        call    generate_edges
        pop     rbx
        cmp     eax, 1
        je      .err_edges
.s_skip_glyph:
        inc     rbx
        jmp     .s_loop
.s_done:
        call    rasterize
        call    box_filter
        call    emit_pgm
        xor     edi, edi
        jmp     .exit

.usage:
        mov     edi, STDERR
        lea     rsi, [usage_msg]
        mov     edx, usage_len
        mov     eax, SYS_WRITE
        syscall
        mov     edi, 1
        jmp     .exit

.err_open:
        lea     rsi, [err_open]
        mov     edx, err_open_len
        jmp     .err_print

.err_fstat:
        lea     rsi, [err_fstat]
        mov     edx, err_fstat_len
        jmp     .err_print

.err_mmap:
        lea     rsi, [err_mmap]
        mov     edx, err_mmap_len
        jmp     .err_print

.err_sfnt:
        lea     rsi, [err_sfnt]
        mov     edx, err_sfnt_len
        jmp     .err_print

.err_table:
        lea     rsi, [err_table]
        mov     edx, err_table_len
        jmp     .err_print

.err_cmap:
        lea     rsi, [err_cmap]
        mov     edx, err_cmap_len
        jmp     .err_print

.err_glyph:
        lea     rsi, [err_glyph]
        mov     edx, err_glyph_len
        jmp     .err_print

.err_compos:
        lea     rsi, [err_compos]
        mov     edx, err_compos_len
        jmp     .err_print

.err_too_many:
        lea     rsi, [err_too_many]
        mov     edx, err_too_many_len
        jmp     .err_print

.err_too_big:
        lea     rsi, [err_too_big]
        mov     edx, err_too_big_len
        jmp     .err_print

.err_edges:
        lea     rsi, [err_edges]
        mov     edx, err_edges_len
        jmp     .err_print

.err_str_long:
        lea     rsi, [err_str_long]
        mov     edx, err_str_long_len
        jmp     .err_print

.err_print:
        mov     edi, STDERR
        mov     eax, SYS_WRITE
        syscall
        mov     edi, 1

.exit:
        mov     eax, SYS_EXIT
        syscall

%endif  ; !GLYPH_LIB

; ---------------------------------------------------------------------
; glyph_load_font — open + mmap + parse all required tables for a TTF.
; Single-font global state (font_base, table offsets, etc.) is set up
; for subsequent glyph_render_to_alpha calls.
;
;   in : rdi = pointer to null-terminated font file path
;   out: rax = 0 ok, otherwise:
;        1 = open failed     2 = fstat failed
;        3 = mmap failed     4 = not an SFNT file
;        5 = required table missing
;        6 = no usable cmap subtable
glyph_load_font:
        push    rbx
        mov     [arg_font_path], rdi

        mov     rax, SYS_OPEN
        mov     rdi, [arg_font_path]
        xor     esi, esi
        xor     edx, edx
        syscall
        test    rax, rax
        js      .e_open
        mov     [font_fd], rax

        mov     rax, SYS_FSTAT
        mov     rdi, [font_fd]
        lea     rsi, [stat_buf]
        syscall
        test    rax, rax
        js      .e_fstat
        mov     rax, [stat_buf + ST_SIZE_OFF]
        mov     [font_size], rax

        mov     rax, SYS_MMAP
        xor     edi, edi
        mov     rsi, [font_size]
        mov     edx, PROT_READ
        mov     r10d, MAP_PRIVATE
        mov     r8, [font_fd]
        xor     r9d, r9d
        syscall
        cmp     rax, -4096
        ja      .e_mmap
        mov     [font_base], rax

        mov     rax, SYS_CLOSE
        mov     rdi, [font_fd]
        syscall

        call    parse_sfnt
        test    rax, rax
        jnz     .e_sfnt

        cmp     qword [tbl_head_off], 0
        je      .e_table
        cmp     qword [tbl_maxp_off], 0
        je      .e_table
        cmp     qword [tbl_cmap_off], 0
        je      .e_table
        cmp     qword [tbl_glyf_off], 0
        je      .e_table
        cmp     qword [tbl_loca_off], 0
        je      .e_table

        call    parse_head
        call    parse_maxp
        call    parse_hhea
        call    parse_fvar
        call    compute_norm_coord
        call    parse_gvar

        call    find_cmap_format4
        test    rax, rax
        jnz     .e_cmap

        xor     eax, eax
        pop     rbx
        ret
.e_open:
        mov     eax, 1
        pop     rbx
        ret
.e_fstat:
        mov     eax, 2
        pop     rbx
        ret
.e_mmap:
        mov     eax, 3
        pop     rbx
        ret
.e_sfnt:
        mov     eax, 4
        pop     rbx
        ret
.e_table:
        mov     eax, 5
        pop     rbx
        ret
.e_cmap:
        mov     eax, 6
        pop     rbx
        ret

; ---------------------------------------------------------------------
; glyph_set_weight — set the active variation weight (variable fonts).
;   in : rdi = weight (0 = use font's fvar default)
;        Recomputes norm_coord_q from arg_weight and fvar defaults.
glyph_set_weight:
        mov     [arg_weight], rdi
        call    compute_norm_coord
        ret

; ---------------------------------------------------------------------
; glyph_save_pf_state — copy the live per-font state into a caller-
; supplied buffer (must be at least GLYPH_PF_STATE_SIZE bytes,
; currently 408 bytes). Used by glass to snapshot a freshly-loaded
; font into one of N slots.
;   in : rdi = destination buffer
;   out: rax = number of bytes copied (= GLYPH_PF_STATE_SIZE)
glyph_save_pf_state:
        push    rsi
        push    rcx
        lea     rsi, [glyph_pf_state]
        mov     rcx, GLYPH_PF_STATE_SIZE / 8
        rep     movsq
        mov     rax, GLYPH_PF_STATE_SIZE
        pop     rcx
        pop     rsi
        ret

; ---------------------------------------------------------------------
; glyph_restore_pf_state — load a previously-saved per-font snapshot
; back into the live state. Subsequent glyph_render_to_alpha calls use
; that font. norm_coord_q is recomputed from the per-render
; arg_weight + the new font's fvar defaults so the same user weight
; gets normalised correctly across font swaps.
;   in : rdi = source buffer (previously filled by glyph_save_pf_state)
glyph_restore_pf_state:
        push    rsi
        push    rcx
        mov     rsi, rdi
        lea     rdi, [glyph_pf_state]
        mov     rcx, GLYPH_PF_STATE_SIZE / 8
        rep     movsq
        pop     rcx
        pop     rsi
        ; Re-derive norm_coord_q for the new font's fvar.
        call    compute_norm_coord
        ret

; ---------------------------------------------------------------------
; glyph_set_oblique — toggle synthetic italic via post-rasterise shear.
;   in : rdi = 0 (off) or 1 (on)
; The shear is applied per-row after rasterise: each row at distance d
; pixels above the baseline shifts d * 13/64 ≈ tan(11.5°) pixels right;
; rows below baseline shift left by the same factor. Output_buf is
; shifted in place; pixels falling outside [0, img_W) are clipped.
; Works on any TTF — no italic font file needed.
glyph_set_oblique:
        mov     [oblique_mode], dil
        ret

; ---------------------------------------------------------------------
; glyph_set_synthetic_bold — toggle synthetic bold via 1-pixel horizontal
; alpha-dilation post-rasterise.
;   in : rdi = 0 (off) or 1 (on)
; Each pixel ORs in the alpha of its left neighbour (bytewise max), so
; stems thicken by one pixel to the right. Acceptable for monospace
; cells with normal side bearing; for tight fonts a stem on the rightmost
; column may clip by 1 px.
glyph_set_synthetic_bold:
        mov     [synthetic_bold_mode], dil
        ret

; ---------------------------------------------------------------------
; apply_post_process — run any enabled post-rasterise effects on
; output_buf. Inputs: r9 = bearing_y (rows above baseline). Preserves
; r9 (and every caller-saved reg the render path needs after this).
apply_post_process:
        push    rax
        push    rbx
        push    rcx
        push    rdx
        push    rsi
        push    rdi
        push    r8
        push    r10
        push    r11
        push    r12
        push    r13
        push    r14

        ; --- Synthetic bold: horizontal 1-px dilation via byte-max.
        ; For each row, walk x = W-1 down to 1 and set buf[x] = max(buf[x],
        ; buf[x-1]). Right-to-left scan keeps each old left neighbour
        ; live before its slot is overwritten.
        cmp     byte [synthetic_bold_mode], 0
        je      .pp_after_bold
        mov     r12, [img_W]
        test    r12, r12
        jz      .pp_after_bold
        mov     r13, [img_H]
        test    r13, r13
        jz      .pp_after_bold
        xor     rcx, rcx                  ; row counter
.pp_b_row:
        cmp     rcx, r13
        jge     .pp_after_bold
        mov     rax, rcx
        imul    rax, r12
        lea     rsi, [output_buf]
        add     rsi, rax                  ; row base
        mov     rbx, r12
        dec     rbx                       ; x = W-1
.pp_b_col:
        test    rbx, rbx
        jz      .pp_b_row_done
        movzx   eax, byte [rsi + rbx]
        movzx   edx, byte [rsi + rbx - 1]
        cmp     dl, al
        jbe     .pp_b_keep
        mov     al, dl
.pp_b_keep:
        mov     [rsi + rbx], al
        dec     rbx
        jmp     .pp_b_col
.pp_b_row_done:
        inc     rcx
        jmp     .pp_b_row

.pp_after_bold:
        ; --- Oblique: per-row horizontal shift. shift_px = (bearing_y -
        ; row) * 13 / 64 (positive shifts right, negative shifts left).
        ; We copy each row to scratch, zero the row, then re-blit cells
        ; into shifted x positions; out-of-range cells silently drop.
        cmp     byte [oblique_mode], 0
        je      .pp_done
        mov     r12, [img_W]
        test    r12, r12
        jz      .pp_done
        mov     r13, [img_H]
        test    r13, r13
        jz      .pp_done
        cmp     r12, MAX_OUT_DIM
        ja      .pp_done                   ; tmp buffer can't hold row
        xor     rcx, rcx                  ; row counter
.pp_o_row:
        cmp     rcx, r13
        jge     .pp_done
        ; shift = (bearing_y - row) * 13 / 64. r9 holds bearing_y.
        mov     rax, r9
        sub     rax, rcx
        imul    rax, 13
        sar     rax, 6                    ; arithmetic >> 6 (signed)
        mov     r11, rax                  ; r11 = signed shift

        ; Compute row base.
        mov     rax, rcx
        imul    rax, r12
        lea     rsi, [output_buf]
        add     rsi, rax                  ; row base in output_buf

        ; Copy row → post_row_tmp.
        lea     rdi, [post_row_tmp]
        mov     rdx, r12                  ; W bytes
.pp_o_copy:
        test    rdx, rdx
        jz      .pp_o_zero_row
        movzx   eax, byte [rsi]
        mov     [rdi], al
        inc     rsi
        inc     rdi
        dec     rdx
        jmp     .pp_o_copy

.pp_o_zero_row:
        ; Zero the row in output_buf.
        mov     rax, rcx
        imul    rax, r12
        lea     rsi, [output_buf]
        add     rsi, rax
        mov     rdx, r12
.pp_o_zero:
        test    rdx, rdx
        jz      .pp_o_blit
        mov     byte [rsi], 0
        inc     rsi
        dec     rdx
        jmp     .pp_o_zero

.pp_o_blit:
        ; Re-blit shifted: for x in 0..W-1, dst_x = x + shift. Skip
        ; out-of-range. r11 = shift (signed).
        mov     rax, rcx
        imul    rax, r12
        lea     r10, [output_buf]
        add     r10, rax                  ; row base
        xor     rbx, rbx                  ; x = 0
.pp_o_blit_col:
        cmp     rbx, r12
        jge     .pp_o_row_done
        mov     rax, rbx
        add     rax, r11                  ; dst_x = x + shift
        js      .pp_o_blit_skip            ; dst_x < 0
        cmp     rax, r12
        jge     .pp_o_blit_skip            ; dst_x >= W
        movzx   edx, byte [post_row_tmp + rbx]
        mov     [r10 + rax], dl
.pp_o_blit_skip:
        inc     rbx
        jmp     .pp_o_blit_col
.pp_o_row_done:
        inc     rcx
        jmp     .pp_o_row

.pp_done:
        pop     r14
        pop     r13
        pop     r12
        pop     r11
        pop     r10
        pop     r8
        pop     rdi
        pop     rsi
        pop     rdx
        pop     rcx
        pop     rbx
        pop     rax
        ret

; ---------------------------------------------------------------------
; glyph_render_to_alpha — render a single glyph for a codepoint at
; the requested pixel size. The alpha mask is left in output_buf
; (img_W × img_H bytes, top-left origin, 0 = transparent, 255 = opaque).
;
;   in : rdi = codepoint   rsi = pixel_size
;   out: rax = 0 ok, 1 = codepoint not in font, 2 = composite
;             unsupported (only top-level composites cause this), 3 = oversize
;        rcx = width                    rdx = height
;        r8  = bearing_x (pixels)       r9  = bearing_y (pixels above baseline)
;        r10 = advance (pixels)
glyph_render_to_alpha:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15

        mov     [arg_codepoint], rdi
        mov     [arg_size], rsi

        mov     rdi, [arg_codepoint]
        call    cmap_lookup
        test    rax, rax
        jz      .e_glyph
        mov     [glyph_id], rax

        mov     rdi, rax
        call    loca_lookup
        mov     [glyf_off], rax
        mov     [glyf_len], rdx
        test    rdx, rdx
        jz      .empty               ; legitimate empty glyph (e.g. space)

        call    parse_glyf
        cmp     eax, 2
        je      .e_oversize

        ; gvar for outer simple glyph
        mov     rdi, [glyf_off]
        call    be_i16
        test    rax, rax
        js      .skip_outer_gvar
        mov     rdi, [glyph_id]
        xor     rsi, rsi
        xor     rdx, rdx
        call    apply_gvar_to_simple
.skip_outer_gvar:

        call    compute_metrics
        cmp     qword [img_W], MAX_OUT_DIM
        ja      .e_oversize
        cmp     qword [img_H], MAX_OUT_DIM
        ja      .e_oversize

        ; Tight-bbox transform: pen_x = -xMin*scaleFix, baseline = yMax*scaleFix
        mov     rax, [out_xMin]
        neg     rax
        imul    rax, [img_scaleFix]
        mov     rdi, rax
        mov     rax, [out_yMax]
        imul    rax, [img_scaleFix]
        mov     rsi, rax
        call    transform_points

        mov     qword [e_count], 0
        call    generate_edges
        cmp     eax, 1
        je      .e_oversize

        call    clear_big_buffer
        call    rasterize
        call    box_filter

        ; bearing_x_pixels = round_to_nearest(xMin * arg_size / unitsPerEm)
        ; bearing_y_pixels = round_to_nearest(yMax * arg_size / unitsPerEm)
        ; idiv truncates toward zero. With pure truncation, two glyphs
        ; whose true bearings sit on opposite sides of an integer (e.g.
        ; 'b' = 13.51 px, 'u' = 12.49 px) collapse to 13 vs 12 — visibly
        ; different baselines in the rendered text. Add ±UPE/2 before
        ; division for symmetric round-to-nearest, so two glyphs with the
        ; same true baseline land on the same integer pixel.
        mov     rcx, [head_unitsPerEm]
        shr     rcx, 1                   ; UPE/2 (positive)

        mov     rax, [out_xMin]
        imul    rax, [arg_size]
        ; symmetric rounding bias: +UPE/2 when rax≥0, -UPE/2 when rax<0
        mov     rdx, rcx
        test    rax, rax
        jns     .br_x_pos
        neg     rdx
.br_x_pos:
        add     rax, rdx
        cqo
        idiv    qword [head_unitsPerEm]
        mov     r8, rax

        mov     rax, [out_yMax]
        imul    rax, [arg_size]
        mov     rdx, rcx
        test    rax, rax
        jns     .br_y_pos
        neg     rdx
.br_y_pos:
        add     rax, rdx
        cqo
        idiv    qword [head_unitsPerEm]
        mov     r9, rax
        ; advance = (hmtx_advance(gid) * arg_size + unitsPerEm/2) / unitsPerEm
        mov     rdi, [glyph_id]
        call    hmtx_advance
        imul    rax, [arg_size]
        mov     rbx, [head_unitsPerEm]
        mov     r11, rbx
        shr     r11, 1
        add     rax, r11
        cqo
        idiv    rbx
        mov     r10, rax

        ; Apply per-render post-process (synthetic bold + oblique). Both
        ; are no-ops when their respective mode flag is 0 — the call
        ; itself is then ~30 cycles, well below glyph cache amortisation.
        call    apply_post_process

        ; Load W and H AFTER all the divisions — cqo clobbers rdx,
        ; so reading img_H into rdx before any cqo would lose it.
        mov     rcx, [img_W]
        mov     rdx, [img_H]

        xor     eax, eax
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

.empty:
        ; Empty glyph (space etc.): zero-size bitmap, advance = hmtx
        mov     qword [img_W], 0
        mov     qword [img_H], 0
        xor     rcx, rcx
        xor     rdx, rdx
        xor     r8, r8
        xor     r9, r9
        mov     rdi, [glyph_id]
        call    hmtx_advance
        imul    rax, [arg_size]
        mov     rbx, [head_unitsPerEm]
        mov     r11, rbx
        shr     r11, 1
        add     rax, r11
        cqo
        idiv    rbx
        mov     r10, rax
        xor     eax, eax
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

.e_glyph:
        mov     eax, 1
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret
.e_oversize:
        mov     eax, 3
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; parse_sfnt: walk the SFNT directory at [font_base] and store offsets
;             for the required tables. Returns 0 on OK, 1 on bad sfnt.
;
; SFNT header layout (12 bytes):
;   u32  sfntVersion       (0x00010000 for TTF, 'OTTO' for OpenType CFF)
;   u16  numTables
;   u16  searchRange
;   u16  entrySelector
;   u16  rangeShift
;
; Then numTables * 16-byte entries:
;   u32  tag
;   u32  checkSum
;   u32  offset
;   u32  length
parse_sfnt:
        push    rbx
        push    r12
        push    r13
        push    r14

        mov     r12, [font_base]
        mov     eax, [r12]
        bswap   eax
        cmp     eax, 0x00010000          ; TrueType
        je      .ok_ver
        cmp     eax, 0x74727565          ; 'true'
        je      .ok_ver
        cmp     eax, 0x4F54544F          ; 'OTTO'
        je      .ok_ver
        mov     eax, 1
        jmp     .ret
.ok_ver:
        movzx   r13d, word [r12 + 4]     ; numTables (BE)
        rol     r13w, 8

        lea     r14, [r12 + 12]
        xor     ebx, ebx
.loop:
        cmp     ebx, r13d
        jge     .done

        mov     eax, [r14]               ; tag bytes verbatim (disk order)
        xor     edi, edi                 ; rdi = destination slot ptr (0 = skip)

        cmp     eax, [tag_head]
        jne     .t1
        lea     rdi, [tbl_head_off]
        jmp     .store
.t1:    cmp     eax, [tag_maxp]
        jne     .t2
        lea     rdi, [tbl_maxp_off]
        jmp     .store
.t2:    cmp     eax, [tag_hhea]
        jne     .t3
        lea     rdi, [tbl_hhea_off]
        jmp     .store
.t3:    cmp     eax, [tag_hmtx]
        jne     .t4
        lea     rdi, [tbl_hmtx_off]
        jmp     .store
.t4:    cmp     eax, [tag_cmap]
        jne     .t5
        lea     rdi, [tbl_cmap_off]
        jmp     .store
.t5:    cmp     eax, [tag_loca]
        jne     .t6
        lea     rdi, [tbl_loca_off]
        jmp     .store
.t6:    cmp     eax, [tag_glyf]
        jne     .t7
        lea     rdi, [tbl_glyf_off]
        jmp     .store
.t7:    cmp     eax, [tag_fvar]
        jne     .t8
        lea     rdi, [tbl_fvar_off]
        jmp     .store
.t8:    cmp     eax, [tag_gvar]
        jne     .t9
        lea     rdi, [tbl_gvar_off]
        jmp     .store
.t9:    cmp     eax, [tag_avar]
        jne     .next
        lea     rdi, [tbl_avar_off]

.store:
        mov     eax, [r14 + 8]
        bswap   eax
        mov     [rdi], rax
        mov     eax, [r14 + 12]
        bswap   eax
        mov     [rdi + 8], rax

.next:
        add     r14, 16
        inc     ebx
        jmp     .loop

.done:
        xor     eax, eax
.ret:
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

%ifndef GLYPH_LIB
; ---------------------------------------------------------------------
; dump_tables: print the resolved offsets+lengths to stderr.
; Each line: "TAG offset=N length=M"
dump_tables:
        push    rbx
        push    r12

        mov     edi, STDERR
        lea     rsi, [dump_hdr]
        mov     edx, dump_hdr_len
        mov     eax, SYS_WRITE
        syscall

        lea     rsi, [tag_head]
        mov     rdx, [tbl_head_off]
        mov     rcx, [tbl_head_len]
        call    dump_one

        lea     rsi, [tag_maxp]
        mov     rdx, [tbl_maxp_off]
        mov     rcx, [tbl_maxp_len]
        call    dump_one

        lea     rsi, [tag_hhea]
        mov     rdx, [tbl_hhea_off]
        mov     rcx, [tbl_hhea_len]
        call    dump_one

        lea     rsi, [tag_hmtx]
        mov     rdx, [tbl_hmtx_off]
        mov     rcx, [tbl_hmtx_len]
        call    dump_one

        lea     rsi, [tag_cmap]
        mov     rdx, [tbl_cmap_off]
        mov     rcx, [tbl_cmap_len]
        call    dump_one

        lea     rsi, [tag_loca]
        mov     rdx, [tbl_loca_off]
        mov     rcx, [tbl_loca_len]
        call    dump_one

        lea     rsi, [tag_glyf]
        mov     rdx, [tbl_glyf_off]
        mov     rcx, [tbl_glyf_len]
        call    dump_one

        pop     r12
        pop     rbx
        ret

; rsi = pointer to 4 tag bytes, rdx = offset, rcx = length
dump_one:
        push    rbx
        push    r12
        push    r13
        mov     r12, rdx
        mov     r13, rcx

        ; print "  TAG "
        mov     edi, STDERR
        push    rsi
        mov     eax, SYS_WRITE
        mov     rsi, rsp
        ; emit two leading spaces
        mov     byte [rsp - 8], ' '
        mov     byte [rsp - 7], ' '
        lea     rsi, [rsp - 8]
        mov     edx, 2
        syscall
        pop     rsi

        mov     edi, STDERR
        mov     edx, 4
        mov     eax, SYS_WRITE
        syscall

        ; " off=" decimal
        mov     edi, STDERR
        lea     rsi, [space_str]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall

        mov     rax, r12
        call    print_dec_stderr

        ; " len=" decimal
        mov     edi, STDERR
        lea     rsi, [space_str]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall

        mov     rax, r13
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [nl_str]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall

        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; parse_decimal: rdi -> null-terminated decimal string.
; returns rax = value (no error reporting, junk yields garbage).
parse_decimal:
        xor     eax, eax
.l:
        movzx   ecx, byte [rdi]
        test    cl, cl
        jz      .done
        sub     ecx, '0'
        cmp     ecx, 9
        ja      .done
        imul    rax, rax, 10
        add     rax, rcx
        inc     rdi
        jmp     .l
.done:
        ret
%endif  ; !GLYPH_LIB

; ---------------------------------------------------------------------
; Big-endian readers. Each takes a pointer in rdi and returns a value
; in rax. Caller-saved (no rbx/r12-r15 use).

be_u16:
        movzx   eax, word [rdi]
        rol     ax, 8
        movzx   eax, ax
        ret

be_i16:
        movzx   eax, word [rdi]
        rol     ax, 8
        movsx   rax, ax
        ret

be_u32:
        mov     eax, [rdi]
        bswap   eax
        ret

; ---------------------------------------------------------------------
; parse_head — pull unitsPerEm, indexToLocFormat, bbox.
; head table layout (relevant fields):
;   u16 majorVersion (0)
;   u16 minorVersion (2)
;   Fixed fontRevision (4)
;   u32 checkSumAdjustment (8)
;   u32 magicNumber (12)
;   u16 flags (16)
;   u16 unitsPerEm (18)
;   LONGDATETIME created (20)  8 bytes
;   LONGDATETIME modified (28) 8 bytes
;   i16 xMin (36), yMin (38), xMax (40), yMax (42)
;   u16 macStyle (44)
;   u16 lowestRecPPEM (46)
;   i16 fontDirectionHint (48)
;   i16 indexToLocFormat (50)
;   i16 glyphDataFormat (52)
parse_head:
        mov     rdi, [font_base]
        add     rdi, [tbl_head_off]
        push    rdi

        add     rdi, 18
        call    be_u16
        mov     [head_unitsPerEm], rax

        mov     rdi, [rsp]
        add     rdi, 36
        call    be_i16
        mov     [head_xMin], rax
        mov     rdi, [rsp]
        add     rdi, 38
        call    be_i16
        mov     [head_yMin], rax
        mov     rdi, [rsp]
        add     rdi, 40
        call    be_i16
        mov     [head_xMax], rax
        mov     rdi, [rsp]
        add     rdi, 42
        call    be_i16
        mov     [head_yMax], rax

        mov     rdi, [rsp]
        add     rdi, 50
        call    be_i16
        mov     [head_locFormat], rax
        add     rsp, 8
        ret

; ---------------------------------------------------------------------
; parse_maxp — numGlyphs at offset 4 (both v0.5 and v1.0 layouts).
parse_maxp:
        mov     rdi, [font_base]
        add     rdi, [tbl_maxp_off]
        add     rdi, 4
        call    be_u16
        mov     [maxp_numGlyphs], rax
        ret

; ---------------------------------------------------------------------
; parse_hhea — ascent/descent/lineGap/numberOfHMetrics.
;   u16 majorVersion (0)
;   u16 minorVersion (2)
;   FWORD ascender (4)
;   FWORD descender (6)
;   FWORD lineGap (8)
;   ... (typo, advanceWidthMax, ...)
;   u16 numberOfHMetrics (34)
parse_hhea:
        mov     rdi, [font_base]
        add     rdi, [tbl_hhea_off]
        push    rdi

        add     rdi, 4
        call    be_i16
        mov     [hhea_ascent], rax
        mov     rdi, [rsp]
        add     rdi, 6
        call    be_i16
        mov     [hhea_descent], rax
        mov     rdi, [rsp]
        add     rdi, 8
        call    be_i16
        mov     [hhea_lineGap], rax

        mov     rdi, [rsp]
        add     rdi, 34
        call    be_u16
        mov     [hhea_numLongMetrics], rax
        add     rsp, 8
        ret

; ---------------------------------------------------------------------
; parse_fvar — populates fvar_axis_count + the wght-axis defaults if
; an fvar table is present. No-op for static fonts.
;
; fvar layout:
;   u16 majorVersion, minorVersion
;   u16 axesArrayOffset      (from start of fvar)
;   u16 reserved
;   u16 axisCount, axisSize
;   u16 instanceCount, instanceSize
;
; Each variation axis record (axisSize bytes, normally 20):
;   u32 axisTag (4 ASCII)
;   Fixed (i32) minValue, defaultValue, maxValue   (16.16)
;   u16 flags, axisNameID
parse_fvar:
        mov     qword [fvar_axis_count], 0
        mov     qword [fvar_wght_default], 400
        mov     qword [fvar_wght_min], 100
        mov     qword [fvar_wght_max], 900

        cmp     qword [tbl_fvar_off], 0
        je      .ret

        push    rbx
        push    r12
        push    r13
        push    r14

        mov     r12, [font_base]
        add     r12, [tbl_fvar_off]

        ; axisCount at offset 8
        lea     rdi, [r12 + 8]
        call    be_u16
        mov     [fvar_axis_count], rax
        mov     r13, rax                 ; nax

        ; axisSize at offset 10 (typically 20)
        lea     rdi, [r12 + 10]
        call    be_u16
        mov     r14, rax                 ; axsz

        ; axesArrayOffset at offset 4
        lea     rdi, [r12 + 4]
        call    be_u16
        lea     rbx, [r12 + rax]         ; rbx -> first axis record

.l:
        test    r13, r13
        jz      .done
        ; tag
        mov     eax, [rbx]               ; raw bytes (disk order)
        cmp     eax, [tag_wght]
        jne     .next
        ; defaultValue at offset 8 (Fixed = 16.16; integer part is the
        ; weight). Take only the integer part.
        lea     rdi, [rbx + 4]
        call    be_u32
        sar     eax, 16
        mov     [fvar_wght_min], rax
        lea     rdi, [rbx + 8]
        call    be_u32
        sar     eax, 16
        mov     [fvar_wght_default], rax
        lea     rdi, [rbx + 12]
        call    be_u32
        sar     eax, 16
        mov     [fvar_wght_max], rax
        jmp     .done
.next:
        add     rbx, r14
        dec     r13
        jmp     .l
.done:
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
.ret:
        ret

; ---------------------------------------------------------------------
; compute_norm_coord — derives normalized coord (F2DOT14) from
; arg_weight + fvar defaults. Stored at [norm_coord_q].
;
;   wght <= default : norm = (wght - default) / (default - min)  -> [-1..0]
;   wght >  default : norm = (wght - default) / (max - default)  -> (0..+1]
;
; F2DOT14: ±1.0 = ±16384.
compute_norm_coord:
        mov     qword [norm_coord_q], 0

        ; If arg_weight == 0, treat as default → norm=0.
        mov     rax, [arg_weight]
        test    rax, rax
        jz      .ret

        mov     rcx, [fvar_wght_default]
        cmp     rax, rcx
        je      .ret                      ; exactly default → 0
        jl      .below

        ; above default: (wght - default) * 16384 / (max - default)
        sub     rax, rcx
        shl     rax, 14
        mov     rcx, [fvar_wght_max]
        sub     rcx, [fvar_wght_default]
        test    rcx, rcx
        jz      .ret
        cqo
        idiv    rcx
        mov     [norm_coord_q], rax
        jmp     .ret

.below:
        sub     rax, rcx                  ; negative
        shl     rax, 14
        mov     rcx, [fvar_wght_default]
        sub     rcx, [fvar_wght_min]
        test    rcx, rcx
        jz      .ret
        cqo
        idiv    rcx
        mov     [norm_coord_q], rax
.ret:
        ret

; ---------------------------------------------------------------------
; parse_gvar — locate gvar arrays. No-op if no gvar.
;
; gvar header (20 bytes):
;   u16 majorVersion (1)
;   u16 minorVersion (0)
;   u16 axisCount
;   u16 sharedTupleCount
;   u32 sharedTuplesOffset            (from gvar start)
;   u16 glyphCount
;   u16 flags                          (bit 0: 0=u16 offsets/2, 1=u32 byte offsets)
;   u32 glyphVariationDataArrayOffset (from gvar start)
;   then offsets[glyphCount + 1]
parse_gvar:
        mov     qword [gvar_glyph_count], 0
        cmp     qword [tbl_gvar_off], 0
        je      .ret
        push    rbx
        push    r12
        mov     r12, [font_base]
        add     r12, [tbl_gvar_off]

        lea     rdi, [r12 + 4]
        call    be_u16
        mov     [gvar_axis_count], rax

        lea     rdi, [r12 + 6]
        call    be_u16
        mov     [gvar_shared_count], rax

        lea     rdi, [r12 + 8]
        call    be_u32
        lea     rbx, [r12 + rax]
        mov     [gvar_shared_ptr], rbx

        lea     rdi, [r12 + 12]
        call    be_u16
        mov     [gvar_glyph_count], rax

        lea     rdi, [r12 + 14]
        call    be_u16
        mov     [gvar_flags], rax

        lea     rdi, [r12 + 16]
        call    be_u32
        lea     rbx, [r12 + rax]
        mov     [gvar_data_array_ptr], rbx

        ; offset array starts right after the header (20 bytes in)
        lea     rbx, [r12 + 20]
        mov     [gvar_offsets_ptr], rbx

        pop     r12
        pop     rbx
.ret:
        ret

; ---------------------------------------------------------------------
; gvar_lookup — rdi = glyph_id. Returns rax = absolute ptr to this
; glyph's variation data; rdx = byte length (0 = no variation data).
gvar_lookup:
        push    rbx
        cmp     qword [gvar_glyph_count], 0
        je      .none
        cmp     rdi, [gvar_glyph_count]
        jge     .none

        mov     rbx, rdi
        mov     rax, [gvar_flags]
        test    rax, 1
        jnz     .long_fmt

        ; short: u16 entries, multiply by 2 for byte offset
        mov     rdi, [gvar_offsets_ptr]
        lea     rdi, [rdi + rbx*2]
        call    be_u16
        shl     rax, 1
        mov     rdx, rax
        mov     rdi, [gvar_offsets_ptr]
        lea     rdi, [rdi + rbx*2 + 2]
        call    be_u16
        shl     rax, 1
        sub     rax, rdx                 ; length
        mov     rdx, rax
        mov     rax, [gvar_data_array_ptr]
        ; need to add the start offset; recompute
        push    rdx
        mov     rdi, [gvar_offsets_ptr]
        lea     rdi, [rdi + rbx*2]
        call    be_u16
        shl     rax, 1
        pop     rdx
        add     rax, [gvar_data_array_ptr]
        jmp     .ret_check
.long_fmt:
        mov     rdi, [gvar_offsets_ptr]
        lea     rdi, [rdi + rbx*4]
        call    be_u32
        push    rax                      ; start_off
        mov     rdi, [gvar_offsets_ptr]
        lea     rdi, [rdi + rbx*4 + 4]
        call    be_u32
        pop     rdx                      ; reuse stack pop into rdx
        ; rdx = start_off, rax = end_off
        mov     rcx, rax
        sub     rcx, rdx
        mov     rsi, rcx                 ; length
        mov     rax, rdx
        add     rax, [gvar_data_array_ptr]
        mov     rdx, rsi
        jmp     .ret_check
.none:
        xor     eax, eax
        xor     edx, edx
.ret:
        pop     rbx
        ret
.ret_check:
        test    rdx, rdx
        jnz     .ret
        xor     eax, eax
        jmp     .ret

; ---------------------------------------------------------------------
; gv_decode_count — read packed count.
;   in : rdi = ptr
;   out: rax = count, rdi = advanced
; encoding:
;   byte == 0     -> caller treats as "all points" sentinel
;   byte <  0x80  -> count = byte
;   byte >= 0x80  -> count = ((byte & 0x7F) << 8) | next_byte
gv_decode_count:
        movzx   eax, byte [rdi]
        inc     rdi
        test    al, 0x80
        jz      .small
        and     eax, 0x7F
        shl     eax, 8
        movzx   ecx, byte [rdi]
        or      eax, ecx
        inc     rdi
.small:
        ret

; ---------------------------------------------------------------------
; gv_decode_points — decode packed point numbers into _gv_pts (and
; sets _gv_pts_n). If the leading count byte is 0, all glyph points
; are referenced; we fill _gv_pts with 0..npts-1 and set _gv_shared_all
; (caller may opt for the "all" sentinel by inspecting _gv_pts_n).
;
;   in : rdi = ptr to packed data
;   out: rdi advanced past consumed bytes
gv_decode_points:
        push    rbx
        push    r12
        push    r13
        push    r14

        movzx   eax, byte [rdi]
        test    al, al
        jnz     .real
        ; "all points": fill _gv_pts with 0..npts_glyph-1
        inc     rdi
        mov     rcx, [_gv_npts_glyph]
        mov     [_gv_pts_n], rcx
        xor     rbx, rbx
.fa:
        cmp     rbx, rcx
        jge     .fa_done
        mov     [_gv_pts + rbx*2], bx
        inc     rbx
        jmp     .fa
.fa_done:
        jmp     .ret

.real:
        call    gv_decode_count          ; rax = total count, rdi = advanced
        mov     [_gv_pts_n], rax
        mov     r14, rax                 ; total

        xor     r12, r12                 ; running point number
        xor     r13, r13                 ; emitted index
.runs:
        cmp     r13, r14
        jge     .ret
        movzx   eax, byte [rdi]
        inc     rdi
        mov     ebx, eax
        and     ebx, 0x7F
        inc     ebx                      ; run length 1..128
        test    al, 0x80
        jz      .u8_run

        ; u16 deltas
.u16_loop:
        test    ebx, ebx
        jz      .runs
        cmp     r13, r14
        jge     .ret
        movzx   eax, byte [rdi]
        shl     eax, 8
        movzx   ecx, byte [rdi + 1]
        or      eax, ecx
        add     rdi, 2
        add     r12, rax
        mov     [_gv_pts + r13*2], r12w
        inc     r13
        dec     ebx
        jmp     .u16_loop

.u8_run:
.u8_loop:
        test    ebx, ebx
        jz      .runs
        cmp     r13, r14
        jge     .ret
        movzx   eax, byte [rdi]
        inc     rdi
        add     r12, rax
        mov     [_gv_pts + r13*2], r12w
        inc     r13
        dec     ebx
        jmp     .u8_loop

.ret:
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; gv_decode_deltas — decode N packed deltas (each i16 logically) into
; the buffer at rsi (each entry a word). N comes from _gv_pts_n.
;   in : rdi = ptr, rsi = output i16 buffer
;   out: rdi advanced
gv_decode_deltas:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15

        mov     r12, rsi                 ; output ptr
        mov     r13, [_gv_pts_n]         ; total
        xor     r14, r14                 ; emitted

.runs:
        cmp     r14, r13
        jge     .ret
        movzx   eax, byte [rdi]
        inc     rdi
        mov     ebx, eax
        and     ebx, 0x3F
        inc     ebx                      ; run length 1..64
        ; bit 7 (0x80) = ZERO deltas, bit 6 (0x40) = WORD deltas (per OT spec /
        ; fontTools); both clear = byte deltas.
        test    al, 0x80
        jnz     .zero_run
        test    al, 0x40
        jnz     .word_run
        ; default → byte deltas
.byte_run:
        test    ebx, ebx
        jz      .runs
        cmp     r14, r13
        jge     .ret
        movsx   eax, byte [rdi]
        inc     rdi
        mov     [r12 + r14*2], ax
        inc     r14
        dec     ebx
        jmp     .byte_run
.word_run:
        test    ebx, ebx
        jz      .runs
        cmp     r14, r13
        jge     .ret
        movzx   eax, byte [rdi]
        shl     eax, 8
        movzx   ecx, byte [rdi + 1]
        or      eax, ecx
        movsx   eax, ax
        add     rdi, 2
        mov     [r12 + r14*2], ax
        inc     r14
        dec     ebx
        jmp     .word_run
.zero_run:
        test    ebx, ebx
        jz      .runs
        cmp     r14, r13
        jge     .ret
        mov     word [r12 + r14*2], 0
        inc     r14
        dec     ebx
        jmp     .zero_run

.ret:
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; gv_compute_scalar — single-axis tuple-variation scalar at the user's
; normalized coord. Implements the OpenType spec literally:
;
;   peak == 0       -> ignore axis (scalar contribution = 1)
;   norm == 0       -> scalar = 0  (we're at the default)
;   norm == peak    -> scalar = 1
;   sign(norm) != sign(peak) -> scalar = 0
;   default region (no explicit intermediate):
;       intStart = 0
;       intEnd   = +/-1 (same sign as peak)   in F2DOT14: ±16384
;   then in either case (default or explicit intermediate):
;       norm in [intStart, peak]: scalar = (norm - intStart) / (peak - intStart)
;       norm in [peak, intEnd]:   scalar = (intEnd - norm)  / (intEnd - peak)
;       else:                     scalar = 0
;
; All values F2DOT14. Output: [_gv_scalar_q].
gv_compute_scalar:
        push    rbx
        push    r12
        movsx   rbx, word [_gv_peak]
        mov     rcx, [norm_coord_q]

        test    rbx, rbx
        jnz     .have_peak
        mov     qword [_gv_scalar_q], 16384
        jmp     .ret
.have_peak:
        test    rcx, rcx
        jz      .zero
        cmp     rcx, rbx
        je      .one

        ; sign(rcx) XOR sign(rbx); if differ, opposite -> 0
        mov     rax, rcx
        xor     rax, rbx
        js      .zero

        ; resolve intermediate bounds
        cmp     qword [_gv_have_intermediate], 0
        jne     .explicit_int
        ; default region: intStart = 0, intEnd = sign(peak) * 16384
        xor     rdx, rdx                  ; intStart
        mov     r12, 16384                ; intEnd magnitude
        test    rbx, rbx
        jns     .ie_set
        neg     r12                       ; intEnd = -16384 if peak negative
.ie_set:
        jmp     .ranges
.explicit_int:
        movsx   rdx, word [_gv_int_start]
        movsx   r12, word [_gv_int_end]

.ranges:
        ; in [intStart, peak] ? -> rising side
        ; (use signed compare; we know peak and norm same sign)
        ; If peak > 0: rising = intStart <= norm <= peak; falling = peak <= norm <= intEnd
        ; If peak < 0: rising = intStart >= norm >= peak; falling = peak >= norm >= intEnd
        ; The unified formulas work as long as we choose the right branch:
        ;   norm "between intStart and peak" means it's nearer the start side
        ;   norm "between peak and intEnd" means it's nearer the end side
        ;
        ; Test by comparing |norm| vs |peak|: if |norm| < |peak|, rising; else falling.
        mov     rax, rcx
        test    rax, rax
        jns     .nA
        neg     rax
.nA:
        mov     rsi, rbx
        test    rsi, rsi
        jns     .pA
        neg     rsi
.pA:
        cmp     rax, rsi
        jl      .rising

.falling:
        ; scalar = (intEnd - norm) / (intEnd - peak)
        ; require norm in [peak, intEnd] (signed if peak>0, reverse if peak<0).
        ; If sign(intEnd) != sign(peak) we'd have weird, but spec ensures same.
        ; bounds check: norm beyond intEnd -> 0
        test    rbx, rbx
        js      .f_neg
        cmp     rcx, r12
        jg      .zero
        jmp     .f_calc
.f_neg:
        cmp     rcx, r12
        jl      .zero
.f_calc:
        mov     rax, r12
        sub     rax, rcx
        shl     rax, 14
        mov     rdi, r12
        sub     rdi, rbx
        test    rdi, rdi
        jz      .zero
        cqo
        idiv    rdi
        mov     [_gv_scalar_q], rax
        jmp     .ret

.rising:
        ; scalar = (norm - intStart) / (peak - intStart)
        ; bounds check: norm before intStart -> 0
        test    rbx, rbx
        js      .r_neg
        cmp     rcx, rdx
        jl      .zero
        jmp     .r_calc
.r_neg:
        cmp     rcx, rdx
        jg      .zero
.r_calc:
        mov     rax, rcx
        sub     rax, rdx
        shl     rax, 14
        mov     rdi, rbx
        sub     rdi, rdx
        test    rdi, rdi
        jz      .zero
        cqo
        idiv    rdi
        mov     [_gv_scalar_q], rax
        jmp     .ret

.one:
        mov     qword [_gv_scalar_q], 16384
        jmp     .ret
.zero:
        mov     qword [_gv_scalar_q], 0
.ret:
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; iup_axis — Interpolation of Untouched Points along one axis.
;   in : rdi = contour start index (absolute, in pt_*[] / _gv_touched)
;        rsi = contour end index (inclusive)
;        rdx = ptr to original coord array (pt_x or pt_y)
;        rcx = ptr to dense delta array (_gv_dx_dense or _gv_dy_dense)
;
; For each untouched point in the contour, compute its delta by
; interpolation between the cyclically-nearest touched neighbours.
; If no touched points in this contour, leave deltas at 0.
iup_axis:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        mov     r12, rdi                 ; contour start
        mov     r13, rsi                 ; contour end (inclusive)
        mov     r14, rdx                 ; coords ptr
        mov     r15, rcx                 ; deltas ptr
        mov     rbp, r13
        sub     rbp, r12
        inc     rbp                      ; n = end - start + 1
        cmp     rbp, 2
        jl      .ret

        ; Any touched in this contour?
        xor     rbx, rbx
.has_loop:
        cmp     rbx, rbp
        jge     .ret
        mov     rax, r12
        add     rax, rbx
        cmp     byte [_gv_touched + rax], 0
        jne     .iter_init
        inc     rbx
        jmp     .has_loop

.iter_init:
        xor     rbx, rbx
.iter:
        cmp     rbx, rbp
        jge     .ret
        mov     rax, r12
        add     rax, rbx
        cmp     byte [_gv_touched + rax], 0
        jne     .nxt

        ; Find prev touched (cyclic backward)
        mov     rcx, rbx
.find_L:
        test    rcx, rcx
        jnz     .dec_L
        mov     rcx, rbp
.dec_L:
        dec     rcx
        cmp     rcx, rbx
        je      .single
        mov     rax, r12
        add     rax, rcx
        cmp     byte [_gv_touched + rax], 0
        je      .find_L
        mov     rdi, rcx                 ; rdi = L (local)

        ; Find next touched (cyclic forward)
        mov     rcx, rbx
.find_R:
        inc     rcx
        cmp     rcx, rbp
        jl      .check_R
        xor     rcx, rcx
.check_R:
        cmp     rcx, rbx
        je      .single_with_L
        mov     rax, r12
        add     rax, rcx
        cmp     byte [_gv_touched + rax], 0
        je      .find_R
        mov     rsi, rcx                 ; rsi = R (local)

        ; Load pos_L, d_L, pos_R, d_R, pos_P
        mov     rax, r12
        add     rax, rdi
        movsxd  r8, dword [r14 + rax*4]  ; pos_L
        movsxd  r10, dword [r15 + rax*4] ; d_L
        mov     rax, r12
        add     rax, rsi
        movsxd  r9, dword [r14 + rax*4]  ; pos_R
        movsxd  r11, dword [r15 + rax*4] ; d_R
        mov     rax, r12
        add     rax, rbx
        movsxd  rdi, dword [r14 + rax*4] ; pos_P (rdi reused as scratch)

        ; Order so r8 = min_pos with corresponding r10 = its delta.
        cmp     r8, r9
        jle     .ordered
        xchg    r8, r9
        xchg    r10, r11
.ordered:
        cmp     r8, r9
        jne     .differ
        ; pos_L == pos_R: use d_L if equal, else 0
        cmp     r10, r11
        jne     .zero_d
        mov     rax, r10
        jmp     .write
.differ:
        cmp     rdi, r8
        jl      .below
        cmp     rdi, r9
        jg      .above
        ; interpolate: delta = d_min + (pos_P - min_pos) * (d_max - d_min) / (max_pos - min_pos)
        mov     rax, rdi
        sub     rax, r8
        mov     rcx, r11
        sub     rcx, r10
        imul    rax, rcx
        mov     rcx, r9
        sub     rcx, r8
        cqo
        idiv    rcx
        add     rax, r10
        jmp     .write
.below:
        mov     rax, r10
        jmp     .write
.above:
        mov     rax, r11
        jmp     .write
.zero_d:
        xor     eax, eax
.write:
        mov     rcx, r12
        add     rcx, rbx
        mov     [r15 + rcx*4], eax
.nxt:
        inc     rbx
        jmp     .iter

.single_with_L:
        mov     rax, r12
        add     rax, rdi
        movsxd  rax, dword [r15 + rax*4]
        mov     rcx, r12
        add     rcx, rbx
        mov     [r15 + rcx*4], eax
        jmp     .nxt
.single:
        ; Only this point is "untouched" in a contour with 1 point — leave 0.
        jmp     .nxt
.ret:
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; apply_gvar_to_simple — apply gvar deltas to a simple glyph's points
; (which may live anywhere in the pt_x[]/pt_y[] arrays — this is what
; lets composite components carry per-weight gvar deltas).
;
;   rdi = glyph_id of the simple glyph whose gvar to read
;   rsi = start_pts       (this component's first point index)
;   rdx = start_contours  (this component's first contour index)
;
; If no gvar or norm_coord_q == 0 (default master), returns early.
; Single-axis variation only (axis 0).  Phantom points are skipped.
apply_gvar_to_simple:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        mov     rbx, rdi                 ; glyph_id
        mov     r15, rsi                 ; start_pts
        mov     [_ag_start_contours], rdx

        cmp     qword [tbl_gvar_off], 0
        je      .ret
        cmp     qword [norm_coord_q], 0
        je      .ret

        ; gvar lookup
        mov     rdi, rbx
        call    gvar_lookup
        test    rdx, rdx
        jz      .ret
        mov     r12, rax                 ; data ptr
        mov     r13, rdx                 ; length
        mov     rcx, r12
        add     rcx, r13
        mov     [_gv_data_end], rcx

        ; npts_glyph = (out_numPoints - start_pts) + 4 phantom
        mov     rax, [out_numPoints]
        sub     rax, r15
        add     rax, 4
        mov     [_gv_npts_glyph], rax

        ; r12 = start of GlyphVariationData. Read tvc + dataOffset.
        mov     rdi, r12
        call    be_u16
        mov     rbp, rax                 ; tvc + flags (low 12 bits = count)
        add     r12, 2
        mov     rdi, r12
        call    be_u16                   ; dataOffset (from start of GVD)
        ; data_block = start_of_GVD + dataOffset = (r12 - 2) + dataOffset
        mov     rcx, r12
        sub     rcx, 2
        add     rcx, rax
        mov     [_gv_data_block], rcx
        add     r12, 2                   ; r12 -> first TupleVariationHeader

        mov     qword [_gv_shared_all], 0
        mov     qword [_gv_shared_n], 0

        ; If SHARED_POINT_NUMBERS bit (bit 15 of tvc) set, the shared
        ; packed point list is at the start of the data block.
        test    rbp, 0x8000
        jz      .no_shared
        mov     rdi, [_gv_data_block]
        ; decode shared points into _gv_pts (temp), then move to _gv_shared
        push    r12
        call    gv_decode_points
        pop     r12
        ; copy _gv_pts -> _gv_shared
        mov     rcx, [_gv_pts_n]
        mov     [_gv_shared_n], rcx
        xor     rbx, rbx
.cs:
        cmp     rbx, rcx
        jge     .cs_done
        movzx   eax, word [_gv_pts + rbx*2]
        mov     [_gv_shared + rbx*2], ax
        inc     rbx
        jmp     .cs
.cs_done:
        ; Advance the data-block pointer past the shared points block.
        mov     [_gv_data_block], rdi
.no_shared:

        ; tuple count = low 12 bits of rbp
        and     rbp, 0x0FFF
        mov     r14, rbp                 ; remaining tuples

.tuple_loop:
        test    r14, r14
        jz      .ret

        ; Tuple header:
        ;   u16 variationDataSize
        ;   u16 tupleIndex (flags + sharedTupleRecordsIndex)
        ;   F2DOT14 peakTuple[axisCount]    (if EMBEDDED_PEAK_TUPLE)
        ;   F2DOT14 intermediateStartTuple[axisCount]
        ;   F2DOT14 intermediateEndTuple[axisCount]   (both if INTERMEDIATE_REGION)
        mov     rdi, r12
        call    be_u16
        mov     [_gv_size_tmp], rax       ; variationDataSize
        add     r12, 2
        mov     rdi, r12
        call    be_u16
        mov     rbx, rax                  ; tupleIndex flags + idx
        add     r12, 2

        ; peak (single axis assumed)
        test    rbx, 0x8000               ; EMBEDDED_PEAK_TUPLE
        jz      .shared_peak
        mov     rdi, r12
        call    be_u16
        mov     [_gv_peak], ax
        add     r12, 2
        jmp     .have_peak
.shared_peak:
        ; peak from shared tuples table at index (low 12 bits of rbx)
        mov     rcx, rbx
        and     rcx, 0x0FFF
        mov     rdi, [gvar_shared_ptr]
        ; each shared tuple = axisCount * F2DOT14 (we assume axisCount=1, so 2 bytes)
        lea     rdi, [rdi + rcx*2]
        call    be_u16
        mov     [_gv_peak], ax
.have_peak:

        mov     qword [_gv_have_intermediate], 0
        test    rbx, 0x4000               ; INTERMEDIATE_REGION
        jz      .no_int
        mov     rdi, r12
        call    be_u16
        mov     [_gv_int_start], ax
        add     r12, 2
        mov     rdi, r12
        call    be_u16
        mov     [_gv_int_end], ax
        add     r12, 2
        mov     qword [_gv_have_intermediate], 1
.no_int:

        ; Compute scalar.
        call    gv_compute_scalar

        ; If scalar == 0, skip to next tuple.
        cmp     qword [_gv_scalar_q], 0
        je      .skip_tuple

        ; --- decode the per-tuple data block at _gv_data_block ---
        mov     rdi, [_gv_data_block]
        ; If PRIVATE_POINT_NUMBERS bit (0x2000) set, private points list
        ; first; else use shared.
        test    rbx, 0x2000
        jnz     .private_pts
        ; copy _gv_shared -> _gv_pts
        mov     rcx, [_gv_shared_n]
        mov     [_gv_pts_n], rcx
        xor     rdx, rdx
.cp_sh:
        cmp     rdx, rcx
        jge     .cp_sh_done
        movzx   eax, word [_gv_shared + rdx*2]
        mov     [_gv_pts + rdx*2], ax
        inc     rdx
        jmp     .cp_sh
.cp_sh_done:
        jmp     .deltas
.private_pts:
        call    gv_decode_points
.deltas:
        ; X deltas
        push    rdi
        lea     rsi, [_gv_x_deltas]
        pop     rdi
        push    rsi
        push    rdi
        ; gv_decode_deltas(rdi, rsi)
        ; We just set both above; reload cleanly:
        pop     rdi
        pop     rsi
        call    gv_decode_deltas
        ; Y deltas
        lea     rsi, [_gv_y_deltas]
        call    gv_decode_deltas

        ; ---- Build dense deltas + touched flags, run IUP, then apply ----
        ; Operate only on this component's slice [start_pts .. out_numPoints).
        push    r15
        mov     rcx, [out_numPoints]
        sub     rcx, r15                  ; npts_this = component's points
        push    rcx                       ; save npts_this
        ; Clear _gv_touched[start_pts .. start_pts + npts_this)
        lea     rdi, [_gv_touched]
        add     rdi, r15
        xor     eax, eax
        rep     stosb
        ; Clear _gv_dx_dense and _gv_dy_dense in same range
        mov     rcx, [rsp]                ; npts_this
        lea     rdi, [_gv_dx_dense]
        lea     rdi, [rdi + r15*4]
        xor     eax, eax
        rep     stosd
        mov     rcx, [rsp]
        lea     rdi, [_gv_dy_dense]
        lea     rdi, [rdi + r15*4]
        xor     eax, eax
        rep     stosd
        pop     rcx                       ; npts_this
        pop     r15
        push    rcx                       ; keep npts_this on stack for fill bound

        ; Fill from explicit deltas (skip phantom & out-of-range indices).
        xor     rdx, rdx
.fill_loop:
        cmp     rdx, [_gv_pts_n]
        jge     .fill_done
        movzx   r8d, word [_gv_pts + rdx*2]
        cmp     r8, qword [rsp]           ; r8 < npts_this
        jge     .fill_skip
        ; absolute index = start_pts + r8
        mov     r9, r15
        add     r9, r8
        mov     byte [_gv_touched + r9], 1
        movsx   eax, word [_gv_x_deltas + rdx*2]
        mov     [_gv_dx_dense + r9*4], eax
        movsx   eax, word [_gv_y_deltas + rdx*2]
        mov     [_gv_dy_dense + r9*4], eax
.fill_skip:
        inc     rdx
        jmp     .fill_loop
.fill_done:
        pop     rcx                       ; discard npts_this

        ; Run IUP per contour for this component only:
        ; contours [start_contours .. out_numContours).
        mov     r10, [_ag_start_contours]
        ; r11 = contour start (absolute pt index). For the FIRST contour of
        ; this component, start = start_pts. Otherwise start = previous
        ; contour_end + 1.
        cmp     r10, 0
        je      .iup_first_glyph
        mov     eax, [contour_end + r10*4 - 4]
        movsxd  r11, eax
        inc     r11
        jmp     .iup_c_loop
.iup_first_glyph:
        mov     r11, r15                  ; start_pts
.iup_c_loop:
        cmp     r10, [out_numContours]
        jge     .iup_c_done
        mov     edx, [contour_end + r10*4]
        push    r10
        push    r11
        push    rdx
        mov     rdi, r11
        movsxd  rsi, edx
        lea     rdx, [pt_x]
        lea     rcx, [_gv_dx_dense]
        call    iup_axis
        pop     rdx
        push    rdx
        mov     rdi, r11
        movsxd  rsi, edx
        lea     rdx, [pt_y]
        lea     rcx, [_gv_dy_dense]
        call    iup_axis
        pop     rdx
        pop     r11
        pop     r10
        movsxd  r11, edx
        inc     r11
        inc     r10
        jmp     .iup_c_loop
.iup_c_done:

        ; Apply scalar*delta to this component's points only.
        mov     rdx, r15
.app_loop:
        cmp     rdx, [out_numPoints]
        jge     .app_done
        movsxd  rax, dword [_gv_dx_dense + rdx*4]
        imul    rax, [_gv_scalar_q]
        sar     rax, 14
        add     [pt_x + rdx*4], eax
        movsxd  rax, dword [_gv_dy_dense + rdx*4]
        imul    rax, [_gv_scalar_q]
        sar     rax, 14
        add     [pt_y + rdx*4], eax
        inc     rdx
        jmp     .app_loop
.app_done:
        ; Advance _gv_data_block past the consumed bytes (variationDataSize)
        mov     rax, [_gv_data_block]
        add     rax, [_gv_size_tmp]
        mov     [_gv_data_block], rax
        jmp     .next_tuple

.skip_tuple:
        ; Just advance data block.
        mov     rax, [_gv_data_block]
        add     rax, [_gv_size_tmp]
        mov     [_gv_data_block], rax

.next_tuple:
        dec     r14
        jmp     .tuple_loop

.ret:
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; find_cmap_format4 — pick a Unicode cmap subtable in format 4 and
; populate cmap_subtable_ptr + segment array pointers.
; Returns 0 on success, 1 if no usable subtable.
;
; cmap header (4 bytes):
;   u16 version
;   u16 numTables
; Then numTables * 8-byte encoding records:
;   u16 platformID
;   u16 encodingID
;   u32 subtableOffset (from cmap table base)
;
; Preferred subtable platform/encoding for Unicode BMP:
;   (3, 1)  Microsoft Unicode BMP
;   (0, *)  Unicode (anything; 0/3 most common for BMP)
find_cmap_format4:
        push    rbx
        push    r12
        push    r13
        push    r14

        mov     r12, [font_base]
        add     r12, [tbl_cmap_off]      ; r12 = cmap table base

        ; numTables
        lea     rdi, [r12 + 2]
        call    be_u16
        mov     r13, rax                 ; r13 = numTables

        lea     r14, [r12 + 4]           ; r14 = first encoding record

        xor     ebx, ebx
        xor     r15, r15                 ; will hold chosen subtable abs ptr (0 = none)
        push    r15                      ; reserve [rsp] = chosen_ptr (avoid using r15 across calls)
.loop:
        cmp     ebx, r13d
        jge     .done

        ; platformID
        mov     rdi, r14
        call    be_u16
        mov     ecx, eax                 ; ecx = platformID

        ; encodingID
        lea     rdi, [r14 + 2]
        call    be_u16
        mov     edx, eax                 ; edx = encodingID

        ; subtableOffset
        lea     rdi, [r14 + 4]
        call    be_u32
        ; rax = offset from cmap base
        lea     rdi, [r12 + rax]         ; rdi = subtable absolute pointer

        ; check format
        push    rdi
        call    be_u16                   ; rax = format
        pop     rdi
        cmp     eax, 4
        jne     .skip

        ; accept (3,1) immediately; (0,*) acceptable as fallback
        cmp     ecx, 3
        jne     .try_uni
        cmp     edx, 1
        jne     .skip
        mov     [rsp], rdi
        jmp     .done                    ; preferred match — stop
.try_uni:
        cmp     ecx, 0
        jne     .skip
        ; only set if no preferred chosen yet
        cmp     qword [rsp], 0
        jne     .skip
        mov     [rsp], rdi
.skip:
        add     r14, 8
        inc     ebx
        jmp     .loop

.done:
        mov     rax, [rsp]
        add     rsp, 8
        test    rax, rax
        jz      .fail
        mov     [cmap_subtable_ptr], rax

        ; subtable layout (format 4):
        ;   u16 format (0)
        ;   u16 length (2)
        ;   u16 language (4)
        ;   u16 segCountX2 (6)
        ;   u16 searchRange (8), entrySelector (10), rangeShift (12)
        ;   u16 endCode[segCount] (14)
        ;   u16 reservedPad
        ;   u16 startCode[segCount]
        ;   i16 idDelta[segCount]
        ;   u16 idRangeOffset[segCount]
        ;   u16 glyphIdArray[]
        mov     rdi, rax
        add     rdi, 6
        push    rax                      ; preserve subtable base
        call    be_u16                   ; segCountX2
        shr     eax, 1
        mov     [cmap_segCount], rax
        mov     rcx, rax                 ; rcx = segCount

        pop     rax                      ; rax = subtable base
        lea     rbx, [rax + 14]          ; endCode
        mov     [cmap_endCode_ptr], rbx

        ; startCode = endCode + segCount*2 + 2 (reservedPad)
        lea     rbx, [rbx + rcx*2]
        add     rbx, 2
        mov     [cmap_startCode_ptr], rbx

        ; idDelta = startCode + segCount*2
        lea     rbx, [rbx + rcx*2]
        mov     [cmap_idDelta_ptr], rbx

        ; idRangeOffset = idDelta + segCount*2
        lea     rbx, [rbx + rcx*2]
        mov     [cmap_idRangeOffset_ptr], rbx

        xor     eax, eax
        jmp     .ret
.fail:
        mov     eax, 1
.ret:
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; cmap_lookup — rdi = codepoint, returns rax = glyph_id (0 = .notdef).
; Linear scan over segments (segCount typically <300, fine for MVP).
cmap_lookup:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15

        mov     r12, rdi                 ; r12 = codepoint
        mov     rcx, [cmap_segCount]
        mov     r13, rcx                 ; r13 = segCount
        xor     ebx, ebx                 ; ebx = i

        mov     r14, [cmap_endCode_ptr]
.find:
        cmp     ebx, r13d
        jge     .notdef
        ; endCode[i]
        lea     rdi, [r14 + rbx*2]
        call    be_u16
        cmp     r12, rax
        jle     .got_seg
        inc     ebx
        jmp     .find
.got_seg:
        ; check startCode[i] <= cp
        mov     rdi, [cmap_startCode_ptr]
        lea     rdi, [rdi + rbx*2]
        call    be_u16
        mov     r15, rax                 ; r15 = startCode[i]
        cmp     r12, rax
        jl      .notdef

        ; idRangeOffset[i]
        mov     rdi, [cmap_idRangeOffset_ptr]
        lea     r14, [rdi + rbx*2]       ; r14 = address of idRangeOffset[i]
        mov     rdi, r14
        call    be_u16
        test    eax, eax
        jz      .delta_only

        ; idRangeOffset != 0:
        ;   glyphAddr = &idRangeOffset[i] + idRangeOffset[i] + 2*(cp - startCode[i])
        ; Note: idRangeOffset is in BYTES per the OT spec computation
        ; (its value is bytes from the field's address).
        mov     rcx, r12
        sub     rcx, r15                 ; cp - startCode
        shl     rcx, 1                   ; *2 (u16 entries)
        add     rcx, rax                 ; + idRangeOffset bytes
        add     rcx, r14                 ; + addr of idRangeOffset[i]
        mov     rdi, rcx
        call    be_u16
        test    eax, eax
        jz      .notdef                  ; missing glyph maps to 0

        ; add idDelta (mod 65536)
        mov     r15d, eax                ; preserve glyph word
        mov     rdi, [cmap_idDelta_ptr]
        lea     rdi, [rdi + rbx*2]
        call    be_i16
        add     rax, r15
        and     rax, 0xFFFF
        jmp     .ret

.delta_only:
        mov     rdi, [cmap_idDelta_ptr]
        lea     rdi, [rdi + rbx*2]
        call    be_i16
        add     rax, r12
        and     rax, 0xFFFF
        jmp     .ret

.notdef:
        xor     eax, eax
.ret:
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; loca_lookup — rdi = glyph_id. Returns rax = absolute file offset of
; the glyph's glyf entry, rdx = byte length (0 = empty glyph).
loca_lookup:
        push    rbx
        push    r12
        push    r13

        mov     r12, rdi                 ; glyph id
        mov     rax, [head_locFormat]
        test    rax, rax
        jnz     .long_fmt

        ; short loca: u16[] entries, actual offset = entry * 2
        mov     rdi, [font_base]
        add     rdi, [tbl_loca_off]
        lea     rbx, [rdi + r12*2]
        mov     rdi, rbx
        call    be_u16
        mov     r13, rax
        shl     r13, 1
        lea     rdi, [rbx + 2]
        call    be_u16
        shl     rax, 1
        sub     rax, r13                 ; rax = length
        mov     rdx, rax
        jmp     .compute_off

.long_fmt:
        mov     rdi, [font_base]
        add     rdi, [tbl_loca_off]
        lea     rbx, [rdi + r12*4]
        mov     rdi, rbx
        call    be_u32
        mov     r13, rax
        lea     rdi, [rbx + 4]
        call    be_u32
        sub     rax, r13                 ; rax = length
        mov     rdx, rax

.compute_off:
        mov     rax, [font_base]
        add     rax, [tbl_glyf_off]
        add     rax, r13

        pop     r13
        pop     r12
        pop     rbx
        ret

%ifndef GLYPH_LIB
; ---------------------------------------------------------------------
; dump_parsed — print head/maxp/hhea + resolved glyf to stderr.
dump_parsed:
        push    rbx

        mov     edi, STDERR
        lea     rsi, [dump_head_lbl]
        mov     edx, dump_head_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [head_unitsPerEm]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_maxp_lbl]
        mov     edx, dump_maxp_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [maxp_numGlyphs]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_hhea_lbl]
        mov     edx, dump_hhea_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [hhea_ascent]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_desc_lbl]
        mov     edx, dump_desc_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [hhea_descent]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_lf_lbl]
        mov     edx, dump_lf_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [head_locFormat]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [nl_str]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall

        ; second line: glyph_id, glyf_off, glyf_len
        mov     edi, STDERR
        lea     rsi, [dump_glyph_lbl]
        mov     edx, dump_glyph_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [glyph_id]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_off_lbl]
        mov     edx, dump_off_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [glyf_off]
        sub     rax, [font_base]         ; show relative for sanity check
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_glen_lbl]
        mov     edx, dump_glen_lbl_len
        mov     eax, SYS_WRITE
        syscall

        mov     rax, [glyf_len]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [nl_str]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall

        pop     rbx
        ret
%endif  ; !GLYPH_LIB

; ---------------------------------------------------------------------
; parse_glyf — TOP-LEVEL entry. Resets accumulators, sets bbox from
; this glyph's own header, then dispatches to the simple or composite
; parser. Returns 0 ok, 2 if storage exhausted.
;
; Glyph header (10 bytes):
;   i16 numContours    (negative = composite)
;   i16 xMin, yMin, xMax, yMax
parse_glyf:
        push    rbx
        push    r12

        mov     qword [out_numPoints], 0
        mov     qword [out_numContours], 0

        mov     r12, [glyf_off]

        lea     rdi, [r12 + 2]
        call    be_i16
        mov     [out_xMin], rax
        lea     rdi, [r12 + 4]
        call    be_i16
        mov     [out_yMin], rax
        lea     rdi, [r12 + 6]
        call    be_i16
        mov     [out_xMax], rax
        lea     rdi, [r12 + 8]
        call    be_i16
        mov     [out_yMax], rax

        mov     rdi, r12
        call    be_i16
        test    rax, rax
        js      .composite

        ; simple top-level
        mov     rdi, r12
        xor     esi, esi
        xor     edx, edx
        call    parse_simple_into
        jmp     .ret

.composite:
        mov     rdi, r12
        call    parse_composite_into

.ret:
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; parse_simple_into(rdi=glyf_off, rsi=dx_font, rdx=dy_font)
; Appends a simple glyph's points/contours starting at out_numPoints/
; out_numContours, adding (dx,dy) to all coords (font units).
; Returns 0 ok, 2 storage exhausted.
;
; Flag bits:
;   0x01 ON_CURVE   0x02 X_SHORT   0x04 Y_SHORT
;   0x08 REPEAT     0x10 X_IS_SAME 0x20 Y_IS_SAME
parse_simple_into:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        mov     r12, rdi                 ; walking pointer
        mov     r15, rsi                 ; dx
        mov     rbp, rdx                 ; dy
        mov     r13, [out_numPoints]     ; start_pts
        mov     r14, [out_numContours]   ; start_contours

        mov     rdi, r12
        call    be_i16
        mov     [_ps_nc], rax

        mov     rdi, r14
        add     rdi, rax
        cmp     rdi, MAX_CONTOURS
        ja      .toomany

        add     r12, 10

        xor     rbx, rbx
.ep_loop:
        cmp     rbx, [_ps_nc]
        jge     .ep_done
        mov     rdi, r12
        call    be_u16
        add     rax, r13
        mov     rcx, r14
        add     rcx, rbx
        mov     [contour_end + rcx*4], eax
        add     r12, 2
        inc     rbx
        jmp     .ep_loop
.ep_done:
        mov     rcx, r14
        add     rcx, [_ps_nc]
        dec     rcx
        mov     eax, [contour_end + rcx*4]
        sub     rax, r13
        inc     rax
        mov     [_ps_npts], rax

        mov     rdi, r13
        add     rdi, rax
        cmp     rdi, MAX_POINTS
        ja      .toomany
        mov     [out_numPoints], rdi
        mov     rdi, r14
        add     rdi, [_ps_nc]
        mov     [out_numContours], rdi

        ; skip instructions
        mov     rdi, r12
        call    be_u16
        add     r12, 2
        add     r12, rax

        ; flags (with REPEAT) -> pt_flags[r13 + i]
        xor     rbx, rbx
.fl_loop:
        cmp     rbx, [_ps_npts]
        jge     .fl_done
        movzx   eax, byte [r12]
        inc     r12
        mov     rdi, r13
        add     rdi, rbx
        mov     [pt_flags + rdi], al
        inc     rbx
        test    al, 0x08
        jz      .fl_loop
        movzx   ecx, byte [r12]
        inc     r12
.fl_rep:
        test    ecx, ecx
        jz      .fl_loop
        cmp     rbx, [_ps_npts]
        jge     .fl_done
        mov     rdi, r13
        add     rdi, rbx
        mov     [pt_flags + rdi], al
        inc     rbx
        dec     ecx
        jmp     .fl_rep
.fl_done:

        ; xCoords -> pt_x[r13 + i], accumulator starts at dx
        mov     r9, r15
        xor     rbx, rbx
.xc_loop:
        cmp     rbx, [_ps_npts]
        jge     .xc_done
        mov     rdi, r13
        add     rdi, rbx
        movzx   eax, byte [pt_flags + rdi]
        test    al, 0x02
        jnz     .x_short
        test    al, 0x10
        jnz     .x_same
        mov     rdi, r12
        call    be_i16
        add     r9, rax
        add     r12, 2
        jmp     .xc_store
.x_short:
        movzx   eax, byte [r12]
        inc     r12
        mov     rdi, r13
        add     rdi, rbx
        movzx   ecx, byte [pt_flags + rdi]
        test    cl, 0x10
        jnz     .x_pos
        neg     eax
.x_pos:
        movsx   rax, eax
        add     r9, rax
        jmp     .xc_store
.x_same:
.xc_store:
        mov     rdi, r13
        add     rdi, rbx
        mov     [pt_x + rdi*4], r9d
        inc     rbx
        jmp     .xc_loop
.xc_done:

        ; yCoords -> pt_y[r13 + i], accumulator starts at dy
        mov     r9, rbp
        xor     rbx, rbx
.yc_loop:
        cmp     rbx, [_ps_npts]
        jge     .yc_done
        mov     rdi, r13
        add     rdi, rbx
        movzx   eax, byte [pt_flags + rdi]
        test    al, 0x04
        jnz     .y_short
        test    al, 0x20
        jnz     .y_same
        mov     rdi, r12
        call    be_i16
        add     r9, rax
        add     r12, 2
        jmp     .yc_store
.y_short:
        movzx   eax, byte [r12]
        inc     r12
        mov     rdi, r13
        add     rdi, rbx
        movzx   ecx, byte [pt_flags + rdi]
        test    cl, 0x20
        jnz     .y_pos
        neg     eax
.y_pos:
        movsx   rax, eax
        add     r9, rax
        jmp     .yc_store
.y_same:
.yc_store:
        mov     rdi, r13
        add     rdi, rbx
        mov     [pt_y + rdi*4], r9d
        inc     rbx
        jmp     .yc_loop
.yc_done:

        xor     eax, eax
        jmp     .ret
.toomany:
        mov     eax, 2
.ret:
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; parse_composite_into(rdi=glyf_off)
; Walks composite components, dispatching each to parse_simple_into
; with the component's xy offset. Components that are themselves
; composite (depth > 1) are skipped — nesting is rare in real fonts.

%define CF_ARG_1_AND_2_ARE_WORDS 0x0001
%define CF_ARGS_ARE_XY_VALUES    0x0002
%define CF_WE_HAVE_A_SCALE       0x0008
%define CF_MORE_COMPONENTS       0x0020
%define CF_HAVE_X_AND_Y_SCALE    0x0040
%define CF_HAVE_TWO_BY_TWO       0x0080

parse_composite_into:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        mov     r12, rdi
        add     r12, 10                  ; past header
.next_comp:
        mov     rdi, r12
        call    be_u16
        mov     r13, rax                 ; flags
        add     r12, 2

        mov     rdi, r12
        call    be_u16
        mov     r14, rax                 ; component glyph_id
        add     r12, 2

        ; arg1, arg2
        test    r13, CF_ARG_1_AND_2_ARE_WORDS
        jz      .args_byte
        mov     rdi, r12
        call    be_i16
        mov     r15, rax
        add     r12, 2
        mov     rdi, r12
        call    be_i16
        mov     rbp, rax
        add     r12, 2
        jmp     .args_done
.args_byte:
        movsx   rax, byte [r12]
        mov     r15, rax
        inc     r12
        movsx   rax, byte [r12]
        mov     rbp, rax
        inc     r12
.args_done:

        ; ARGS_ARE_XY_VALUES → use as offset; else point matching (skip)
        test    r13, CF_ARGS_ARE_XY_VALUES
        jnz     .have_xy
        xor     r15, r15
        xor     rbp, rbp
.have_xy:

        ; Skip optional transform bytes (we don't apply scale yet).
        test    r13, CF_WE_HAVE_A_SCALE
        jz      .check_xy_scale
        add     r12, 2
        jmp     .skip_xform_done
.check_xy_scale:
        test    r13, CF_HAVE_X_AND_Y_SCALE
        jz      .check_2x2
        add     r12, 4
        jmp     .skip_xform_done
.check_2x2:
        test    r13, CF_HAVE_TWO_BY_TWO
        jz      .skip_xform_done
        add     r12, 8
.skip_xform_done:

        ; Look up component's glyf entry via loca.
        mov     rdi, r14
        call    loca_lookup              ; rax = abs ptr, rdx = length
        test    rdx, rdx
        jz      .skip_comp

        ; If component is composite (numContours < 0), skip (no recursion).
        push    rax
        mov     rdi, rax
        call    be_i16
        pop     rdi
        test    rax, rax
        js      .skip_comp

        ; Save the component's start indices for the gvar pass.
        push    qword [out_numPoints]
        push    qword [out_numContours]

        ; parse_simple_into(rdi=glyf_off, rsi=dx, rdx=dy)
        mov     rsi, r15
        mov     rdx, rbp
        call    parse_simple_into
        cmp     eax, 2
        je      .done_pop2

        ; Apply the COMPONENT's own gvar deltas to its newly-added points.
        pop     rdx                       ; start_contours
        pop     rsi                       ; start_pts
        push    rsi                       ; restore for stack discipline
        push    rdx
        mov     rdi, r14                  ; component glyph_id
        ; rsi/rdx already set
        call    apply_gvar_to_simple

        add     rsp, 16                   ; drop the saved start_* values

.skip_comp:
        test    r13, CF_MORE_COMPONENTS
        jnz     .next_comp

.done:
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret
.done_pop2:
        add     rsp, 16
        jmp     .done

%ifndef GLYPH_LIB
; ---------------------------------------------------------------------
; dump_outline — print numContours/numPoints + bbox.
dump_outline:
        push    rbx

        mov     edi, STDERR
        lea     rsi, [dump_outline_lbl]
        mov     edx, dump_outline_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [out_numContours]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_npts_lbl]
        mov     edx, dump_npts_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [out_numPoints]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_bbox_lbl]
        mov     edx, dump_bbox_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [out_xMin]
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [dump_comma]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [out_yMin]
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [dump_comma]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [out_xMax]
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [dump_comma]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [out_yMax]
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [dump_close]
        mov     edx, dump_close_len
        mov     eax, SYS_WRITE
        syscall

        pop     rbx
        ret

%endif  ; !GLYPH_LIB

; ---------------------------------------------------------------------
; compute_metrics — fills img_W/H, img_bigW/H, img_scaleFix.
;
; pixelSize = arg_size
; scale     = pixelSize / unitsPerEm
; W = ceil((xMax - xMin) * scale)
; H = ceil((yMax - yMin) * scale)
; scaleFix  = (pixelSize * SS * 65536) / unitsPerEm   (16.16 fixed)
compute_metrics:
        ; W = ((xMax - xMin) * pixelSize + unitsPerEm - 1) / unitsPerEm
        mov     rax, [out_xMax]
        sub     rax, [out_xMin]
        mov     rcx, [arg_size]
        imul    rax, rcx
        mov     rcx, [head_unitsPerEm]
        add     rax, rcx
        dec     rax
        xor     edx, edx
        div     rcx
        mov     [img_W], rax

        mov     rax, [out_yMax]
        sub     rax, [out_yMin]
        mov     rcx, [arg_size]
        imul    rax, rcx
        mov     rcx, [head_unitsPerEm]
        add     rax, rcx
        dec     rax
        xor     edx, edx
        div     rcx
        mov     [img_H], rax

        mov     rax, [img_W]
        shl     rax, 2                  ; * SS (=4)
        mov     [img_bigW], rax
        mov     rax, [img_H]
        shl     rax, 2
        mov     [img_bigH], rax

        ; scaleFix = (arg_size * SS * 65536) / unitsPerEm
        mov     rax, [arg_size]
        shl     rax, 2                  ; * SS
        shl     rax, 16                 ; * 65536
        xor     edx, edx
        div     qword [head_unitsPerEm]
        mov     [img_scaleFix], rax
        ret

; ---------------------------------------------------------------------
; transform_points — pt_x[i],pt_y[i] (font units) -> big_x[i],big_y[i]
; in 16.16 fixed-point, big-pixel coordinate space (Y flipped).
;
;   big_x = pen_x_fix + fx * scaleFix
;   big_y = baseline_y_fix - fy * scaleFix
;
; Args:
;   rdi = pen_x_fix       (16.16, left-edge anchor in big pixels)
;   rsi = baseline_y_fix  (16.16, baseline y in big pixels)
transform_points:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15

        mov     r13, rdi                 ; pen_x_fix
        mov     r14, rsi                 ; baseline_y_fix
        mov     r12, [img_scaleFix]

        mov     rcx, [out_numPoints]
        xor     ebx, ebx
.loop:
        cmp     rbx, rcx
        jge     .done

        movsxd  rax, dword [pt_x + rbx*4]
        imul    rax, r12
        add     rax, r13
        mov     [big_x + rbx*4], eax

        movsxd  rax, dword [pt_y + rbx*4]
        imul    rax, r12
        mov     rdx, r14
        sub     rdx, rax
        mov     [big_y + rbx*4], edx

        inc     rbx
        jmp     .loop
.done:
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; clear_big_buffer — zero img_bigW * img_bigH bytes of big_buffer
; (only the active region; full BSS is already zeroed at start).
clear_big_buffer:
        push    rbx
        mov     rax, [img_bigW]
        mov     rcx, [img_bigH]
        imul    rax, rcx
        mov     rcx, rax                 ; bytes
        lea     rdi, [big_buffer]
        xor     eax, eax
        rep     stosb
        pop     rbx
        ret

; ---------------------------------------------------------------------
; emit_line — line segment from (x0,y0) to (x1,y1), all 16.16.
; Generates edges into e_*[].
;   args:  esi = x0, edi = y0, edx = x1, ecx = y1   (32-bit each, signed)
; Skips horizontal segments. ymin/ymax become integer scanline indices.
emit_line:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        mov     r12d, esi               ; x0
        mov     r13d, edi               ; y0
        mov     r14d, edx               ; x1
        mov     r15d, ecx               ; y1

        ; If y0 == y1: horizontal, skip.
        cmp     r13d, r15d
        je      .done

        ; Determine ymin, ymax in fixed; winding +1 if y1>y0 (downward), else -1.
        cmp     r13d, r15d
        jl      .down
        ; y1 < y0: upward edge, winding = -1
        mov     ebp, -1
        ; swap so (x0,y0) is the top: top=(x1,y1), bottom=(x0,y0)
        xchg    r12d, r14d
        xchg    r13d, r15d
        jmp     .have_dir
.down:
        mov     ebp, 1
.have_dir:
        ; Now r13d = y_top (16.16, smaller), r15d = y_bot (16.16)
        ;     r12d = x at top, r14d = x at bottom

        ; integer scanline range: ymin = floor(y_top + 0.5), ymax = floor(y_bot + 0.5)
        ; (we sample at y+0.5 for each integer scanline y, so we want scanlines
        ;  where y+0.5 is in [y_top, y_bot)).
        mov     eax, r13d
        add     eax, 0x8000              ; +0.5
        sar     eax, 16                  ; floor
        mov     ebx, eax                 ; ebx = ymin

        mov     eax, r15d
        add     eax, 0x8000
        sar     eax, 16
        mov     edi, eax                 ; edi = ymax (exclusive)

        cmp     ebx, edi
        jge     .done                    ; no scanline crosses

        ; clamp to [0, bigH)
        mov     ecx, dword [img_bigH]
        test    ebx, ebx
        jns     .clamp_top_done
        xor     ebx, ebx
.clamp_top_done:
        cmp     edi, ecx
        jle     .clamp_bot_done
        mov     edi, ecx
.clamp_bot_done:
        cmp     ebx, edi
        jge     .done

        ; slope dx/dy in 16.16 = (x_bot - x_top) * 65536 / (y_bot - y_top)
        ; both in 16.16, so dy = (y_bot - y_top) is 16.16; dx_input = x_bot - x_top is 16.16.
        ; result = (dx_input << 16) / dy.
        mov     eax, r14d
        sub     eax, r12d                ; dx 16.16 (signed)
        movsxd  rax, eax
        shl     rax, 16
        mov     ecx, r15d
        sub     ecx, r13d                ; dy 16.16 (positive)
        movsxd  rcx, ecx
        cqo
        idiv    rcx                      ; rax = dx per 1.0-y step (16.16)
        mov     r9d, eax                 ; r9d = dx_per_dy

        ; x_at_top_scanline_center = x_top + dx_per_dy * (ymin + 0.5 - y_top_in_units_of_y)
        ; In 16.16: ymin*65536 + 0x8000 - y_top  (all 16.16)
        mov     eax, ebx                 ; ymin
        shl     eax, 16
        add     eax, 0x8000
        sub     eax, r13d                ; (ymin+0.5)*65536 - y_top   (16.16 delta-y)
        movsxd  rax, eax
        movsxd  r10, r9d
        imul    rax, r10
        sar     rax, 16                  ; multiply two 16.16 -> 16.16: shift back
        add     eax, r12d                ; + x_top
        mov     r10d, eax                ; x at first scanline

        ; store edge
        mov     rax, [e_count]
        cmp     rax, MAX_EDGES
        jge     .overflow
        mov     [e_ymin + rax*4], ebx
        mov     [e_ymax + rax*4], edi
        mov     [e_x0   + rax*4], r10d
        mov     [e_dx   + rax*4], r9d
        mov     [e_dir  + rax], bpl
        inc     rax
        mov     [e_count], rax
.done:
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret
.overflow:
        ; silently drop further edges; caller can detect via e_count==MAX_EDGES
        jmp     .done

; ---------------------------------------------------------------------
; emit_quad — quadratic Bezier from (x0,y0) via control (cx,cy) to
; (x1,y1). All inputs 32-bit 16.16. Uses fixed N-step subdivision.
;
; Stack args layout (caller pushes in reverse):
;   [rsp+8]  = x0
;   [rsp+16] = y0
;   [rsp+24] = cx
;   [rsp+32] = cy
;   [rsp+40] = x1
;   [rsp+48] = y1
; Each stored as full 64-bit (sign-extended 32-bit value).
emit_quad:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        ; load args (after 6 pushes, [rsp+56] is return addr)
        mov     r12, [rsp + 64]          ; x0
        mov     r13, [rsp + 72]          ; y0
        mov     r14, [rsp + 80]          ; cx
        mov     r15, [rsp + 88]          ; cy
        mov     rbx, [rsp + 96]          ; x1
        mov     rbp, [rsp + 104]         ; y1

        ; subdivide into BEZIER_SUBDIV segments
        ; B(t) = (1-t)^2 P0 + 2t(1-t) C + t^2 P1
        ; Use t = i/N for i = 0..N
        mov     rcx, BEZIER_SUBDIV       ; counter (we generate N segments)
        ; previous point starts at (P0)
        mov     r8, r12                  ; prev_x
        mov     r9, r13                  ; prev_y
        mov     r10, 1                   ; i = 1
.q_loop:
        ; t = i / N (we keep i in r10, compute scaled below)
        ; To avoid floating point: compute coefficients * 65536:
        ;   t_num = i, t_den = N
        ;   one_minus_t_num = N - i
        ;   weights:
        ;     w0 = (N-i)^2 / N^2
        ;     w1 = 2*i*(N-i) / N^2
        ;     w2 = i^2 / N^2
        ;   Each scaled by 65536 to keep precision.
        ;     w0_q = (N-i)^2 * 65536 / N^2
        mov     r11, BEZIER_SUBDIV
        sub     r11, r10                 ; r11 = N - i
        mov     rax, r11
        imul    rax, r11                 ; (N-i)^2
        shl     rax, 16
        mov     rdx, BEZIER_SUBDIV * BEZIER_SUBDIV
        xor     edx, edx
        mov     rsi, BEZIER_SUBDIV * BEZIER_SUBDIV
        div     rsi
        mov     rdi, rax                 ; rdi = w0_q

        mov     rax, r10
        imul    rax, r11                 ; i*(N-i)
        shl     rax, 17                  ; *2*65536
        xor     edx, edx
        mov     rsi, BEZIER_SUBDIV * BEZIER_SUBDIV
        div     rsi
        mov     rsi, rax                 ; rsi = w1_q

        mov     rax, r10
        imul    rax, r10                 ; i^2
        shl     rax, 16
        xor     edx, edx
        mov     r11, BEZIER_SUBDIV * BEZIER_SUBDIV
        div     r11
        ; rax = w2_q

        ; px = (w0 * P0.x + w1 * C.x + w2 * P1.x) / 65536
        ; All weights are .16 fixed; coords are 16.16.
        ; Output is also 16.16 (because (.16 * 16.16) = 32.16 which then >> 16 leaves .16... wait)
        ;
        ; Actually: weights are 16.16 fixed (range 0..65536).
        ;   coord is 16.16 fixed (range integer .. 16-bit fractional)
        ;   product is 32.32, then shift right 16 to get 16.16.
        ; But weight is only ".16" (0..1.0 fixed), so:
        ;   weight * coord = (fraction.16) * (int16.16) = (32-bit int .* 32-bit int) = 64-bit
        ;   we want the result as 16.16 = (weight * coord) >> 16.
        push    rax                      ; save w2_q
        push    rsi                      ; save w1_q
        push    rdi                      ; save w0_q

        ; px contribution
        movsxd  rax, r12d                ; P0.x (sign-extended)
        imul    rax, qword [rsp]         ; * w0_q
        sar     rax, 16
        movsxd  rdx, r14d                ; C.x
        imul    rdx, qword [rsp + 8]     ; * w1_q
        sar     rdx, 16
        add     rax, rdx
        movsxd  rdx, ebx                 ; P1.x
        imul    rdx, qword [rsp + 16]    ; * w2_q
        sar     rdx, 16
        add     rax, rdx
        ; rax = new px (16.16)
        push    rax                      ; save px

        ; py contribution
        movsxd  rax, r13d                ; P0.y
        imul    rax, qword [rsp + 8]     ; w0_q (now at +8 due to extra push)
        sar     rax, 16
        movsxd  rdx, r15d                ; C.y
        imul    rdx, qword [rsp + 16]    ; w1_q
        sar     rdx, 16
        add     rax, rdx
        movsxd  rdx, ebp                 ; P1.y
        imul    rdx, qword [rsp + 24]    ; w2_q
        sar     rdx, 16
        add     rax, rdx
        ; rax = new py
        mov     r11, rax
        pop     rax                      ; restore px to rax
        ; emit_line(prev, new) — emit_line takes (x0=esi, y0=edi, x1=edx, y1=ecx)
        push    rax                      ; px back on stack
        mov     esi, r8d                 ; prev_x
        mov     edi, r9d                 ; prev_y
        mov     edx, eax                 ; new px (truncated to 32-bit)
        mov     ecx, r11d                ; new py (truncated)
        push    r10
        push    r11
        push    rcx
        call    emit_line
        pop     rcx
        pop     r11
        pop     r10
        pop     rax                      ; px

        mov     r8, rax                  ; prev = new
        mov     r9, r11

        add     rsp, 24                  ; drop saved w0/w1/w2

        inc     r10
        cmp     r10, BEZIER_SUBDIV
        jle     .q_loop

        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; generate_edges — walk all contours, expanding off-curve points into
; quadratic Beziers (then flattened) and on-on into line segments.
; Returns 0 ok, 1 if too many edges (already capped by emit_line).
;
; Algorithm per contour:
;   - Find a starting "pen" position:
;       * if pts[start].on    : pen = pts[start]
;       * elif pts[end].on    : pen = pts[end] ; walk pts[start..end-1]
;       * else                : pen = midpoint(pts[end], pts[start])
;   - Walk through points (in cyclic order), track pending_off control.
;   - Close back to starting pen with a final line or quadratic.
generate_edges:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        ; e_count is NOT reset — callers reset before the first glyph
        ; so that string-mode rendering can accumulate edges across glyphs.

        mov     r15, [out_numContours]
        test    r15, r15
        jz      .all_done
        xor     r12, r12                 ; r12 = contour index
        xor     r13, r13                 ; r13 = first point index of current contour
.c_loop:
        cmp     r12, r15
        jge     .all_done
        ; r14 = end point index of contour (inclusive)
        mov     r14d, [contour_end + r12*4]
        ; n = r14 - r13 + 1 ; if n < 2, skip
        mov     rax, r14
        sub     rax, r13
        cmp     rax, 1
        jl      .c_next

        ; render contour from index r13..r14
        sub     rsp, 64                  ; scratch: sx, sy, px, py, pox, poy, has_pending, start_idx_offset
        mov     qword [rsp + 48], 0      ; has_pending = 0

        ; Determine starting (sx,sy) and walk start
        ; Look at flags of points[r13] and points[r14]:
        movzx   eax, byte [pt_flags + r13]
        test    al, 1
        jz      .start_first_off

        ; start = pts[r13] (first is on); walk i from r13+1 to r14
        mov     ecx, [big_x + r13*4]
        mov     [rsp +  0], rcx          ; sx
        mov     ecx, [big_y + r13*4]
        mov     [rsp +  8], rcx          ; sy
        mov     ecx, [big_x + r13*4]
        mov     [rsp + 16], rcx          ; px = sx
        mov     ecx, [big_y + r13*4]
        mov     [rsp + 24], rcx          ; py = sy
        mov     rax, r13
        inc     rax
        mov     [rsp + 56], rax          ; walk_i
        jmp     .walk

.start_first_off:
        movzx   eax, byte [pt_flags + r14]
        test    al, 1
        jz      .start_both_off
        ; first off, last on: start = pts[r14]; walk r13..r14-1
        mov     ecx, [big_x + r14*4]
        mov     [rsp +  0], rcx
        mov     ecx, [big_y + r14*4]
        mov     [rsp +  8], rcx
        mov     ecx, [big_x + r14*4]
        mov     [rsp + 16], rcx          ; px = sx
        mov     ecx, [big_y + r14*4]
        mov     [rsp + 24], rcx
        mov     rax, r13
        mov     [rsp + 56], rax
        ; walk-end: r14-1 (we'll handle by limiting in loop)
        ; Easiest: temporarily set r14 = r14 - 1 for this contour.
        dec     r14
        jmp     .walk

.start_both_off:
        ; both ends off: pen = midpoint(pts[r14], pts[r13])
        mov     eax, [big_x + r14*4]
        add     eax, [big_x + r13*4]
        sar     eax, 1
        mov     [rsp +  0], rax
        mov     [rsp + 16], rax
        mov     eax, [big_y + r14*4]
        add     eax, [big_y + r13*4]
        sar     eax, 1
        mov     [rsp +  8], rax
        mov     [rsp + 24], rax
        mov     rax, r13
        mov     [rsp + 56], rax

.walk:
        mov     rbx, [rsp + 56]
.w_loop:
        cmp     rbx, r14
        jg      .w_close
        movzx   eax, byte [pt_flags + rbx]
        test    al, 1
        jz      .pt_off

        ; ON point
        cmp     qword [rsp + 48], 0
        jne     .on_with_pending
        ; emit line from (px,py) -> (pts[rbx])
        mov     esi, [rsp + 16]          ; px
        mov     edi, [rsp + 24]          ; py
        mov     edx, [big_x + rbx*4]
        mov     ecx, [big_y + rbx*4]
        push    rbx
        call    emit_line
        pop     rbx
        mov     ecx, [big_x + rbx*4]
        mov     [rsp + 16], rcx          ; px = new
        mov     ecx, [big_y + rbx*4]
        mov     [rsp + 24], rcx          ; py = new
        jmp     .w_advance
.on_with_pending:
        ; emit_quad(prev_pen, pending_off, new_on)
        ; push args in reverse (right-to-left): y1, x1, cy, cx, y0, x0
        ; emit_quad expects 64-bit args (sign-extended)
        movsxd  rax, dword [big_y + rbx*4]
        push    rax
        movsxd  rax, dword [big_x + rbx*4]
        push    rax
        movsxd  rax, dword [rsp + 32 + 24]   ; poy (rsp moved by 16)
        push    rax
        movsxd  rax, dword [rsp + 32 + 24]   ; pox  (now rsp moved by 24)
        push    rax
        movsxd  rax, dword [rsp + 32 + 24]   ; py
        push    rax
        movsxd  rax, dword [rsp + 32 + 24]   ; px
        push    rax
        push    rbx
        call    emit_quad
        pop     rbx
        add     rsp, 48
        ; px = pts[rbx]
        mov     ecx, [big_x + rbx*4]
        mov     [rsp + 16], rcx
        mov     ecx, [big_y + rbx*4]
        mov     [rsp + 24], rcx
        mov     qword [rsp + 48], 0      ; clear pending
        jmp     .w_advance

.pt_off:
        ; OFF point
        cmp     qword [rsp + 48], 0
        jne     .off_with_pending
        ; first off: store as pending
        mov     eax, [big_x + rbx*4]
        mov     [rsp + 32], rax          ; pox
        mov     eax, [big_y + rbx*4]
        mov     [rsp + 40], rax          ; poy
        mov     qword [rsp + 48], 1
        jmp     .w_advance

.off_with_pending:
        ; implicit on at midpoint(pending, current_off)
        ; emit_quad(pen, pending, midpoint), then pending = current
        mov     eax, [rsp + 32]          ; pox
        add     eax, [big_x + rbx*4]
        sar     eax, 1
        mov     r10d, eax                ; mx
        mov     eax, [rsp + 40]
        add     eax, [big_y + rbx*4]
        sar     eax, 1
        mov     r11d, eax                ; my
        ; Save r10/r11 BEFORE arg pushes so they don't disturb emit_quad's
        ; expected stack-arg offsets (+64..+104).
        push    r11
        push    r10
        ; emit_quad args (right-to-left): y1=my, x1=mx, cy=poy, cx=pox, y0=py, x0=px
        ; Local frame is now 16 bytes deeper because of r11/r10 pushes, so
        ; the [rsp + 32 + 24] = +56 trick still walks the frame correctly:
        ; after 2 (r11,r10) + N pushes, [rsp + 56 + 16] reads slot at original
        ; offset (40 - 8N) — exactly the same pattern as on_with_pending.
        movsxd  rax, r11d                ; my
        push    rax
        movsxd  rax, r10d                ; mx
        push    rax
        movsxd  rax, dword [rsp + 56 + 16]   ; poy (rsp deeper by 16 + 16)
        push    rax
        movsxd  rax, dword [rsp + 56 + 16]
        push    rax
        movsxd  rax, dword [rsp + 56 + 16]
        push    rax
        movsxd  rax, dword [rsp + 56 + 16]
        push    rax
        push    rbx
        call    emit_quad
        pop     rbx
        add     rsp, 48
        pop     r10
        pop     r11
        ; pen = midpoint
        mov     [rsp + 16], r10d
        mov     [rsp + 24], r11d
        ; pending = current off
        mov     eax, [big_x + rbx*4]
        mov     [rsp + 32], rax
        mov     eax, [big_y + rbx*4]
        mov     [rsp + 40], rax

.w_advance:
        inc     rbx
        jmp     .w_loop

.w_close:
        ; close back to (sx,sy)
        cmp     qword [rsp + 48], 0
        jne     .close_quad
        ; line from (px,py) to (sx,sy)
        mov     esi, [rsp + 16]
        mov     edi, [rsp + 24]
        mov     edx, [rsp +  0]
        mov     ecx, [rsp +  8]
        call    emit_line
        jmp     .c_done
.close_quad:
        ; quad from (px,py) via (pox,poy) to (sx,sy)
        ; Pushes (right-to-left): sy, sx, poy, pox, py, px.
        ; After 2 pushes the local frame slot N is at [rsp + N + 16]; we use
        ; the trick of always reading [rsp + 56] which walks the next-deeper
        ; slot as each push happens.
        movsxd  rax, dword [rsp +  8]    ; sy
        push    rax
        movsxd  rax, dword [rsp +  8]    ; sx (after 1 push, sx is at [rsp+8])
        push    rax
        movsxd  rax, dword [rsp + 56]    ; poy
        push    rax
        movsxd  rax, dword [rsp + 56]    ; pox
        push    rax
        movsxd  rax, dword [rsp + 56]    ; py
        push    rax
        movsxd  rax, dword [rsp + 56]    ; px
        push    rax
        push    rbx                      ; padding push so emit_quad's stack arg offsets line up
        call    emit_quad
        pop     rbx
        add     rsp, 48
.c_done:
        add     rsp, 64

.c_next:
        ; restore r14 if we decremented (start_first_off + last_on case): we need
        ; to reset r13 = old_r14 + 1 = (current_r14_after_dec + 1) if dec'd, else
        ; r13 = current_r14 + 1. Either way r13 = original_end + 1, so just read
        ; contour_end again.
        mov     r14d, [contour_end + r12*4]
        mov     r13, r14
        inc     r13
        inc     r12
        jmp     .c_loop
.all_done:
        xor     eax, eax
        cmp     qword [e_count], MAX_EDGES
        jne     .ret
        mov     eax, 1
.ret:
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; rasterize — for each scanline 0..bigH-1, scan all edges, find x
; intersections at y+0.5, sort, then NZW-fill spans into big_buffer.
; Uses a small static buffer for per-scanline (x, dir) pairs.
;
; xs_buf: i32[MAX_INTS]  (x in 16.16)
; ds_buf: i8[MAX_INTS]   (winding dir)
section .bss
%define MAX_INTS_PER_SCAN  256
xs_buf:                 resd MAX_INTS_PER_SCAN
ds_buf:                 resb MAX_INTS_PER_SCAN
section .text

rasterize:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15

        xor     r12, r12                 ; y = 0
        mov     r13, [img_bigH]
.y_loop:
        cmp     r12, r13
        jge     .y_done

        ; collect intersections for scanline y
        xor     r14, r14                 ; intersection count
        xor     rbx, rbx                 ; edge index
        mov     r15, [e_count]
.e_loop:
        cmp     rbx, r15
        jge     .e_done
        mov     ecx, [e_ymin + rbx*4]    ; ymin (int)
        cmp     r12d, ecx
        jl      .e_skip
        mov     ecx, [e_ymax + rbx*4]
        cmp     r12d, ecx
        jge     .e_skip
        ; x = e_x0 + (y - e_ymin) * e_dx
        mov     eax, r12d
        sub     eax, [e_ymin + rbx*4]    ; (y - ymin) integer
        movsxd  rax, eax
        movsxd  rcx, dword [e_dx + rbx*4]
        imul    rax, rcx                 ; (y - ymin) * dx (16.16)
        movsxd  rcx, dword [e_x0 + rbx*4]
        add     rax, rcx                 ; x in 16.16
        cmp     r14, MAX_INTS_PER_SCAN
        jge     .e_skip
        mov     [xs_buf + r14*4], eax
        movsx   ecx, byte [e_dir + rbx]
        mov     [ds_buf + r14], cl
        inc     r14
.e_skip:
        inc     rbx
        jmp     .e_loop
.e_done:
        ; sort by x (insertion sort, parallel arrays)
        mov     rcx, 1
.s_outer:
        cmp     rcx, r14
        jge     .s_done
        mov     eax, [xs_buf + rcx*4]
        movzx   esi, byte [ds_buf + rcx]
        mov     rdx, rcx
.s_inner:
        test    rdx, rdx
        jz      .s_place
        mov     edi, [xs_buf + rdx*4 - 4]
        cmp     edi, eax
        jle     .s_place
        mov     [xs_buf + rdx*4], edi
        movzx   edi, byte [ds_buf + rdx - 1]
        mov     [ds_buf + rdx], dil
        dec     rdx
        jmp     .s_inner
.s_place:
        mov     [xs_buf + rdx*4], eax
        mov     [ds_buf + rdx], sil
        inc     rcx
        jmp     .s_outer
.s_done:

        ; NZW fill
        xor     rcx, rcx                 ; intersection iterator
        xor     r10d, r10d               ; winding sum (in r10 — rdi gets clobbered by stosb)
        xor     ebp, ebp                 ; prev_x int (only valid when inside)
.f_loop:
        cmp     rcx, r14
        jge     .f_eos
        ; current intersection x_int = (xs[i] + 0x8000) >> 16  (round to nearest)
        mov     eax, [xs_buf + rcx*4]
        add     eax, 0x8000
        sar     eax, 16
        ; clamp to [0, bigW]
        cmp     eax, 0
        jge     .clamp_lo
        xor     eax, eax
.clamp_lo:
        cmp     eax, dword [img_bigW]
        jle     .clamp_hi
        mov     eax, dword [img_bigW]
.clamp_hi:
        mov     ebx, eax                 ; ebx = x_int

        test    r10d, r10d
        jz      .skip_fill
        ; fill big_buffer[y*bigW + prev_x .. x_int)
        mov     rax, r12
        imul    rax, [img_bigW]
        lea     rsi, [big_buffer]
        add     rsi, rax
        movsxd  rax, ebp
        add     rsi, rax
        mov     edx, ebx
        sub     edx, ebp
        jle     .skip_fill
        push    rcx
        mov     ecx, edx
        mov     al, 1
        mov     rdi, rsi
        rep     stosb
        pop     rcx
.skip_fill:
        movsx   eax, byte [ds_buf + rcx]
        add     r10d, eax
        mov     ebp, ebx
        inc     rcx
        jmp     .f_loop
.f_eos:

        inc     r12
        jmp     .y_loop
.y_done:
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; box_filter — average each SS x SS block of big_buffer to one byte
; in output_buf.  output[oy*W + ox] = sum * 255 / (SS*SS)
box_filter:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15
        push    rbp

        mov     r12, [img_W]
        mov     r13, [img_H]
        mov     r14, [img_bigW]

        xor     r15, r15                 ; oy
.oy_loop:
        cmp     r15, r13
        jge     .done
        xor     rbx, rbx                 ; ox
.ox_loop:
        cmp     rbx, r12
        jge     .ox_done
        xor     edi, edi                 ; sum
        xor     rcx, rcx                 ; sy
.sy_loop:
        cmp     rcx, SS
        jge     .sy_done
        mov     rax, r15
        imul    rax, SS
        add     rax, rcx                 ; by = oy*SS + sy
        imul    rax, r14                 ; *bigW
        mov     rdx, rbx
        imul    rdx, SS                  ; bx = ox*SS
        add     rax, rdx
        lea     rsi, [big_buffer]
        add     rsi, rax
        ; sum 4 bytes
        movzx   ebp, byte [rsi]
        add     edi, ebp
        movzx   ebp, byte [rsi + 1]
        add     edi, ebp
        movzx   ebp, byte [rsi + 2]
        add     edi, ebp
        movzx   ebp, byte [rsi + 3]
        add     edi, ebp
        inc     rcx
        jmp     .sy_loop
.sy_done:
        ; alpha = gamma_lut[sum]  (sum ∈ 0..16, gamma ≈ 1.43 → bolder mids)
        ; Linear sum*255/16 made AA glyphs look pale on dark backgrounds;
        ; the LUT applies sRGB-ish gamma correction so coverage maps to
        ; perceptual brightness, matching FreeType+kitty appearance.
        mov     eax, edi
        movzx   eax, byte [gamma_lut + rax]
        ; store
        mov     rdx, r15
        imul    rdx, r12
        add     rdx, rbx
        lea     rsi, [output_buf]
        mov     [rsi + rdx], al
        inc     rbx
        jmp     .ox_loop
.ox_done:
        inc     r15
        jmp     .oy_loop
.done:
        pop     rbp
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

%ifndef GLYPH_LIB
; ---------------------------------------------------------------------
; emit_pgm — write PGM (P5) to stdout: header + raw bytes.
emit_pgm:
        ; header: "P5\nW H\n255\n"
        lea     rdi, [pgm_hdr]
        mov     byte [rdi], 'P'
        mov     byte [rdi+1], '5'
        mov     byte [rdi+2], 10
        add     rdi, 3
        mov     rax, [img_W]
        call    itoa
        mov     byte [rdi], ' '
        inc     rdi
        mov     rax, [img_H]
        call    itoa
        mov     byte [rdi], 10
        inc     rdi
        mov     byte [rdi],   '2'
        mov     byte [rdi+1], '5'
        mov     byte [rdi+2], '5'
        mov     byte [rdi+3], 10
        add     rdi, 4

        ; write header
        lea     rsi, [pgm_hdr]
        mov     rdx, rdi
        sub     rdx, rsi
        mov     edi, STDOUT
        mov     eax, SYS_WRITE
        syscall

        ; write data
        mov     rdx, [img_W]
        imul    rdx, [img_H]
        lea     rsi, [output_buf]
        mov     edi, STDOUT
        mov     eax, SYS_WRITE
        syscall
        ret

emit_empty_pgm:
        lea     rdi, [pgm_hdr]
        mov     byte [rdi],   'P'
        mov     byte [rdi+1], '5'
        mov     byte [rdi+2], 10
        mov     byte [rdi+3], '1'
        mov     byte [rdi+4], ' '
        mov     byte [rdi+5], '1'
        mov     byte [rdi+6], 10
        mov     byte [rdi+7], '2'
        mov     byte [rdi+8], '5'
        mov     byte [rdi+9], '5'
        mov     byte [rdi+10], 10
        mov     byte [rdi+11], 0
        mov     edx, 12
        lea     rsi, [pgm_hdr]
        mov     edi, STDOUT
        mov     eax, SYS_WRITE
        syscall
        ret

; ---------------------------------------------------------------------
; itoa — rax = unsigned value, rdi = output buffer (writes ASCII,
; ADVANCES rdi past last char). No null terminator.
itoa:
        push    rbx
        push    r12
        push    r13
        mov     r12, rdi                 ; remember start
        mov     rbx, 10
        test    rax, rax
        jnz     .l
        mov     byte [rdi], '0'
        inc     rdi
        jmp     .ret
.l:
        mov     r13, rdi                 ; remember pre-loop end
.l2:
        xor     edx, edx
        div     rbx
        add     dl, '0'
        mov     [rdi], dl
        inc     rdi
        test    rax, rax
        jnz     .l2
        ; reverse from r13..rdi-1
        lea     rcx, [rdi - 1]
.rev:
        cmp     r13, rcx
        jge     .ret
        mov     al, [r13]
        mov     dl, [rcx]
        mov     [r13], dl
        mov     [rcx], al
        inc     r13
        dec     rcx
        jmp     .rev
.ret:
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; dump_metrics — print W/H/bigW/bigH/edges to stderr.
dump_metrics:
        push    rbx
        mov     edi, STDERR
        lea     rsi, [dump_dim_lbl]
        mov     edx, dump_dim_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [img_W]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_h_lbl]
        mov     edx, dump_h_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [img_H]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_bigw_lbl]
        mov     edx, dump_bigw_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [img_bigW]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_bigh_lbl]
        mov     edx, dump_bigh_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [img_bigH]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [dump_edges_lbl]
        mov     edx, dump_edges_lbl_len
        mov     eax, SYS_WRITE
        syscall
        mov     rax, [e_count]
        call    print_dec_stderr

        mov     edi, STDERR
        lea     rsi, [nl_str]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        pop     rbx
        ret
%endif  ; !GLYPH_LIB

; ---------------------------------------------------------------------
; utf8_next — decode one UTF-8 codepoint.
;   in : rdi = pointer into string
;   out: rax = codepoint (0 at NUL terminator)
;        rdi = pointer past the consumed bytes
; Handles 1/2/3/4-byte sequences. Malformed input yields the raw byte
; (and advances by 1) — best-effort, no validation.
utf8_next:
        movzx   eax, byte [rdi]
        test    al, al
        jz      .done                    ; rax=0, rdi unchanged
        test    al, 0x80
        jz      .one                     ; ASCII fast path
        ; multibyte
        mov     ecx, eax
        and     ecx, 0xE0
        cmp     ecx, 0xC0                ; 110xxxxx -> 2 bytes
        je      .two
        mov     ecx, eax
        and     ecx, 0xF0
        cmp     ecx, 0xE0                ; 1110xxxx -> 3 bytes
        je      .three
        mov     ecx, eax
        and     ecx, 0xF8
        cmp     ecx, 0xF0                ; 11110xxx -> 4 bytes
        je      .four
        ; malformed leading byte: return raw, advance 1
        inc     rdi
        ret
.one:
        inc     rdi
        ret
.two:
        and     eax, 0x1F                ; low 5 bits
        shl     eax, 6
        movzx   ecx, byte [rdi + 1]
        and     ecx, 0x3F
        or      eax, ecx
        add     rdi, 2
        ret
.three:
        and     eax, 0x0F
        shl     eax, 12
        movzx   ecx, byte [rdi + 1]
        and     ecx, 0x3F
        shl     ecx, 6
        or      eax, ecx
        movzx   ecx, byte [rdi + 2]
        and     ecx, 0x3F
        or      eax, ecx
        add     rdi, 3
        ret
.four:
        and     eax, 0x07
        shl     eax, 18
        movzx   ecx, byte [rdi + 1]
        and     ecx, 0x3F
        shl     ecx, 12
        or      eax, ecx
        movzx   ecx, byte [rdi + 2]
        and     ecx, 0x3F
        shl     ecx, 6
        or      eax, ecx
        movzx   ecx, byte [rdi + 3]
        and     ecx, 0x3F
        or      eax, ecx
        add     rdi, 4
.done:
        ret

; ---------------------------------------------------------------------
; hmtx_advance — rdi = glyph_id, returns rax = advance width (font units).
; hmtx layout:
;   numberOfHMetrics × { u16 advanceWidth; i16 lsb }
;   then (numGlyphs - numberOfHMetrics) × i16 lsb (advance shared with last)
hmtx_advance:
        push    rbx
        mov     rbx, rdi
        mov     rcx, [hhea_numLongMetrics]
        cmp     rbx, rcx
        jl      .normal
        ; clamp to last entry
        mov     rbx, rcx
        dec     rbx
.normal:
        mov     rdi, [font_base]
        add     rdi, [tbl_hmtx_off]
        lea     rdi, [rdi + rbx*4]
        call    be_u16
        pop     rbx
        ret

%ifndef GLYPH_LIB
; ---------------------------------------------------------------------
; string_prepass — rdi = pointer to null-terminated ASCII string.
; Walks the string. For each byte: cmap_lookup -> glyph_id; record
; pen_x_fix in big-pixel 16.16; sum advances. Stores str_glyph_ids[],
; str_pen_x_fix[], str_total_W (in OUTPUT pixels), str_len.
;
; scaleFix isn't computed yet here (we don't know img_W until total
; advance is known); use a per-pixel "advanceFix" = arg_size * SS *
; 65536 / unitsPerEm (same as scaleFix).
;
; Returns rax = 0 ok, 1 = string too long.
string_prepass:
        push    rbx
        push    r12
        push    r13
        push    r14
        push    r15

        mov     r12, rdi                 ; str pointer

        ; advanceFix = arg_size * SS * 65536 / unitsPerEm (16.16 big-pixel scale)
        mov     rax, [arg_size]
        shl     rax, 2                   ; * SS
        shl     rax, 16                  ; * 65536
        xor     edx, edx
        div     qword [head_unitsPerEm]
        mov     r13, rax                 ; r13 = scaleFix

        xor     r14, r14                 ; pen_x_fix accumulator (16.16 big-pixel)
        xor     r15, r15                 ; index
.l:
        ; UTF-8 decode at [r12 + ...]; advance r12 past the consumed bytes.
        ; rax = codepoint, 0 = end.
        mov     rdi, r12
        call    utf8_next
        test    rax, rax
        jz      .done
        mov     r12, rdi                 ; r12 advances past the decoded char

        cmp     r15, MAX_STR_GLYPHS
        jge     .toolong

        push    rax
        mov     rdi, rax
        call    cmap_lookup
        mov     rbx, rax                 ; glyph_id
        pop     rax

        mov     [str_glyph_ids + r15*4], ebx
        mov     [str_pen_x_fix + r15*4], r14d

        mov     rdi, rbx
        call    hmtx_advance
        imul    rax, r13                 ; advance * scaleFix
        add     r14, rax

        inc     r15
        jmp     .l
.done:
        mov     [str_len], r15

        ; total_W in OUTPUT pixels = ceil(pen_x_fix / 65536 / SS)
        mov     rax, r14
        add     rax, (65536 * SS) - 1    ; round up
        shr     rax, 16
        shr     rax, 2                   ; / SS
        mov     [str_total_W], rax

        xor     eax, eax
        jmp     .ret
.toolong:
        mov     eax, 1
.ret:
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
dump_points_debug:
        push    rbx
        mov     rcx, [out_numPoints]
        xor     ebx, ebx
.l:
        cmp     rbx, rcx
        jge     .d
        push    rcx
        push    rbx
        mov     rax, rbx
        call    print_dec_stderr
        pop     rbx
        pop     rcx
        mov     edi, STDERR
        mov     byte [dec_buf], ':'
        mov     byte [dec_buf+1], ' '
        lea     rsi, [dec_buf]
        mov     edx, 2
        mov     eax, SYS_WRITE
        syscall
        push    rcx
        push    rbx
        movsxd  rax, dword [pt_x + rbx*4]
        call    print_signed_stderr
        pop     rbx
        pop     rcx
        mov     edi, STDERR
        mov     byte [dec_buf], ','
        lea     rsi, [dec_buf]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        push    rcx
        push    rbx
        movsxd  rax, dword [pt_y + rbx*4]
        call    print_signed_stderr
        pop     rbx
        pop     rcx
        push    rcx
        push    rbx
        movzx   eax, byte [pt_flags + rbx]
        and     eax, 1
        add     al, '0'
        mov     [dec_buf], byte ' '
        mov     [dec_buf+1], al
        mov     [dec_buf+2], byte 10
        mov     edi, STDERR
        lea     rsi, [dec_buf]
        mov     edx, 3
        mov     eax, SYS_WRITE
        syscall
        pop     rbx
        pop     rcx
        inc     rbx
        jmp     .l
.d:
        pop     rbx
        ret

; ---------------------------------------------------------------------
dump_edges_debug:
        push    rbx
        push    r12
        mov     r12, [e_count]
        xor     rbx, rbx
.l:
        cmp     rbx, r12
        jge     .d
        ; "edge i: y[a..b) x0=N dx=N dir=±1\n"
        mov     rax, rbx
        call    print_dec_stderr
        mov     edi, STDERR
        lea     rsi, [edge_lbl_y]
        mov     edx, edge_lbl_y_len
        mov     eax, SYS_WRITE
        syscall
        movsxd  rax, dword [e_ymin + rbx*4]
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [dump_comma]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        movsxd  rax, dword [e_ymax + rbx*4]
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [edge_lbl_x0]
        mov     edx, edge_lbl_x0_len
        mov     eax, SYS_WRITE
        syscall
        movsxd  rax, dword [e_x0 + rbx*4]
        sar     rax, 16
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [edge_lbl_dir]
        mov     edx, edge_lbl_dir_len
        mov     eax, SYS_WRITE
        syscall
        movsx   eax, byte [e_dir + rbx]
        call    print_signed_stderr
        mov     edi, STDERR
        lea     rsi, [nl_str]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        inc     rbx
        jmp     .l
.d:
        pop     r12
        pop     rbx
        ret

; ---------------------------------------------------------------------
; print_signed_stderr: rax = signed 64-bit, prints to stderr with sign.
print_signed_stderr:
        test    rax, rax
        jns     print_dec_stderr
        push    rax
        mov     edi, STDERR
        mov     byte [dec_buf], '-'
        lea     rsi, [dec_buf]
        mov     edx, 1
        mov     eax, SYS_WRITE
        syscall
        pop     rax
        neg     rax
        jmp     print_dec_stderr

; ---------------------------------------------------------------------
; print_dec_stderr: rax = value, prints decimal to stderr.
print_dec_stderr:
        push    rbx
        push    r12
        lea     r12, [dec_buf + 31]     ; write backwards
        mov     byte [r12], 0
        mov     rbx, 10
        test    rax, rax
        jnz     .l
        dec     r12
        mov     byte [r12], '0'
        jmp     .emit
.l:
        xor     edx, edx
        div     rbx
        dec     r12
        add     dl, '0'
        mov     [r12], dl
        test    rax, rax
        jnz     .l
.emit:
        lea     rax, [dec_buf + 31]
        sub     rax, r12
        mov     edx, eax
        mov     rsi, r12
        mov     edi, STDERR
        mov     eax, SYS_WRITE
        syscall
        pop     r12
        pop     rbx
        ret
%endif  ; !GLYPH_LIB
