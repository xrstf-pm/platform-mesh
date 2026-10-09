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

# Deletes prerelease versions (tags matching -dev.) of the Platform Mesh
# aggregate component from GHCR that are older than a number of days. Only the
# aggregate's descriptors are removed; charts and other components it
# references are regular versions and stay.
#
# Usage: cleanup-prereleases.sh <org> [--days N] [--component NAME] [--dry-run]
#
#   --days N          delete versions older than N days (default 14)
#   --component NAME  OCM component name (default github.com/platform-mesh/platform-mesh)
#   --dry-run         only print what would be deleted
#
# Needs `gh` authenticated with permission to delete packages in <org>.

set -euo pipefail

org="${1:?usage: $0 <org> [--days N] [--component NAME] [--dry-run]}"; shift
days=14
component="github.com/platform-mesh/platform-mesh"
dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --days) days="$2"; shift 2 ;;
    --component) component="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

package="component-descriptors/$component"
encoded="$(jq -rn --arg p "$package" '$p | @uri')"
cutoff="$(date -u -d "-$days days" +%Y-%m-%dT%H:%M:%SZ)"

echo "Looking for -dev. versions of $package older than $cutoff ..."
versions="$(gh api --paginate "/orgs/$org/packages/container/$encoded/versions?per_page=100" \
  | jq -c --arg cutoff "$cutoff" '.[] | select(.created_at < $cutoff) | select(any(.metadata.container.tags[]?; test("-dev\\."))) | {id, tags: .metadata.container.tags, created_at}')"

if [[ -z "$versions" ]]; then
  echo "Nothing to delete."
  exit 0
fi

count=0
while IFS= read -r v; do
  id="$(jq -r .id <<<"$v")"; tags="$(jq -r '.tags | join(",")' <<<"$v")"; created="$(jq -r .created_at <<<"$v")"
  if [[ "$dry_run" == "true" ]]; then
    echo "would delete $tags (created $created)"
  else
    gh api -X DELETE "/orgs/$org/packages/container/$encoded/versions/$id" >/dev/null
    echo "deleted $tags (created $created)"
  fi
  count=$((count + 1))
done <<<"$versions"
echo "$count version(s) $( [[ "$dry_run" == "true" ]] && echo "would be" || echo "were") deleted."
