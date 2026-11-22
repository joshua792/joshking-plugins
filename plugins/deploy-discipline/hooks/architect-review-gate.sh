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

# ---- Built-in defaults ------------------------------------------------------
# A project's .claude/deploy.config.json ADDS to the default risky paths and
# patterns; it doesn't replace them. Set gate.defaultRiskyPaths or
# gate.defaultRiskyPatterns to false to drop a default list.
DEFAULT_LINE_THRESHOLD=40
DEFAULT_UNCOUNTED='(\.md$|^e2e/|/__tests__/|^package-lock\.json$)'
DEFAULT_BRANCH=master

# Paths where any change, however small, gets reviewed. ERE fragments, anchored
# as ^(a|b|...). Stack-agnostic on purpose: request handlers, the data layer,
# migrations and schema, middleware, and anything named for auth or money.
DEFAULT_RISKY_PATHS=(
  '(.*/)?migrations?/'
  '(.*/)?(api|routes|controllers|handlers|graphql|trpc)/'
  '(.*/)?(db|database|repositories|models|queries|dal)/'
  '(.*/)?schema\.[a-z]+'
  '(.*/)?middleware\.[jt]s'
  '(.*/)?[^/]*(auth|session|role|permission|acl|tenant|stripe|payment|billing|invoice|pricing|refund|payout|financial|money|ledger|webhook|secret|crypto|token)[^/]*'
  '\.github/'
  '\.claude/'
  '([^/]*/)*package\.json'
  '([^/]*/)*\.env[^/]*'
  '(.*/)?(next|vite|webpack)\.config\.[a-z]+'
  '([^/]*/)*vercel\.json'
  '([^/]*/)*Dockerfile'
)

# Code that gets reviewed wherever it appears, matched against ADDED lines only
# (test files included). Raw SQL, shell/eval, committed secrets, skipped or
# focused tests, destructive SQL, suppressed checks.
DEFAULT_RISKY_PATTERNS=(
  'sql\.raw\(|[qQ]ueryRawUnsafe|[eE]xecuteRawUnsafe'
  '(^|[^A-Za-z0-9_.])(eval|exec|execSync|spawn|spawnSync)\(|child_process|dangerouslySetInnerHTML|\.innerHTML *='
  '(sk|rk)_live_[A-Za-z0-9]{10,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abprs]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{30,}'
  '(^|[^A-Za-z0-9_])(it|test|describe)\.(skip|only|todo)\(|(^|[^A-Za-z0-9_])x(it|describe|test)\('
  '(DROP|TRUNCATE) +(TABLE|COLUMN|DATABASE|SCHEMA)|RENAME +COLUMN'
  'eslint-disable|@ts-ignore|@ts-nocheck|--no-verify'
)

REVIEW_REF=refs/architect-review/reviewed

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
LOG="$(git rev-parse --git-common-dir)/architect-review.log"
CONFIG="$(git rev-parse --show-toplevel)/.claude/deploy.config.json"

join_alt() { local IFS='|'; echo "$*"; }

# Load config (fail-closed on a present-but-unreadable config, so a broken file
# can't silently disable the gate). A missing config just uses the defaults.
LINE_THRESHOLD=$DEFAULT_LINE_THRESHOLD
UNCOUNTED=$DEFAULT_UNCOUNTED
PRODUCTION_BRANCH=$DEFAULT_BRANCH
RISKY_PATHS=("${DEFAULT_RISKY_PATHS[@]}")
RISKY_PATTERNS=("${DEFAULT_RISKY_PATTERNS[@]}")

load_config() {
  [ -f "$CONFIG" ] || return 0
  command -v jq >/dev/null || return 1
  jq -e . "$CONFIG" >/dev/null 2>&1 || return 1

  local v line
  v=$(jq -r '.gate.lineThreshold // empty' "$CONFIG"); [ -n "$v" ] && LINE_THRESHOLD=$v
  v=$(jq -r '.deploy.productionBranch // empty' "$CONFIG"); [ -n "$v" ] && PRODUCTION_BRANCH=$v

  # Opt-outs for the default lists (explicit false only).
  [ "$(jq -r '.gate.defaultRiskyPaths' "$CONFIG")" = "false" ] && RISKY_PATHS=()
  [ "$(jq -r '.gate.defaultRiskyPatterns' "$CONFIG")" = "false" ] && RISKY_PATTERNS=()

  # Project additions: riskyPaths (ERE fragments, anchored for you) and
  # riskyPatterns (ERE matched against added lines).
  if jq -e '.gate.riskyPaths | type == "array"' "$CONFIG" >/dev/null 2>&1; then
    while IFS= read -r line; do [ -n "$line" ] && RISKY_PATHS+=("$line"); done \
      < <(jq -r '.gate.riskyPaths[]' "$CONFIG")
  fi
  if jq -e '.gate.riskyPatterns | type == "array"' "$CONFIG" >/dev/null 2>&1; then
    while IFS= read -r line; do [ -n "$line" ] && RISKY_PATTERNS+=("$line"); done \
      < <(jq -r '.gate.riskyPatterns[]' "$CONFIG")
  fi
  # uncounted: array of regex fragments → (frag|frag|...). Replaces the default.
  if jq -e '.gate.uncounted | type == "array"' "$CONFIG" >/dev/null 2>&1; then
    local joined
    joined=$(jq -r '.gate.uncounted | join("|")' "$CONFIG")
    [ -n "$joined" ] && UNCOUNTED="($joined)"
  fi
  return 0
}

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

# Sets BASE, LINES, RISKY_FILES, RISKY_HITS, REQUIRED.
decide() {
  local risky_re='$^' pattern_re='$^'
  [ ${#RISKY_PATHS[@]} -gt 0 ] && risky_re="^($(join_alt "${RISKY_PATHS[@]}"))"
  [ ${#RISKY_PATTERNS[@]} -gt 0 ] && pattern_re="($(join_alt "${RISKY_PATTERNS[@]}"))"
  export UNCOUNTED PATTERN_RE="$pattern_re"  # the awk below reads them from the environment

  BASE=$(baseline)
  if [ -z "$BASE" ]; then REQUIRED=yes; LINES=0; RISKY_FILES=""; RISKY_HITS=""; return; fi
  LINES=$(git diff --numstat "$BASE" HEAD |
    awk '$1 != "-" && $3 !~ ENVIRON["UNCOUNTED"] { n += $1 + $2 } END { print n + 0 }')
  RISKY_FILES=$(git diff --name-only "$BASE" HEAD | grep -E "$risky_re" || true)
  # First added line per file that matches a risky pattern: "path: line".
  RISKY_HITS=$(git diff -U0 --no-color "$BASE" HEAD |
    awk '/^\+\+\+ / { f = substr($0, 7); next }
         /^\+/ && f != "" && substr($0, 2) ~ ENVIRON["PATTERN_RE"] && !(f in seen) {
           seen[f] = 1; l = substr($0, 2); gsub(/^[ \t]+/, "", l); print f ": " substr(l, 1, 100) }')
  if [ -n "$RISKY_FILES" ] || [ -n "$RISKY_HITS" ] || [ "$LINES" -ge "$LINE_THRESHOLD" ]; then
    REQUIRED=yes
  else
    REQUIRED=no
  fi
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
  if [ -n "$RISKY_HITS" ]; then
    echo "always-reviewed code added:"
    printf '%s\n' "$RISKY_HITS" | sed 's/^/  /'
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
