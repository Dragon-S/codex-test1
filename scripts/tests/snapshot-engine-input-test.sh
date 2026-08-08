#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h:h}"
fixture_root="$(mktemp -d)"
trap 'chmod -R u+w "$fixture_root" 2>/dev/null || true; rm -rf "$fixture_root"' EXIT

source_root="$fixture_root/source"
snapshot_root="$fixture_root/snapshot"
mkdir -p "$source_root/include/mpv" "$source_root/lib" "$source_root/notices"
print -r -- "header-v1" > "$source_root/include/mpv/client.h"
print -r -- "library-v1" > "$source_root/lib/libmpv.2.dylib"
print -r -- "notice-v1" > "$source_root/notices/mpv-Copyright.txt"

"$repository_root/scripts/snapshot-engine-input.sh" "$source_root" "$snapshot_root"

print -r -- "header-v2" > "$source_root/include/mpv/client.h"
print -r -- "library-v2" > "$source_root/lib/libmpv.2.dylib"
print -r -- "notice-v2" > "$source_root/notices/mpv-Copyright.txt"

[[ "$(<"$snapshot_root/include/mpv/client.h")" == "header-v1" ]]
[[ "$(<"$snapshot_root/lib/libmpv.2.dylib")" == "library-v1" ]]
[[ "$(<"$snapshot_root/notices/mpv-Copyright.txt")" == "notice-v1" ]]
[[ ! -w "$snapshot_root/lib/libmpv.2.dylib" ]] \
  || { print -u2 "引擎输入快照仍可写"; exit 1; }
