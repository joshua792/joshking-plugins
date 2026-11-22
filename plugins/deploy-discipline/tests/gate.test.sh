#!/usr/bin/env bash
# Tests for hooks/architect-review-gate.sh decisions. No network; builds a
# throwaway repo in a temp dir. Run: bash plugins/deploy-discipline/tests/gate.test.sh
set -uo pipefail

GATE="$(cd "$(dirname "$0")/.." && pwd)/hooks/architect-review-gate.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

setup() { # fresh repo with origin/master at one commit
  rm -rf "$TMP/r" "$TMP/o.git"
  git init -q --bare -b master "$TMP/o.git"
  git init -q -b master "$TMP/r"
  cd "$TMP/r" || exit 1
  git config user.name t; git config user.email t@example.invalid; git config commit.gpgsign false
  mkdir -p src/components src/lib .claude
  echo "export const x = 1;" > src/lib/util.ts
  git add -A; git commit -qm base
  git remote add origin "$TMP/o.git"; git -c push.negotiate=false push -q origin master; git fetch -q origin
}

change() { # change <path> <content>; commits it
  mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; git add -A; git commit -qm change
}

expect() { # expect yes|no <label>
  local got; got=$(bash "$GATE" status 2>&1 | sed -n 's/^required: //p')
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $2 (want $1, got ${got:-error})"; bash "$GATE" status; fi
}

setup; change src/components/Button.tsx 'export const Button = () => null;';  expect no  "small UI change"
setup; change docs/notes.md 'hello';                                         expect no  "docs only"
setup; change src/lib/format.ts 'export const f = (s: string) => s.trim();'; expect no  "small util"
setup; change src/app/api/orders/route.ts 'export async function GET() {}';  expect yes "Next.js API route"
setup; change src/routes/users.js 'module.exports = {};';                    expect yes "Express-style routes dir"
setup; change src/lib/db/orders.ts 'export const q = 1;';                    expect yes "data layer"
setup; change src/lib/pricing.ts 'export const tax = 0.08;';                 expect yes "money-named file"
setup; change prisma/schema.prisma 'model A { id Int @id }';                 expect yes "schema file"
setup; change src/components/Box.tsx '// eslint-disable-next-line';         expect yes "suppressed lint in UI"
setup; change src/lib/__tests__/u.test.ts 'it.skip("x", () => {});';        expect yes "skipped test"
setup; change src/lib/k.ts 'const k = "sk_live_abcdefghijklmnop";';          expect yes "live key in a util"
setup; change src/lib/q.ts 'db.execute(sql.raw(`x ${y}`));';                 expect yes "sql.raw in a util"
setup; change src/lib/q.ts 'await db.execute(sql`select ${y}`);';            expect no  "parameterized sql in a util"

setup; echo '{"gate":{"riskyPaths":["src/components/"]}}' > .claude/deploy.config.json; git add -A; git commit -qm cfg -q
git -c push.negotiate=false push -q origin master; git fetch -q origin
change src/components/Card.tsx 'export const Card = 1;';                     expect yes "project riskyPaths adds a path"
change src/lib/db/x.ts 'export const y = 2;';                                expect yes "defaults still apply with project paths"

setup; echo '{"gate":{"defaultRiskyPaths":false}}' > .claude/deploy.config.json; git add -A; git commit -qm cfg -q
git -c push.negotiate=false push -q origin master; git fetch -q origin
change src/lib/db/x.ts 'export const y = 2;';                                expect no  "defaultRiskyPaths:false opts out"

setup; echo '{"gate":{"riskyPatterns":["TODO\\(security\\)"]}}' > .claude/deploy.config.json; git add -A; git commit -qm cfg -q
git -c push.negotiate=false push -q origin master; git fetch -q origin
change src/lib/a.ts '// TODO(security) revisit';                             expect yes "project riskyPatterns adds a pattern"

setup; echo '{not json' > .claude/deploy.config.json; git add -A; git commit -qm cfg -q
git -c push.negotiate=false push -q origin master; git fetch -q origin
out=$(echo '{"tool_input":{"command":"git push origin master"}}' | bash "$GATE" hook 2>&1); code=$?
if [ $code -eq 2 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: broken config must block (exit $code): $out"; fi

echo "gate tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
