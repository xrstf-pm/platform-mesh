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

# Prints the version the next Platform Mesh release from this checkout will
# have: the minor from the VERSION file at the repository root, the patch from
# the release tags of that minor reachable from HEAD:
#
#   VERSION 0.61, no v0.61.* tag reachable      ->  0.61.0   (main before the release)
#   VERSION 0.60, v0.60.0 reachable             ->  0.60.1   (release branch after 0.60.0)
#   VERSION 0.60, v0.60.1-rc.1 reachable only   ->  0.60.1   (release in progress)
#
# VERSION is bumped on main right after a minor release, so builds from main
# are versioned towards the next minor; release branches keep their minor.
# Used by prerelease.yml (<next>-dev.<n>.g<sha>); for a release, tag what it
# prints: git tag "v$(hack/release/next-version.sh)".
#
# Usage: next-version.sh [--minor]   (--minor prints only X.Y)

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

minor="$(grep -vE '^\s*(#|$)' VERSION | head -1 | tr -d '[:space:]')"
[[ "$minor" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "VERSION must contain MAJOR.MINOR, got '$minor'" >&2; exit 1; }

if [[ "${1:-}" == "--minor" ]]; then
  echo "$minor"
  exit 0
fi

# Highest final release of this minor that is an ancestor of HEAD.
latest="$(git tag -l "v${minor}.[0-9]*" --merged HEAD 2>/dev/null | grep -vE -- '-' | sort -V | tail -1 || true)"
if [[ -z "$latest" ]]; then
  echo "${minor}.0"
else
  patch="${latest##*.}"
  echo "${minor}.$((patch + 1))"
fi
