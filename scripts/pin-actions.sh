#!/usr/bin/env bash
# Pin GitHub Actions to commit SHAs.
#
# `uses: actions/checkout@v4` resolves a MUTABLE tag. Whoever controls that
# repo can repoint v4 at any commit, and your next CI run executes it with
# whatever permissions the workflow holds — for the apply job, that's write
# access to your infrastructure. Supply chain attacks on popular actions are
# a real and recurring category.
#
# A commit SHA is immutable. The tag is preserved in a trailing comment so
# you can still tell what version you're on, and re-running this updates the
# pins to whatever the tags currently point at.
#
# Usage:  ./scripts/pin-actions.sh [--check]
#         --check  exit non-zero if anything is unpinned (for CI)

set -euo pipefail

WORKFLOW_DIR=".github/workflows"
CHECK_ONLY="${1:-}"

resolve() {
  # Resolve owner/repo@ref to a commit SHA via the public API.
  local repo="$1" ref="$2"
  curl -sf "https://api.github.com/repos/${repo}/commits/${ref}" \
    | grep -m1 '"sha"' \
    | sed -E 's/.*"sha": *"([a-f0-9]{40})".*/\1/'
}

changed=0

for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [ -e "$wf" ] || continue
  echo "→ $wf"

  # Match: uses: owner/repo@ref   (skip local ./actions and already-pinned SHAs)
  grep -oE 'uses: *[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+' "$wf" \
  | sed 's/uses: *//' | sort -u | while read -r entry; do
      repo="${entry%@*}"
      ref="${entry#*@}"

      # Already a 40-char SHA? Nothing to do.
      if [[ "$ref" =~ ^[a-f0-9]{40}$ ]]; then
        echo "    ✓ $repo already pinned"
        continue
      fi

      sha="$(resolve "$repo" "$ref" || true)"
      if [ -z "$sha" ]; then
        echo "    ✗ $repo@$ref — could not resolve" >&2
        continue
      fi

      if [ "$CHECK_ONLY" = "--check" ]; then
        echo "    ✗ $repo@$ref is unpinned (would be $sha)" >&2
        changed=1
        continue
      fi

      # Replace and append the original tag as a comment for readability.
      sed -i.bak -E "s|uses: *${repo//\//\\/}@${ref}([[:space:]]*)$|uses: ${repo}@${sha} # ${ref}|" "$wf"
      rm -f "${wf}.bak"
      echo "    → $repo@$ref  ⇒  ${sha:0:12}… # $ref"
      changed=1
    done
done

if [ "$CHECK_ONLY" = "--check" ]; then
  [ "$changed" -eq 0 ] && echo "All actions pinned." || { echo "Unpinned actions found."; exit 1; }
fi

echo
echo "Done. Review the diff before committing:  git diff $WORKFLOW_DIR"
