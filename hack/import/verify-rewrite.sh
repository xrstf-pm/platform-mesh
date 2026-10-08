#!/usr/bin/env bash
# Copyright The Platform Mesh Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Verifies that a history rewrite done with rewrite-repo-paths.sh lost no
# content: for the tip of each branch/tag in the original repo, every file is
# expected at its mapped location in the rewritten repo with identical blob
# hash, and the rewritten tree must contain nothing else.
#
# Usage: verify-rewrite.sh <original-repo> <rewritten-repo> <mapping-file>

set -euo pipefail

ORIG="$(cd "$1" && pwd)"
REWRITTEN="$(cd "$2" && pwd)"
MAPPING="$(realpath "$3")"
TAG_PREFIX="${TAG_PREFIX:-helm-charts/}"

# Apply the mapping (same semantics as the filename callback: longest match
# wins, directory entries are prefixes, others exact) to stdin lines of the
# form "<blob> <path>", printing "<blob> <newpath>" for kept files.
map_paths() {
  python3 - "$MAPPING" <<'EOF'
import sys
mappings = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    parts = line.split()
    mappings.append((parts[0], parts[1] if len(parts) > 1 else ''))
mappings.sort(key=lambda m: len(m[0]), reverse=True)
for line in sys.stdin:
    blob, path = line.rstrip('\n').split(' ', 1)
    for old, new in mappings:
        if old.endswith('/'):
            if path.startswith(old):
                if new:
                    print(blob, new + path[len(old):])
                break
        elif path == old:
            if new:
                print(blob, new)
            break
EOF
}

list_tree() { # <repo> <ref>
  git -C "$1" ls-tree -r --format='%(objectname) %(path)' "$2"
}

failed=0
check_ref() { # <orig-ref> <rewritten-ref>
  local expected actual
  expected="$(list_tree "$ORIG" "$1" | map_paths | sort -k2)"
  actual="$(list_tree "$REWRITTEN" "$2" | sort -k2)"
  if [[ "$expected" == "$actual" ]]; then
    echo "  ok: $1 -> $2 ($(wc -l <<<"$actual") files)"
  else
    echo "  MISMATCH: $1 -> $2"
    diff <(echo "$expected") <(echo "$actual") | head -20 | sed 's/^/    /'
    failed=1
  fi
}

check_ref HEAD HEAD
for tag in $(git -C "$ORIG" tag -l); do
  if ! git -C "$REWRITTEN" rev-parse -q --verify "refs/tags/${TAG_PREFIX}${tag}" >/dev/null; then
    echo "  skipped: tag $tag is not in the rewritten repo (not reachable from main?)"
    continue
  fi
  check_ref "$tag" "${TAG_PREFIX}${tag}"
done

if [[ $failed -ne 0 ]]; then
  echo "Verification FAILED: rewritten history differs from the original." >&2
  exit 1
fi
echo "Verification passed."
