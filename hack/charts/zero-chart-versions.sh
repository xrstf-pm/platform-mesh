#!/usr/bin/env bash
# Copyright The Platform Mesh Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Puts every chart under charts/ into the shape the release process expects
# (docs/release/process.md): no versions in git. Concretely
#
#   version      -> 0.0.0 for every chart
#   appVersion   -> 0.0.0 for charts whose image is built in this repository
#                   (listed with `chart:` in ocm/components.yaml); charts
#                   wrapping another repository's image keep theirs
#   dependencies -> dependencies on charts that live in charts/ become
#                   `file://../<name>` at 0.0.0; vendored .tgz and Chart.lock
#                   files are removed (they are regenerated on package)
#
# hack/release/stage-charts.sh is the inverse at build time. Idempotent; used
# once when the helm-charts repository was imported, and again whenever a
# chart with a real version is brought in from elsewhere.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=../release/tools.sh
source hack/release/tools.sh
require_tools yq

inhouse="$("$YQ" -r '.components[] | select(.chart != null) | .chart | sub("^charts/", "")' ocm/components.yaml)"
local_charts="$(ls charts/)"

for chart_yaml in charts/*/Chart.yaml charts/*/test-chart/Chart.yaml; do
  [[ -f "$chart_yaml" ]] || continue
  dir="$(dirname "$chart_yaml")"
  name="$("$YQ" -r '.name' "$chart_yaml")"

  "$YQ" -i '.version = "0.0.0"' "$chart_yaml"
  if grep -qx "$name" <<<"$inhouse"; then
    "$YQ" -i '.appVersion = "0.0.0"' "$chart_yaml"
  fi

  for dep in $("$YQ" -r '.dependencies[]?.name' "$chart_yaml"); do
    if grep -qx "$dep" <<<"$local_charts"; then
      rel="$(realpath --relative-to="$dir" "charts/$dep")"
      dep="$dep" rel="$rel" "$YQ" -i '
        (.dependencies[] | select(.name == strenv(dep))) |= (.version = "0.0.0" | .repository = "file://" + strenv(rel))
      ' "$chart_yaml"
    fi
  done

  rm -f "$dir/Chart.lock" "$dir"/charts/*.tgz
  rmdir "$dir/charts" 2>/dev/null || true
done

echo "charts reset to 0.0.0; regenerate docs and snapshots:"
echo "  task charts:docs charts:helmtest-update"
