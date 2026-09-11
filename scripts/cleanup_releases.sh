#!/bin/bash
set -euo pipefail
CURRENT_TAG="v$(tr -d '[:space:]' < VERSION)"
for RELEASE_ID in $(gh api --paginate "repos/$GITHUB_REPOSITORY/releases" --jq ".[] | select(.tag_name != \"$CURRENT_TAG\") | .id"); do
  gh api --method DELETE "repos/$GITHUB_REPOSITORY/releases/$RELEASE_ID"
done
