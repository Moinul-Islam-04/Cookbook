#!/bin/bash
# Screenshots every main screen with live data, for UI reviews and before/after checks.
#
#   ios/screenshots.sh [output-dir]          # default: ios/screenshots/<branch>-<time>
#   APPEARANCE=dark ios/screenshots.sh
#   DEVICE="iPhone 17e" ios/screenshots.sh
#
# Needs the backend running (ops/install-services.sh) and the Simulator app paired. The
# tour creates an import draft (it expires after 24 h) but never saves a recipe.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${DEVICE:-iPhone 18 Pro}"
OUT="${1:-$HERE/screenshots/$(git -C "$HERE" branch --show-current)-$(date +%H%M%S)}"
LOG="$OUT/xcodebuild.log"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"; LOG="$OUT/xcodebuild.log"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl ui "$DEVICE" appearance "${APPEARANCE:-light}"
TEST_RUNNER_SCREENSHOT_DIR="$OUT" xcodebuild test \
  -project "$HERE/Cookbook.xcodeproj" -scheme Screenshots \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "${TMPDIR:-/tmp}/cookbook-tests-dd" >"$LOG" 2>&1 &
pid=$!
# xcodebuild (Xcode 27) sometimes never exits after the tests finish; stop it once the
# summary is written.
until grep -qE "Test Suite 'All tests' (passed|failed)|\*\* (BUILD|TEST) FAILED" "$LOG" 2>/dev/null || ! kill -0 $pid 2>/dev/null; do
  sleep 2
done
sleep 3; kill $pid 2>/dev/null
grep -E "error:|Test Case .*(passed|failed|skipped)" "$LOG"
echo "Screenshots: $OUT"
ls "$OUT"
