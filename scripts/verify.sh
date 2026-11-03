#!/usr/bin/env bash
#
# Verify the signature of a source image with cosign before it is mirrored.
# Configured per image in images/*.yaml:
#
#   signature:
#     verify: true
#     key: https://example.com/cosign.pub
#     # or keyless:
#     keyless:
#       issuer: https://token.actions.githubusercontent.com
#       subjectRegExp: https://github.com/org/repo/.+
#
# Material is passed in by sync.sh through MIRROR_VERIFY_* variables.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

ref=${1:-}
[[ -n $ref ]] || die "usage: verify.sh <image-ref>"
require_cmd cosign yq

on_missing=$(policy '.spec.signature.onMissing' warn)

run_verify() {
  if ! "$@"; then
    if [[ $on_missing == "fail" ]]; then
      error "signature verification failed for ${ref}"
      return 1
    fi
    warn "signature verification failed for ${ref} (signature.onMissing: warn)"
    return 0
  fi
  ok "signature verified: ${ref}"
}

if [[ -n ${MIRROR_VERIFY_KEY:-} ]]; then
  info "cosign verify --key for ${ref}"
  run_verify cosign verify --key "$MIRROR_VERIFY_KEY" "$ref"
elif [[ -n ${MIRROR_VERIFY_SUBJECT_REGEXP:-} ]]; then
  issuer=${MIRROR_VERIFY_ISSUER:-https://token.actions.githubusercontent.com}
  info "cosign verify keyless for ${ref} (issuer ${issuer})"
  run_verify cosign verify \
    --certificate-identity-regexp "$MIRROR_VERIFY_SUBJECT_REGEXP" \
    --certificate-oidc-issuer "$issuer" \
    "$ref"
else
  die "signature.verify is set for ${ref} but neither signature.key nor signature.keyless is configured"
fi
