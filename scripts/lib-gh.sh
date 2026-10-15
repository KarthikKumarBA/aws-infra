#!/usr/bin/env bash
# Shared helper: trigger a GitHub Actions workflow, wait for it, fail if it fails.
# Usage (after sourcing): run_and_wait <repo> <workflow-file> [-f key=value ...]

OWNER="${OWNER:-KarthikKumarBA}"

run_and_wait() {
  local repo="$1" wf="$2"; shift 2
  local before
  before=$(gh run list --repo "$OWNER/$repo" --workflow "$wf" --limit 1 --json databaseId --jq '.[0].databaseId // 0')
  echo "==> Triggering $repo / $wf $*"
  gh workflow run "$wf" --repo "$OWNER/$repo" --ref main "$@" || return 1
  local id=""
  for i in $(seq 1 30); do
    sleep 4
    id=$(gh run list --repo "$OWNER/$repo" --workflow "$wf" --limit 1 --json databaseId --jq '.[0].databaseId')
    [ -n "$id" ] && [ "$id" != "$before" ] && break
  done
  if [ -z "$id" ] || [ "$id" = "$before" ]; then echo "Run did not start"; return 1; fi
  echo "    Run $id: https://github.com/$OWNER/$repo/actions/runs/$id"
  gh run watch "$id" --repo "$OWNER/$repo" --exit-status --interval 15 > /dev/null
  local result=$?
  gh run view "$id" --repo "$OWNER/$repo" --json conclusion --jq '"    Result: " + .conclusion'
  if [ $result -ne 0 ]; then
    echo "    Failed step log:"
    gh run view "$id" --repo "$OWNER/$repo" --log-failed | tail -n 30
  fi
  return $result
}
