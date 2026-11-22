#!/usr/bin/env bash
# Architect review gate (deploy-discipline plugin).
#
# Pushing the production branch deploys, so it needs a passing architect review
# of everything since the last reviewed commit — once that change is big or
# risky enough. Thresholds, risky paths and the production branch are read from
# the PROJECT's .claude/deploy.config.json (see deploy.config.example.json);
# built-in defaults apply when a key is missing.
#
#   hook               PreToolUse hook (JSON on stdin); exit 2 blocks the push
#   status             prints whether HEAD needs a review, and the range to review
#   stamp              records that HEAD passed review
#   override "reason"  records the user's override of a BLOCK (only on their word)
set -uo pipefail

# ---- Built-in defaults (overridden per project by .claude/deploy.config.json) ----
DEFAULT_LINE_THRESHOLD=40
DEFAULT_RISKY='^(migrations/|src/lib/db/schema\.ts|src/lib/.*(auth|role|stripe|payment|financial).*\.ts|src/middleware\.ts|src/app/api/(payments|webhooks)/|\.github/|package\.json|next\.config\.ts|vercel\.json)'
DEFAULT_UNCOUNTED='(\.md$|^e2e/|/__tests__/|^package-lock\.json$)'
DEFAULT_BRANCH=master

REVIEW_REF=refs/architect-review/reviewed

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
LOG="$(git rev-parse --git-common-dir)/architect-review.log"
CONFIG="$(git rev-parse --show-toplevel)/.claude/deploy.config.json"

# Load config (fail-closed on a present-but-unreadable config, so a broken file
# can't silently disable the gate). A missing config just uses the defaults.
LINE_THRESHOLD=$DEFAULT_LINE_THRESHOLD
RISKY=$DEFAULT_RISKY
UNCOUNTED=$DEFAULT_UNCOUNTED
PRODUCTION_BRANCH=$DEFAULT_BRANCH

load_config() {
  [ -f "$CONFIG" ] || return 0
  command -v jq >/dev/null || return 1
  jq -e . "$CONFIG" >/dev/null 2>&1 || return 1

  local v
  v=$(jq -r '.gate.lineThreshold // empty' "$CONFIG"); [ -n "$v" ] && LINE_THRESHOLD=$v
  v=$(jq -r '.deploy.productionBranch // empty' "$CONFIG"); [ -n "$v" ] && PRODUCTION_BRANCH=$v

  # riskyPaths: array of regex fragments → ^(frag|frag|...). Empty array → match nothing.
  if jq -e '.gate.riskyPaths | type == "array"' "$CONFIG" >/dev/null 2>&1; then
    local joined
    joined=$(jq -r '.gate.riskyPaths | join("|")' "$CONFIG")
    if [ -n "$joined" ]; then RISKY="^($joined)"; else RISKY='$^'; fi
  fi
  # uncounted: array of regex fragments → (frag|frag|...).
  if jq -e '.gate.uncounted | type == "array"' "$CONFIG" >/dev/null 2>&1; then
    local joined
    joined=$(jq -r '.gate.uncounted | join("|")' "$CONFIG")
    [ -n "$joined" ] && UNCOUNTED="($joined)"
  fi
  return 0
}

export UNCOUNTED  # the awk below reads it from the environment

# The last reviewed commit if HEAD builds on it, else where HEAD left the production branch.
baseline() {
  local ref
  ref=$(git rev-parse -q --verify "$REVIEW_REF" 2>/dev/null)
  if [ -n "$ref" ] && git merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
    echo "$ref"
  else
    git merge-base "origin/$PRODUCTION_BRANCH" HEAD 2>/dev/null
  fi
}

# Sets BASE, LINES, RISKY_FILES, REQUIRED.
decide() {
  BASE=$(baseline)
  if [ -z "$BASE" ]; then REQUIRED=yes; LINES=0; RISKY_FILES=""; return; fi
  LINES=$(git diff --numstat "$BASE" HEAD |
    awk '$1 != "-" && $3 !~ ENVIRON["UNCOUNTED"] { n += $1 + $2 } END { print n + 0 }')
  RISKY_FILES=$(git diff --name-only "$BASE" HEAD | grep -E "$RISKY" || true)
  if [ -n "$RISKY_FILES" ] || [ "$LINES" -ge "$LINE_THRESHOLD" ]; then REQUIRED=yes; else REQUIRED=no; fi
}

print_status() {
  echo "required: $REQUIRED"
  echo "range: ${BASE:0:7}..HEAD"
  echo "counted_lines: $LINES (threshold $LINE_THRESHOLD)"
  echo "production_branch: $PRODUCTION_BRANCH"
  if [ -n "$RISKY_FILES" ]; then
    echo "always-reviewed files touched:"
    printf '%s\n' "$RISKY_FILES" | sed 's/^/  /'
  fi
}

record() { # record PASS|OVERRIDE [reason]
  git update-ref "$REVIEW_REF" HEAD
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(git rev-parse --short HEAD)" "${2:-}" >> "$LOG"
  echo "Recorded $1 for $(git rev-parse --short HEAD)."
}

case "${1:-}" in
  hook)
    # Fail closed: a gate that can't read its inputs must not wave a push through.
    command -v jq >/dev/null || { echo "architect-review-gate: jq is not installed; install it (brew install jq / apt-get install jq)" >&2; exit 2; }
    load_config || { echo "architect-review-gate: .claude/deploy.config.json is present but unreadable/invalid; fix it or remove it" >&2; exit 2; }
    cmd=$(jq -er '.tool_input.command' 2>/dev/null) ||
      { echo "architect-review-gate: could not read the command from the hook input" >&2; exit 2; }
    # A push that starts a command (not the words inside a commit message).
    printf '%s' "$cmd" | grep -Eq '(^|[;&|(]) *git( +-[cC] +[^ ]+)* +push( |$)' || exit 0
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$branch" != "$PRODUCTION_BRANCH" ] && ! printf '%s' "$cmd" | grep -q "$PRODUCTION_BRANCH"; then exit 0; fi
    decide
    [ "$REQUIRED" = no ] && exit 0
    {
      echo "Blocked: pushing to $PRODUCTION_BRANCH deploys, and this change needs an architect review first."
      print_status
      echo "Run /architect-review. On BLOCK, fix the findings or ask the user; only the user can"
      echo "override, with: <plugin>/hooks/architect-review-gate.sh override \"<their reason>\""
    } >&2
    exit 2
    ;;
  status) load_config || { echo "architect-review-gate: config invalid" >&2; exit 1; }; decide; print_status ;;
  stamp) load_config || true; record PASS ;;
  override)
    [ -n "${2:-}" ] || { echo "override needs a reason" >&2; exit 1; }
    load_config || true
    record OVERRIDE "$2"
    ;;
  *) echo "usage: $0 hook|status|stamp|override \"reason\"" >&2; exit 1 ;;
esac
