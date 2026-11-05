#!/bin/bash
set -euo pipefail

# Ad-hoc signatures have no Team ID, so local packages cannot use Team-ID library validation.
# Developer ID distribution must use its own signing and notarization workflow.
app_path="${1:?Usage: sign-local-release.sh /path/to/boringNotch.app}"
entitlements="$(mktemp -t boring-notch-entitlements)"
trap 'rm -f "$entitlements"' EXIT

codesign --display --entitlements :- "$app_path" >"$entitlements" 2>/dev/null
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :com.apple.security.cs.disable-library-validation true' "$entitlements" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$entitlements"
codesign --force --sign - --options runtime --entitlements "$entitlements" "$app_path"
codesign --verify --deep --strict "$app_path"
