#!/bin/bash
# ABYSS build — assemble + emit XEX. Usage: ./build.sh [-DSYM=val ...]
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

# Regenerate the art the assembler `ins`-includes, EVERY time.
#
# This did not used to happen, and it cost a build: a preview script imported
# tools/genweapon.py to render the gun off-screen, the import ran the module,
# the module wrote src/weapon.bin as a side effect, and the next ./build.sh
# quietly shipped a discarded draft. Nothing was out of date and nothing warned
# -- the .bin on disk simply stopped being the thing the .py describes.
#
# Three seconds a build makes the .py files the single source of truth by
# construction. The level and table generators are NOT here: they are run
# explicitly when the levels change, and they assert their own size limits.
python3 "$HERE/tools/gensprites.py" > /dev/null
python3 "$HERE/tools/genweapon.py"  > /dev/null
python3 "$HERE/tools/gentitle.py"   > /dev/null
# MADS is a third-party binary and is not committed here. Point $MADS at your
# own build, or drop one next to this script in tools/, or keep the wider
# atari400-800 workspace layout.
MADS="${MADS:-}"
for c in "$HERE/tools/mads" "$HERE/../tools/mads" "$(command -v mads 2>/dev/null)"; do
    [ -n "$MADS" ] && break
    [ -x "$c" ] && MADS="$c"
done
if [ ! -x "$MADS" ]; then
    echo "mads not found. Set \$MADS, or put the binary in tools/. See README." >&2
    exit 1
fi
"$MADS" -o:"$HERE/abyss.xex" -l:"$HERE/abyss.lst" -t:"$HERE/abyss.lab" "$@" "$HERE/src/main.asm" | tail -4
ls -la "$HERE/abyss.xex"
