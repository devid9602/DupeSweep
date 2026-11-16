#!/bin/bash
# protect-all-repos.sh – applies the same security rules to every repository you own on GitHub.
#
#   bash protect-all-repos.sh            preview only: shows what would change, changes nothing
#   bash protect-all-repos.sh --apply    makes the changes
#
# Needs the GitHub CLI (https://cli.github.com), signed in with:  gh auth login
# Safe to run more than once: existing rules are updated, not duplicated.
# Works with the bash that ships with macOS (3.2), and on Linux and Windows (Git Bash).

set -u
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

command -v gh > /dev/null 2>&1 || { echo "The GitHub CLI isn't installed. Get it from https://cli.github.com and run: gh auth login"; exit 1; }
gh auth status > /dev/null 2>&1 || { echo "You're not signed in. Run: gh auth login"; exit 1; }

OWNER=$(gh api user --jq .login) || exit 1
OWNER_ID=$(gh api user --jq .id) || exit 1
REPOS=$(gh repo list "$OWNER" --source --no-archived --limit 200 --json name --jq '.[].name') || exit 1
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0
CHANGES=0

BRANCH_RULESET="Protect main and develop"
TAG_RULESET="Protect release tags"
# Repositories whose automated checks must pass before a pull request can merge.
DUPESWEEP_CHECKS='"test (ubuntu-latest)","test (windows-latest)","test (macos-latest)","dependency-audit","Analyze (python)","Analyze (actions)","dependency-review"'

# ---------------------------------------------------------------- helpers

# run "description" command args…   – runs only with --apply, otherwise prints the plan.
run() {
  local desc="$1"
  shift
  CHANGES=$((CHANGES + 1))
  if [ "$APPLY" = 1 ]; then
    local out
    if out=$("$@" 2>&1); then
      echo "   ✓ $desc"
      return 0
    fi
    echo "   ✗ $desc – $(echo "$out" | tail -1)"
    FAILS=$((FAILS + 1))
    return 1
  fi
  echo "   • would: $desc"
  return 0
}

branch_ruleset_json() {   # $1 = repo name
  local checks=""
  if [ "$1" = "DupeSweep" ]; then
    local list
    list=$(echo "$DUPESWEEP_CHECKS" | sed 's/"\([^"]*\)"/{ "context": "\1" }/g')   # "a","b" -> { "context": "a" },{ "context": "b" }
    checks=',
    { "type": "required_status_checks", "parameters": { "strict_required_status_checks_policy": true, "do_not_enforce_on_create": false, "required_status_checks": ['"$list"'] } }'
  fi
  cat << EOF
{
  "name": "$BRANCH_RULESET",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH", "refs/heads/main", "refs/heads/develop"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request" } ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": { "required_approving_review_count": 1, "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": true, "require_last_push_approval": true, "required_review_thread_resolution": true,
        "allowed_merge_methods": ["merge", "squash"] } }$checks
  ]
}
EOF
}

tag_ruleset_json() {
  cat << EOF
{
  "name": "$TAG_RULESET",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ],
  "rules": [ { "type": "creation" }, { "type": "update" }, { "type": "deletion" }, { "type": "non_fast_forward" } ]
}
EOF
}

# upsert_ruleset repo name jsonfile – creates the ruleset, or updates it if it already exists.
upsert_ruleset() {
  local repo="$1" name="$2" file="$3" id
  id=$(gh api "repos/$OWNER/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2> /dev/null | head -1)
  if [ -n "$id" ]; then
    run "update ruleset \"$name\"" gh api -X PUT "repos/$OWNER/$repo/rulesets/$id" --input "$file" --silent
  else
    run "create ruleset \"$name\"" gh api -X POST "repos/$OWNER/$repo/rulesets" --input "$file" --silent
  fi
}

# ---------------------------------------------------------------- per repository

protect_repo() {
  local R="$1" DEF b branches rs_ok=1
  DEF=$(gh api "repos/$OWNER/$R" --jq .default_branch)
  echo ""
  echo "=== $OWNER/$R   (default branch: $DEF)"

  # Current state, so the preview shows what is there today.
  echo "   Current rulesets:"
  local current
  current=$(gh api "repos/$OWNER/$R/rulesets" --jq '.[] | "     - \(.name) (\(.target), id \(.id))"' 2> /dev/null) || current="     (could not read)"
  echo "${current:-     (none)}"
  branches=""
  for b in "$DEF" main develop; do
    case " $branches " in *" $b "*) continue ;; esac
    gh api "repos/$OWNER/$R/branches/$b" --silent > /dev/null 2>&1 && branches="$branches $b"
  done
  for b in $branches; do
    if gh api "repos/$OWNER/$R/branches/$b/protection" --silent > /dev/null 2>&1; then
      echo "   Classic branch protection on: $b"
    fi
  done

  # 1. Security features
  run "turn on Dependabot alerts" gh api -X PUT "repos/$OWNER/$R/vulnerability-alerts" --silent
  run "turn on Dependabot security updates" gh api -X PUT "repos/$OWNER/$R/automated-security-fixes" --silent
  run "turn on private vulnerability reporting" gh api -X PUT "repos/$OWNER/$R/private-vulnerability-reporting" --silent
  printf '%s' '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}' > "$TMP/sec.json"
  run "turn on secret scanning and push protection" gh api -X PATCH "repos/$OWNER/$R" --input "$TMP/sec.json" --silent

  # 2. Pull request settings
  printf '%s' '{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":false,"delete_branch_on_merge":true,"allow_update_branch":true,"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"PR_BODY"}' > "$TMP/merge.json"
  run "allow squash and merge commits only, delete merged branches" gh api -X PATCH "repos/$OWNER/$R" --input "$TMP/merge.json" --silent

  # 3. GitHub Actions
  run "make the workflow token read-only by default" \
    gh api -X PUT "repos/$OWNER/$R/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false --silent
  run "require your approval before outside contributors' workflows run" \
    gh api -X PUT "repos/$OWNER/$R/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors --silent

  # 4. Rulesets
  branch_ruleset_json "$R" > "$TMP/branch.json"
  tag_ruleset_json > "$TMP/tag.json"
  upsert_ruleset "$R" "$BRANCH_RULESET" "$TMP/branch.json" || rs_ok=0
  upsert_ruleset "$R" "$TAG_RULESET" "$TMP/tag.json" || rs_ok=0

  # 5. Retire the old rules – only once the new rulesets are in place.
  if [ "$rs_ok" = 1 ]; then
    for b in $branches; do
      if gh api "repos/$OWNER/$R/branches/$b/protection" --silent > /dev/null 2>&1; then
        run "remove classic branch protection on $b (replaced by the ruleset)" gh api -X DELETE "repos/$OWNER/$R/branches/$b/protection" --silent
      fi
    done
    gh api "repos/$OWNER/$R/rulesets" --jq ".[] | select(.target == \"branch\" and .name != \"$BRANCH_RULESET\") | \"\(.id)|\(.name)\"" 2> /dev/null > "$TMP/old.txt"
    while IFS='|' read -r oid oname; do
      [ -n "$oid" ] && run "delete old branch ruleset \"$oname\"" gh api -X DELETE "repos/$OWNER/$R/rulesets/$oid" --silent
    done < "$TMP/old.txt"
  else
    echo "   ! kept the old branch protection because a new ruleset failed"
  fi

  # 6. DupeSweep only: release approval and locked-down Actions
  if [ "$R" = "DupeSweep" ]; then
    printf '{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":%s}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' "$OWNER_ID" > "$TMP/env.json"
    run "create the \"release\" environment that needs your approval" gh api -X PUT "repos/$OWNER/$R/environments/release" --input "$TMP/env.json" --silent
    if ! gh api "repos/$OWNER/$R/environments/release/deployment-branch-policies" --jq '.branch_policies[] | select(.type == "tag") | .name' 2> /dev/null | grep -qx 'v\*'; then
      run "allow releases only from v* tags" gh api -X POST "repos/$OWNER/$R/environments/release/deployment-branch-policies" -f name='v*' -f type=tag --silent
    fi
    printf '%s' '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}' > "$TMP/actions.json"
    run "allow only GitHub's own actions and Scorecard, pinned to exact commits" gh api -X PUT "repos/$OWNER/$R/actions/permissions" --input "$TMP/actions.json" --silent
    printf '%s' '{"github_owned_allowed":true,"verified_allowed":false,"patterns_allowed":["ossf/scorecard-action@*"]}' > "$TMP/sel.json"
    run "set the allowed actions list" gh api -X PUT "repos/$OWNER/$R/actions/permissions/selected-actions" --input "$TMP/sel.json" --silent
  fi
}

echo "GitHub account: $OWNER"
echo "Repositories:   $(echo "$REPOS" | tr '\n' ' ')"
[ "$APPLY" = 1 ] && echo "Mode:           APPLY – making changes" || echo "Mode:           PREVIEW – nothing will be changed"

for R in $REPOS; do
  protect_repo "$R"
done

echo ""
if [ "$APPLY" = 1 ]; then
  echo "Done: $CHANGES changes attempted, $FAILS failed."
  if [ "$FAILS" -gt 0 ]; then
    echo "Lines marked ✗ didn't apply – send this output to get them fixed."
    exit 1
  fi
else
  echo "Preview complete: $CHANGES changes planned. Nothing was changed."
  echo "To apply them, run:  bash protect-all-repos.sh --apply"
fi
exit 0
