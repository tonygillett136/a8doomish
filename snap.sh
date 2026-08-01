#!/bin/bash
# snapshot sources after a verified-good build
cd "$(dirname "$0")"
D=.snapshots/$(date +%H%M%S)
mkdir -p "$D" && cp src/*.asm src/*.inc tools/*.py "$D"/ 2>/dev/null
echo "snapshot -> $D"
