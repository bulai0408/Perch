#!/usr/bin/env bash
# End-to-end test on a Mac (Apple silicon, Xcode + an iOS Simulator)
# against a real, throwaway magpie CLI. It never touches your own magpie:
# everything runs under a temporary HOME and is thrown away afterwards.
#
# Usage: scripts/e2e.sh        (from the repository root)
#
# Environment (all optional):
#   PERCH_E2E_ARTIFACTS    where logs, the .xcresult and screenshots go
#                          (default: ./build/e2e, gitignored)
#   PERCH_E2E_PORT         port for `magpie serve` (default: 3430)
#   PERCH_E2E_DESTINATION  xcodebuild -destination
#                          (default: platform=iOS Simulator,name=iPhone 17)
#   MAGPIE_BIN             a magpie CLI binary to use instead of downloading
#                          the latest magpie-cli-darwin-arm64 release
#   XCODEBUILD             the test runner command (default: xcodebuild)
#
# To point PerchUITests at a magpie you run yourself instead, skip this
# script and pass TEST_RUNNER_PERCH_E2E_ADDRESS, TEST_RUNNER_PERCH_E2E_KEY
# and TEST_RUNNER_PERCH_E2E_VIEW_KEY to `xcodebuild test` (see CONTRIBUTING.md).
#
# 1. Downloads magpie-cli-darwin-arm64 (latest release) into a temp dir and
#    gives it a throwaway HOME.
# 2. Starts two fake OpenAI-compatible upstreams (alpha, beta) that log
#    which model they were asked for (alpha, beta, gamma), adds them as
#    providers, and makes two routing groups: 「Coder」 (alpha, beta, gamma,
#    按顺序) and 「Pinned」 (alpha, beta, 手动 on alpha).
# 3. Makes two 密钥: one with 「可看额度」 + 管理 API 「任何电脑均可」 (admin any),
#    one with 「可看额度」 only. Starts `magpie serve` on 0.0.0.0:3430.
# 4. Runs the PerchUITests XCUITest (connect, 额度, 路由组, 设置) in the
#    Simulator against the Mac's LAN address, so magpie sees Perch the way
#    it sees a phone (on loopback it takes any key for 额度).
# 5. Checks on the magpie side that both groups changed, and that requests
#    to group/coder and group/pinned really go to the new 首选.
#
# Secrets (the 密钥) never get printed.
set -euo pipefail

ROOT="$PWD"
ART="${PERCH_E2E_ARTIFACTS:-$ROOT/build/e2e}"
mkdir -p "$ART"
LOG="$ART/e2e-log.txt"
exec > >(tee "$LOG") 2>&1

PORT="${PERCH_E2E_PORT:-3430}"
UP_A=18301
UP_B=18302
UP_C=18303
UP_BROKE=18304
UP_LIMIT=18305
UP_SLOW=18306
W="$(mktemp -d /tmp/perch-e2e-run.XXXXXX)"
CFG_DIR=/tmp/perch-e2e
mkdir -p "$W/home" "$W/dl" "$CFG_DIR"
chmod 700 "$CFG_DIR"
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null || true; done
  rm -f "$CFG_DIR/config.json"
}
trap cleanup EXIT

if [ -n "${MAGPIE_BIN:-}" ]; then
  echo "== magpie from MAGPIE_BIN"
  cp "$MAGPIE_BIN" "$W/dl/magpie"
else
  echo "== download magpie"
  curl -fsSL --retry 3 -o "$W/dl/magpie" \
    https://github.com/yetone/magpie-releases/releases/latest/download/magpie-cli-darwin-arm64
fi
chmod +x "$W/dl/magpie"
xattr -c "$W/dl/magpie" 2>/dev/null || true

M() {
  env HOME="$W/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" MAGPIE_NO_ACCOUNTS=1 "$W/dl/magpie" "$@"
}
MAGPIE_VERSION="$(M --version 2>/dev/null | head -1 || echo unknown)"
echo "magpie version: $MAGPIE_VERSION"

echo "== fake upstreams"
cat > "$W/fakeup.py" <<'PY'
import http.server, json, sys, time
name, port, logp = sys.argv[1], int(sys.argv[2]), sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _w(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self._w(200, {"object": "list", "data": [{"id": "m-" + name, "object": "model"}]})
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n)
        try: model = json.loads(body).get("model")
        except Exception: model = "?"
        with open(logp, "a") as f: f.write(f"{name} POST {self.path} model={model}\n")
        # 1.4: a broken upstream (500), a rate-limited one (429), a slow one.
        if name == "broke":
            return self._w(500, {"error": {"message": "upstream exploded", "type": "api_error"}})
        if name == "limit":
            return self._w(429, {"error": {"message": "Rate limit reached for requests", "type": "rate_limit_error"}})
        if name == "slow":
            time.sleep(20)
        self._w(200, {"id": "x", "object": "chat.completion", "created": 1, "model": model,
                      "choices": [{"index": 0, "message": {"role": "assistant", "content": "hello from " + name}, "finish_reason": "stop"}],
                      "usage": {"prompt_tokens": 3, "completion_tokens": 3, "total_tokens": 6}})
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
UPLOG="$W/up.log"; : > "$UPLOG"
/usr/bin/python3 "$W/fakeup.py" alpha "$UP_A" "$UPLOG" & PIDS+=($!)
/usr/bin/python3 "$W/fakeup.py" beta "$UP_B" "$UPLOG" & PIDS+=($!)
/usr/bin/python3 "$W/fakeup.py" gamma "$UP_C" "$UPLOG" & PIDS+=($!)
/usr/bin/python3 "$W/fakeup.py" broke "$UP_BROKE" "$W/up-extra.log" & PIDS+=($!)
/usr/bin/python3 "$W/fakeup.py" limit "$UP_LIMIT" "$W/up-extra.log" & PIDS+=($!)
/usr/bin/python3 "$W/fakeup.py" slow "$UP_SLOW" "$W/up-extra.log" & PIDS+=($!)
sleep 1

echo "== providers and the routing groups"
M provider add alpha "url=http://127.0.0.1:$UP_A/v1" key=fake models=m-alpha | tail -1
M provider add beta "url=http://127.0.0.1:$UP_B/v1" key=fake models=m-beta | tail -1
M provider add gamma "url=http://127.0.0.1:$UP_C/v1" key=fake models=m-gamma | tail -1
M group add "Coder" models=alpha/m-alpha,beta/m-beta,gamma/m-gamma routing=order | sed -n 1,2p
M group add "Pinned" models=alpha/m-alpha,beta/m-beta routing=manual | sed -n 1,2p
M provider add broke "url=http://127.0.0.1:$UP_BROKE/v1" key=fake models=m-broke | tail -1
M provider add limit "url=http://127.0.0.1:$UP_LIMIT/v1" key=fake models=m-limit | tail -1
M provider add slow "url=http://127.0.0.1:$UP_SLOW/v1" key=fake models=m-slow | tail -1
M group add "Fallback" models=broke/m-broke,alpha/m-alpha routing=order | sed -n 1,2p
# Stopped and deleted groups: 「Retired」 is switched off, 「Gone」 deleted,
# and alpha2 (alpha's upstream again) makes magpie find a group for m-alpha,
# which is deleted too (magpie keeps that one in its list, "hidden").
M provider add alpha2 "url=http://127.0.0.1:$UP_A/v1" key=fake-alpha2 models=m-alpha | tail -1 || echo "alpha2 not added: no found group to delete"
M group add "Retired" models=alpha/m-alpha,beta/m-beta routing=order | sed -n 1,2p
M group add "Gone" models=beta/m-beta routing=order | sed -n 1,2p

echo "== 密钥"
new_key() {
  local k; k="$(M gateway-key add "$1" 2>/dev/null | tail -1 | tr -d '[:space:]')"
  case "$k" in sk-magpie-*) ;; *) echo "no key from gateway-key add $1" >&2; exit 1;; esac
  printf '%s' "$k"
}
key_id() { M gateway-key list | awk -v n="$1" '$2==n{print $1; exit}'; }
ADMIN_KEY="$(new_key perch-admin)"
VIEW_KEY="$(new_key perch-view)"
echo "keys created (${#ADMIN_KEY} and ${#VIEW_KEY} chars)"
M gateway-key quotas "$(key_id perch-admin)" on | tail -1
M gateway-key admin "$(key_id perch-admin)" any | tail -1
M gateway-key quotas "$(key_id perch-view)" on | tail -1

# 1.5 history fix: this throwaway magpie has no accounts (MAGPIE_NO_ACCOUNTS),
# so it keeps no quota history of its own. Seed its history file (the shape
# magpie itself writes, ~/.config/magpie/quota-history.json) so that
# GET /v1/magpie/quotas/history answers with the real, current format.
MCFG="$(dirname "$(find "$W/home" -name providers.json -print -quit 2>/dev/null || true)")"
case "$MCFG" in ""|.) MCFG="$W/home/.config/magpie" ;; esac
mkdir -p "$MCFG"
/usr/bin/python3 - "$MCFG/quota-history.json" <<'PY'
import json, sys, datetime as dt
now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
def line(span_h, lefts, reset_in_h):
    reset = now + dt.timedelta(hours=reset_in_h); start = reset - dt.timedelta(hours=span_h)
    n = len(lefts); el = (now - start).total_seconds()
    return [{"at": iso(start + dt.timedelta(seconds=el * i / (n - 1))), "left": l,
             "start": iso(start), "resetsAt": iso(reset)} for i, l in enumerate(lefts)]
h = {"claude|work@example.com": {
        "5 hours": line(5, [100, 88, 70, 52, 38], 3),
        "7 days": line(168, [100, 92, 80, 71, 59], 60),
        "7 days · Fable": line(168, [100, 100, 100], 60)},
     "codex|me@example.com": {"5 hours": line(5, [100, 64], 2)}}
json.dump(h, open(sys.argv[1], "w"))
PY
echo "seeded quota history in $MCFG"

echo "== start magpie serve"
env HOME="$W/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" MAGPIE_NO_ACCOUNTS=1 MAGPIE_ADDR="0.0.0.0:$PORT" \
  "$W/dl/magpie" serve > "$W/magpie.log" 2>&1 & PIDS+=($!)
G="http://127.0.0.1:$PORT"
code=000
for _ in $(seq 1 60); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN_KEY" "$G/v1/magpie/quotas/cards" || true)"
  [ "$code" = 200 ] && break
  sleep 1
done
echo "quotas/cards with the admin key: HTTP $code"
[ "$code" = 200 ]

A="$G/v1/magpie/admin/routing-groups"
code="$(curl -s -o "$W/groups-before.json" -w '%{http_code}' -H "Authorization: Bearer $ADMIN_KEY" "$A")"
echo "routing-groups with the admin key: HTTP $code"
[ "$code" = 200 ]
code="$(curl -s -o "$W/noadmin.json" -w '%{http_code}' -H "Authorization: Bearer $VIEW_KEY" "$A")"
echo "routing-groups with the quotas-only key: HTTP $code, $(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["error"].get("code"))' "$W/noadmin.json")"
[ "$code" = 403 ]

# Pinned: 手动 on alpha (the pick is set through the API, as Perch does).
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN_KEY" -H 'Content-Type: application/json' \
  "$A/pick" -d '{"id":"pinned","pick":"alpha/m-alpha"}')"
echo "pinned pick alpha: HTTP $code"
[ "$code" = 200 ]

# Stop 「Retired」, delete 「Gone」 and the group magpie found (the Routing
# page's switch and delete, through the Management API).
post_admin() { curl -s -o "$W/admin-$1.json" -w '%{http_code}' -H "Authorization: Bearer $ADMIN_KEY" -H 'Content-Type: application/json' "$A/$1" -d "$2"; }
echo "switch retired off: HTTP $(post_admin switch '{"id":"retired","on":false}')"
echo "delete gone: HTTP $(post_admin delete '{"id":"gone"}')"
FOUND_ID="$(curl -s -H "Authorization: Bearer $ADMIN_KEY" "$A" | /usr/bin/python3 -c 'import json,sys
gs=[g for g in json.load(sys.stdin).get("groups", []) if g.get("auto") and not g.get("hidden")]
print(gs[0]["id"] if gs else "")' || true)"
if [ -n "$FOUND_ID" ]; then
  echo "found group $FOUND_ID; delete it: HTTP $(post_admin delete "{\"id\":\"$FOUND_ID\"}")"
else
  echo "magpie found no group for m-alpha (no hidden group to check)"
fi
curl -s -H "Authorization: Bearer $ADMIN_KEY" "$A" > "$ART/routing-groups-stopped-deleted.json"
/usr/bin/python3 - "$ART/routing-groups-stopped-deleted.json" "$FOUND_ID" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); found = sys.argv[2]
gs = {g["id"]: g for g in d.get("groups", [])}
for g in d.get("groups", []):
    print("  group", g["id"], "disabled=%s hidden=%s auto=%s" % (g.get("disabled", False), g.get("hidden", False), g.get("auto", False)))
assert gs.get("retired", {}).get("disabled") is True, "retired is not disabled"
assert "gone" not in gs, "a deleted group of the user's is still listed"
if found:
    assert gs.get(found, {}).get("hidden") is True, "the deleted found group is not hidden"
print("stopped/deleted shape OK: disabled=true for a stopped group; a deleted user group is gone; a deleted found group stays with hidden=true")
PY

# Perch talks to magpie like a phone: over the LAN address, not loopback.
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[ -n "$LAN_IP" ] || LAN_IP="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
PHONE_ADDR="$G"; LAN=false
if [ -n "$LAN_IP" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer sk-magpie-perch-e2e-wrong-key-0000" "http://$LAN_IP:$PORT/v1/magpie/quotas/cards" || true)"
  echo "wrong key over the LAN address: HTTP $code"
  if [ "$code" = 401 ]; then PHONE_ADDR="http://$LAN_IP:$PORT"; LAN=true; fi
fi
echo "Perch connects to: $([ "$LAN" = true ] && echo "the LAN address" || echo "loopback (no LAN address; the wrong-key test skips)")"

# 1.5 history fix: what this magpie's GET /v1/magpie/quotas/history answers,
# asked the way Perch asks it (the phone's address, the quotas-only key).
code="$(curl -s -o "$ART/quota-history-response.json" -w '%{http_code}' -H "Authorization: Bearer $VIEW_KEY" "$PHONE_ADDR/v1/magpie/quotas/history")"
echo "quotas/history with the quotas-only key: HTTP $code"
/usr/bin/python3 - "$ART/quota-history-response.json" <<'PY' || echo "history shape: (unreadable)"
import json, sys
d = json.load(open(sys.argv[1]))
items = d.get("data") if isinstance(d, dict) else d
print("history shape: top keys", sorted(d) if isinstance(d, dict) else "list",
      "| item keys", sorted(items[0]) if items else "-",
      "| line keys", sorted(items[0]["lines"][0]) if items and items[0].get("lines") else "-",
      "| point keys", sorted(items[0]["lines"][0]["points"][0]) if items and items[0].get("lines") else "-")
for a in items or []:
    print("  ", a.get("provider"), a.get("user") or "-", [(l.get("name"), len(l.get("points") or [])) for l in a.get("lines") or []])
PY

coder() {
  curl -s -H "Authorization: Bearer $ADMIN_KEY" "$A/coder" | /usr/bin/python3 -c 'import json,sys; g=json.load(sys.stdin); print(",".join(g["members"]), g.get("routing") or "smart")'
}
pinned() {
  curl -s -H "Authorization: Bearer $ADMIN_KEY" "$A/pinned" | /usr/bin/python3 -c 'import json,sys; g=json.load(sys.stdin); print(g.get("routing") or "smart", g.get("pick") or "-")'
}
chat_goes_to() {
  : > "$UPLOG"
  curl -s -m 60 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN_KEY" -H 'Content-Type: application/json' \
    "$G/v1/chat/completions" -d "{\"model\":\"group/${1:-coder}\",\"messages\":[{\"role\":\"user\",\"content\":\"perch e2e $RANDOM\"}]}" >/dev/null
  awk 'NR==1{print $1}' "$UPLOG"
}
read -r BEFORE_MEMBERS BEFORE_ROUTING < <(coder)
echo "Coder before: $BEFORE_MEMBERS ($BEFORE_ROUTING)"
echo "group/coder before goes to: $(chat_goes_to coder)"
read -r PIN_ROUTING PIN_PICK < <(pinned)
echo "Pinned before: $PIN_ROUTING on $PIN_PICK; group/pinned goes to: $(chat_goes_to pinned)"

# 1.4: Claude Code calls (magpie tells the agent by its User-Agent): a few
# that work, one rate-limited (429), one magpie hands on (500 → alpha);
# and, while the UI test runs, one slow call after another for 正在进行.
agent_call() {
  curl -s -m 60 -o /dev/null -w '%{http_code}' -A 'claude-cli/2.0.0 (external, cli)' \
    -H "Authorization: Bearer $ADMIN_KEY" -H 'Content-Type: application/json' \
    "$G/v1/chat/completions" -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"perch e2e $RANDOM\"}]}" || true
}
AGENT_CALLS=true
for _ in 1 2 3; do echo "claude-cli → alpha/m-alpha: HTTP $(agent_call alpha/m-alpha)"; done
echo "claude-cli → limit/m-limit: HTTP $(agent_call limit/m-limit)"
echo "claude-cli → group/fallback: HTTP $(agent_call group/fallback)"
( while true; do agent_call slow/m-slow >/dev/null; done ) & PIDS+=($!)
SLOW_PID=$!

/usr/bin/python3 - "$CFG_DIR/config.json" "$PHONE_ADDR" "$ADMIN_KEY" "$VIEW_KEY" "$LAN" "$AGENT_CALLS" "$FOUND_ID" <<'PY'
import json, sys, os
p, address, key, view, lan, agent, found = sys.argv[1:]
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump({"address": address, "key": key, "viewKey": view, "group": "coder",
               "member": "beta/m-beta", "memberTitle": "m-beta",
               "lan": lan == "true", "agentCalls": agent == "true",
               "disabledGroup": "retired", "deletedGroups": ["gone"] + ([found] if found else [])}, f)
PY

echo "== XCUITest"
rm -rf "$ART/E2EResults.xcresult"
set +e
TEST_RUNNER_PERCH_E2E_CONFIG="$CFG_DIR/config.json" \
${XCODEBUILD:-xcodebuild} test \
  -project Perch.xcodeproj \
  -scheme Perch \
  -destination "${PERCH_E2E_DESTINATION:-platform=iOS Simulator,name=iPhone 17}" \
  -only-testing:PerchUITests \
  -skip-testing:PerchUITests/PerchShotsTests \
  -skip-testing:PerchUITests/PerchE2ETests/test9a_videoSlow \
  -skip-testing:PerchUITests/PerchE2ETests/test9b_videoBlockFailed \
  -skip-testing:PerchUITests/PerchE2ETests/test9c_videoPageFailed \
  -skip-testing:PerchUITests/PerchE2ETests/test9d_videoOffline \
  -skip-testing:PerchUITests/PerchE2ETests/test9e_videoSummary \
  -resultBundlePath "$ART/E2EResults.xcresult"
TEST_STATUS=$?
set -e
echo "xcodebuild test exit: $TEST_STATUS"

# Slow-network recordings against this magpie (test9*): a fresh iPhone
# Pro, one mp4 per case. The test drops <name>.start/.stop in $VID; this
# watcher runs simctl io recordVideo between them. Calls keep landing so
# each refresh rolls numbers to new values.
VIDEOS="$ART/slownet-videos"
rm -rf "$VIDEOS"; mkdir -p "$VIDEOS"
VID="$CFG_DIR/video"; rm -rf "$VID"; mkdir -p "$VID"
VRUNTIME="$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r.get("platform","iOS")=="iOS" and "iOS" in r["name"]]
print(rs[-1]["identifier"] if rs else "")')"
VTYPE="$(xcrun simctl list devicetypes -j | /usr/bin/python3 -c '
import json,sys
ts={t["name"]:t["identifier"] for t in json.load(sys.stdin)["devicetypes"]}
for n in ("iPhone 18 Pro","iPhone 17 Pro","iPhone 16 Pro"):
    if n in ts: print(ts[n]); break')"
VUDID=""
if [ -n "$VRUNTIME" ] && [ -n "$VTYPE" ]; then
  VUDID="$(xcrun simctl create perch-video "$VTYPE" "$VRUNTIME" 2>/dev/null || true)"
fi
VIDEO_STATUS=0
if [ -n "$VUDID" ]; then
  xcrun simctl boot "$VUDID" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$VUDID" -b >/dev/null 2>&1 || true
  xcrun simctl status_bar "$VUDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 >/dev/null 2>&1 || true
  ( while true; do agent_call alpha/m-alpha >/dev/null; sleep 2; done ) & PIDS+=($!)
  CALLS_PID=$!
  (
    REC=""
    while true; do
      for f in "$VID"/*.start; do
        [ -e "$f" ] || continue
        n="$(basename "$f" .start)"; rm -f "$f"
        xcrun simctl io "$VUDID" recordVideo --codec h264 --force "$VIDEOS/$n.mp4" > "$VID/$n.log" 2>&1 &
        REC=$!
        for _ in $(seq 1 60); do grep -q "Recording started" "$VID/$n.log" 2>/dev/null && break; sleep 0.1; done
        touch "$VID/$n.recording"
      done
      for f in "$VID"/*.stop; do
        [ -e "$f" ] || continue
        n="$(basename "$f" .stop)"; rm -f "$f"
        if [ -n "$REC" ]; then kill -INT "$REC" 2>/dev/null || true; wait "$REC" 2>/dev/null || true; fi
        REC=""
        touch "$VID/$n.done"
      done
      sleep 0.2
    done
  ) & PIDS+=($!)
  WATCH_PID=$!
  echo "== recordings on $VUDID"
  set +e
  TEST_RUNNER_PERCH_E2E_CONFIG="$CFG_DIR/config.json" TEST_RUNNER_PERCH_VIDEO_DIR="$VID" xcodebuild test \
    -project Perch.xcodeproj -scheme Perch \
    -destination "id=$VUDID" \
    -only-testing:PerchUITests/PerchE2ETests/test9a_videoSlow \
    -only-testing:PerchUITests/PerchE2ETests/test9b_videoBlockFailed \
    -only-testing:PerchUITests/PerchE2ETests/test9c_videoPageFailed \
    -only-testing:PerchUITests/PerchE2ETests/test9d_videoOffline \
    -only-testing:PerchUITests/PerchE2ETests/test9e_videoSummary \
    -resultBundlePath "$W/Videos.xcresult" 2>&1 | sed -E 's/sk-magpie-[A-Za-z0-9_-]+/sk-magpie-…/g' > "$VIDEOS/recordings-log.txt"
  VIDEO_STATUS=${PIPESTATUS[0]}
  grep -E "Test Case .*(passed|failed)|error:|SLOWNET-VIDEO|SUMMARY-NUMBERS|Executed" "$VIDEOS/recordings-log.txt" | sort -u
  set -e
  echo "xcodebuild recordings exit: $VIDEO_STATUS"
  kill "$WATCH_PID" "$CALLS_PID" 2>/dev/null || true
  sleep 3   # let a call in flight finish before the routing checks read the upstream log
  xcrun simctl shutdown "$VUDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$VUDID" >/dev/null 2>&1 || true
  for v in "$VIDEOS"/*.mp4; do
    [ -e "$v" ] || continue
    echo "recording $(basename "$v"): $(( $(stat -f %z "$v") / 1024 )) KB"
  done
else
  echo "no iPhone Pro device for the recordings"; VIDEO_STATUS=1
fi
# Named copies: (a) the summary, no count-up; (b) 连不上 / the banner collapsing.
ROUND3="$ART/collapse-and-summary"; rm -rf "$ROUND3"; mkdir -p "$ROUND3"
[ -e "$VIDEOS/5-summary.mp4" ] && cp "$VIDEOS/5-summary.mp4" "$ROUND3/a-agent-summary-no-countup.mp4"
[ -e "$VIDEOS/4-offline.mp4" ] && cp "$VIDEOS/4-offline.mp4" "$ROUND3/b-offline-card-collapse.mp4"
[ -e "$VIDEOS/3-page-failed.mp4" ] && cp "$VIDEOS/3-page-failed.mp4" "$ROUND3/b-banner-collapse.mp4"
echo "summary/collapse recordings: $(ls "$ROUND3" | tr '\n' ' ')"
[ "$VIDEO_STATUS" -eq 0 ] || echo "RECORDINGS FAILED ($VIDEO_STATUS)"
kill "$SLOW_PID" 2>/dev/null || true
echo "usage rows (claude): $(curl -s -H "Authorization: Bearer $ADMIN_KEY" "$G/v1/magpie/usage/requests?period=today&agent=claude&limit=20" \
  | /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)
for r in d.get("rows", d.get("requests", []))[:12]:
    print(" ", r.get("model"), r.get("status"), r.get("tries"), r.get("retried_ms"), (r.get("err") or r.get("error") or "")[:60])' 2>/dev/null || echo '(unreadable)')"

SHOTS="$ART/screenshots"
rm -rf "$SHOTS" "$W/att"
mkdir -p "$SHOTS" "$W/att"
if xcrun xcresulttool export attachments --path "$ART/E2EResults.xcresult" --output-path "$W/att" >/dev/null 2>&1; then
  # Name each screenshot after its XCTAttachment name (06-routes.png, ...).
  /usr/bin/python3 - "$W/att" "$SHOTS" <<'PY'
import json, os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(src, "manifest.json"))):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        base = name.split("_0_")[0] if "_0_" in name else os.path.splitext(name)[0]
        # Keep only the named screenshots (01-…); skip recordings, snapshots, debug text.
        if not base[:2].isdigit():
            continue
        ext = os.path.splitext(a["exportedFileName"])[1] or ".png"
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(dst, base + ext))
print("screenshots:", " ".join(sorted(os.listdir(dst))))
PY
else
  echo "(could not export attachments)"
fi
# Slow network (test5): its shots in their own folder too.
SLOWNET="$ART/e2e-shots-slownet-e2e"
rm -rf "$SLOWNET"; mkdir -p "$SLOWNET"
for f in "$SHOTS"/6[0-9]-*.png; do [ -e "$f" ] && cp "$f" "$SLOWNET/"; done
echo "slow-network e2e shots: $(ls "$SLOWNET" | tr '\n' ' ')"

echo "== magpie side"
read -r AFTER_MEMBERS AFTER_ROUTING < <(coder)
echo "Coder after: $AFTER_MEMBERS ($AFTER_ROUTING)"
SERVED="$(chat_goes_to coder)"
echo "group/coder after goes to: $SERVED"
read -r PIN_ROUTING PIN_PICK < <(pinned)
PIN_SERVED="$(chat_goes_to pinned)"
echo "Pinned after: $PIN_ROUTING on $PIN_PICK; group/pinned goes to: $PIN_SERVED"

if [ "$TEST_STATUS" -ne 0 ]; then
  echo "magpie log tail:"; tail -20 "$W/magpie.log" | sed -E 's/sk-magpie-[A-Za-z0-9_-]+/sk-magpie-…/g'
  exit "$TEST_STATUS"
fi
[ "$VIDEO_STATUS" -eq 0 ] || { echo "FAIL: the slow-network recordings (test9*) failed"; exit "$VIDEO_STATUS"; }
[ "${AFTER_MEMBERS%%,*}" = "beta/m-beta" ] || { echo "FAIL: Coder's first model is still ${AFTER_MEMBERS%%,*}"; exit 1; }
[ "$AFTER_ROUTING" = "order" ] || { echo "FAIL: Coder routes by $AFTER_ROUTING, not order"; exit 1; }
[ "$SERVED" = "beta" ] || { echo "FAIL: group/coder went to ${SERVED:-nobody}, not beta"; exit 1; }
[ "$PIN_ROUTING" = "manual" ] || { echo "FAIL: Pinned routes by $PIN_ROUTING, not manual"; exit 1; }
[ "$PIN_PICK" = "beta/m-beta" ] || { echo "FAIL: Pinned picks $PIN_PICK, not beta/m-beta"; exit 1; }
[ "$PIN_SERVED" = "beta" ] || { echo "FAIL: group/pinned went to ${PIN_SERVED:-nobody}, not beta"; exit 1; }
echo "E2E PASSED on magpie $MAGPIE_VERSION: Coder is 按顺序 with beta first, Pinned is 手动 on beta; both groups now go to beta"
