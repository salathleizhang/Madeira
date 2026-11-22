#!/usr/bin/env bash
# Compile DXMT's .metal airconv shaders to .air and embed them as C headers.
# The DXMT meson flow does this via its metalir/hexdump generators; the iOS
# static-library flow consumes the headers directly, so this step reproduces
# that generation with the same compiler, flags, and xxd embedding.
#
# DeckRT fork change (2026-11-23): the atomic call's arity is decided by asking
# this Metal toolchain, on a private copy of the shader. Upstream decided it by
# whether __METAL_MEMORY_FLAGS_NONE__ is defined, which is wrong on Xcode 26.6
# (metal 32023.883): it defines the macro but still takes the four-argument
# form, so the shader failed with "too many arguments to function call". A
# source file the compiler's own headers define cannot answer this; a compile
# of the real call can. Upstream's version also rewrote the dxmt submodule's
# source in place, which left the working tree dirty.
set -euo pipefail
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SRC="$ROOT/dxmt/src/airconv/shaders"
OUT="$ROOT/build/dxmt-ios/shader-headers"
SHADERS=(air_msad air_samplepos air_tessellation)

mkdir -p "$OUT"

# Rewrite the copy's atomic call to the requested arity. Shaders without the
# block are unchanged.
atomic_arity() {  # $1 = copy, $2 = 4 | 5
  python3 - "$1" "$2" <<'PY'
import re
import sys

path, arity = sys.argv[1], sys.argv[2]
text = open(path).read()
block = re.compile(
    r"#ifdef __METAL_MEMORY_FLAGS_NONE__\n(?P<five>[^\n]*)\n"
    r"#else\n(?P<four>[^\n]*)\n#endif\n"
)
match = block.search(text)
if not match:
    sys.exit(0)  # this shader has no atomic call
call = match.group("five") if arity == "5" else match.group("four")
text = text[:match.start()] + call + "\n" + text[match.end():]
open(path, "w").write(text)
PY
}

compile_shader() {  # $1 = source path, $2 = destination air
  xcrun -sdk macosx metal -o "$2" -c "$1" \
    -std=metal3.1 --target=air64-apple-macos14.0
}

# Try the four-argument form on a copy, then the five-argument one: picking
# wrong is a hard compile error, so the toolchain answers instead of a macro.
probe_arity() {
  for arity in 4 5; do
    cp "$SRC/air_tessellation.metal" "$OUT/.arity.metal"
    atomic_arity "$OUT/.arity.metal" "$arity"
    if compile_shader "$OUT/.arity.metal" /dev/null >/dev/null 2>&1; then
      rm -f "$OUT/.arity.metal"
      echo "$arity"
      return 0
    fi
  done
  rm -f "$OUT/.arity.metal"
  return 1
}
ARITY="$(probe_arity)" || { echo "ERROR: neither form of the atomic call compiles with this Metal toolchain" >&2; exit 1; }

for name in "${SHADERS[@]}"; do
  [[ -f "$SRC/$name.metal" ]] || { echo "ERROR: missing shader source $SRC/$name.metal (is the dxmt submodule checked out?)" >&2; exit 1; }
  copy="$OUT/$name.metal"
  cp "$SRC/$name.metal" "$copy"
  atomic_arity "$copy" "$ARITY"
  echo "shader $name: compiling (atomic arity $ARITY)"
  compile_shader "$copy" "$OUT/$name.air"
  xxd -n "$name" -i "$OUT/$name.air" "$OUT/$name.h"
  rm -f "$copy"
done
