; glyph.inc — public engine include for the glyph TTF rasterizer.
;
; Provides three procedures (no _start, no PGM output, no argv parsing,
; no stderr dumps) for embedding the rasterizer into other CHasm tools:
;
;   glyph_load_font(rdi=path)              -> rax=0 ok / 1..6 error
;   glyph_set_weight(rdi=weight)           -> sets variation weight
;   glyph_render_to_alpha(rdi=cp, rsi=size)
;       -> rax=0 ok / 1=missing / 3=oversize
;          rcx=W rdx=H r8=bearing_x r9=bearing_y r10=advance
;          alpha mask in output_buf (W*H bytes, 0..255)
;
; Single-font global state. Caller (e.g. glass) layers a glyph cache +
; XRender Glyph upload on top.
;
; Usage:
;   %include "../glyph/glyph.inc"
;
; Build pattern: nothing extra — host's normal nasm/ld pipeline.
%define GLYPH_LIB
%include "glyph.asm"
