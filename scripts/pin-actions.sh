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
# you can still tell what version you're on, and re-running this re-resolves
# that tag and updates the pin if it has moved.
#
# Usage:  ./scripts/pin-actions.sh [--check]
#         --check  exit non-zero if anything is unpinned or stale (for CI)
#
# Set GITHUB_TOKEN to raise the anonymous API rate limit (60/hr).

set -euo pipefail

WORKFLOW_DIR=".github/workflows"
CHECK_ONLY="${1:-}"

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "No $WORKFLOW_DIR — run this from the repository root." >&2
  exit 1
fi

# Resolutions are cached so a repo used by several steps costs one API call.
# Two parallel indexed arrays rather than an associative array, which bash 3.2
# does not have.
cache_keys=()
cache_vals=()

cache_get() {
  local i=0
  while [ "$i" -lt "${#cache_keys[@]}" ]; do
    if [ "${cache_keys[$i]}" = "$1" ]; then
      printf '%s' "${cache_vals[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

api() {
  # NOTE: do NOT build the auth header in an array and expand it as
  # "${auth[@]}". Under `set -u`, bash 3.2 — which is what /bin/bash still is
  # on macOS — treats the expansion of an EMPTY array as an unbound variable
  # and aborts. Inside a command substitution that kills the subshell, which
  # surfaces as every single action failing to resolve. Branch instead.
  local url="$1"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -sS -f -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null
  else
    curl -sS -f -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null
  fi
}

# Resolve owner/repo@ref to a commit SHA. Result goes in RESOLVED_SHA rather
# than stdout, because the caller would otherwise have to invoke this as
# sha="$(resolve ...)" — a command substitution, which is a subshell, which
# would discard the cache writes below exactly the way the original version
# of this script discarded its `changed` counter. Same trap, one layer down.
# Returns non-zero on failure; RESOLVED_SHA is only meaningful on success.
RESOLVED_SHA=""

resolve() {
  local repo="$1" ref="$2" key out sha
  key="${repo}@${ref}"
  RESOLVED_SHA=""

  if out="$(cache_get "$key")"; then
    RESOLVED_SHA="$out"
    return 0
  fi

  out="$(api "https://api.github.com/repos/${repo}/commits/${ref}")" || return 1

  # First "sha" in the payload is the commit's own SHA.
  sha="$(printf '%s' "$out" \
    | grep -m1 -oE '"sha"[[:space:]]*:[[:space:]]*"[a-f0-9]{40}"' \
    | grep -oE '[a-f0-9]{40}')" || return 1
  [ -n "$sha" ] || return 1

  cache_keys+=("$key")
  cache_vals+=("$sha")
  RESOLVED_SHA="$sha"
}

# Distinguishing "GitHub is rate-limiting you" from "that action does not
# exist" is the difference between waiting an hour and hunting a typo.
rate_limit_remaining() {
  api "https://api.github.com/rate_limit" 2>/dev/null \
    | grep -m1 -oE '"remaining"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' || printf 'unknown'
}

# Collect workflow files first. A glob that matches nothing expands to itself,
# so test each path exists.
files=()
for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [ -e "$wf" ] && files+=("$wf")
done

if [ "${#files[@]}" -eq 0 ]; then
  echo "No workflow files found in $WORKFLOW_DIR." >&2
  exit 1
fi

# NOTE: these counters are updated inside the loops below, which is why the
# loops must not run in a subshell. Piping into `while read` forks one and
# every increment is discarded — the previous version of this script did
# exactly that, so --check always reported success and the CI gate it was
# meant to provide was a no-op. Redirecting a file INTO the loop (`done <
# "$wf"`) reads the same content in the current shell. Avoid `mapfile` here:
# it is bash 4+, and macOS still ships bash 3.2 as /bin/bash.
stale=0
failed=0

for wf in "${files[@]}"; do
  echo "→ $wf"

  lines=()
  modified=0

  # `|| [ -n "$line" ]` catches a final line with no trailing newline.
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done < "$wf"

  for i in "${!lines[@]}"; do
    line="${lines[$i]}"

    # prefix | owner/repo | subpath | ref | trailing remainder (may hold "# tag")
    #
    # The subpath group is what makes actions living in a subdirectory work —
    # github/codeql-action/init@v3 and github/codeql-action/upload-sarif@v3
    # are four of the entries in this repo. An earlier version of this regex
    # required owner/repo to be followed immediately by "@", so those lines
    # matched nothing and were skipped in silence: never pinned, and never
    # reported by --check either. A supply-chain gate with a silent blind
    # spot is worse than no gate, because it reads as green.
    #
    # The API call still uses owner/repo — commits belong to the repository,
    # not the subdirectory — while the rewritten line keeps the full path.
    [[ "$line" =~ ^([[:space:]]*-?[[:space:]]*uses:[[:space:]]*)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)((/[A-Za-z0-9_.-]+)*)@([A-Za-z0-9_.-]+)(.*)$ ]] || continue

    prefix="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    subpath="${BASH_REMATCH[3]}"
    ref="${BASH_REMATCH[5]}"
    rest="${BASH_REMATCH[6]}"
    action="${repo}${subpath}"

    # Local actions (./.github/actions/foo) are checked out with the repo and
    # have no upstream to resolve.
    case "$repo" in
      .*|/*) continue ;;
    esac

    if [[ "$ref" =~ ^[a-f0-9]{40}$ ]]; then
      # Already pinned. Recover the tag from the trailing comment so we can
      # check whether that tag has since moved. No comment means we have no
      # way to know what it tracks — leave it alone.
      if [[ "$rest" =~ \#[[:space:]]*([A-Za-z0-9_.-]+) ]]; then
        tag="${BASH_REMATCH[1]}"
      else
        echo "    ✓ $action pinned (no tag comment, not checked)"
        continue
      fi
    else
      tag="$ref"
    fi

    # Called bare, not in a command substitution — see the note on resolve().
    if ! resolve "$repo" "$tag" || [ -z "$RESOLVED_SHA" ]; then
      echo "    ✗ $action@$tag — could not resolve" >&2
      failed=$((failed + 1))
      continue
    fi
    sha="$RESOLVED_SHA"

    if [ "$sha" = "$ref" ]; then
      echo "    ✓ $action@$tag already pinned"
      continue
    fi

    stale=$((stale + 1))

    if [ "$CHECK_ONLY" = "--check" ]; then
      if [[ "$ref" =~ ^[a-f0-9]{40}$ ]]; then
        echo "    ✗ $action is pinned to $ref but $tag now points at $sha" >&2
      else
        echo "    ✗ $action@$ref is unpinned (would be $sha)" >&2
      fi
      continue
    fi

    lines[$i]="${prefix}${action}@${sha} # ${tag}"
    modified=1
    echo "    → $action@$tag  ⇒  ${sha:0:12}… # $tag"
  done

  if [ "$modified" -eq 1 ]; then
    printf '%s\n' "${lines[@]}" > "$wf"
  fi
done

echo

if [ "$failed" -gt 0 ]; then
  remaining="$(rate_limit_remaining)"
  echo "$failed action(s) could not be resolved." >&2
  if [ "$remaining" = "0" ]; then
    echo "GitHub API rate limit is exhausted (remaining: 0). Anonymous requests" >&2
    echo "get 60/hour. Set GITHUB_TOKEN and re-run:" >&2
    echo "  export GITHUB_TOKEN=\$(gh auth token)" >&2
  elif [ "$remaining" = "unknown" ]; then
    echo "Could not reach api.github.com at all — check network access." >&2
  else
    echo "Rate limit is not the cause (remaining: $remaining), so the names above" >&2
    echo "are likely wrong or the refs no longer exist." >&2
  fi
fi

if [ "$failed" -gt 0 ] && [ "$CHECK_ONLY" = "--check" ]; then
  echo "Failing rather than passing blind." >&2
  exit 1
fi

if [ "$CHECK_ONLY" = "--check" ]; then
  if [ "$stale" -eq 0 ]; then
    echo "All actions pinned and current."
    exit 0
  fi
  echo "$stale action(s) unpinned or stale." >&2
  exit 1
fi

echo "Done. Review the diff before committing:  git diff $WORKFLOW_DIR"
