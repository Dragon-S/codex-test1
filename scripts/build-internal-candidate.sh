#!/bin/zsh

set -euo pipefail

repository_root="${0:A:h:h}"
engine_root="${ENGINE_ROOT:-}"
development_team="${DEVELOPMENT_TEAM:-}"

fail() {
  print -u2 "候选构建失败：$1"
  exit 1
}

[[ -n "$development_team" ]] || fail "必须通过 DEVELOPMENT_TEAM 指定可用的 Apple 开发团队"

cd "$repository_root"
[[ -z "$(git status --porcelain)" ]] \
  || fail "工作区含未提交或未跟踪内容；候选记录只能绑定干净提交"

commit_sha="$(git rev-parse HEAD)"
short_sha="$(git rev-parse --short=12 HEAD)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_parent="${CANDIDATE_OUTPUT_ROOT:-$repository_root/.build/internal-candidate}"
candidate_root="$output_parent/$short_sha-$timestamp"
derived_data="$candidate_root/DerivedData"
archive_path="$candidate_root/MacMediaPlayer.xcarchive"
mkdir -p "$candidate_root"

engine_built_from_source=false
if [[ -n "$engine_root" ]]; then
  engine_root="${engine_root:A}"
else
  engine_build_root="$candidate_root/LockedEngine"
  "$repository_root/scripts/build-locked-engine.sh" "$engine_build_root"
  engine_root="$engine_build_root/universal"
  engine_built_from_source=true
fi

source_lock="$repository_root/prototypes/lgpl-packaging-proof/sources.lock"
"$repository_root/scripts/verify-candidate-inputs.sh" \
  "$engine_root" \
  "$source_lock" \
  "$repository_root"
"$repository_root/scripts/tests/verify-candidate-inputs-test.sh"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
    -project MacMediaPlayer/MacMediaPlayer.xcodeproj \
    -scheme MacMediaPlayer \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    test \
    ENGINE_ROOT="$engine_root" \
    DEVELOPMENT_TEAM="$development_team"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
    -project MacMediaPlayer/MacMediaPlayer.xcodeproj \
    -scheme MacMediaPlayer \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$archive_path" \
    -derivedDataPath "$derived_data" \
    -allowProvisioningUpdates \
    archive \
    ENGINE_ROOT="$engine_root" \
    DEVELOPMENT_TEAM="$development_team" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO

app_path="$archive_path/Products/Applications/MacMediaPlayer.app"
executable="$app_path/Contents/MacOS/MacMediaPlayer"
frameworks="$app_path/Contents/Frameworks"
[[ -x "$executable" ]] || fail "归档中缺少候选应用"

codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
[[ "$signature_details" == *"runtime"* ]] || fail "候选应用未启用 Hardened Runtime"
[[ "$signature_details" == *"library-validation"* ]] || fail "候选应用未启用 library validation"

entitlements_plist="$candidate_root/entitlements.plist"
codesign -d --entitlements :- "$app_path" > "$entitlements_plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements_plist")" == true ]] \
  || fail "候选签名缺少 App Sandbox"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-only' "$entitlements_plist")" == true ]] \
  || fail "候选签名缺少只读文件权限"
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.network.client' "$entitlements_plist" >/dev/null 2>&1; then
  fail "候选签名意外包含网络客户端权限"
fi

actual_frameworks="$(find "$frameworks" -maxdepth 1 -type f -name '*.dylib' -exec basename {} \; | LC_ALL=C sort)"
expected_frameworks="$(find "$engine_root/lib" -maxdepth 1 -type f -name '*.dylib' -exec basename {} \; | LC_ALL=C sort)"
[[ "$actual_frameworks" == "$expected_frameworks" ]] || fail "归档未嵌入精确动态依赖闭包"

while IFS= read -r dylib; do
  [[ "$(lipo -archs "$dylib")" == *arm64* && "$(lipo -archs "$dylib")" == *x86_64* ]] \
    || fail "${dylib:t} 不是双架构"
done < <(find "$frameworks" -maxdepth 1 -type f -name '*.dylib' | LC_ALL=C sort)

open -n "$app_path"
candidate_pid=""
for _ in {1..50}; do
  candidate_pid="$(pgrep -f "$executable" | head -1 || true)"
  [[ -n "$candidate_pid" ]] && break
  sleep 0.1
done
[[ -n "$candidate_pid" ]] || fail "候选应用未能启动"
kill -TERM "$candidate_pid"

binary_sha256="$(shasum -a 256 "$executable" | awk '{print $1}')"
source_lock_sha256="$(shasum -a 256 "$source_lock" | awk '{print $1}')"
runtime_lock_sha256="$(shasum -a 256 "$repository_root/prototypes/lgpl-packaging-proof/runtime-closure.sha256" | awk '{print $1}')"
notice_lock_sha256="$(shasum -a 256 "$repository_root/prototypes/lgpl-packaging-proof/notices.sha256" | awk '{print $1}')"
header_lock_sha256="$(shasum -a 256 "$repository_root/prototypes/lgpl-packaging-proof/headers.sha256" | awk '{print $1}')"
closure_manifest="$candidate_root/dynamic-closure.sha256"
while IFS= read -r dylib; do
  shasum -a 256 "$dylib"
done < <(find "$frameworks" -maxdepth 1 -type f -name '*.dylib' | LC_ALL=C sort) > "$closure_manifest"
closure_sha256="$(shasum -a 256 "$closure_manifest" | awk '{print $1}')"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app_path/Contents/Info.plist")"
xcode_version="$(xcodebuild -version | paste -sd ' ' -)"
macos_version="$(sw_vers -productVersion) ($(sw_vers -buildVersion))"

jq -n \
  --arg status "AUTOMATED_PASS_PHYSICAL_PENDING" \
  --arg scope "离线内部 MVP 候选；不是公开发布或 App Store 资格" \
  --arg commit "$commit_sha" \
  --arg builtAt "$timestamp" \
  --arg app "$app_path" \
  --arg binarySHA256 "$binary_sha256" \
  --arg sourceLockSHA256 "$source_lock_sha256" \
  --arg runtimeLockSHA256 "$runtime_lock_sha256" \
  --arg noticeLockSHA256 "$notice_lock_sha256" \
  --arg headerLockSHA256 "$header_lock_sha256" \
  --argjson engineBuiltFromSource "$engine_built_from_source" \
  --arg closureSHA256 "$closure_sha256" \
  --arg minimumMacOS "$minimum_macos" \
  --arg xcode "$xcode_version" \
  --arg macOS "$macos_version" \
  '{
    status: $status,
    scope: $scope,
    git: {commit: $commit, clean: true},
    build: {
      builtAtUTC: $builtAt,
      configuration: "Release",
      architectures: ["arm64", "x86_64"],
      minimumMacOS: $minimumMacOS,
      appPath: $app,
      executableSHA256: $binarySHA256,
      dynamicClosureSHA256: $closureSHA256,
      sourceLockSHA256: $sourceLockSHA256,
      runtimeInputLockSHA256: $runtimeLockSHA256,
      noticeLockSHA256: $noticeLockSHA256,
      headerLockSHA256: $headerLockSHA256,
      engineBuiltFromSource: $engineBuiltFromSource,
      xcode: $xcode,
      hostMacOS: $macOS
    },
    automatedAcceptance: {
      swiftContracts: "PASS",
      appAndRealEngineContracts: "PASS",
      freshUserData: "PASS",
      populatedUserData: "PASS",
      signedLaunch: "PASS"
    },
    physicalAcceptance: "PENDING"
  }' > "$candidate_root/candidate-record.json"

sed \
  -e "s/{{COMMIT}}/$commit_sha/g" \
  -e "s/{{BUILD_ID}}/$binary_sha256/g" \
  -e "s/{{BUILT_AT}}/$timestamp/g" \
  "$repository_root/docs/internal-mvp-physical-acceptance.md" \
  > "$candidate_root/PHYSICAL-ACCEPTANCE.md"

print -r -- "候选自动化验收通过，物理机验收仍待执行：$candidate_root"
