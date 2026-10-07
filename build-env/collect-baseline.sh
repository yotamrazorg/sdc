#!/usr/bin/env bash
# =============================================================================
# collect-baseline.sh - run the unit tests of one repo (or all five baseline repos)
# and write machine-readable per-module results.
#
# Usage:
#   build-env/collect-baseline.sh [options] <repo|all> [<repo> ...]
#
#   repos: sdc so aai-resources aai-traversal policy-api   ("all" = these five)
#
# Options:
#   --jdk 17|21          JDK to run on (default: ${JAVA_VERSION_SELECT:-17}; the pre-change
#                        baseline was recorded on 17)
#   --workspace DIR      directory holding the repo checkouts
#                        (default: parent directory of the sdc checkout containing this script,
#                        override with MCODE_WORKSPACE)
#   --log-dir DIR        Maven console logs + per-repo JSON go here
#                        (default: ${MCODE_BASELINE_LOGS:-<workspace>/../mcode/baseline-logs} -
#                        always OUTSIDE the repos)
#   --out FILE           aggregate JSON to create/update (default: build-env/test-baseline.json)
#   --no-aggregate       only write per-repo JSON into the log dir
#   --parse-only         do not run Maven, only (re)parse existing target/ reports and logs
#   -h|--help
#
# Environment:
#   MVN_THREADS          pass -T<value> to Maven (sdc defaults to its .mvn/maven.config -T2)
#   MVN_EXTRA_ARGS       extra Maven arguments appended to every invocation
#   MVN_FORK_TIMEOUT     seconds after which a hung surefire/failsafe fork is killed
#                        (-Dsurefire.timeout, command line only; default 2400)
#   MVN_STEP_TIMEOUT     seconds after which a whole Maven invocation is killed
#                        (coreutils `timeout`; default 14400)
#   MCODE_BUILD_CACHE    toolchain cache (see bootstrap-java21.sh)
#
# Test classes that hang / cannot run in the sandbox are listed in baseline-exclusions.json,
# excluded through a generated -Dsurefire.excludesFile (never by editing poms) and recorded in
# the JSON as environment_exclusions. A fork killed by the fork timeout is recorded as
# fork_timeouts and makes the repo status "partial".
#
# Maven is always run with --fail-at-end and -Dmaven.test.failure.ignore=true so that every
# module is attempted and all reports are kept. The tree is `clean`ed first so no stale
# report can leak into the counts. Only surefire/failsafe *unit* test results are recorded;
# the failsafe integration tests of sdc need Docker/Testcontainers and are excluded.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDC_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACE="${MCODE_WORKSPACE:-$(cd "$SDC_ROOT/.." && pwd)}"
JDK_SEL="${JAVA_VERSION_SELECT:-17}"
OUT="$HERE/test-baseline.json"
AGGREGATE=1
RUN_MAVEN=1
LOG_DIR=""
REPOS=()

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jdk) JDK_SEL="$2"; shift 2 ;;
    --workspace) WORKSPACE="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --no-aggregate) AGGREGATE=0; shift ;;
    --parse-only) RUN_MAVEN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    all) REPOS+=(sdc so aai-resources aai-traversal policy-api); shift ;;
    sdc|so|aai-resources|aai-traversal|policy-api) REPOS+=("$1"); shift ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ ${#REPOS[@]} -gt 0 ]] || { usage >&2; exit 2; }
LOG_DIR="${LOG_DIR:-${MCODE_BASELINE_LOGS:-$WORKSPACE/../mcode/baseline-logs}}"
mkdir -p "$LOG_DIR"
LOG_DIR="$(cd "$LOG_DIR" && pwd)"

# ---- toolchain ---------------------------------------------------------------
export JAVA_VERSION_SELECT="$JDK_SEL"
export MCODE_BOOTSTRAP_QUIET=1
# shellcheck source=bootstrap-java21.sh
source "$HERE/bootstrap-java21.sh" || exit 1
JDK_VERSION="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
MVN_VERSION="$(mvn -v | head -1 | sed -E 's/^Apache Maven ([^ ]+).*/\1/')"
echo "[collect-baseline] JDK $JDK_VERSION (select $JDK_SEL), Maven $MVN_VERSION, logs in $LOG_DIR" >&2

FORK_TIMEOUT="${MVN_FORK_TIMEOUT:-2400}"
STEP_TIMEOUT="${MVN_STEP_TIMEOUT:-14400}"
EXCLUSIONS_JSON="$HERE/baseline-exclusions.json"
COMMON_ARGS=(-B -ntp -fae -Dmaven.test.failure.ignore=true -Dstyle.color=never
             "-Dsurefire.timeout=$FORK_TIMEOUT")
[[ -n "${MVN_THREADS:-}" ]] && COMMON_ARGS+=("-T${MVN_THREADS}")
# shellcheck disable=SC2206
[[ -n "${MVN_EXTRA_ARGS:-}" ]] && COMMON_ARGS+=(${MVN_EXTRA_ARGS})

# step_args <repo> -> prints one Maven step per line:  <subdir-relative -f arg or .>|<args...>
# Each step is "<label>|<maven args>" and runs from the repo root.
repo_steps() {
  case "$1" in
    sdc)
      # fast-build-no-ui = every Java backend module (openecomp-be, common, catalog-be, asdctool,
      # webseal-simulator, ...) without catalog-ui/openecomp-ui/dox/cucumber UI modules and
      # without catalog-fe. '!skip-integration-tests' / -DskipITs: the failsafe ITs need Docker.
      # catalog-fe is not part of any UI-free profile and is built standalone afterwards.
      echo "reactor|-Pfast-build-no-ui,!skip-integration-tests -DskipITs=true clean install"
      echo "catalog-fe|-f catalog-fe/pom.xml clean install"
      ;;
    so)            echo "reactor|clean install" ;;
    aai-resources) echo "reactor|clean install" ;;
    aai-traversal) echo "reactor|clean install" ;;
    policy-api)    echo "reactor|clean install" ;;
  esac
}

# write_excludes <repo> <file>: surefire excludesFile (one **/Class.java per line); returns 1 if none
write_excludes() {
  python3 - "$EXCLUSIONS_JSON" "$1" "$2" <<'PY'
import json, sys
path, repo, out = sys.argv[1:4]
try:
    entries = [e for e in json.load(open(path)).get("exclusions", []) if e.get("repo") == repo]
except OSError:
    entries = []
classes = sorted({c.rsplit(".", 1)[-1] for e in entries for c in e.get("test_classes", [])})
if not classes:
    sys.exit(1)
open(out, "w").write("".join(f"**/{c}.java\n" for c in classes))
PY
}

run_repo() {
  local repo="$1" dir="$WORKSPACE/$1" step label margs rc
  local logs=() cmds=() rcs=()
  [[ -d "$dir" ]] || { echo "[collect-baseline] $dir not found" >&2; return 1; }
  local json="$LOG_DIR/$repo-baseline.json"
  local excl="$LOG_DIR/$repo-surefire-excludes.txt" xargs_=() xshown=""
  if write_excludes "$repo" "$excl"; then
    xargs_=("-Dsurefire.excludesFile=$excl")
    xshown=" -Dsurefire.excludesFile=<log-dir>/$repo-surefire-excludes.txt"
  else
    rm -f "$excl"
  fi

  if [[ "$RUN_MAVEN" == 1 ]]; then
    while IFS= read -r step; do
      label="${step%%|*}"; margs="${step#*|}"
      local log="$LOG_DIR/$repo-$label.log"
      echo "[collect-baseline] $repo/$label: mvn ${COMMON_ARGS[*]}$xshown $margs" >&2
      # shellcheck disable=SC2086
      ( cd "$dir" && timeout --kill-after=60 "$STEP_TIMEOUT" mvn "${COMMON_ARGS[@]}" "${xargs_[@]+"${xargs_[@]}"}" $margs ) > "$log" 2>&1
      rc=$?
      echo "[collect-baseline] $repo/$label exit code $rc" >&2
      logs+=("$log"); cmds+=("mvn ${COMMON_ARGS[*]}$xshown $margs"); rcs+=("$rc")
    done < <(repo_steps "$repo")
  else
    while IFS= read -r step; do
      label="${step%%|*}"; logs+=("$LOG_DIR/$repo-$label.log")
    done < <(repo_steps "$repo")
    # keep the commands / exit codes recorded by the earlier real run (e.g. when only the notes changed)
    if [[ -f "$json" ]]; then
      while IFS=$'\t' read -r kind val; do
        if [[ "$kind" == cmd ]]; then cmds+=("$val"); else rcs+=("$val"); fi
      done < <(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for c in d.get("commands",[]): print("cmd\t"+c)
for c in d.get("build_exit_codes",[]): print("rc\t"+str(c))' "$json")
    fi
  fi

  local pargs=(repo --repo "$repo" --root "$dir" --out "$json" --exclusions "$EXCLUSIONS_JSON"
               --jdk-version "$JDK_VERSION" --jdk-select "$JDK_SEL" --maven-version "$MVN_VERSION")
  local l c r
  for l in "${logs[@]}"; do pargs+=(--reactor-log "$l"); done
  for c in "${cmds[@]+"${cmds[@]}"}"; do pargs+=(--command "$c"); done
  for r in "${rcs[@]+"${rcs[@]}"}"; do pargs+=(--exit-code "$r"); done
  # an earlier attempt on JDK 17 that could not build (see --jdk 21 re-run of the same repo)
  if [[ "$JDK_SEL" != 17 && -f "$LOG_DIR/$repo-jdk17-baseline.json" ]]; then
    pargs+=(--prior-attempt "$LOG_DIR/$repo-jdk17-baseline.json")
  fi
  if [[ -f "$LOG_DIR/$repo.notes" ]]; then
    while IFS= read -r l; do [[ -n "$l" ]] && pargs+=(--note "$l"); done < "$LOG_DIR/$repo.notes"
  fi
  python3 "$HERE/parse_surefire.py" "${pargs[@]}"
}

rc_all=0
for repo in "${REPOS[@]}"; do
  run_repo "$repo" || rc_all=1
done

if [[ "$AGGREGATE" == 1 ]]; then
  inputs=()
  for repo in "${REPOS[@]}"; do inputs+=("$LOG_DIR/$repo-baseline.json"); done
  python3 "$HERE/parse_surefire.py" merge --update --out "$OUT" "${inputs[@]}" && \
    echo "[collect-baseline] wrote $OUT" >&2
fi
exit $rc_all
