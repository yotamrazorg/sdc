#!/usr/bin/env bash
# =============================================================================
# smoke-catalog-fe-jdk21.sh - run the catalog-fe war on JDK 21 without Docker.
#
# Replicates what catalog-fe/sdc-frontend/Dockerfile + startup.sh do inside the
# eclipse-temurin:21-jre-alpine image:
#   * Jetty distribution of the version in the root pom (jetty-distribution.version)
#     is downloaded (SHA-1 verified) into a cache dir OUTSIDE the repo and unpacked
#   * a fresh JETTY_BASE is created with the same start.jar commands as
#     set-http-module.sh (deploy, http, https, rewrite; "setuid" is skipped because
#     it needs the container's `onap` user)
#   * the Dockerfile's COPY layout is reproduced (wars -> webapps, artifacts/files/*
#     -> config/ etc/ start.d/, startup.sh) and the real startup.sh is executed
#   * a tiny local HTTP listener stands in for SDC-BE: it records the
#     MonitoringEvent JSON that FeMonitoringService POSTs (this is where the JDK
#     OperatingSystemMXBean based MonitoringMetricsFetcher output becomes visible)
#
# Checks (exit code != 0 when any fails):
#   (a) GET /sdc1/rest/healthCheck answers with HTTP 200/500 and a JSON body
#   (b) the running JVM is Java 21 (jcmd VM.version, /proc/<pid>/exe, Jetty's own
#       startup log line "jvm 21.x")
#   (c) the posted MonitoringEvent carries real values: hostcpu 0..100, hostmem
#       0..100, hostdisk map, jvmcpu > 0, jvmmem > 0, jvmtnum > 0; no sigar anywhere
#
# Usage:  build-env/smoke-catalog-fe-jdk21.sh
# Environment knobs
#   SMOKE_CACHE       cache dir (default: $HOME/.cache/onap-smoke); holds the Jetty
#                     download and the per-run JETTY_BASE (<cache>/run)
#   SMOKE_HTTP_PORT   Jetty HTTP port  (default: first free port from 8181)
#   SMOKE_HTTPS_PORT  Jetty HTTPS port (default: first free port from 9443)
#   SMOKE_BE_PORT     stand-in BE port (default: first free port from 18080)
#   SMOKE_BUILD       1 = always (re)build the war, 0 = never, auto (default) = only
#                     when catalog-fe/target/catalog-fe-<version>.war is missing
#   SMOKE_TIMEOUT     seconds to wait for health / first metrics event (default 120)
#   SMOKE_REQUIRE_200 1 = also fail when the health endpoint is not 200 after the stand-in BE
#                     reports UP (informational by default: it needs the onboarding war)
#   SMOKE_KEEP        1 = keep the run dir + logs after the run (always kept on failure)
# The Maven build log is written to $SMOKE_LOG_DIR (default <cache>/logs).
# =============================================================================
set -uo pipefail

SDC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SDC_ROOT" || exit 2

SMOKE_CACHE="${SMOKE_CACHE:-$HOME/.cache/onap-smoke}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-120}"
SMOKE_BUILD="${SMOKE_BUILD:-auto}"
SMOKE_LOG_DIR="${SMOKE_LOG_DIR:-$SMOKE_CACHE/logs}"
RUN_DIR="$SMOKE_CACHE/run"
mkdir -p "$SMOKE_CACHE" "$SMOKE_LOG_DIR"

FAILED=0
JETTY_PGID=""
STUB_PID=""

log()  { printf '[smoke] %s\n' "$*"; }
fail() { printf '[smoke] FAIL: %s\n' "$*" >&2; FAILED=1; }
die()  { fail "$*"; exit 1; }

# ---- always stop Jetty and the stand-in BE ----------------------------------
cleanup() {
  local rc=$?
  [[ $FAILED -ne 0 && $rc -eq 0 ]] && rc=1
  if [[ -n "$JETTY_PGID" ]]; then
    kill -TERM -- "-$JETTY_PGID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$JETTY_PGID" 2>/dev/null || break; sleep 1; done
    kill -KILL -- "-$JETTY_PGID" 2>/dev/null || true
    log "Jetty stopped"
  fi
  if [[ -n "$STUB_PID" ]]; then kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; fi
  if [[ $rc -eq 0 && "${SMOKE_KEEP:-0}" != 1 ]]; then
    rm -rf "$RUN_DIR"
  else
    log "run dir kept for inspection: $RUN_DIR"
  fi
  if [[ $rc -eq 0 ]]; then log "RESULT: PASS"; else log "RESULT: FAIL (exit $rc)"; fi
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

free_port() { # first free TCP port >= $1
  python3 - "$1" <<'PY'
import socket, sys
p = int(sys.argv[1])
while True:
    s = socket.socket()
    try:
        s.bind(("127.0.0.1", p)); s.close(); print(p); break
    except OSError:
        s.close(); p += 1
PY
}

# ---- 0. toolchain -----------------------------------------------------------
# shellcheck disable=SC1091
MCODE_BOOTSTRAP_QUIET=1 source "$SDC_ROOT/build-env/bootstrap-java21.sh" || die "toolchain bootstrap failed"
command -v python3 >/dev/null || die "python3 is required"
command -v curl >/dev/null || die "curl is required"
JAVA_VER_LINE="$(java -version 2>&1 | head -1)"
log "toolchain: $JAVA_VER_LINE  (JAVA_HOME=$JAVA_HOME)"
[[ "$JAVA_VER_LINE" == *'"21.'* ]] || die "java on PATH is not 21"

# ---- 1. versions / war ------------------------------------------------------
JETTY_VER="$(sed -n 's#.*<jetty-distribution.version>\(.*\)</jetty-distribution.version>.*#\1#p' pom.xml | head -1)"
if [[ "$JETTY_VER" == '${jetty.version}' ]]; then
  JETTY_VER="$(sed -n 's#.*<jetty.version>\(.*\)</jetty.version>.*#\1#p' pom.xml | head -1)"
fi
[[ -n "$JETTY_VER" ]] || die "cannot determine jetty-distribution.version from pom.xml"
SDC_VER="$(sed -n '0,/<version>/s#.*<version>\(.*\)</version>.*#\1#p' catalog-fe/pom.xml | head -1)"
[[ -n "$SDC_VER" ]] || SDC_VER="$(sed -n 's#.*<version>\(1\.[0-9.]*-SNAPSHOT\)</version>.*#\1#p' pom.xml | head -1)"
WAR="catalog-fe/target/catalog-fe-${SDC_VER}.war"
log "jetty-distribution $JETTY_VER, catalog-fe $SDC_VER"

if [[ "$SMOKE_BUILD" == 1 || ( "$SMOKE_BUILD" == auto && ! -f "$WAR" ) ]]; then
  log "building catalog-fe war (log: $SMOKE_LOG_DIR/catalog-fe-build.log)"
  mvn -f catalog-fe/pom.xml -DskipTests install > "$SMOKE_LOG_DIR/catalog-fe-build.log" 2>&1 \
    || die "catalog-fe build failed, see $SMOKE_LOG_DIR/catalog-fe-build.log"
fi
[[ -f "$WAR" ]] || die "war not found: $WAR (run: mvn -f catalog-fe/pom.xml -DskipTests install)"

# the war must be free of native sigar libraries
python3 - "$WAR" <<'PY' || die "sigar artifacts found in $WAR"
import sys, zipfile
bad = [n for n in zipfile.ZipFile(sys.argv[1]).namelist() if 'sigar' in n.lower()]
print("[smoke] war sigar entries: %d" % len(bad))
sys.exit(1 if bad else 0)
PY

# onboarding-fe war: the image ships it next to catalog-fe (ADD onboarding*.war)
ONBOARDING_WAR=""
for c in "openecomp-ui/target/onboarding-fe-${SDC_VER}.war"; do [[ -f "$c" ]] && ONBOARDING_WAR="$c"; done
if [[ -z "$ONBOARDING_WAR" ]]; then
  M2REPO="$(mvn -q -o help:evaluate -Dexpression=settings.localRepository -DforceStdout 2>/dev/null | tail -1)"
  c="$M2REPO/org/openecomp/sdc/onboarding-fe/${SDC_VER}/onboarding-fe-${SDC_VER}.war"
  [[ -f "$c" ]] && ONBOARDING_WAR="$c"
fi
if [[ -n "$ONBOARDING_WAR" ]]; then log "onboarding-fe war: $ONBOARDING_WAR"; else log "onboarding-fe war not found, deploying catalog-fe only"; fi

# ---- 2. Jetty distribution (cache, outside the repo) ------------------------
JETTY_TGZ="$SMOKE_CACHE/jetty-distribution-${JETTY_VER}.tar.gz"
JETTY_HOME="$SMOKE_CACHE/jetty-home-${JETTY_VER}"
if [[ ! -x "$JETTY_HOME/start.jar" && ! -f "$JETTY_HOME/start.jar" ]]; then
  base_url="https://repo1.maven.org/maven2/org/eclipse/jetty/jetty-distribution/${JETTY_VER}/jetty-distribution-${JETTY_VER}.tar.gz"
  if [[ ! -f "$JETTY_TGZ" ]]; then
    log "downloading jetty-distribution ${JETTY_VER}"
    curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 30 -o "$JETTY_TGZ.part" "$base_url" || die "jetty download failed"
    mv "$JETTY_TGZ.part" "$JETTY_TGZ"
  fi
  want="$(curl -fsSL --retry 3 "$base_url.sha1" | awk '{print $1}')"
  got="$(sha1sum "$JETTY_TGZ" | awk '{print $1}')"
  if [[ -z "$want" || "$want" != "$got" ]]; then rm -f "$JETTY_TGZ"; die "jetty SHA-1 mismatch (want '$want' got '$got')"; fi
  rm -rf "$JETTY_HOME.tmp" && mkdir -p "$JETTY_HOME.tmp"
  tar xzf "$JETTY_TGZ" -C "$JETTY_HOME.tmp" --strip-components=1 && mv "$JETTY_HOME.tmp" "$JETTY_HOME" || die "jetty unpack failed"
fi
log "JETTY_HOME=$JETTY_HOME"

# ---- 3. JETTY_BASE like the image (fresh every run => idempotent) -----------
HTTP_PORT="${SMOKE_HTTP_PORT:-$(free_port 8181)}"
HTTPS_PORT="${SMOKE_HTTPS_PORT:-$(free_port 9443)}"
BE_PORT="${SMOKE_BE_PORT:-$(free_port 18080)}"
[[ "$HTTPS_PORT" != "$HTTP_PORT" ]] || HTTPS_PORT="$(free_port $((HTTP_PORT + 1)))"
log "ports: http=$HTTP_PORT https=$HTTPS_PORT stand-in-BE=$BE_PORT"

rm -rf "$RUN_DIR"
JETTY_BASE="$RUN_DIR/jetty-base"
mkdir -p "$JETTY_BASE/webapps" "$JETTY_BASE/config/catalog-fe" "$JETTY_BASE/config/onboarding-fe" "$JETTY_BASE/etc" "$JETTY_BASE/logs" "$JETTY_BASE/temp"
FE="catalog-fe/sdc-frontend"

(
  cd "$JETTY_BASE" || exit 1
  export JETTY_HOME JETTY_BASE
  # same commands as artifacts/scripts/set-http-module.sh (without setuid)
  java -jar "$JETTY_HOME/start.jar" --add-to-start=deploy
  java -jar "$JETTY_HOME/start.jar" --create-startd --add-to-start=http,https,rewrite
) > "$RUN_DIR/jetty-base-setup.log" 2>&1 || { tail -30 "$RUN_DIR/jetty-base-setup.log"; die "JETTY_BASE setup failed"; }

cp "$WAR" "$JETTY_BASE/webapps/"
[[ -n "$ONBOARDING_WAR" ]] && cp "$ONBOARDING_WAR" "$JETTY_BASE/webapps/onboarding-fe-${SDC_VER}.war"
cp "$FE"/artifacts/files/catalog-fe/*     "$JETTY_BASE/config/catalog-fe/"
cp "$FE"/artifacts/files/onboardingfe/*   "$JETTY_BASE/config/onboarding-fe/"
cp "$FE"/artifacts/files/fe_etc/*         "$JETTY_BASE/etc/"
cp "$FE"/artifacts/files/startdConfig/*   "$JETTY_BASE/start.d/"
cp "$FE"/artifacts/files/org.onap.sdc.p12 "$FE"/artifacts/files/org.onap.sdc.trust.jks "$JETTY_BASE/etc/"
cp "$FE/startup.sh" "$JETTY_BASE/startup.sh" && chmod 755 "$JETTY_BASE/startup.sh"
echo "etc/rewrite-root-to-sdc1.xml" >> "$JETTY_BASE/start.d/rewrite.ini"
echo "jetty.httpConfig.sendServerVersion=false" >> "$JETTY_BASE/start.d/start.ini"

# smoke-only deviations from the image (ports + monitoring on + BE pointing to the stand-in)
sed -i "s/^jetty.http.port=.*/jetty.http.port=${HTTP_PORT}/"   "$JETTY_BASE/start.d/http.ini"
sed -i "s/^jetty.https.port=.*/jetty.https.port=${HTTPS_PORT}/" "$JETTY_BASE/start.d/https.ini"
sed -i "s/^jetty.ssl.port=.*/jetty.ssl.port=${HTTPS_PORT}/"     "$JETTY_BASE/start.d/ssl.ini" 2>/dev/null || true
CFG="$JETTY_BASE/config/catalog-fe/configuration.yaml"
python3 - "$CFG" "$HTTP_PORT" "$BE_PORT" <<'PY' || die "cannot adapt configuration.yaml"
import re, sys
path, http_port, be_port = sys.argv[1:4]
t = open(path).read()
def sub(pattern, repl):
    global t
    t, n = re.subn(pattern, repl, t, count=1, flags=re.M)
    if n != 1:
        sys.exit("pattern not found in configuration.yaml: " + pattern)
sub(r'^beHost:.*$', 'beHost: 127.0.0.1')
sub(r'^beHttpPort:.*$', 'beHttpPort: ' + be_port)
sub(r'^(\s+)hostFe: .*$', r'\1hostFe: 127.0.0.1')
sub(r'^(\s+)portFe: .*$', r'\1portFe: ' + http_port)
sub(r'^(\s+)enabled: false$', r'\1enabled: true')          # systemMonitoring.enabled
sub(r'^(\s+)probeIntervalInSeconds: .*$', r'\1probeIntervalInSeconds: 3')
open(path, 'w').write(t)
PY
grep -n -A3 "systemMonitoring" "$CFG" | sed 's/^/[smoke] cfg: /'
# the Jetty XML rewrite config and gzip are used unchanged

# ---- 4. stand-in BE ---------------------------------------------------------
EVENTS="$RUN_DIR/monitoring-events.jsonl"
cat > "$RUN_DIR/stub_be.py" <<'PY'
import http.server, json, os, sys
port, out = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _reply(self, code, body=b""):
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0) or 0)).decode()
        if self.path == "/sdc2/rest/monitoring":
            with open(out, "a") as f:
                f.write(json.dumps({"path": self.path, "event": json.loads(body)}) + "\n")
            return self._reply(200)
        self._reply(404)
    def do_GET(self):
        # default: no SDC-BE here (stand-alone case => FE health 500 "BE DOWN").
        # When <out>.health-up exists the stand-in answers like a healthy SDC-BE.
        if self.path == "/sdc2/rest/healthCheck" and os.path.exists(out + ".health-up"):
            comps = [{"healthCheckComponent": c, "healthCheckStatus": "UP", "version": "stand-in", "description": "OK"}
                     for c in ("BE", "JANUSGRAPH", "CASSANDRA", "DE")]
            body = json.dumps({"sdcVersion": "stand-in", "siteMode": "UNKNOWN", "componentsInfo": comps}).encode()
            self.send_response(200); self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        self._reply(404)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
PY
python3 "$RUN_DIR/stub_be.py" "$BE_PORT" "$EVENTS" > "$RUN_DIR/stub_be.log" 2>&1 &
STUB_PID=$!

# ---- 5. start Jetty via the real startup.sh ---------------------------------
JETTY_LOG="$RUN_DIR/jetty-console.log"
log "starting Jetty with startup.sh (JAVA_OPTIONS=-Xmx512m -Djetty.base=<run dir>)"
(
  export JETTY_HOME JETTY_BASE JETTY_USER="$(id -un)" JETTY_GROUP="$(id -gn)" JAVA_OPTIONS="-Xmx512m -Djetty.base=$JETTY_BASE"
  exec setsid sh "$JETTY_BASE/startup.sh"
) > "$JETTY_LOG" 2>&1 &
JETTY_PGID=$!

URL="http://127.0.0.1:${HTTP_PORT}/sdc1/rest/healthCheck"
deadline=$((SECONDS + SMOKE_TIMEOUT))
HC_CODE=""; HC_BODY=""
while (( SECONDS < deadline )); do
  kill -0 "$JETTY_PGID" 2>/dev/null || { tail -40 "$JETTY_LOG"; die "Jetty exited prematurely"; }
  HC_BODY="$(curl -s --max-time 5 -o "$RUN_DIR/health.body" -w '%{http_code}' -H 'Accept: application/json' "$URL" 2>/dev/null)" || HC_BODY=""
  HC_CODE="$HC_BODY"; HC_BODY="$(cat "$RUN_DIR/health.body" 2>/dev/null || true)"
  # the very first answer can be "500 {}" until the scheduled task ran once
  if [[ "$HC_CODE" =~ ^(200|500)$ && "$HC_BODY" != "{}" && -n "$HC_BODY" ]]; then break; fi
  sleep 2
done

echo "=== (a) health endpoint ==="
echo "GET $URL -> HTTP $HC_CODE"
echo "$HC_BODY"
if [[ "$HC_CODE" =~ ^(200|500)$ ]] && python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$HC_BODY" 2>/dev/null && [[ "$HC_BODY" != "{}" ]]; then
  log "health endpoint answered (HTTP $HC_CODE, JSON body)"
else
  tail -60 "$JETTY_LOG"; fail "health endpoint did not answer with 200/500 + JSON"
fi
# informational: same endpoint once the stand-in BE reports UP (what the container probe expects: 200)
touch "$EVENTS.health-up"
UP_CODE=""
for _ in $(seq 1 15); do
  UP_CODE="$(curl -s --max-time 5 -o "$RUN_DIR/health-up.body" -w '%{http_code}' -H 'Accept: application/json' "$URL" 2>/dev/null || true)"
  [[ "$UP_CODE" == 200 ]] && break
  sleep 2
done
echo "--- with the stand-in BE reporting UP: GET $URL -> HTTP $UP_CODE"
tr -d '\n ' < "$RUN_DIR/health-up.body" 2>/dev/null; echo
if [[ "${SMOKE_REQUIRE_200:-0}" == 1 && "$UP_CODE" != 200 ]]; then fail "expected HTTP 200 with a healthy stand-in BE"; fi
ROOT_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HTTP_PORT}/" || true)"
echo "GET / -> HTTP $ROOT_CODE (rewrite rule redirects to /sdc1)"

# ---- 6. JVM version evidence ------------------------------------------------
echo "=== (b) JVM version ==="
JPID=""
for p in $(pgrep -g "$JETTY_PGID" 2>/dev/null); do
  if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'start.jar' && [[ "$(basename "$(readlink -f "/proc/$p/exe")")" == java ]]; then JPID=$p; break; fi
done
if [[ -z "$JPID" ]]; then fail "cannot find the Jetty JVM pid"; else
  echo "jvm pid: $JPID"
  echo "/proc/$JPID/exe -> $(readlink -f "/proc/$JPID/exe")"
  echo "cmdline: $(tr '\0' ' ' < "/proc/$JPID/cmdline" | sed 's/-Djavax.net.ssl.trustStorePassword=[^ ]*/-Djavax.net.ssl.trustStorePassword=***/')"
  VMV="$(jcmd "$JPID" VM.version 2>&1 | sed -n '2,$p' | tr '\n' ' ')"
  echo "jcmd VM.version: $VMV"
  jcmd "$JPID" VM.system_properties 2>/dev/null | grep -E '^(java.version|java.vm.name|java.vm.version|java.specification.version|java.home)=' | sed 's/^/sysprop: /'
  [[ "$VMV" == *"JDK 21."* ]] || fail "jcmd VM.version does not report JDK 21: $VMV"
  [[ "$(readlink -f "/proc/$JPID/exe")" == "$(readlink -f "$JAVA_HOME")"/* ]] || fail "JVM binary is not under JAVA_HOME ($JAVA_HOME)"
fi
JETTY_LINE="$(grep -h -m1 -E 'jetty-[0-9.]+.*jvm ' "$JETTY_LOG" "$JETTY_BASE"/logs/* 2>/dev/null | head -1)"
echo "Jetty's own log line: ${JETTY_LINE:-<not found>}"
[[ "$JETTY_LINE" == *"jvm 21."* ]] || fail "Jetty startup log does not report 'jvm 21.'"

# ---- 7. monitoring metrics (sigar replacement) ------------------------------
echo "=== (c) monitoring metrics POSTed by FeMonitoringService (JDK OperatingSystemMXBean) ==="
deadline=$((SECONDS + SMOKE_TIMEOUT))
while (( SECONDS < deadline )) && [[ ! -s "$EVENTS" ]]; do sleep 1; done
if [[ ! -s "$EVENTS" ]]; then
  tail -60 "$JETTY_LOG"; fail "no MonitoringEvent reached the stand-in BE within ${SMOKE_TIMEOUT}s"
else
  sleep 4   # collect a second sample to show the values are live
  python3 - "$EVENTS" <<'PY' || fail "monitoring metrics validation failed"
import json, sys
events = [json.loads(l)["event"] for l in open(sys.argv[1]) if l.strip()]
print("received %d MonitoringEvent(s); first and last:" % len(events))
for e in (events[0], events[-1]):
    print(json.dumps(e, sort_keys=True))
e = events[-1]
errs = []
if not (isinstance(e.get("hostcpu"), (int, float)) and 0 <= e["hostcpu"] <= 100): errs.append("hostcpu not in 0..100: %r" % e.get("hostcpu"))
if not (isinstance(e.get("hostmem"), (int, float)) and 0 < e["hostmem"] <= 100): errs.append("hostmem not in (0,100]: %r" % e.get("hostmem"))
if not (isinstance(e.get("hostdisk"), str) and e["hostdisk"].startswith("{") and "=" in e["hostdisk"]): errs.append("hostdisk is not a mount->percent map: %r" % e.get("hostdisk"))
if not (isinstance(e.get("jvmcpu"), (int, float)) and e["jvmcpu"] > 0): errs.append("jvmcpu (ns) not > 0: %r" % e.get("jvmcpu"))
if not (isinstance(e.get("jvmmem"), (int, float)) and e["jvmmem"] > 0): errs.append("jvmmem not > 0: %r" % e.get("jvmmem"))
if not (isinstance(e.get("jvmtnum"), (int, float)) and e["jvmtnum"] > 0): errs.append("jvmtnum not > 0: %r" % e.get("jvmtnum"))
if e.get("jvmid") != "jetty-fe": errs.append("jvmid != jetty-fe: %r" % e.get("jvmid"))
if len(events) > 1 and events[0]["jvmcpu"] >= events[-1]["jvmcpu"]: errs.append("jvmcpu did not advance between samples")
for m in errs: print("  BAD:", m)
print("values: hostcpu=%s%% hostmem=%s%% hostdisk=%s jvmcpu=%sns jvmmem=%sB jvmtnum=%s" % (
    e.get("hostcpu"), e.get("hostmem"), e.get("hostdisk"), e.get("jvmcpu"), e.get("jvmmem"), e.get("jvmtnum")))
sys.exit(1 if errs else 0)
PY
fi
if grep -qi 'sigar' "$JETTY_LOG" "$JETTY_BASE"/logs/* 2>/dev/null; then
  fail "sigar mentioned in the Jetty logs"; grep -i sigar "$JETTY_LOG" | head -5
fi
if grep -E 'UnsatisfiedLinkError|NoClassDefFoundError|IllegalAccessError|InaccessibleObjectException|Unrecognized VM option|Could not create the Java Virtual Machine' "$JETTY_LOG" 2>/dev/null | head -5 | grep -q .; then
  fail "JDK 21 incompatibility signatures in the Jetty console log:"; grep -E 'UnsatisfiedLinkError|NoClassDefFoundError|IllegalAccessError|InaccessibleObjectException|Unrecognized VM option|Could not create' "$JETTY_LOG" | head -5
fi

[[ $FAILED -eq 0 ]] || exit 1
exit 0
