NAME := glyph
SRC  := $(NAME).asm
OBJ  := $(NAME).o
BIN  := $(NAME)

NASM := nasm
LD   := ld

.PHONY: all clean run smoke

all: $(BIN)

$(BIN): $(OBJ)
	$(LD) $(OBJ) -o $(BIN)

$(OBJ): $(SRC)
	$(NASM) -f elf64 $(SRC) -o $(OBJ)

clean:
	rm -f $(OBJ) $(BIN)

# Smoke test: dump SFNT directory of DejaVu Sans Mono.
smoke: $(BIN)
	./$(BIN) /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf 65 32 2>&1 1>/dev/null
