#!/bin/bash
# Iterate every open PR, validate it against the corpus rules, and either
# merge or close. Designed to run in a GitHub Actions job with `gh` and
# `jq` available and `GH_TOKEN` (or `GITHUB_TOKEN`) set.
#
# Validation rules (any failure closes the PR):
#   * No file change may sit under a path component starting with `.`.
#   * Every changed file must have status `added` (no modifies/deletes).
#   * Every added file must live exactly at `rust-lightning/<target>/<file>`
#     where `<target>` is a folder that already exists on master.
# A PR with merge conflicts against master is also closed.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

git fetch --quiet origin master
MASTER_TREE="origin/master"

# All directories that exist under master. Used to validate that added files
# don't introduce a new fuzz-target directory.
mapfile -t MASTER_DIRS < <(git ls-tree -dr --name-only "$MASTER_TREE")

dir_exists_on_master() {
    local target="$1"
    for d in "${MASTER_DIRS[@]}"; do
        [ "$d" = "$target" ] && return 0
    done
    return 1
}

path_has_dot_component() {
    local path="$1"
    case "/$path/" in
        */.*) return 0 ;;
    esac
    return 1
}

close_pr() {
    local pr="$1" reason="$2"
    echo "Closing #$pr: $reason"
    gh pr close "$pr" \
        --comment "Closing automatically: $reason. See [README](../blob/master/README.md#contributing)."
}

mapfile -t PRS < <(gh pr list --state open --limit 1000 --json number --jq '.[].number')

if [ ${#PRS[@]} -eq 0 ]; then
    echo "No open PRs."
fi

for PR in "${PRS[@]}"; do
    echo "::group::PR #$PR"

    # Pull every changed file (paginated; cap at 3000 — beyond that it's not a
    # corpus PR we want to auto-merge anyway).
    FILES_JSON=$(gh api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" \
        | jq -s 'add')
    NUM_FILES=$(echo "$FILES_JSON" | jq 'length')
    echo "$NUM_FILES changed files"

    if [ "$NUM_FILES" -gt 3000 ]; then
        close_pr "$PR" "PR changes too many files ($NUM_FILES) for automated review"
        echo "::endgroup::"
        continue
    fi

    BAD_REASON=""
    while IFS=$'\t' read -r STATUS FILENAME; do
        if path_has_dot_component "$FILENAME"; then
            BAD_REASON="\`$FILENAME\` has a path component starting with \`.\`"
            break
        fi
        if [ "$STATUS" != "added" ]; then
            BAD_REASON="\`$FILENAME\` was \`$STATUS\` — only \`added\` allowed"
            break
        fi
        DIR=$(dirname "$FILENAME")
        case "$DIR" in
            rust-lightning/*/*)
                BAD_REASON="\`$FILENAME\` is too deep — corpus files must live at \`rust-lightning/<target>/<file>\`"
                ;;
            rust-lightning/?*)
                if ! dir_exists_on_master "$DIR"; then
                    BAD_REASON="\`$FILENAME\` is in non-existing target folder \`$DIR\`"
                fi
                ;;
            *)
                BAD_REASON="\`$FILENAME\` is outside \`rust-lightning/\` — only corpus contributions are accepted"
                ;;
        esac
        [ -n "$BAD_REASON" ] && break
    done < <(echo "$FILES_JSON" | jq -r '.[] | "\(.status)\t\(.filename)"')

    if [ -n "$BAD_REASON" ]; then
        close_pr "$PR" "$BAD_REASON"
        echo "::endgroup::"
        continue
    fi

    # GitHub may report `mergeable` as null/UNKNOWN until it computes the
    # mergeability check. Poll briefly.
    MERGEABLE="UNKNOWN"
    for _ in 1 2 3 4 5 6; do
        MERGEABLE=$(gh pr view "$PR" --json mergeable --jq '.mergeable // "UNKNOWN"')
        [ "$MERGEABLE" != "UNKNOWN" ] && break
        sleep 5
    done

    case "$MERGEABLE" in
        CONFLICTING)
            close_pr "$PR" "merge conflict with \`master\`"
            ;;
        MERGEABLE)
            # `--delete-branch` removes the head branch after merge. For PRs
            # opened from a fork, deleting the fork's branch fails silently
            # without affecting the merge.
            if ! gh pr merge "$PR" --merge --delete-branch; then
                echo "Merge of #$PR failed unexpectedly; leaving open."
            fi
            ;;
        *)
            echo "PR #$PR has mergeable=$MERGEABLE; leaving open for next run."
            ;;
    esac

    echo "::endgroup::"
done

# Sweep up any remaining branches on the corpus repo. After this point all
# open PRs have been closed, merged, or deferred to the next run. Closed-PR
# branches stick around because `gh pr close` doesn't delete them, and
# any abandoned ci-bot branches accumulate too. Master is the only branch
# we want to keep.
echo "::group::Cleanup stale branches"
git fetch --quiet --prune origin
mapfile -t STALE_BRANCHES < <(
    git for-each-ref --format='%(refname:short)' refs/remotes/origin/ \
        | sed 's|^origin/||' \
        | grep -vxF master \
        | grep -vxF HEAD
)
if [ ${#STALE_BRANCHES[@]} -eq 0 ]; then
    echo "No stale branches."
else
    REFSPECS=()
    for B in "${STALE_BRANCHES[@]}"; do
        [ -n "$B" ] && REFSPECS+=(":refs/heads/$B")
    done
    echo "Deleting ${#REFSPECS[@]} branches: ${STALE_BRANCHES[*]}"
    git push origin "${REFSPECS[@]}" || echo "Some branch deletions failed."
fi
echo "::endgroup::"
