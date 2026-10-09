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

# Source this file to get the pinned release tooling (ocm, helm, yq) on PATH.
# The versions live in tools/Taskfile.yaml; `task tools:release` installs them
# into bin/ and symlinks bin/release/{ocm,helm,yq}. Scripts and workflows use
# this instead of maintaining their own download snippets.
#
#   source "$(git rev-parse --show-toplevel)/hack/release/tools.sh"
#
# Set RELEASE_TOOLS_FROM_PATH=true to skip the installation and use whatever
# ocm/helm/yq are already on PATH (for environments without task or network).

if [ "${RELEASE_TOOLS_FROM_PATH:-false}" != "true" ]; then
  _release_tools_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
  if ! command -v task >/dev/null; then
    echo "error: 'task' (https://taskfile.dev) is required to install the release tooling; install it or set RELEASE_TOOLS_FROM_PATH=true" >&2
    return 1 2>/dev/null || exit 1
  fi
  task -d "$_release_tools_root" tools:release
  export PATH="$_release_tools_root/bin/release:$PATH"
  unset _release_tools_root
fi
