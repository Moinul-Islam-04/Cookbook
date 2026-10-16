#!/bin/bash
# Runs the CookbookTests XCTest target on a Simulator.
#
#   ios/run-tests.sh                          # offline unit tests; live contract tests skip
#   TOKEN=ckb_... ios/run-tests.sh            # also the live contract tests, against 127.0.0.1:8000
#   TOKEN=ckb_... API_URL=https://... ios/run-tests.sh
#   DEVICE="iPhone 16" ios/run-tests.sh       # another Simulator (xcrun simctl list devices)
#
# The live tests create and delete their own data. The import-draft test runs whatever
# extractor the server uses (a few seconds on Claude Haiku).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export TEST_RUNNER_COOKBOOK_TEST_TOKEN="${TOKEN:-}"
export TEST_RUNNER_COOKBOOK_TEST_API_URL="${API_URL:-}"
xcodebuild test \
  -project "$HERE/Cookbook.xcodeproj" -scheme Cookbook \
  -destination "platform=iOS Simulator,name=${DEVICE:-iPhone 18 Pro}" \
  -derivedDataPath "${TMPDIR:-/tmp}/cookbook-tests-dd" \
  2>&1 | grep -E "error:|Test Case .*(passed|failed|skipped)|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|\*\* "
exit "${PIPESTATUS[0]}"
