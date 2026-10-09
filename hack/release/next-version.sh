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

# Prints the version the next Platform Mesh release will most likely have,
# derived from the release tags reachable from HEAD:
#
#   latest tag v0.6.0-rc.2  ->  0.6.0   (a release in progress)
#   latest tag v0.6.0       ->  0.7.0   (next minor)
#   no tags                 ->  0.1.0
#
# Used by prerelease.yml to version builds from main as <next>-dev.<n>.g<sha>.
#
# Usage: next-version.sh

set -euo pipefail

latest="$(git tag -l 'v[0-9]*' --merged HEAD | sort -V | tail -1)"
if [[ -z "$latest" ]]; then
  echo "0.1.0"
  exit 0
fi

version="${latest#v}"
base="${version%%-*}"
if [[ "$version" == *-* ]]; then
  echo "$base"
else
  IFS=. read -r major minor _ <<<"$base"
  echo "$major.$((minor + 1)).0"
fi
