# glyph

Pure x86_64 assembly TrueType / OpenType font rasterizer. Parses TTF
files, flattens quadratic Bezier curves into line segments, runs a
scanline non-zero-winding fill with 4×4 supersample AA, returns an
8-bit alpha bitmap per glyph. ~4.2k lines of NASM, ~37 KB binary.

Goal: replace glass's X core bitmap fonts so the entire CHasm
desktop renders TTF text without dynamic linking.

## Build

```bash
nasm -f elf64 glyph.asm -o glyph.o && ld glyph.o -o glyph
```

CLI for testing:
```bash
./glyph font.ttf 'Hello' 32          # rasterise "Hello" at 32px, dump PGM
./glyph -dump font.ttf U+0041        # dump glyph for a single codepoint
```

When linked into glass (planned), it's used as a library: glass calls
`glyph_render_to_alpha(codepoint, font_size)` and gets a pointer to
the alpha buffer + width/height/bearing/advance metrics.

## What's implemented

- TTF / OpenType **table parser** (head, maxp, hhea, hmtx, cmap, loca,
  glyf, cvt, fpgm, prep)
- **cmap format 4** + **format 12** (BMP and supplementary planes —
  emoji codepoints work)
- **Composite glyphs** (recursive component combination with
  per-component transform)
- **Quadratic Bezier flattening** (de Casteljau subdivision until
  segment length < 0.5px)
- **Scanline non-zero winding fill** with **4×4 supersample AA**
  (16 samples per output pixel → 8-bit alpha)
- **Variable-font support**: `fvar` table parse, `gvar` deltas, IUP
  (Inferred Untouched Point) reconstruction. glyph can interpolate
  between weight masters (e.g. Regular ↔ Bold) at arbitrary axis
  positions.
- **UTF-8** input decoding

## What's NOT implemented (yet)

- TTF hinting bytecode (cvt/fpgm/prep are parsed but not executed —
  the rasterizer is unhinted; small sizes may look slightly fuzzy
  vs. FreeType)
- CFF / CFF2 (only TrueType outlines)
- Subpixel AA (only grayscale)
- Kerning (the kern table isn't parsed — apps must call
  `glyph_advance_for(cp)` and add manually if they care)
- ColorEmoji / SVG / sbix tables (renders the outline shape only
  for emoji)

## Architecture

### Outline pipeline

```
codepoint → cmap lookup → glyph index
glyph index → loca → glyf offset
glyf parse → contours of (x, y, on-curve flag) points
Bezier flatten → list of line segments
Scanline raster → alpha bitmap
```

Each stage has a dedicated entry point — useful when debugging "is
the wrong shape stored or am I rendering it wrong?".

### Composite glyphs

`g_parse_composite` recursively descends components. Each component
specifies a child glyph index + a 2×2 affine transform + offset
(point-match or pixel coords). Transforms compose multiplicatively
down the tree. Detects cycles via a max-depth limit (16); deeper
trees are rejected.

### Variable fonts

```
fvar  → (axis count, axis names, default values, axis ranges)
gvar  → per-glyph delta sets, one per "variation tuple"
```

At render time, given an axis position (e.g. weight=600), `glyph`
walks the variation tuples for the requested glyph, computes each
tuple's scalar contribution, and applies the deltas to the base
outline points. IUP fills in untouched points by interpolating
neighbours along each axis.

### Output

- `output_buf`: 8-bit alpha buffer, sized W × H of the rasterised
  glyph
- `glyph_info`: W, H, x_bearing (signed), y_bearing (signed),
  off_x (signed advance origin offset), off_y (signed)

Glass's `ttf_upload_glyph` reads `output_buf` + `glyph_info` and
uploads to X via XRender's `AddGlyphs` request.

## CRITICAL: rbx is clobbered by the rendering pipeline

The internal rasterizer entry points trash `rbx` despite being
called from outside the file. Wrap with `push rbx` / `pop rbx`
around any glyph render call **at the call site** — don't rely on
the rasterizer to preserve it. This bit glass during integration:
the caller had a counter in rbx, called the rasterizer, lost the
counter.

The right long-term fix is to audit and add `push rbx` inside the
rasterizer entry points; until that's done, the wrap-at-call-site
rule must be followed.

## Key code sections

- `_start`: arg parse, font load via mmap
- `parse_tables`: walks the table directory, fills offset cache
- `cmap_lookup`: codepoint → glyph index (format 4 + 12 dispatch)
- `g_parse_simple`: flat outline parser
- `g_parse_composite`: recursive component combiner
- `flatten_quad`: de Casteljau subdivision
- `raster_scanline`: NZW + 4×4 supersample AA
- `apply_gvar_deltas`: variable-font outline mutation
- `iup_pass`: untouched-point interpolation along an axis
- `glyph_render_to_alpha`: public entry — codepoint+size → output_buf

## Pitfalls

See the global x86_64-asm skill for the 15 NASM/x86_64 pitfalls that
apply to every CHasm asm project. glyph-specific:

- **rbx clobber across rasterizer calls** — see CRITICAL section above
- **All TTF integers are big-endian** — use `bswap` when reading;
  forgetting bites every new table parser written
- **`loca` table format depends on `head.indexToLocFormat`** — short
  (uint16, ×2) or long (uint32). Branch on this when computing glyf
  offsets, or you'll read garbage.
- **fvar axis count can be 0** — non-variable fonts have an empty fvar
  table or no fvar at all; render path must skip the variation pass
  in that case.
- **Composite glyph max depth must be enforced** — pathological fonts
  can recurse forever; current limit is 16.
