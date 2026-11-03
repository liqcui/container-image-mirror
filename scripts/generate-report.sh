#!/usr/bin/env bash
#
# Merge the JSONL result files written by sync.sh into a Markdown report and
# publish it to the GitHub Actions step summary when running in CI.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_cmd jq

files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  shopt -s nullglob
  files=("$RESULTS_DIR"/*.jsonl)
  shopt -u nullglob
fi

[[ ${#files[@]} -gt 0 ]] || die "no result files found (run sync.sh first)"

records='[]'
for f in "${files[@]}"; do
  [[ -f $f ]] || continue
  records=$(jq -s --argjson acc "$records" '$acc + .' "$f")
done

total=$(jq 'length' <<<"$records")
count_status() { jq --arg s "$1" '[.[] | select(.status == $s)] | length' <<<"$records"; }

success=$(count_status success)
skipped=$(count_status skipped)
planned=$(count_status planned)
checked=$(count_status checked)
failed=$(count_status failed)
drift=$(count_status drift)
scan_failed=$(count_status scan-failed)

report=$(
  cat <<EOF
## Image sync report

| Result | Count |
| --- | --- |
| Total | ${total} |
| Mirrored | ${success} |
| Already up to date | ${skipped} |
| Planned (dry run) | ${planned} |
| Sources checked | ${checked} |
| Failed | ${failed} |
| Digest drift | ${drift} |
| Scan failed | ${scan_failed} |
EOF
)

problems=$(jq -r '
  [.[] | select(.status == "failed" or .status == "drift" or .status == "scan-failed")]
  | if length == 0 then empty
    else
      "| Image | Tag | Status | Reason |\n| --- | --- | --- | --- |\n"
      + (map("| \(.image) | \(.tag) | \(.status) | \(.reason) |") | join("\n"))
    end
' <<<"$records")

if [[ -n $problems ]]; then
  report+=$'\n\n'"### Problems"$'\n\n'"${problems}"
fi

digests=$(jq -r '
  [.[] | select(.status == "success" or .status == "skipped")]
  | if length == 0 then empty
    else
      "| Target | Digest |\n| --- | --- |\n"
      + (map("| \(.target) | \(.targetDigest // "-") |") | join("\n"))
    end
' <<<"$records")

if [[ -n $digests ]]; then
  report+=$'\n\n'"### Mirrored digests"$'\n\n'"${digests}"
fi

printf '%s\n' "$report"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  printf '%s\n' "$report" >>"$GITHUB_STEP_SUMMARY"
fi

if ((failed + drift + scan_failed > 0)); then
  exit 1
fi
