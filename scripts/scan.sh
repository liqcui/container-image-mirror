#!/usr/bin/env bash
#
# Scan mirrored images with Trivy and emit a CycloneDX SBOM for each one.
#
#   scan.sh <ref> [<ref>...]     # scan specific references
#   scan.sh --all                # scan every target declared in images/*.yaml
#   scan.sh --category networking
#
# Scanning happens on the digest that was actually pushed, not on the tag, so a
# later tag move cannot make the report describe different bytes.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

OUT_DIR="${MIRROR_SCAN_DIR:-${RESULTS_DIR}/scan}"
SCAN_ALL=false
CATEGORY=all
REFS=()
failures=0

usage() {
  cat <<'EOF'
Usage: scan.sh [--all | --category NAME] [REF...]

  --all             scan every target declared in images/*.yaml
  --category NAME   restrict --all to one manifest file
  -h, --help        show this help
EOF
}

while (($#)); do
  case $1 in
    --all) SCAN_ALL=true; shift ;;
    --category) CATEGORY=${2:?--category needs a value}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *) REFS+=("$1"); shift ;;
  esac
done

require_cmd trivy jq
mkdir -p "$OUT_DIR"

scanners=$(policy '.spec.scan.scanners | join(",")' vuln)
severities=$(policy '.spec.scan.severities | join(",")' 'HIGH,CRITICAL')
ignore_unfixed=$(policy '.spec.scan.ignoreUnfixed' true)
sbom_enabled=$(policy '.spec.scan.sbom' true)
sbom_format=$(policy '.spec.scan.sbomFormat' cyclonedx)
fail_on_findings=$(policy '.spec.scan.failOnFindings' false)

scan_one() {
  local ref=$1 slug json sbom critical high
  slug=$(printf '%s' "$ref" | sed -e 's|^docker://||' -e 's|[/:@]|_|g')
  json="${OUT_DIR}/${slug}.trivy.json"

  local -a args=(image --quiet --format json --output "$json" --scanners "$scanners" --severity "$severities")
  if [[ $ignore_unfixed == true ]]; then
    args+=(--ignore-unfixed)
  fi

  info "scanning ${ref}"
  if ! trivy "${args[@]}" "$ref"; then
    error "trivy scan failed for ${ref}"
    return 1
  fi

  critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$json")
  high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "$json")

  if [[ $sbom_enabled == true ]]; then
    sbom="${OUT_DIR}/${slug}.sbom.${sbom_format}.json"
    if ! trivy image --quiet --format "$sbom_format" --output "$sbom" "$ref"; then
      warn "SBOM generation failed for ${ref}"
    fi
  fi

  if ((critical > 0 || high > 0)); then
    warn "${ref}: ${critical} critical, ${high} high"
  else
    ok "${ref}: no ${severities} findings"
  fi

  if [[ $fail_on_findings == true ]] && ((critical + high > 0)); then
    error "${ref}: failing because scan.failOnFindings is true"
    return 1
  fi
  return 0
}

if [[ $SCAN_ALL == true ]]; then
  require_cmd skopeo yq
  prepare_authfile
  trap cleanup_authfile EXIT

  manifest_lines=$(select_manifest_files "$CATEGORY") || die "failed to load manifests"
  while IFS=$'\t' read -r category doc; do
    [[ -n $category ]] || continue
    image_count=$(jq '.spec.images | length' <<<"$doc")
    for ((i = 0; i < image_count; i++)); do
      target=$(jq -r --argjson i "$i" '.spec.images[$i].target' <<<"$doc")
      name=$(jq -r --argjson i "$i" '.spec.images[$i].name' <<<"$doc")
      version_count=$(jq --argjson i "$i" '.spec.images[$i].versions | length' <<<"$doc")
      for ((k = 0; k < version_count; k++)); do
        tag=$(jq -r --argjson i "$i" --argjson k "$k" '.spec.images[$i].versions[$k].tag' <<<"$doc")
        tref="${target}:${tag}"
        if digest=$(manifest_digest "$tref"); then
          scan_one "${tref}@${digest}" || failures=$((failures + 1))
        else
          error "${name}:${tag}: target not found in the registry (${tref})"
          failures=$((failures + 1))
        fi
      done
    done
  done <<<"$manifest_lines"
else
  ((${#REFS[@]} > 0)) || {
    usage
    die "no references given"
  }
  for ref in "${REFS[@]}"; do
    scan_one "$ref" || failures=$((failures + 1))
  done
fi

if ((failures > 0)); then
  error "${failures} image(s) failed to scan"
  exit 1
fi

ok "scanned all requested images; reports in ${OUT_DIR}"
