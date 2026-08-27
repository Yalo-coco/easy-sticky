#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
project_root=$(cd "$script_dir/.." && pwd)
configuration=${1:-release}

swift build --package-path "$project_root" -c "$configuration" --product EasySticky
binary_dir=$(swift build --package-path "$project_root" -c "$configuration" --product EasySticky --show-bin-path)
binary_path="$binary_dir/EasySticky"
app_path="$project_root/.build/Easy Sticky.app"
contents_path="$app_path/Contents"

case "$app_path" in
    "$project_root"/.build/*) ;;
    *)
        echo "Refusing to replace unexpected app path: $app_path" >&2
        exit 1
        ;;
esac

rm -rf "$app_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_path" "$contents_path/MacOS/EasySticky"
cp "$project_root/Resources/Info.plist" "$contents_path/Info.plist"
codesign --force --deep --sign - "$app_path" >/dev/null

echo "$app_path"
