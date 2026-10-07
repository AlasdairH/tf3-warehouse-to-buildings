#!/usr/bin/env bash
# Checks the mod before it goes into the game:
# - mod.json and modinfo.json are valid JSON,
# - _content.json lists every file under content/ (the game reads only listed files),
# - the tests pass (tests/run.lua against tests/mock_engine.lua).
#
# Usage: tools/check.sh [--fix]   (--fix rewrites _content.json)
# Uses lua5.2 (the game's version) if installed, else lua; set LUA to override.
set -euo pipefail
cd "$(dirname "$0")/.."
MOD=mod/warehouse_distribution_1

python3 - "$MOD" "${1:-}" <<'PY'
import json, os, sys
mod, fix = sys.argv[1], sys.argv[2] == "--fix"
for f in ("mod.json", "_metadata/modinfo.json", "_content.json"):
    json.load(open(os.path.join(mod, f)))
content = os.path.join(mod, "content")
files = sorted(os.path.relpath(os.path.join(r, n), content).replace(os.sep, "/")
               for r, _, ns in os.walk(content) for n in ns)
listed = json.load(open(os.path.join(mod, "_content.json")))["files"]
if sorted(listed) != files:
    if fix:
        with open(os.path.join(mod, "_content.json"), "w", newline="\n") as h:
            h.write(json.dumps({"archives": None, "files": files}, indent=4) + "\n")
        print("_content.json rewritten")
    else:
        sys.exit(f"_content.json is out of date (run tools/check.sh --fix); expected {files}")
print("metadata ok")
PY

LUA="${LUA:-$(command -v lua5.2 || command -v lua)}"
"$LUA" -v
"$LUA" tests/run.lua
