#!/usr/bin/env bash
# Copyright The Platform Mesh Authors.
# SPDX-License-Identifier: Apache-2.0
#
# Imports the platform-mesh/helm-charts repository into this monorepo,
# preserving history. Paths are rewritten according to mappings/helm-charts.txt.
#
# Usage:
#   hack/import/import-helm-charts.sh [--reset] [--source <path-or-url>] [--no-merge]
#
# Options:
#   --reset            Undo a previous import first (resets the current branch to the
#                      commit recorded in .git/HELM_CHARTS_IMPORT_BASE). Use this to
#                      tweak the mapping file and run the import again.
#   --source <src>     Repository to import. Default: https://github.com/platform-mesh/helm-charts
#                      A local clone is much faster for repeated runs.
#   --no-merge         Only produce the rewritten repository, do not merge it.
#
# The rewritten repository is left at hack/import/temp/helm-charts-rewritten (gitignored)
# and attached as git remote "helm-charts-import" for inspection.
#
# Re-running: edit mappings/helm-charts.txt, then
#   hack/import/import-helm-charts.sh --reset --source ../helm-charts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SOURCE="https://github.com/platform-mesh/helm-charts"
RESET=false
MERGE=true
REMOTE_NAME="helm-charts-import"
TEMP_DIR="$SCRIPT_DIR/temp"
REWRITTEN="$TEMP_DIR/helm-charts-rewritten"
BASE_FILE="$REPO_ROOT/.git/HELM_CHARTS_IMPORT_BASE"
MAPPING="$SCRIPT_DIR/mappings/helm-charts.txt"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset) RESET=true; shift ;;
    --source) SOURCE="$2"; shift 2 ;;
    --no-merge) MERGE=false; shift ;;
    -h|--help) sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree is not clean." >&2
  exit 1
fi

if [[ "$RESET" == "true" ]]; then
  if [[ ! -f "$BASE_FILE" ]]; then
    echo "Error: --reset requested but no previous import recorded ($BASE_FILE missing)." >&2
    exit 1
  fi
  base="$(cat "$BASE_FILE")"
  echo "Resetting $(git rev-parse --abbrev-ref HEAD) to pre-import commit $base..."
  git reset --hard "$base"
  git remote remove "$REMOTE_NAME" 2>/dev/null || true
  # Drop tags from the previous import run so they can be recreated.
  git tag -l 'helm-charts/*' | xargs -r git tag -d >/dev/null
elif [[ -f "$BASE_FILE" ]]; then
  echo "Error: a previous import is recorded in $BASE_FILE. Use --reset to redo it," >&2
  echo "or delete the file if the import is final." >&2
  exit 1
fi

# Resolve a local source to an absolute path; URLs are passed through.
if [[ -d "$SOURCE" ]]; then
  SOURCE="$(cd "$SOURCE" && pwd)"
fi

mkdir -p "$TEMP_DIR"

if [[ ! -d "$SOURCE" ]]; then
  # rewrite-repo-paths.sh needs a local repository to clone from.
  CLONE="$TEMP_DIR/helm-charts-source"
  if [[ ! -d "$CLONE/.git" ]]; then
    echo "Cloning $SOURCE..."
    git clone --quiet "$SOURCE" "$CLONE"
  else
    echo "Updating existing clone in $CLONE..."
    (cd "$CLONE" && git fetch --quiet --all --tags)
  fi
  SOURCE="$CLONE"
fi

echo "Rewriting history of $SOURCE..."
"$SCRIPT_DIR/rewrite-repo-paths.sh" \
  --tag-prefix 'helm-charts/' \
  --rewrite-issues 'platform-mesh/helm-charts' \
  "$SOURCE" "$MAPPING" "$REWRITTEN"

if [[ "$MERGE" != "true" ]]; then
  echo "Done (no merge). Rewritten repository: $REWRITTEN"
  exit 0
fi

git rev-parse HEAD > "$BASE_FILE"
echo "Recorded pre-import commit $(cat "$BASE_FILE") in $BASE_FILE"

git remote remove "$REMOTE_NAME" 2>/dev/null || true
git remote add "$REMOTE_NAME" "$REWRITTEN"
git fetch --quiet --tags "$REMOTE_NAME"

echo "Merging..."
git merge --allow-unrelated-histories --no-ff --signoff \
  -m "Merge platform-mesh/helm-charts into the monorepo

Imported with hack/import/import-helm-charts.sh; see
hack/import/mappings/helm-charts.txt for how paths were moved." \
  "$REMOTE_NAME/main"

echo ""
echo "Done. Imported $(git rev-list --count "$REMOTE_NAME/main") commits."
echo "Imported tags: $(git tag -l 'helm-charts/*' | tr '\n' ' ')"
echo ""
echo "Inspect, then either:"
echo "  - tweak $MAPPING and re-run with --reset, or"
echo "  - accept: rm $BASE_FILE; git remote remove $REMOTE_NAME"
