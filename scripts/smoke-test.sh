#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd "$script_dir/.." && pwd)
app_path="$project_root/.build/Easy Sticky.app"
binary_path="$app_path/Contents/MacOS/EasySticky"
info_plist="$app_path/Contents/Info.plist"
smoke_data="$project_root/.build/smoke-data"

test -x "$binary_path"
plutil -lint "$info_plist" >/dev/null
codesign --verify --deep --strict "$app_path"
file "$binary_path" | grep -q 'Mach-O 64-bit executable'

user_id=$(id -u)
if launchctl print "gui/$user_id" >/dev/null 2>&1; then
    open -W -n "$app_path" --args --smoke-test --data-dir "$smoke_data"
    echo "PASS GUI launch smoke test"
else
    echo "SKIP GUI launch: no gui/$user_id launchd domain; bundle checks passed"
fi
