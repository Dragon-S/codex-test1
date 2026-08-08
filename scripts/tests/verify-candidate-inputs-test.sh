#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h:h}"
fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

engine_root="$fixture_root/engine"
fake_tools="$fixture_root/tools"
fixture_repository="$fixture_root/repository"
mkdir -p "$engine_root/include/mpv" "$engine_root/lib" "$engine_root/notices" "$fake_tools"

touch "$engine_root/include/mpv/client.h" "$engine_root/include/mpv/render_gl.h"

for dylib in \
  libmpv.2.dylib \
  libass.9.dylib \
  libavcodec.62.dylib \
  libavfilter.11.dylib \
  libavformat.62.dylib \
  libavutil.60.dylib \
  libplacebo.338.dylib \
  libswresample.6.dylib \
  libswscale.9.dylib \
  libfreetype.6.dylib \
  libfribidi.0.dylib \
  libharfbuzz.0.dylib
do
  touch "$engine_root/lib/$dylib"
done

for notice in \
  mpv-Copyright.txt \
  mpv-LGPL-2.1.txt \
  FFmpeg-LICENSE.txt \
  FFmpeg-LGPL-2.1.txt \
  libplacebo-LICENSE.txt \
  libass-COPYING.txt \
  FreeType-LICENSE.txt \
  FriBidi-COPYING.txt \
  HarfBuzz-COPYING.txt
do
  print -r -- "fixture license" > "$engine_root/notices/$notice"
done

cat > "$fake_tools/lipo" <<'EOF'
#!/bin/zsh
print -r -- "x86_64 arm64"
EOF
chmod +x "$fake_tools/lipo"

cat > "$fake_tools/otool" <<'EOF'
#!/bin/zsh
file="${@: -1}"
name="${file:t}"
if [[ "$1" == "-D" ]]; then
  print -r -- "$file:"
  print -r -- "@rpath/$name"
else
  print -r -- "$file:"
  print -- "\t@rpath/$name (compatibility version 1.0.0, current version 1.0.0)"
  print -- "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)"
fi
EOF
chmod +x "$fake_tools/otool"

mkdir -p \
  "$fixture_repository/.git" \
  "$fixture_repository/prototypes/lgpl-packaging-proof" \
  "$fixture_repository/MacMediaPlayer/MacMediaPlayer.xcodeproj" \
  "$fixture_repository/MacMediaPlayer/App"
ditto \
  "$repository_root/prototypes/lgpl-packaging-proof/sources.lock" \
  "$fixture_repository/prototypes/lgpl-packaging-proof/sources.lock"
ditto \
  "$repository_root/prototypes/lgpl-packaging-proof/BUILD.md" \
  "$fixture_repository/prototypes/lgpl-packaging-proof/BUILD.md"
ditto \
  "$repository_root/MacMediaPlayer/MacMediaPlayer.xcodeproj/project.pbxproj" \
  "$fixture_repository/MacMediaPlayer/MacMediaPlayer.xcodeproj/project.pbxproj"
ditto \
  "$repository_root/MacMediaPlayer/App/MacMediaPlayer.entitlements" \
  "$fixture_repository/MacMediaPlayer/App/MacMediaPlayer.entitlements"
ditto \
  "$repository_root/MacMediaPlayer/App/MPVClient.h" \
  "$fixture_repository/MacMediaPlayer/App/MPVClient.h"
(
  cd "$engine_root/lib"
  shasum -a 256 *.dylib | LC_ALL=C sort -k2 \
    > "$fixture_repository/prototypes/lgpl-packaging-proof/runtime-closure.sha256"
)
(
  cd "$engine_root/notices"
  shasum -a 256 *.txt | LC_ALL=C sort -k2 \
    > "$fixture_repository/prototypes/lgpl-packaging-proof/notices.sha256"
)
(
  cd "$engine_root/include"
  shasum -a 256 mpv/client.h mpv/render_gl.h \
    > "$fixture_repository/prototypes/lgpl-packaging-proof/headers.sha256"
)

PATH="$fake_tools:/usr/bin:/bin" \
  "$repository_root/scripts/verify-candidate-inputs.sh" \
  "$engine_root" \
  "$fixture_repository/prototypes/lgpl-packaging-proof/sources.lock" \
  "$fixture_repository"

touch "$engine_root/lib/libgpl-plugin.dylib"
if PATH="$fake_tools:/usr/bin:/bin" \
  "$repository_root/scripts/verify-candidate-inputs.sh" \
  "$engine_root" \
  "$fixture_repository/prototypes/lgpl-packaging-proof/sources.lock" \
  "$fixture_repository" >/dev/null 2>&1
then
  print -u2 "验证器错误接受了闭包外动态库"
  exit 1
fi
