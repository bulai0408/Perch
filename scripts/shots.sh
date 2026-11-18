#!/usr/bin/env bash
# Screenshots on demo data (no magpie): PerchShotsTests on an
# iPhone Pro in light and dark, then on an SE-size iPhone in light and dark.
# Each run's attachments land in $PERCH_SHOTS_ARTIFACTS/shots/ (default
# ./build/shots/shots/) as <tag>-NN-name.png.
set -uo pipefail

ROOT="$PWD"
ART="${PERCH_SHOTS_ARTIFACTS:-$ROOT/build/shots}"
SHOTS="$ART/shots"
mkdir -p "$ART"
W="$(mktemp -d /tmp/perch-shots.XXXXXX)"
rm -rf "$SHOTS"; mkdir -p "$SHOTS"
LOG="$ART/shots-log.txt"
exec > >(tee "$LOG") 2>&1

RUNTIME="$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r.get("platform", r.get("name", "")).startswith("iOS")]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')"
echo "runtime: $RUNTIME"
TYPES="$(xcrun simctl list devicetypes -j)"

# The first device type of `names` this Xcode has; prints "name|identifier".
pick_type() {
  /usr/bin/python3 -c '
import json, sys
types = {t["name"]: t["identifier"] for t in json.loads(sys.argv[1])["devicetypes"]}
for n in sys.argv[2:]:
    if n in types:
        print(n + "|" + types[n]); break' "$TYPES" "$@"
}

make_device() { # name type → udid (booted)
  local udid
  udid="$(xcrun simctl create "$1" "$2" "$RUNTIME")" || return 1
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  printf '%s' "$udid"
}

STATUS=0
run_on() { # udid tag appearance
  local udid=$1 tag=$2 look=$3
  xcrun simctl ui "$udid" appearance "$look" || true
  echo "== $tag on $udid ($look)"
  rm -rf "$W/$tag.xcresult" "$W/att-$tag"
  TEST_RUNNER_PERCH_SHOT_TAG="$tag" xcodebuild test \
    -project Perch.xcodeproj -scheme Perch \
    -destination "id=$udid" \
    -only-testing:PerchUITests/PerchShotsTests \
    -resultBundlePath "$W/$tag.xcresult" -quiet
  local s=$?
  echo "xcodebuild test ($tag) exit: $s"
  [ $s -eq 0 ] || STATUS=$s
  mkdir -p "$W/att-$tag"
  xcrun xcresulttool export attachments --path "$W/$tag.xcresult" --output-path "$W/att-$tag" >/dev/null 2>&1 || echo "(no attachments for $tag)"
  /usr/bin/python3 - "$W/att-$tag" "$SHOTS" "$tag" <<'PY'
import json, os, shutil, sys
src, dst, tag = sys.argv[1:]
m = os.path.join(src, "manifest.json")
if os.path.exists(m):
    for test in json.load(open(m)):
        for a in test.get("attachments", []):
            name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
            base = name.split("_0_")[0] if "_0_" in name else os.path.splitext(name)[0]
            if not base.startswith(tag + "-"):
                continue
            shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, base + ".png"))
PY
}

PRO="$(pick_type "iPhone 18 Pro" "iPhone 17 Pro" "iPhone 16 Pro")"
SE="$(pick_type "iPhone SE (3rd generation)" "iPhone SE (2nd generation)" "iPhone 13 mini" "iPhone 12 mini" "iPhone 16e")"
echo "pro device type: ${PRO%%|*}"
echo "SE-size device type: ${SE:-none}"

if [ -n "$PRO" ]; then
  U="$(make_device perch-shots-pro "${PRO#*|}")"
  run_on "$U" light light
  run_on "$U" dark dark
  xcrun simctl delete "$U" >/dev/null 2>&1 || true
else
  echo "no iPhone Pro device type"; STATUS=1
fi
if [ -n "$SE" ]; then
  U="$(make_device perch-shots-se "${SE#*|}")"
  run_on "$U" se light
  run_on "$U" se-dark dark
  xcrun simctl delete "$U" >/dev/null 2>&1 || true
else
  echo "no SE-size device type on this Xcode"
fi
echo "screenshots: $(ls "$SHOTS" | tr '\n' ' ')"
# The slow-network shots (10-15) also in their own folder.
SLOW="$ART/e2e-shots-slownet"
rm -rf "$SLOW"; mkdir -p "$SLOW"
for f in "$SHOTS"/*-1[0-5]-*.png; do [ -e "$f" ] && cp "$f" "$SLOW/"; done
echo "slow-network shots: $(ls "$SLOW" | tr '\n' ' ')"
exit $STATUS
