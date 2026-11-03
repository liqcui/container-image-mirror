#!/usr/bin/env bash
#
# Copy every pinned image version declared in images/*.yaml from its upstream
# registry into the destination project, verifying the manifest digest after
# each copy.
#
#   sync.sh                        # every manifest
#   sync.sh --category networking  # one file
#   sync.sh --image nginx          # one image, all of its versions
#   sync.sh --tag 1.31.8           # one tag
#   sync.sh --dry-run              # print the plan, no registry access
#   sync.sh --check-sources        # resolve sources only, never write
#   sync.sh --scan                 # run Trivy after each successful copy

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

CATEGORY=all
IMAGE_FILTER=''
TAG_FILTER=''
DRY_RUN=false
CHECK_SOURCES=false
SCAN=false

usage() {
  cat <<'EOF'
Usage: sync.sh [options]

  --category NAME   sync only images/NAME.yaml (default: all)
  --image NAME      only this image name
  --tag TAG         only this tag
  --dry-run         print the plan without contacting any registry
  --check-sources   resolve sources and assert platforms, but never write
  --scan            run Trivy on the mirrored digest after each copy
  -h, --help        show this help
EOF
}

while (($#)); do
  case $1 in
    --category) CATEGORY=${2:?--category needs a value}; shift 2 ;;
    --image) IMAGE_FILTER=${2:?--image needs a value}; shift 2 ;;
    --tag) TAG_FILTER=${2:?--tag needs a value}; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --check-sources) CHECK_SOURCES=true; shift ;;
    --scan) SCAN=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

require_cmd jq yq

# --dry-run never talks to a registry, so it does not need skopeo or secrets.
if [[ $DRY_RUN == false || $CHECK_SOURCES == true ]]; then
  require_cmd skopeo
  prepare_authfile
  trap cleanup_authfile EXIT
else
  AUTHFILE=''
fi

mkdir -p "$RESULTS_DIR"
SYNC_RESULTS_FILE="${SYNC_RESULTS_FILE:-${RESULTS_DIR}/results-${CATEGORY}.jsonl}"
: >"$SYNC_RESULTS_FILE"

failures=0
total=0

sync_one() {
  local category=$1 name=$2 img_json=$3 src=$4 dst=$5 tag=$6 pinned=$7 platforms_json=$8
  local src_ref="${src}:${tag}"
  local dst_ref="${dst}:${tag}"
  local start=$SECONDS
  local src_digest=''
  local dst_digest=''
  local platforms_count

  record() {
    record_result "$SYNC_RESULTS_FILE" \
      category="$category" image="$name" tag="$tag" \
      source="$src_ref" target="$dst_ref" \
      status="$1" reason="$2" \
      sourceDigest="$src_digest" targetDigest="$dst_digest" \
      durationSeconds="$((SECONDS - start))"
  }

  printf '\n%s==>%s %s:%s\n' "$C_BLUE" "$C_RESET" "$name" "$tag" >&2

  if [[ $DRY_RUN == true && $CHECK_SOURCES == false ]]; then
    record planned 'dry run: no registry access'
    info "would copy ${src_ref} -> ${dst_ref}"
    return 0
  fi

  if ! src_digest=$(manifest_digest "$src_ref"); then
    src_digest=''
    record failed 'cannot resolve source manifest (tag missing or authentication failed)'
    error "cannot resolve ${src_ref}"
    return 1
  fi

  # A pinned digest turns the manifest into an assertion about upstream bytes.
  # If the tag now points somewhere else, fail instead of silently replacing a
  # mirrored image that production may already be running.
  if [[ -n $pinned && $src_digest != "$pinned" ]]; then
    record drift "upstream digest ${src_digest} does not match pinned ${pinned}; refusing to copy"
    error "digest drift on ${src_ref}: pinned ${pinned}, upstream ${src_digest}"
    return 1
  fi

  platforms_count=$(jq 'length' <<<"$platforms_json")
  if ((platforms_count > 0)); then
    local -a platforms=()
    local p
    while IFS= read -r p; do
      if [[ -n $p ]]; then
        platforms+=("$p")
      fi
    done < <(jq -r '.[]' <<<"$platforms_json")
    if ! assert_platforms "$src_ref" "${platforms[@]}"; then
      record failed 'declared platform(s) missing from the source manifest'
      return 1
    fi
  fi

  if [[ $CHECK_SOURCES == true ]]; then
    record checked "source reachable (${src_digest}), copy not requested"
    ok "source ok: ${src_ref} (${src_digest})"
    return 0
  fi

  if [[ $(jq -r '.signature.verify // false' <<<"$img_json") == true ]]; then
    info "verifying signature of ${src_ref}@${src_digest}"
    if ! MIRROR_VERIFY_KEY=$(jq -r '.signature.key // ""' <<<"$img_json") \
      MIRROR_VERIFY_ISSUER=$(jq -r '.signature.keyless.issuer // ""' <<<"$img_json") \
      MIRROR_VERIFY_SUBJECT_REGEXP=$(jq -r '.signature.keyless.subjectRegExp // ""' <<<"$img_json") \
      "${SCRIPT_DIR}/verify.sh" "${src_ref}@${src_digest}"; then
      record failed 'signature verification failed'
      return 1
    fi
  fi

  if dst_digest=$(manifest_digest "$dst_ref"); then
    if [[ $dst_digest == "$src_digest" ]]; then
      record skipped 'target already matches the source digest'
      ok "already mirrored: ${dst_ref} (${dst_digest})"
      return 0
    fi

    # A tag that already exists with other bytes means either upstream moved
    # the tag or someone pushed over it. Without a pinned digest the manifest
    # does not say which bytes are correct, so refuse instead of following
    # upstream. With a pin, the pin already matched the source above, so
    # replacing the target is a repair of the declared state.
    if [[ -z $pinned ]] && [[ $(policy '.spec.verify.allowDigestReplace' false) != "true" ]]; then
      record drift "target tag exists with a different digest (${dst_digest}); refusing to replace it without a pinned digest"
      error "refusing to overwrite ${dst_ref}: target ${dst_digest} != source ${src_digest}"
      error "pin versions[].digest, or set verify.allowDigestReplace: true to opt in"
      return 1
    fi
    info "replacing existing target digest ${dst_digest} with ${src_digest}"
  else
    dst_digest=''
  fi

  info "copy ${src_ref} -> ${dst_ref}"
  if ! retry skopeo_copy "$src_ref" "$dst_ref"; then
    record failed 'skopeo copy failed after retries'
    return 1
  fi

  if ! dst_digest=$(manifest_digest "$dst_ref"); then
    dst_digest=''
    record failed 'target manifest unreadable after copy'
    return 1
  fi

  if [[ $dst_digest != "$src_digest" ]]; then
    record failed "digest mismatch after copy: source ${src_digest} target ${dst_digest}"
    error "digest mismatch for ${dst_ref}: ${src_digest} != ${dst_digest}"
    return 1
  fi

  if [[ $SCAN == true ]]; then
    if ! "${SCRIPT_DIR}/scan.sh" "${dst_ref}@${dst_digest}"; then
      record scan-failed 'image copied but the vulnerability scan failed'
      return 1
    fi
  fi

  record success 'digest verified'
  ok "mirrored: ${dst_ref} (${dst_digest})"
}

manifest_lines=$(select_manifest_files "$CATEGORY") || die "failed to load manifests from ${IMAGES_DIR}"

while IFS=$'\t' read -r category doc; do
  [[ -n $category ]] || continue

  image_count=$(jq '.spec.images | length' <<<"$doc")
  for ((i = 0; i < image_count; i++)); do
    img_json=$(jq -c --argjson i "$i" '.spec.images[$i]' <<<"$doc")
    name=$(jq -r '.name' <<<"$img_json")

    if [[ -n $IMAGE_FILTER && $name != "$IMAGE_FILTER" ]]; then
      continue
    fi

    src=$(jq -r '.source' <<<"$img_json")
    dst=$(jq -r '.target' <<<"$img_json")
    platforms_json=$(jq -c --argjson i "$i" \
      '(.spec.defaults.platforms // []) as $def | .spec.images[$i].platforms // $def' <<<"$doc")

    version_count=$(jq '.versions | length' <<<"$img_json")
    for ((k = 0; k < version_count; k++)); do
      tag=$(jq -r --argjson k "$k" '.versions[$k].tag' <<<"$img_json")
      pinned=$(jq -r --argjson k "$k" '.versions[$k].digest // ""' <<<"$img_json")

      if [[ -n $TAG_FILTER && $tag != "$TAG_FILTER" ]]; then
        continue
      fi

      total=$((total + 1))
      if ! sync_one "$category" "$name" "$img_json" "$src" "$dst" "$tag" "$pinned" "$platforms_json"; then
        failures=$((failures + 1))
      fi
    done
  done
done <<<"$manifest_lines"

printf '\n'
if ((failures > 0)); then
  error "${failures} of ${total} version(s) failed; see ${SYNC_RESULTS_FILE}"
  exit 1
fi

if [[ $DRY_RUN == true && $CHECK_SOURCES == false ]]; then
  ok "planned ${total} version(s); nothing was written"
elif [[ $CHECK_SOURCES == true ]]; then
  ok "checked ${total} source version(s)"
else
  ok "all ${total} version(s) synced"
fi
