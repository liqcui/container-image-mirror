#!/usr/bin/env bash
#
# Static validation of images/*.yaml, config/registries.yaml and
# config/policies.yaml. Runs without any registry credentials and without
# network access, so it is safe on pull requests.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd yq jq

[[ -f $POLICY_FILE ]] || die "policy file not found: $POLICY_FILE"
[[ -f $REGISTRY_FILE ]] || die "registry file not found: $REGISTRY_FILE"

destinations=$(yq -o=json -I=0 '[.spec.destinations[]? | {"host": .host, "project": .project}]' "$REGISTRY_FILE")
sources=$(yq -o=json -I=0 '[.spec.sources[]?.host]' "$REGISTRY_FILE")
default_platforms=$(yq -o=json -I=0 '.spec.manifest.defaultPlatforms // []' "$POLICY_FILE")
allow_latest=$(policy '.spec.manifest.allowLatest' false)
require_host=$(policy '.spec.manifest.requireSourceHostInTarget' true)

violations=()

# --- config files ---------------------------------------------------------

[[ $(yq -r '.apiVersion // ""' "$REGISTRY_FILE") == "$MIRROR_API_VERSION" ]] ||
  violations+=("config/registries.yaml: apiVersion must be ${MIRROR_API_VERSION}")
[[ $(yq -r '.kind // ""' "$REGISTRY_FILE") == "RegistryList" ]] ||
  violations+=("config/registries.yaml: kind must be RegistryList")
[[ $(yq -r '.apiVersion // ""' "$POLICY_FILE") == "$MIRROR_API_VERSION" ]] ||
  violations+=("config/policies.yaml: apiVersion must be ${MIRROR_API_VERSION}")
[[ $(yq -r '.kind // ""' "$POLICY_FILE") == "MirrorPolicy" ]] ||
  violations+=("config/policies.yaml: kind must be MirrorPolicy")

if [[ $(jq 'length' <<<"$destinations") -eq 0 ]]; then
  violations+=("config/registries.yaml: at least one destination is required")
fi

while IFS= read -r host; do
  [[ -n $host ]] || continue
  if [[ $(registry_json "$host" | jq -r '.auth // ""') != "credentials" ]]; then
    violations+=("config/registries.yaml: destination ${host} must use auth: credentials")
  fi
done <<<"$(jq -r '.[].host' <<<"$destinations")"

# --- manifests ------------------------------------------------------------

manifest_lines=$(select_manifest_files all) || die "failed to load manifests from ${IMAGES_DIR}"
manifest_count=0
source_refs=''
target_refs=''

while IFS=$'\t' read -r category doc; do
  [[ -n $category ]] || continue
  manifest_count=$((manifest_count + 1))
  file="${category}.yaml"

  if ! out=$(jq -r -f "${SCRIPT_DIR}/validate.jq" \
    --arg file "$file" \
    --arg api "$MIRROR_API_VERSION" \
    --argjson destinations "$destinations" \
    --argjson sources "$sources" \
    --argjson defaultPlatforms "$default_platforms" \
    --arg allowLatest "$allow_latest" \
    --arg requireHost "$require_host" <<<"$doc"); then
    violations+=("${file}: validation program failed, the document could not be parsed")
    continue
  fi

  while IFS= read -r line; do
    if [[ -n $line ]]; then
      violations+=("$line")
    fi
  done <<<"$out"

  source_refs+=$(jq -r '.spec.images[]? | .source as $s | .versions[]? | "\($s):\(.tag)"' <<<"$doc")$'\n'
  target_refs+=$(jq -r '.spec.images[]? | .target as $t | .versions[]? | "\($t):\(.tag)"' <<<"$doc")$'\n'
done <<<"$manifest_lines"

[[ $manifest_count -gt 0 ]] || die "no manifest files found in ${IMAGES_DIR}"

# A tag may legitimately appear under several repositories, but the exact same
# source:tag or target:tag twice means someone will copy it twice.
while IFS= read -r dup; do
  if [[ -n $dup ]]; then
    violations+=("duplicate source reference across manifests: ${dup}")
  fi
done < <(printf '%s' "$source_refs" | sort | uniq -d)

while IFS= read -r dup; do
  if [[ -n $dup ]]; then
    violations+=("duplicate target reference across manifests: ${dup}")
  fi
done < <(printf '%s' "$target_refs" | sort | uniq -d)

# --- result ---------------------------------------------------------------

if ((${#violations[@]})); then
  for v in "${violations[@]}"; do
    error "$v"
  done
  printf '\n%d problem(s) found in %d manifest file(s)\n' "${#violations[@]}" "$manifest_count" >&2
  exit 1
fi

ok "validated ${manifest_count} manifest file(s)"
