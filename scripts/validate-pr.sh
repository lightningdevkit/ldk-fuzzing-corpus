#!/bin/bash
# Validate a single pull request against the corpus rules. Closes the PR
# with a comment if invalid; exits non-zero. Exits 0 on valid.
#
# Used by:
#   * `.github/workflows/pr-validation.yml` — runs on every PR via
#     `pull_request_target`, so the workflow file and this script always come
#     from base (`master`), not from the PR branch. A PR cannot bypass
#     validation by editing either file.
#   * `scripts/manage-prs.sh` — nightly backstop. PRs created with
#     `GITHUB_TOKEN` (the corpus minimization PR) don't trigger
#     `pull_request_target` workflows, so the bot's PR is validated here.
#
# Validation rules (any failure closes the PR):
#   * No file may live under a directory whose name starts with `.` (e.g.
#     `.github/`). Filenames may begin with `.` (this allows `.gitkeep`
#     markers in otherwise-empty target folders).
#   * Every changed file must live exactly at `rust-lightning/<target>/<file>`
#     where `<target>` already exists on master.
#   * For PRs from `github-actions[bot]` (the nightly minimization PR),
#     every git-diff status (`added`, `removed`, `modified`, `renamed`,
#     `copied`, `changed`) is allowed as long as the file lives at a valid
#     corpus path. For all other authors, only `added` is accepted.

set -euo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
PR="${PR_NUMBER:?PR_NUMBER must be set}"

git fetch --quiet origin master
mapfile -t MASTER_DIRS < <(git ls-tree -dr --name-only origin/master)

dir_exists_on_master() {
    local target="$1"
    for d in "${MASTER_DIRS[@]}"; do
        [ "$d" = "$target" ] && return 0
    done
    return 1
}

# Returns 0 iff any *directory* segment of the path begins with `.`.
# The basename is intentionally exempt so `.gitkeep` is permitted.
path_has_dot_dir() {
    local path="$1"
    local dir
    dir=$(dirname "$path")
    [ "$dir" = "." ] && return 1
    case "/$dir/" in
        */.*) return 0 ;;
    esac
    return 1
}

close_pr() {
    local reason="$1"
    echo "Closing #$PR: $reason"
    gh pr close "$PR" \
        --comment "Closing automatically: $reason. See [README](../blob/master/README.md#contributing)."
}

PR_AUTHOR=$(gh api "repos/$REPO/pulls/$PR" --jq '.user.login')
case "$PR_AUTHOR" in
    "github-actions[bot]") IS_GHA_BOT=1 ;;
    *)                     IS_GHA_BOT=0 ;;
esac
echo "PR #$PR author: $PR_AUTHOR (gha-bot=$IS_GHA_BOT)"

FILES_JSON=$(gh api --paginate "repos/$REPO/pulls/$PR/files?per_page=100" | jq -s 'add')
NUM_FILES=$(echo "$FILES_JSON" | jq 'length')
echo "$NUM_FILES changed files"

if [ "$NUM_FILES" -gt 3000 ]; then
    close_pr "PR changes too many files ($NUM_FILES) for automated review"
    exit 1
fi

BAD_REASON=""
while IFS=$'\t' read -r STATUS FILENAME; do
    if path_has_dot_dir "$FILENAME"; then
        BAD_REASON="\`$FILENAME\` lives under a directory whose name starts with \`.\`"
        break
    fi
    if [ "$IS_GHA_BOT" -ne 1 ] && [ "$STATUS" != "added" ]; then
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
            BAD_REASON="\`$FILENAME\` is outside \`rust-lightning/<target>/\` — only corpus contributions are accepted"
            ;;
    esac
    [ -n "$BAD_REASON" ] && break
done < <(echo "$FILES_JSON" | jq -r '.[] | "\(.status)\t\(.filename)"')

if [ -n "$BAD_REASON" ]; then
    close_pr "$BAD_REASON"
    exit 1
fi

echo "PR #$PR validated."
