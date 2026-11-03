#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared helpers for container-image-mirror. This file is sourced by the other
# scripts and is never executed on its own.

set -euo pipefail

ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
IMAGES_DIR="${IMAGES_DIR:-${ROOT_DIR}/images}"
CONFIG_DIR="${CONFIG_DIR:-${ROOT_DIR}/config}"
RESULTS_DIR="${RESULTS_DIR:-${ROOT_DIR}/.results}"
POLICY_FILE="${POLICY_FILE:-${CONFIG_DIR}/policies.yaml}"
REGISTRY_FILE="${REGISTRY_FILE:-${CONFIG_DIR}/registries.yaml}"

# Consumed by validate.sh; shellcheck analyses each file in isolation.
# shellcheck disable=SC2034
MIRROR_API_VERSION="mirror.suanova.io/v1alpha1"

if [[ -t 2 ]]; then
  C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_BLUE=$'\033[34m' C_RESET=$'\033[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_RESET=''
fi

info() { printf '%s[info]%s  %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
ok() { printf '%s[ ok ]%s  %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '%s[warn]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() {
  error "$*"
  exit 1
}

require_cmd() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

# Linux has sha256sum, macOS ships shasum, and openssl is everywhere else.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 -r | cut -d' ' -f1
  else
    die "no sha256 tool available (need sha256sum, shasum or openssl)"
  fi
}

# policy <yq-expression> [default]
policy() {
  local expr=$1 default=${2-} value
  value=$(yq -r "(${expr}) // \"\"" "$POLICY_FILE" 2>/dev/null || true)
  if [[ -n $value ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$default"
  fi
}

strip_scheme() {
  local ref=${1#docker://}
  printf '%s' "${ref#oci://}"
}

# host_of <ref> — DOCKER-IO is not treated as a default; manifests must spell
# out the registry so provenance is unambiguous.
host_of() {
  local ref first
  ref=$(strip_scheme "$1")
  first=${ref%%/*}
  if [[ $first == *.* || $first == *:* || $first == localhost ]]; then
    printf '%s' "$first"
  else
    printf 'docker.io'
  fi
}

registry_json() {
  local host=$1
  host=$host yq -o=json -I=0 '
    [ (.spec.sources // [])[], (.spec.destinations // [])[] ]
    | map(select(.host == env(host)))
    | .[0] // {}
  ' "$REGISTRY_FILE"
}

tls_verify_for() {
  registry_json "$1" | jq -r 'if .tlsVerify == null then "true" else (.tlsVerify | tostring) end'
}

destination_project_for() {
  registry_json "$1" | jq -r '.project // ""'
}

is_destination() {
  registry_json "$1" | jq -e '(.project // "") != ""' >/dev/null 2>&1
}

is_known_source() {
  registry_json "$1" | jq -e '(.auth // "") != ""' >/dev/null 2>&1
}

AUTHFILE=""

# Builds one authfile containing every configured host, from the JSON blob in
# MIRROR_CREDENTIALS_JSON. A single file keeps skopeo invocation simple and
# avoids needing --src-authfile/--dest-authfile (added in later skopeo builds).
prepare_authfile() {
  local raw=${MIRROR_CREDENTIALS_JSON:-} dir
  dir=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
  AUTHFILE="${dir}/mirror-auth-$$.json"

  if [[ -z $raw ]]; then
    printf '{"auths":{}}\n' >"$AUTHFILE"
  else
    printf '%s' "$raw" | jq -e . >/dev/null 2>&1 ||
      die "MIRROR_CREDENTIALS_JSON is not valid JSON"
    printf '%s' "$raw" | jq -c '
      (if has("auths") then .auths else . end) as $m
      | {
          auths: ($m | to_entries | map(
            . as $e
            | {
                key: $e.key,
                value: (
                  if $e.value.auth then { auth: $e.value.auth }
                  elif ($e.value.username and $e.value.password) then
                    { auth: (($e.value.username + ":" + $e.value.password) | @base64) }
                  else
                    error("credentials for \($e.key) need auth or username+password")
                  end
                )
              }
          ) | from_entries)
        }
    ' >"$AUTHFILE" || die "failed to build authfile from MIRROR_CREDENTIALS_JSON"
  fi
  chmod 600 "$AUTHFILE"
}

cleanup_authfile() {
  if [[ -n ${AUTHFILE:-} && -f $AUTHFILE ]]; then
    rm -f "$AUTHFILE"
  fi
}

skopeo_inspect_raw() {
  local ref
  ref=$(strip_scheme "$1")
  local -a args=(inspect --raw --authfile "$AUTHFILE")
  if [[ $(tls_verify_for "$(host_of "$ref")") == "false" ]]; then
    args+=(--tls-verify=false)
  fi
  skopeo "${args[@]}" "docker://$ref"
}

# Digest of the manifest as served by the registry (sha256 of the raw bytes).
# Deliberately not `skopeo inspect --format {{.Digest}}`: hashing the raw
# manifest is independent of how skopeo resolves manifest lists.
manifest_digest() {
  skopeo_inspect_raw "$1" 2>/dev/null | sha256_stdin | sed 's/^/sha256:/'
}

# Prints one "os/arch[/variant]" per available platform.
manifest_platforms() {
  local ref raw
  ref=$(strip_scheme "$1")
  if raw=$(skopeo_inspect_raw "$ref" 2>/dev/null) &&
    [[ $(jq -r '.manifests | length' <<<"$raw" 2>/dev/null || echo 0) -gt 0 ]]; then
    jq -r '.manifests[].platform | "\(.os)/\(.architecture)" + (if .variant then "/" + .variant else "" end)' \
      <<<"$raw" | sort -u
    return 0
  fi

  local -a args=(inspect --authfile "$AUTHFILE")
  if [[ $(tls_verify_for "$(host_of "$ref")") == "false" ]]; then
    args+=(--tls-verify=false)
  fi
  skopeo "${args[@]}" --format '{{.Os}}/{{.Architecture}}{{if .Variant}}/{{.Variant}}{{end}}' \
    "docker://$ref" 2>/dev/null
}

# assert_platforms <ref> <platform>...
#
# A declared platform without a variant (e.g. linux/arm64) matches any variant
# of that os/arch, because registries commonly publish linux/arm64/v8. A
# declared variant must match exactly.
assert_platforms() {
  local ref=$1
  shift
  (($#)) || return 0

  local available missing=() p available_platform match
  available=$(manifest_platforms "$ref") || {
    warn "cannot determine platforms for $ref"
    return 1
  }
  for p in "$@"; do
    match=0
    while IFS= read -r available_platform; do
      if [[ -z $available_platform ]]; then
        continue
      fi
      if [[ $p == */*/* ]]; then
        if [[ $available_platform == "$p" ]]; then
          match=1
          break
        fi
      else
        if [[ $available_platform == "$p" || $available_platform == "$p"/* ]]; then
          match=1
          break
        fi
      fi
    done <<<"$available"

    if ((match == 0)); then
      missing+=("$p")
    fi
  done

  if ((${#missing[@]})); then
    warn "missing platform(s) for $ref: ${missing[*]}"
    warn "available: $(tr '\n' ' ' <<<"$available")"
    return 1
  fi
}

skopeo_copy() {
  local src dst
  src=$(strip_scheme "$1")
  dst=$(strip_scheme "$2")
  local -a args=(copy --all --authfile "$AUTHFILE" --retry-times "$(policy '.spec.copy.retryTimes' 5)")
  if [[ $(tls_verify_for "$(host_of "$src")") == "false" ]]; then
    args+=(--src-tls-verify=false)
  fi
  if [[ $(tls_verify_for "$(host_of "$dst")") == "false" ]]; then
    args+=(--dest-tls-verify=false)
  fi
  skopeo "${args[@]}" "docker://$src" "docker://$dst"
}

retry() {
  local max delay attempt=1
  max=$(policy '.spec.copy.retryTimes' 5)
  delay=$(policy '.spec.copy.retryDelaySeconds' 10)

  until "$@"; do
    if ((attempt >= max)); then
      error "giving up after $max attempt(s): $*"
      return 1
    fi
    warn "attempt $attempt/$max failed, retrying in ${delay}s: $*"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    ((delay > 60)) && delay=60
  done
}

# record_result <file> key=value...
record_result() {
  local file=$1
  shift
  local json='{}' kv
  for kv in "$@"; do
    json=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '.[$k] = $v' <<<"$json")
  done
  printf '%s\n' "$(jq -c '. + {timestamp: (now | todate)}' <<<"$json")" >>"$file"
}

# Prints "category<TAB>json-document" for every manifest file selected.
select_manifest_files() {
  local category=${1:-all} f
  local -a files=()
  shopt -s nullglob
  if [[ $category == all ]]; then
    files=("$IMAGES_DIR"/*.yaml)
  else
    files=("$IMAGES_DIR/${category}.yaml")
  fi
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    die "unknown category '${category}' (no manifest matched)"
  fi

  for f in "${files[@]}"; do
    [[ -f $f ]] || die "unknown category '${category}' (no such file: $f)"
    printf '%s\t%s\n' "$(basename "$f" .yaml)" "$(yq -o=json -I=0 '.' "$f")"
  done
}
