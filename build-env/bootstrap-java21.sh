#!/usr/bin/env bash
# =============================================================================
# bootstrap-java21.sh - provision and select the build toolchain for the ONAP
# Java 21 modernization (sdc, so, aai-resources, aai-traversal, policy-api,
# oom, integration).
#
#   * Temurin JDK 21 (pinned release, SHA-256 verified)
#   * Apache Maven 3.9.x (pinned release, SHA-512 verified)
#   * both are unpacked into a cache directory and re-used on later runs
#   * JAVA_HOME / MAVEN_HOME / PATH / MAVEN_ARGS are exported
#
# Usage
#   source sdc/build-env/bootstrap-java21.sh        # preferred: affects the caller shell
#   sdc/build-env/bootstrap-java21.sh               # provision only, print versions
#   eval "$(sdc/build-env/bootstrap-java21.sh --print-env)"   # executed, export into caller
#
# Environment knobs
#   JAVA_VERSION_SELECT   21 (default) or 17. 17 selects the *system* JDK 17
#                         (needed for the pre-change baseline); Maven is still
#                         provisioned. JAVA17_HOME overrides JDK 17 discovery.
#   MCODE_BUILD_CACHE     cache dir (default: $HOME/.cache/onap-java21-toolchain)
#   MCODE_MAVEN_SETTINGS  settings.xml passed to Maven via MAVEN_ARGS
#                         (default: <this dir>/settings.xml; set to "none" to
#                         not inject any settings file)
#   MCODE_BOOTSTRAP_QUIET 1 = do not print the version summary
#
# No absolute paths are hard-coded: everything is derived from the location of
# this script or from environment variables.
# =============================================================================

# ---- pinned versions --------------------------------------------------------
_MC_TEMURIN_TAG='jdk-21.0.12.1+1'              # Adoptium release tag
_MC_TEMURIN_FILE_VERSION='21.0.12.1_1'         # as used in the tarball name
_MC_TEMURIN_SHA256_X64='ce79869e1307ed8ee1e2baa86a412b1eb5b75d10a01006d788a6f968bcfaee94'
_MC_TEMURIN_SHA256_AARCH64='23e37e026f12f3e706f18938ff611db3032d075b09d0879a25d06718c773e223'

_MC_MAVEN_VERSION='3.9.11'
_MC_MAVEN_SHA512='bcfe4fe305c962ace56ac7b5fc7a08b87d5abd8b7e89027ab251069faebee516b0ded8961445d6d91ec1985dfe30f8153268843c89aa392733d1a3ec956c9978'

# ---- sourced vs executed ----------------------------------------------------
_MC_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
if [[ "${BASH_SOURCE[0]:-$0}" != "$0" ]]; then
  _MC_SOURCED=1
else
  _MC_SOURCED=0
  set -euo pipefail
fi
_MC_DIR="$(cd "$(dirname "$_MC_SCRIPT_PATH")" && pwd)"

_mc_log() { printf '[bootstrap-java21] %s\n' "$*" >&2; }
_mc_err() { printf '[bootstrap-java21] ERROR: %s\n' "$*" >&2; }

# Everything lives in functions that `return` (never `exit`) so that sourcing
# this file cannot terminate the caller's shell.

_mc_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo x64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) _mc_err "unsupported architecture: $(uname -m)"; return 1 ;;
  esac
}

_mc_fetch() { # url dest
  curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 30 -o "$2" "$1"
}

_mc_sha() { # algo(256|512) file
  "sha${1}sum" "$2" | awk '{print $1}'
}

# $1 = tarball, $2 = expected sha, $3 = algo
_mc_verify() {
  local got
  got="$(_mc_sha "$3" "$1")"
  if [[ "$got" != "$2" ]]; then
    _mc_err "SHA-$3 mismatch for $(basename "$1"): expected $2, got $got"
    return 1
  fi
}

# $1 = target dir (final), $2 = tarball
_mc_extract() {
  local target="$1" tarball="$2" tmp
  tmp="$(mktemp -d "${target}.tmp.XXXXXX")" || return 1
  tar -xzf "$tarball" -C "$tmp" --strip-components=1 || { rm -rf "$tmp"; return 1; }
  if [[ -d "$target" ]]; then rm -rf "$tmp"; return 0; fi  # concurrent winner
  mv "$tmp" "$target"
}

_mc_provision_jdk21() {
  local arch sha file dir tarball url_gh url_api tagenc
  arch="$(_mc_arch)" || return 1
  file="OpenJDK21U-jdk_${arch}_linux_hotspot_${_MC_TEMURIN_FILE_VERSION}.tar.gz"
  dir="$MCODE_BUILD_CACHE/temurin-${_MC_TEMURIN_TAG//+/_}-${arch}"
  if [[ -x "$dir/bin/java" ]]; then
    MC_JDK21_HOME="$dir"; return 0
  fi
  if [[ "$arch" == x64 ]]; then sha="$_MC_TEMURIN_SHA256_X64"; else sha="$_MC_TEMURIN_SHA256_AARCH64"; fi
  tagenc="${_MC_TEMURIN_TAG//+/%2B}"
  url_gh="https://github.com/adoptium/temurin21-binaries/releases/download/${tagenc}/${file}"
  url_api="https://api.adoptium.net/v3/binary/version/${tagenc}/linux/${arch}/jdk/hotspot/normal/eclipse"
  tarball="$MCODE_BUILD_CACHE/downloads/${file}"
  mkdir -p "$MCODE_BUILD_CACHE/downloads"
  if [[ ! -f "$tarball" ]] || ! _mc_verify "$tarball" "$sha" 256 2>/dev/null; then
    rm -f "$tarball"
    _mc_log "downloading Temurin ${_MC_TEMURIN_TAG} (${arch})"
    if ! _mc_fetch "$url_api" "$tarball.part" 2>/dev/null; then
      _mc_log "Adoptium API download failed, falling back to GitHub release"
      _mc_fetch "$url_gh" "$tarball.part" || { rm -f "$tarball.part"; _mc_err "cannot download Temurin 21"; return 1; }
    fi
    if ! _mc_verify "$tarball.part" "$sha" 256; then rm -f "$tarball.part"; return 1; fi
    mv "$tarball.part" "$tarball"
  fi
  _mc_extract "$dir" "$tarball" || return 1
  MC_JDK21_HOME="$dir"
}

_mc_provision_maven() {
  local dir tarball file u
  dir="$MCODE_BUILD_CACHE/apache-maven-${_MC_MAVEN_VERSION}"
  if [[ -x "$dir/bin/mvn" ]]; then MAVEN_HOME="$dir"; return 0; fi
  file="apache-maven-${_MC_MAVEN_VERSION}-bin.tar.gz"
  tarball="$MCODE_BUILD_CACHE/downloads/${file}"
  mkdir -p "$MCODE_BUILD_CACHE/downloads"
  if [[ ! -f "$tarball" ]] || ! _mc_verify "$tarball" "$_MC_MAVEN_SHA512" 512 2>/dev/null; then
    rm -f "$tarball"
    _mc_log "downloading Apache Maven ${_MC_MAVEN_VERSION}"
    for u in \
      "https://archive.apache.org/dist/maven/maven-3/${_MC_MAVEN_VERSION}/binaries/${file}" \
      "https://dlcdn.apache.org/maven/maven-3/${_MC_MAVEN_VERSION}/binaries/${file}" \
      "https://repo1.maven.org/maven2/org/apache/maven/apache-maven/${_MC_MAVEN_VERSION}/apache-maven-${_MC_MAVEN_VERSION}-bin.tar.gz"; do
      if _mc_fetch "$u" "$tarball.part" 2>/dev/null; then break; fi
    done
    [[ -s "$tarball.part" ]] || { rm -f "$tarball.part"; _mc_err "cannot download Maven ${_MC_MAVEN_VERSION}"; return 1; }
    if ! _mc_verify "$tarball.part" "$_MC_MAVEN_SHA512" 512; then rm -f "$tarball.part"; return 1; fi
    mv "$tarball.part" "$tarball"
  fi
  _mc_extract "$dir" "$tarball" || return 1
  MAVEN_HOME="$dir"
}

# Locate the system JDK 17 (does not download anything).
_mc_find_jdk17() {
  local c j v
  for c in "${JAVA17_HOME:-}" /usr/lib/jvm/java-17-openjdk-amd64 /usr/lib/jvm/java-17-openjdk-arm64 \
           /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/temurin-17-jdk-amd64 /usr/lib/jvm/temurin-17-jdk-arm64; do
    [[ -n "$c" && -x "$c/bin/java" && -x "$c/bin/javac" ]] && { echo "$c"; return 0; }
  done
  # fall back to whatever `java` on PATH is, when it is a 17
  j="$(command -v java 2>/dev/null || true)"
  if [[ -n "$j" ]]; then
    j="$(readlink -f "$j")"; j="${j%/bin/java}"
    v="$("$j/bin/java" -version 2>&1 | head -1)"
    [[ "$v" == *'"17.'* && -x "$j/bin/javac" ]] && { echo "$j"; return 0; }
  fi
  return 1
}

_mc_path_prepend() { # dir
  case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}

_mc_main() {
  MCODE_BUILD_CACHE="${MCODE_BUILD_CACHE:-$HOME/.cache/onap-java21-toolchain}"
  local sel="${JAVA_VERSION_SELECT:-21}" jdk settings
  mkdir -p "$MCODE_BUILD_CACHE" || return 1

  case "$sel" in
    21) _mc_provision_jdk21 || return 1; jdk="$MC_JDK21_HOME" ;;
    17) jdk="$(_mc_find_jdk17)" || { _mc_err "no system JDK 17 found (set JAVA17_HOME)"; return 1; } ;;
    *)  _mc_err "JAVA_VERSION_SELECT must be 21 or 17 (got '$sel')"; return 1 ;;
  esac
  _mc_provision_maven || return 1

  # Drop previously selected toolchain entries so repeated sourcing / switching works.
  local p newpath="" IFS=':'
  for p in $PATH; do
    case "$p" in
      "$MCODE_BUILD_CACHE"/*|"${JAVA_HOME:-/nonexistent}/bin"|"${MAVEN_HOME:-/nonexistent}/bin") ;;
      *) newpath="${newpath:+$newpath:}$p" ;;
    esac
  done
  unset IFS
  PATH="$newpath"

  export JAVA_HOME="$jdk"
  export MAVEN_HOME
  export M2_HOME="$MAVEN_HOME"
  _mc_path_prepend "$MAVEN_HOME/bin"
  _mc_path_prepend "$JAVA_HOME/bin"
  export PATH
  export MCODE_BUILD_CACHE
  export MCODE_JAVA_VERSION_SELECTED="$sel"

  # Public ONAP repositories (oparent, aai-parent and policy parent SNAPSHOTs are
  # not on Maven Central). Injected through MAVEN_ARGS (honoured by Maven >= 3.9).
  settings="${MCODE_MAVEN_SETTINGS:-$_MC_DIR/settings.xml}"
  if [[ "$settings" != none ]]; then
    if [[ -f "$settings" ]]; then
      # do not stack a second -s when re-sourcing or when the caller set its own
      MAVEN_ARGS="${MAVEN_ARGS:-}"
      if [[ " $MAVEN_ARGS " != *" -s "* && " $MAVEN_ARGS " != *" --settings"* ]]; then
        export MAVEN_ARGS="${MAVEN_ARGS:+$MAVEN_ARGS }-s $settings"
      fi
    else
      _mc_err "settings file not found: $settings"
    fi
  fi
  hash -r 2>/dev/null || true

  # Sanity: the selected JDK must really be the requested one.
  local jv
  jv="$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
  if [[ "$jv" != *"\"$sel."* && "$jv" != *"\"$sel\""* ]]; then
    _mc_err "JAVA_HOME=$JAVA_HOME does not report Java $sel: $jv"
    return 1
  fi

  if [[ "${MCODE_BOOTSTRAP_QUIET:-0}" != 1 ]]; then
    {
      echo "=== build toolchain (JAVA_VERSION_SELECT=$sel) ==="
      echo "JAVA_HOME=$JAVA_HOME"
      echo "MAVEN_HOME=$MAVEN_HOME"
      echo "MAVEN_ARGS=${MAVEN_ARGS:-}"
      "$JAVA_HOME/bin/java" -version 2>&1 | sed 's/^/java: /'
      "$MAVEN_HOME/bin/mvn" -v 2>&1 | sed 's/^/mvn:  /'
    } >&2
  fi
}

if [[ "$_MC_SOURCED" == 1 ]]; then
  _mc_main || { _mc_err "toolchain bootstrap failed"; return 1; }
else
  if [[ "${1:-}" == "--print-env" ]]; then
    MCODE_BOOTSTRAP_QUIET=1 _mc_main
    for v in JAVA_HOME MAVEN_HOME M2_HOME PATH MAVEN_ARGS MCODE_BUILD_CACHE MCODE_JAVA_VERSION_SELECTED; do
      printf 'export %s=%q\n' "$v" "${!v:-}"
    done
  else
    _mc_main
    _mc_log "done. In your shell run: source ${_MC_SCRIPT_PATH}"
  fi
fi
