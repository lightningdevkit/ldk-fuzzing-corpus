#!/bin/bash
# Iterate every open PR, validate it, and either merge or close. Designed
# to run in a GitHub Actions job with `gh` and `jq` available and `GH_TOKEN`
# (or `GITHUB_TOKEN`) set.
#
# Per-PR validation is delegated to `validate-pr.sh`, which is also wired
# up as a `pull_request_target` CI check so contributors get fast feedback.
# We re-run it here as a backstop because PRs created by `GITHUB_TOKEN`
# (i.e. the nightly minimization PR opened by `github-actions[bot]`) do not
# trigger workflows, so the per-PR CI never ran for them — the validation
# call below is the one that gates that PR.
#
# After the PR loop we sweep stale branches: anything in this repo that
# isn't `master` and isn't the head branch of a still-open PR.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git fetch --quiet origin master

mapfile -t PRS < <(gh pr list --state open --limit 1000 --json number --jq '.[].number')

if [ ${#PRS[@]} -eq 0 ]; then
    echo "No open PRs."
fi

for PR in "${PRS[@]}"; do
    echo "::group::PR #$PR"

    # Validate. `validate-pr.sh` closes the PR with a reason comment if it
    # fails, so we just need to skip the merge step on non-zero exit.
    if ! PR_NUMBER="$PR" "$SCRIPT_DIR/validate-pr.sh"; then
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
            echo "Closing #$PR: merge conflict with master"
            gh pr close "$PR" \
                --comment "Closing automatically: merge conflict with \`master\`. See [README](../blob/master/README.md#contributing)."
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

# Sweep up branches that don't belong to any still-open PR. Closed-PR
# branches stick around because `gh pr close` doesn't delete them, and
# abandoned ci-bot branches accumulate too. Branches of PRs we left open
# above (e.g. transient UNKNOWN mergeability, or the freshly-created
# minimization PR if process-prs is run after minimize for some reason)
# are preserved.
echo "::group::Cleanup stale branches"
mapfile -t OPEN_PR_BRANCHES < <(
    gh pr list --state open --limit 1000 \
        --json headRefName,headRepository \
        --jq ".[] | select(.headRepository.nameWithOwner == \"$REPO\") | .headRefName"
)
git fetch --quiet --prune origin
mapfile -t REMOTE_BRANCHES < <(
    git for-each-ref --format='%(refname:short)' refs/remotes/origin/ \
        | sed 's|^origin/||' \
        | grep -vxF master \
        | grep -vxF HEAD
)

STALE_BRANCHES=()
for B in "${REMOTE_BRANCHES[@]}"; do
    [ -n "$B" ] || continue
    keep=0
    for OPB in ${OPEN_PR_BRANCHES[@]+"${OPEN_PR_BRANCHES[@]}"}; do
        if [ "$B" = "$OPB" ]; then
            keep=1
            break
        fi
    done
    [ "$keep" -eq 0 ] && STALE_BRANCHES+=("$B")
done

if [ ${#STALE_BRANCHES[@]} -eq 0 ]; then
    echo "No stale branches."
else
    REFSPECS=()
    for B in "${STALE_BRANCHES[@]}"; do
        REFSPECS+=(":refs/heads/$B")
    done
    echo "Deleting ${#REFSPECS[@]} branches: ${STALE_BRANCHES[*]}"
    git push origin "${REFSPECS[@]}" || echo "Some branch deletions failed."
fi
echo "::endgroup::"
