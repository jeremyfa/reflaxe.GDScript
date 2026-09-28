#!/usr/bin/env bash
# Compiles and runs the expression lowering test suite headlessly.
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
printf '[application]\nconfig/name="gdexpressions"\n\n[debug]\ngdscript/warnings/enable=false\n' > "$proj/project.godot"
cat > "$proj/run.gd" <<'GD'
extends SceneTree

func _initialize() -> void:
	Main.main()
	quit(0)
GD

"$godot" --headless --path "$proj" --import > /dev/null 2>&1 || true
# --quit-after: a script that fails to parse never calls quit(), exit anyway
output="$("$godot" --headless --path "$proj" --quit-after 600 --script res://run.gd 2>&1 || true)"
echo "$output"
if echo "$output" | grep -q "ALL_EXPR_TESTS_PASSED"; then
    echo "OK"
else
    echo "FAILED"
    exit 1
fi
