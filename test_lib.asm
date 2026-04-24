; test_lib.asm — verify glyph.inc assembles in library mode AND
; that the engine is callable from a host that supplies its own _start.
; This is just a build-mode smoke test; it loads a font and renders
; one glyph to /dev/null to prove the API works.
%include "glyph.inc"

section .data
test_path:      db "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 0

section .text
global _start
_start:
        lea     rdi, [test_path]
        call    glyph_load_font
        test    rax, rax
        jnz     .fail
        mov     rdi, 65                  ; 'A'
        mov     rsi, 32                  ; 32 px
        call    glyph_render_to_alpha
        test    rax, rax
        jnz     .fail
        ; success — exit 0
        xor     edi, edi
        jmp     .exit
.fail:
        mov     edi, 1
.exit:
        mov     eax, 60                  ; SYS_EXIT
        syscall
