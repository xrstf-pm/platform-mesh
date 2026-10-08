#!/usr/bin/env bash
# Copyright 2026 Platform Mesh Authors
# SPDX-License-Identifier: Apache-2.0
#
# Rewrites a git repository's history to move files to new locations.
# This is useful when merging multiple repos into a monorepo while preserving history.
#
# Usage:
#   ./rewrite-repo-paths.sh [options] <source-repo> <mapping-file> [output-dir]
#
# Options:
#   --drop-message-regex <regex>   Drop commits whose message matches this regex
#   --drop-author-regex <regex>    Drop commits whose author matches this regex
#                                  Dropped commits are squashed into the next kept commit
#                                  on the same first-parent line, so no changes are lost.
#                                  Branch tips and tag targets are never dropped.
#   --drop-tags                    Remove all tags from the rewritten history
#   --tag-prefix <prefix>          Prefix all tags (e.g. 'helm-charts/' turns 0.5.2 into helm-charts/0.5.2)
#   --rewrite-issues <org/repo>    Rewrite issue refs (#123 -> org/repo#123)
#   --help                         Show this help
#
# The mapping file contains lines of the form:
#   <old-path-prefix> <new-path-prefix>
#
# Example mapping file:
#   api/ apis/core/
#   internal/ operators/account-operator/internal/
#   cmd/ operators/account-operator/cmd/
#   pkg/ operators/account-operator/pkg/
#   main.go operators/account-operator/main.go
#
# Rules:
#   - Entries ending in / are directory prefixes and match everything below them
#   - Other entries must match the full file path exactly
#   - The longest matching entry wins (so hack/ocm/ beats hack/)
#   - Files not matching any entry, or mapped to an empty target, are removed from history
#   - Comments (lines starting with #) and empty lines are ignored
#
# Example with commit filtering:
#   ./rewrite-repo-paths.sh \
#       --drop-message-regex '^(chore\(deps\)|Update .* to )' \
#       --drop-author-regex 'renovate\[bot\]|dependabot' \
#       --rewrite-issues platform-mesh/account-operator \
#       /path/to/source mapping.txt /tmp/output
#
# The script creates a fresh clone, rewrites it, and leaves it ready to be
# merged into the target repo with:
#   git remote add <name> <rewritten-repo-path>
#   git fetch <name>
#   git merge --allow-unrelated-histories <name>/main

set -euo pipefail

# Parse options
DROP_MESSAGE_REGEX=""
DROP_AUTHOR_REGEX=""
DROP_TAGS=false
TAG_PREFIX=""
REWRITE_ISSUES=""

show_help() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --drop-message-regex)
            DROP_MESSAGE_REGEX="$2"
            shift 2
            ;;
        --drop-author-regex)
            DROP_AUTHOR_REGEX="$2"
            shift 2
            ;;
        --drop-tags)
            DROP_TAGS=true
            shift
            ;;
        --tag-prefix)
            TAG_PREFIX="$2"
            shift 2
            ;;
        --rewrite-issues)
            REWRITE_ISSUES="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 [options] <source-repo> <mapping-file> [output-dir]" >&2
    echo "Run with --help for more information." >&2
    exit 1
fi

SOURCE_REPO="$1"
MAPPING_FILE="$2"
OUTPUT_DIR="${3:-/tmp/rewritten-repo}"

# Resolve to absolute paths
SOURCE_REPO="$(cd "$SOURCE_REPO" && pwd)"
MAPPING_FILE="$(realpath "$MAPPING_FILE")"

# Validate inputs
if [[ ! -d "$SOURCE_REPO/.git" ]] && [[ ! -d "$SOURCE_REPO/objects" ]]; then
    echo "Error: $SOURCE_REPO does not appear to be a git repository" >&2
    exit 1
fi

if [[ ! -f "$MAPPING_FILE" ]]; then
    echo "Error: Mapping file $MAPPING_FILE not found" >&2
    exit 1
fi

# Check for git filter-repo
if ! git filter-repo --version &>/dev/null; then
    echo "Error: git filter-repo is not installed" >&2
    echo "Install it with: sudo dnf install git-filter-repo" >&2
    exit 1
fi

# Clean up and create fresh clone
rm -rf "$OUTPUT_DIR"
echo "Cloning $SOURCE_REPO to $OUTPUT_DIR..."
git clone --no-local --single-branch "$SOURCE_REPO" "$OUTPUT_DIR"

cd "$OUTPUT_DIR"

# Build the filename callback from the mapping file.
#
# We deliberately do not use --path/--path-rename: filter-repo applies
# --path-rename rules sequentially (so hack/ocm/ -> hack/release/ followed by
# hack/ -> hack/charts/ would chain into hack/charts/release/), and --path
# cannot express "delete". A filename callback with longest-prefix-wins gives
# the mapping file the semantics documented above.

MAPPING_PY=""
MAPPING_COUNT=0

echo "Reading mappings from $MAPPING_FILE..."
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

    # Parse old and new paths
    old_path=$(echo "$line" | awk '{print $1}')
    new_path=$(echo "$line" | awk '{print $2}')

    if [[ -z "$old_path" ]]; then
        continue
    fi

    echo "  $old_path -> ${new_path:-(delete)}"
    MAPPING_PY+="    (b'''$old_path''', b'''$new_path'''),"$'\n'
    MAPPING_COUNT=$((MAPPING_COUNT + 1))
done < "$MAPPING_FILE"

if [[ $MAPPING_COUNT -eq 0 ]]; then
    echo "Error: No valid mappings found in $MAPPING_FILE" >&2
    exit 1
fi

# Directory prefixes (ending in /) match any path below them; other entries
# must match the full filename exactly. Longest matching prefix wins. Unmatched
# files and files mapped to an empty target are dropped from history.
FILENAME_CALLBACK="
MAPPINGS = [
${MAPPING_PY}]
MAPPINGS.sort(key=lambda m: len(m[0]), reverse=True)
for old, new in MAPPINGS:
    if old.endswith(b'/'):
        if filename.startswith(old):
            return (new + filename[len(old):]) if new else None
    elif filename == old:
        return new if new else None
return None
"

# Build commit callback if we need to filter commits
CALLBACK_FILE=""
if [[ -n "$DROP_MESSAGE_REGEX" || -n "$DROP_AUTHOR_REGEX" ]]; then
    CALLBACK_FILE=$(mktemp --suffix=.py)
    trap 'rm -f "$CALLBACK_FILE"' EXIT

    # Commits that are branch tips or tag targets are never dropped: dropping
    # them would move the ref to the parent and lose the tip's changes.
    PROTECTED_IDS=$(git for-each-ref --format='%(objectname) %(*objectname)' refs/heads refs/tags \
        | tr ' ' '\n' | grep -v '^$' | sort -u | sed "s/.*/    b'&',/")

    cat > "$CALLBACK_FILE" << PYTHON_EOF
import re

# Compile regexes
message_pattern = re.compile(rb'''$DROP_MESSAGE_REGEX''') if '''$DROP_MESSAGE_REGEX''' else None
author_pattern = re.compile(rb'''$DROP_AUTHOR_REGEX''') if '''$DROP_AUTHOR_REGEX''' else None

protected = {
$PROTECTED_IDS
}

# Dropping a commit with commit.skip() only removes it from the output stream;
# fast-export lists per commit only the files that commit changed, so a
# skipped commit's changes would silently vanish from history until some
# later commit happens to touch the same file. To squash instead of lose, we
# carry the skipped commit's file changes forward (keyed by its original mark)
# and fold them into the next kept commit whose original *first* parent it is.
# Merge commits take their tree from the first parent, so only the first-parent
# line matters; changes reachable via a second parent are already part of the
# merge commit's own diff.
#
# pending:  original mark -> list of FileChange carried forward
# squashed: original mark -> number of commits squashed into that list
pending = {}
squashed = {}
dropped_count = 0

def _inherited(metadata):
    orig_parents = metadata.get('orig_parents') or []
    first = orig_parents[0] if orig_parents else None
    if isinstance(first, int) and first in pending:
        return pending[first], squashed[first]
    return [], 0

def _merge_changes(inherited, own):
    # Later entries win; the commit's own changes come last.
    by_name = {}
    for fc in list(inherited) + list(own):
        by_name[fc.filename] = fc
    return list(by_name.values())

def commit_callback(commit, metadata):
    global dropped_count

    inherited, inherited_count = _inherited(metadata)

    drop = False
    if message_pattern and message_pattern.search(commit.message):
        drop = True
    if author_pattern:
        author_info = commit.author_name + b' <' + commit.author_email + b'>'
        if author_pattern.search(author_info):
            drop = True
    if commit.original_id in protected or not commit.parents:
        drop = False

    if drop:
        dropped_count += 1
        pending[commit.old_id] = _merge_changes(inherited, commit.file_changes)
        squashed[commit.old_id] = inherited_count + 1
        # Remap this commit's id to its (already translated) first parent so
        # children stay attached. A bare skip() would map it to None.
        commit.skip(new_id=commit.first_parent())
        return

    if not commit.file_changes:
        # Nothing of ours in this commit (filter-repo will most likely prune
        # it as empty); pass the carried changes on to its first-parent child.
        if inherited:
            pending[commit.old_id] = inherited
            squashed[commit.old_id] = inherited_count
        return

    if inherited:
        commit.file_changes = _merge_changes(inherited, commit.file_changes)
        commit.message = commit.message.rstrip(b'\n') + (
            b'\n\nIncludes the changes of %d automated commit(s) squashed into this one\n'
            b'during the monorepo import.\n' % inherited_count)
PYTHON_EOF

    echo ""
    echo "Commit filtering enabled:"
    [[ -n "$DROP_MESSAGE_REGEX" ]] && echo "  Drop messages matching: $DROP_MESSAGE_REGEX"
    [[ -n "$DROP_AUTHOR_REGEX" ]] && echo "  Drop authors matching: $DROP_AUTHOR_REGEX"
fi

echo ""
echo "Running git-filter-repo..."
echo "  $MAPPING_COUNT mapping rules"

# Build final command
FILTER_CMD=(git filter-repo --force --filename-callback "$FILENAME_CALLBACK")

if [[ "$DROP_TAGS" == "true" ]]; then
    # --tag-callback handles annotated tags
    FILTER_CMD+=(--tag-callback "tag.skip()")
elif [[ -n "$TAG_PREFIX" ]]; then
    FILTER_CMD+=(--tag-rename ":${TAG_PREFIX}")
fi

if [[ -n "$CALLBACK_FILE" ]]; then
    FILTER_CMD+=(--commit-callback "$(cat "$CALLBACK_FILE")")
fi

# Run it
"${FILTER_CMD[@]}"

# Delete all tags if requested (handles both annotated and lightweight tags)
if [[ "$DROP_TAGS" == "true" ]]; then
    echo "Removing all tags..."
    git tag -l | xargs -r git tag -d >/dev/null 2>&1 || true
fi

# Rewrite issue references in commit messages
if [[ -n "$REWRITE_ISSUES" ]]; then
    echo ""
    echo "Rewriting issue references to $REWRITE_ISSUES..."
    FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --tag-name-filter cat --msg-filter \
        "sed -E 's@(^|[^a-zA-Z0-9])#([0-9]+)@\1$REWRITE_ISSUES#\2@g'" \
        -- --all
    rm -rf .git/refs/original/
fi

# Count commits before and after (approximately, by counting in log)
COMMIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "?")

echo ""
echo "Verifying result..."
echo "Commits in rewritten history: $COMMIT_COUNT"
echo ""
echo "Files in rewritten repo:"
git ls-files | sed -n '1,20p'
FILE_COUNT=$(git ls-files | wc -l)
if [[ $FILE_COUNT -gt 20 ]]; then
    echo "... and $((FILE_COUNT - 20)) more files"
fi

echo ""
echo "Done! Rewritten repository is at: $OUTPUT_DIR"
echo ""
echo "To merge into your target repo:"
echo "  cd <target-repo>"
echo "  git remote add temp-merge $OUTPUT_DIR"
echo "  git fetch temp-merge"
echo "  git merge --allow-unrelated-histories temp-merge/<branch> -m 'Merge <name> with history'"
echo "  git remote remove temp-merge"
