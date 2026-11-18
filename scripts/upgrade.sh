#!/usr/bin/env bash
# Upgrade launch check on a Mac with Xcode, against the real magpie CLI:
# an older Perch build with saved state, then this build installed over it.
#
# 1. Starts magpie (one provider, one group, a 密钥 with 可看额度 + 管理,
#    a few Claude Code calls), like scripts/e2e.sh but smaller.
# 2. Builds the old build ($OLD_REV, any git revision of this repo) and
#    this tree, both Release, for one fresh Simulator.
# 3. Old build: connect and use every tab (PerchE2ETests/test8a, driven by
#    this tree's UI test runner pointed at the old app).
# 4. This build installed over it (data kept), launched twice the way the
#    Home Screen does (test8b), then with magpie gone and hanging (test8c).
#    Any Perch crash report is copied out.
#
# Usage: OLD_REV=<git rev> scripts/upgrade.sh
# Artifacts land in $PERCH_UPGRADE_ARTIFACTS (default ./build/upgrade).
set -euo pipefail

ROOT="$PWD"
ART="${PERCH_UPGRADE_ARTIFACTS:-$ROOT/build/upgrade}"
rm -rf "$ART"; mkdir -p "$ART"
LOG="$ART/upgrade-log.txt"
exec > >(tee "$LOG") 2>&1

OLD_REV="${OLD_REV:?set OLD_REV to the git revision to upgrade from}"
PORT=3431
UP_A=18311
W="$(mktemp -d /tmp/perch-upgrade.XXXXXX)"
CFG_DIR=/tmp/perch-e2e
mkdir -p "$W/home" "$W/dl" "$CFG_DIR"
chmod 700 "$CFG_DIR"
PIDS=()
UDID=""
cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  rm -f "$CFG_DIR/config.json"
  if [ -n "$UDID" ]; then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "== old source ($OLD_REV)"
OLD="$W/old"
mkdir -p "$OLD"
if git -c safe.directory='*' cat-file -e "$OLD_REV^{commit}" 2>/dev/null; then
  git -c safe.directory='*' archive "$OLD_REV" | tar -x -C "$OLD"
else
  echo "no source for $OLD_REV (not a commit in this repo)"; exit 1
fi
grep -m1 -E "CURRENT_PROJECT_VERSION|MARKETING_VERSION" "$OLD/Perch.xcodeproj/project.pbxproj" || true

echo "== magpie"
curl -fsSL --retry 3 -o "$W/dl/magpie" \
  https://github.com/yetone/magpie-releases/releases/latest/download/magpie-cli-darwin-arm64
chmod +x "$W/dl/magpie"; xattr -c "$W/dl/magpie" 2>/dev/null || true
M() { env HOME="$W/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" MAGPIE_NO_ACCOUNTS=1 "$W/dl/magpie" "$@"; }
echo "magpie version: $(M --version 2>/dev/null | head -1 || echo unknown)"
cat > "$W/fakeup.py" <<'PY'
import http.server, json, sys
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _w(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self._w(200, {"object": "list", "data": [{"id": "m-alpha", "object": "model"}]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n)
        try: model = json.loads(body).get("model")
        except Exception: model = "?"
        self._w(200, {"id": "x", "object": "chat.completion", "created": 1, "model": model,
                      "choices": [{"index": 0, "message": {"role": "assistant", "content": "hi"}, "finish_reason": "stop"}],
                      "usage": {"prompt_tokens": 3, "completion_tokens": 3, "total_tokens": 6}})
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
/usr/bin/python3 "$W/fakeup.py" "$UP_A" & PIDS+=($!)
sleep 1
M provider add alpha "url=http://127.0.0.1:$UP_A/v1" key=fake models=m-alpha | tail -1
M group add "Coder" models=alpha/m-alpha routing=order | sed -n 1,2p
KEY="$(M gateway-key add perch-admin 2>/dev/null | tail -1 | tr -d '[:space:]')"
case "$KEY" in sk-magpie-*) ;; *) echo "no key"; exit 1;; esac
KID="$(M gateway-key list | awk '$2=="perch-admin"{print $1; exit}')"
M gateway-key quotas "$KID" on | tail -1
M gateway-key admin "$KID" any | tail -1
env HOME="$W/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" MAGPIE_NO_ACCOUNTS=1 MAGPIE_ADDR="0.0.0.0:$PORT" \
  "$W/dl/magpie" serve > "$W/magpie.log" 2>&1 & PIDS+=($!)
MAGPIE_PID=$!
G="http://127.0.0.1:$PORT"
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $KEY" "$G/v1/magpie/quotas/cards" || true)" = 200 ] && break
  sleep 1
done
for _ in 1 2 3 4; do
  curl -s -m 30 -o /dev/null -w 'claude-cli call: HTTP %{http_code}\n' -A 'claude-cli/2.0.0 (external, cli)' \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    "$G/v1/chat/completions" -d '{"model":"alpha/m-alpha","messages":[{"role":"user","content":"perch upgrade"}]}' || true
done
/usr/bin/python3 - "$CFG_DIR/config.json" "$G" "$KEY" <<'PY'
import json, sys, os
p, address, key = sys.argv[1:]
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"address": address, "key": key, "viewKey": key, "group": "coder",
               "member": "alpha/m-alpha", "memberTitle": "m-alpha"}, f)
PY

echo "== Simulator"
# SIM_OS=26: the oldest iOS 26 runtime (the deployment target), else the newest.
echo "runtimes: $(xcrun simctl list runtimes | grep -i ios | tr '\n' ';')"
RUNTIME="$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json,sys,os
rs=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]]
want=os.environ.get("SIM_OS","")
pick=[r for r in rs if r.get("version","").startswith(want + ".") or r.get("version")==want] if want else []
print((pick[0] if pick else rs[-1])["identifier"] if rs else "")')"
TYPE="$(xcrun simctl list devicetypes -j | /usr/bin/python3 -c '
import json,sys
ts={t["name"]:t["identifier"] for t in json.load(sys.stdin)["devicetypes"]}
for n in ("iPhone 18 Pro","iPhone 17 Pro","iPhone 16 Pro","iPhone 16"):
    if n in ts: print(ts[n]); break')"
UDID="$(xcrun simctl create perch-upgrade "$TYPE" "$RUNTIME")"
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
echo "device $UDID ($TYPE, $RUNTIME)"

echo "== build old ($OLD_REV) Release"
set +e
xcodebuild build -project "$OLD/Perch.xcodeproj" -scheme Perch -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$W/dd-old" > "$ART/build-old.txt" 2>&1
S=$?; set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$ART/build-old.txt" | tail -20
[ $S -eq 0 ] || exit $S
OLD_APP="$(find "$W/dd-old/Build/Products" -maxdepth 2 -name Perch.app -type d | head -1)"

echo "== build this tree Release (the app as shipped)"
set +e
xcodebuild build -project Perch.xcodeproj -scheme Perch -configuration Release \
  -destination "id=$UDID" -derivedDataPath "$W/dd-new" > "$ART/build-new.txt" 2>&1
S=$?; set -e
grep -E "error:|BUILD (SUCCEEDED|FAILED)" "$ART/build-new.txt" | tail -20
[ $S -eq 0 ] || exit $S
NEW_APP="$(find "$W/dd-new/Build/Products" -maxdepth 2 -name Perch.app -type d | head -1)"

echo "== build the UI test runner (Debug; it only drives the app)"
set +e
xcodebuild build-for-testing -project Perch.xcodeproj -scheme Perch \
  -destination "id=$UDID" -derivedDataPath "$W/dd-run" > "$ART/build-runner.txt" 2>&1
S=$?; set -e
grep -E "error:|TEST BUILD (SUCCEEDED|FAILED)" "$ART/build-runner.txt" | tail -20
[ $S -eq 0 ] || exit $S
RUN="$(find "$W/dd-run/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)"
RUN_APP="$(find "$W/dd-run/Build/Products" -maxdepth 2 -name Perch.app -type d | head -1)"
for a in "$OLD_APP" "$NEW_APP"; do
  echo "$(basename "$(dirname "$a")"): $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$a/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$a/Info.plist"))"
done

# The runner installs whatever app the xctestrun names: point it at the
# old build for step `old`, back at this one for `new`.
retarget() {
  /usr/bin/python3 - "$RUN" "$RUN_APP" "$1" "$2" <<'PY'
import plistlib, sys
src, new_app, app, out = sys.argv[1:]
d = plistlib.load(open(src, "rb"))
def fix(v):
    if isinstance(v, str): return v.replace("__TESTROOT__/" + new_app.split("/Build/Products/")[1], app) if "Perch.app" in v and "Runner" not in v else v
    if isinstance(v, list): return [fix(x) for x in v]
    if isinstance(v, dict): return {k: fix(x) for k, x in v.items()}
    return v
plistlib.dump(fix(d), open(out, "wb"))
PY
}
retarget "$OLD_APP" "$(dirname "$RUN")/old.xctestrun"
retarget "$NEW_APP" "$(dirname "$RUN")/new.xctestrun"
grep -o "[^<>]*Perch.app[^<>]*" "$(dirname "$RUN")/old.xctestrun" | sort -u | sed 's/^/  old run: /'

MARK="$W/mark"; touch "$MARK"; sleep 1
step() {
  local name="$1" run="$2" test="$3"
  echo "== step $name"
  set +e
  TEST_RUNNER_PERCH_E2E_CONFIG="$CFG_DIR/config.json" TEST_RUNNER_PERCH_UPGRADE_STEP="$name" \
    xcodebuild test-without-building -xctestrun "$run" -destination "id=$UDID" \
    -only-testing:"PerchUITests/PerchE2ETests/$test" -resultBundlePath "$W/$name.xcresult" 2>&1 \
    | sed -E 's/sk-magpie-[A-Za-z0-9_-]+/sk-magpie-…/g' > "$ART/step-$name.txt"
  local s=${PIPESTATUS[0]}
  set -e
  grep -E "Test Case .*(passed|failed|skipped)|error:|Executed|crash|Crash" "$ART/step-$name.txt" | sort -u | head -30
  echo "step $name exit: $s"
  return $s
}
step old "$(dirname "$RUN")/old.xctestrun" test8a_upgradeOldBuildSavesState
echo "-- saved by the old build:"
DATA="$(xcrun simctl get_app_container "$UDID" "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OLD_APP/Info.plist")" data)"
(cd "$DATA" && find . -type f | grep -v -E "/(Snapshots|SplashBoard)/" | head -40)
NEW_STATUS=0
step new "$(dirname "$RUN")/new.xctestrun" test8b_upgradeNewBuildLaunches || NEW_STATUS=$?
# magpie gone, then hanging (the phone away from the computer's network).
kill "$MAGPIE_PID" 2>/dev/null || true; sleep 1
step dead "$(dirname "$RUN")/new.xctestrun" test8c_upgradeNewBuildWithoutMagpie || NEW_STATUS=$?
/usr/bin/python3 - "$PORT" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(64)
held = []
while True:
    c, _ = s.accept(); held.append(c)   # accept, never answer
PY
PIDS+=($!)
sleep 1
step hang "$(dirname "$RUN")/new.xctestrun" test8c_upgradeNewBuildWithoutMagpie || NEW_STATUS=$?

echo "== crash reports"
CR="$ART/crashes"; mkdir -p "$CR"
for d in "$HOME/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports/Retired"; do
  [ -d "$d" ] || continue
  find "$d" -newer "$MARK" -type f \( -name 'Perch*' -o -name '*.ips' \) 2>/dev/null | while read -r f; do
    if grep -q '"Perch"\|Perch.app' "$f" 2>/dev/null; then cp "$f" "$CR/"; echo "crash: $(basename "$f")"; fi
  done
done
for f in "$CR"/*; do
  [ -e "$f" ] || continue
  /usr/bin/python3 - "$f" <<'PY' || head -80 "$f"
import json, sys
t = open(sys.argv[1]).read()
head, _, body = t.partition("\n")
d = json.loads(body)
print("exception:", d.get("exception"), "| termination:", d.get("termination", {}).get("indicator") or d.get("termination"))
print("asi:", d.get("asi"))
imgs = d.get("usedImages", [])
for th in d.get("threads", []):
    if th.get("triggered"):
        for fr in th.get("frames", [])[:30]:
            img = imgs[fr.get("imageIndex", 0)].get("name", "?") if imgs else "?"
            print("  ", img, fr.get("symbol", "?"), "+", fr.get("symbolLocation", ""), fr.get("sourceFile", ""), fr.get("sourceLine", ""))
PY
done
[ -n "$(ls "$CR")" ] || echo "(no Perch crash report)"

# Last log lines of the app, if it died.
xcrun simctl spawn "$UDID" log show --last 3m --style compact --predicate 'process == "Perch"' 2>/dev/null \
  | grep -i -E "fault|crash|fatal|error|assert|terminat" | tail -40 > "$ART/perch-log.txt" || true
echo "perch log lines: $(wc -l < "$ART/perch-log.txt")"; tail -15 "$ART/perch-log.txt"

if [ "$NEW_STATUS" -ne 0 ]; then echo "UPGRADE FAILED: this build over $OLD_REV"; exit "$NEW_STATUS"; fi
echo "UPGRADE PASSED: this build over $OLD_REV launches twice and every tab opens"
