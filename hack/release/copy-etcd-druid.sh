#!/usr/bin/env bash
# Copyright The Platform Mesh Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Copies Gardener's etcd-druid OCM component (with all referenced resources)
# into our OCM repository.
#
# etcd-druid's SPDX resources are backed by a multi-manifest OCI index without
# a top-level parent manifest, which OCM v2 cannot re-pack. We therefore let
# ocm generate a transfer specification, remove the SPDX nodes from it and
# replay the rest. The SPDX resources are omitted from the copy.
#
# Usage: copy-etcd-druid.sh <version> <target-ocm-repo>

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/tools.sh"
require_tools ocm

version="${1:?usage: $0 <version> <target-ocm-repo>}"
target="${2:?usage: $0 <version> <target-ocm-repo>}"
source_repo="europe-docker.pkg.dev/gardener-project/releases"
component="github.com/gardener/etcd-druid"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

"$OCM" transfer component-version --copy-resources --recursive --dry-run -o yaml \
  "$source_repo//$component:$version" "$target" > "$tmp/spec.yaml"

python3 - "$tmp/spec.yaml" "$tmp/spec-nospdx.yaml" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    spec = yaml.safe_load(f)
nodes = spec['transformations']
spdx_ids = {n['id'] for n in nodes if 'Spdx' in n['id']}
def strip(obj):
    if isinstance(obj, list):
        return [strip(i) for i in obj if not (isinstance(i, str) and any(s in i for s in spdx_ids))]
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in obj.items()}
    return obj
filtered = [strip(n) for n in nodes if n['id'] not in spdx_ids]
for n in filtered:
    if 'dependsOn' in n:
        n['dependsOn'] = [d for d in n['dependsOn'] if d not in spdx_ids]
spec['transformations'] = filtered
with open(dst, 'w') as f:
    yaml.dump(spec, f, default_flow_style=False)
print(f"stripped {len(spdx_ids)} SPDX nodes, {len(filtered)} remaining", file=sys.stderr)
PY

"$OCM" transfer component-version --transfer-spec "$tmp/spec-nospdx.yaml"
