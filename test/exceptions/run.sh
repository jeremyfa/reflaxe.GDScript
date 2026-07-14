#!/usr/bin/env bash
# Compiles and runs the exception lowering test suite headlessly.
# Requires haxe (with reflaxe and this library resolvable) and Godot 4.
# Usage: bash test/exceptions/run.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lib="$(cd "$here/../.." && pwd)"
godot="${GODOT_BIN:-godot}"
haxe_bin="${HAXE_BIN:-haxe}"
out="$here/out"

rm -rf "$out"
"$haxe_bin" -cp "$here" -m Main -cp "$lib/src" -cp "$lib/std" -cp "$lib/std/gdscript/_std" \
  -D gdscript -D retain-untyped-meta -D reflaxe.disallow_build_cache_check \
  --macro "gdcompiler.GDCompilerInit.Start()" \
  -lib reflaxe \
  -D gdscript-output="$out"

proj="$here/project"
rm -rf "$proj"
mkdir -p "$proj"
cp "$out"/*.gd "$proj/"
printf '[application]\nconfig/name="gdexceptions"\n\n[debug]\ngdscript/warnings/enable=false\n' > "$proj/project.godot"
cat > "$proj/run.gd" <<'GD'
extends SceneTree

func _initialize() -> void:
	Main.main()
	quit(0)
GD

"$godot" --headless --path "$proj" --import > /dev/null 2>&1 || true
output="$("$godot" --headless --path "$proj" --script res://run.gd 2>&1)"
echo "$output"
if echo "$output" | grep -q "ALL_EXC_TESTS_PASSED"; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi
