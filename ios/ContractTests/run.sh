#!/bin/bash
# Contract tests: compile the app's real API/model/form code with each suite's main.swift
# (macOS command-line binaries, no Simulator) and run them against a live backend.
#
#   ios/ContractTests/run.sh                      # dev-mode server on 127.0.0.1:8000
#   TOKEN=ckb_... ios/ContractTests/run.sh        # token-mode server
#   COOKBOOK_API_URL=https://... TOKEN=... ios/ContractTests/run.sh
#
# Suites create and delete their own data. M3 runs whatever extractor the server uses, so
# it only asserts provider-neutral behavior.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../Cookbook"
BUILD="${TMPDIR:-/tmp}/cookbook-contract-tests"
mkdir -p "$BUILD"
SOURCES=("$APP/API/Models.swift" "$APP/API/DraftModels.swift" "$APP/API/Pairing.swift" "$APP/API/APIClient.swift" "$APP/Features/RecipeEditor/RecipeForm.swift")
PHOTO="$BUILD/photo.jpg"
"$HERE/../../backend/.venv/bin/python" -c "from PIL import Image; Image.new('RGB',(3000,2000),(180,90,30)).save('$PHOTO')"

failed=0
run() { # name sources... -- args...
  local name=$1; shift
  echo "== $name"
  if ! swiftc -swift-version 5 -o "$BUILD/$name" "$@" "$HERE/$name/main.swift" 2>"$BUILD/$name.err"; then
    cat "$BUILD/$name.err"; failed=1; return
  fi
  "$BUILD/$name" ${ARGS:-} | grep -E 'FAIL|PASSED|FAILED' || failed=1
  [ "${PIPESTATUS[0]}" -eq 0 ] || failed=1
}
run InstagramParsing "$APP/Features/InstagramImport/InstagramLink.swift"
for suite in M1Recipes M2SearchDuplicates M3ImportDrafts; do run $suite "${SOURCES[@]}"; done
ARGS="$PHOTO" run M4Photos "${SOURCES[@]}"
exit $failed
