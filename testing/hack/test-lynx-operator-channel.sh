#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../lynx/operator.sh"

package_manifest() {
  local default_channel="$1"
  jq -cn --arg default_channel "${default_channel}" '{
    status: {
      defaultChannel: $default_channel,
      channels: [
        {name: "stable", currentCSVDesc: {version: "2026.1.3-rc.46.gefe4365"}},
        {name: "sonarqube-2026", currentCSVDesc: {version: "2026.1.3-rc.46.gefe4365"}},
        {name: "preview", currentCSVDesc: {version: "2026.1.3-rc.45.gprevious"}}
      ]
    }
  }'
}

selected="$(package_manifest stable | select_operator_channel 2026.1.3-rc.46.gefe4365)"
[[ "${selected}" == "stable" ]]

selected="$(package_manifest stable | select_operator_channel \
  2026.1.3-rc.46.gefe4365 sonarqube-2026)"
[[ "${selected}" == "sonarqube-2026" ]]

selected="$(package_manifest preview | select_operator_channel 2026.1.3-rc.45.gprevious)"
[[ "${selected}" == "preview" ]]

if package_manifest preview | select_operator_channel 2026.1.3-rc.46.gefe4365 >/dev/null; then
  echo "expected ambiguous non-default channels to fail" >&2
  exit 1
fi

if package_manifest stable | select_operator_channel \
  2026.1.3-rc.46.gefe4365 missing-channel >/dev/null; then
  echo "expected a missing requested channel to fail" >&2
  exit 1
fi

echo "operator channel selection tests passed"
