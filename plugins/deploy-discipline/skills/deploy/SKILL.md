---
name: deploy
description: Commit the change, run the architect-review gate, run tests, build the committed tree, apply migrations if needed, push to the production branch only if everything passes, confirm the deploy, and append to the changelog.
disable-model-invocation: true
argument-hint: "[optional commit message] [--full-e2e] [--no-e2e]"
---

# Deploy

Pushing the production branch deploys to production (Vercel). This skill only
pushes code that passed its tests and built on its own.

**AUTONOMOUS EXECUTION**: run every phase in order without pausing or asking
"should I continue?". Stop only at a **GATE** that fails or at Completion. When a
gate fails, commits stay local and unpushed — report what failed and stop.

## Phase 0: Load config

Read `.claude/deploy.config.json` at the repo root. Everything below reads from
it:
- `deploy.productionBranch`, `deploy.provider`, `deploy.vercelProjectId`,
  `deploy.vercelTeamId`, `deploy.productionUrl`
- `commit.types`, `commit.attribution`
- `test.command`, `test.e2eCommand`, `test.baseline`
- `build.command`, `build.envFile`
- `migrate.*` (whole block may be absent)
- `changelog.path` (may be absent)
- `review.rulebook`

If there's no config file, stop and tell the user to copy
`deploy.config.example.json` from the plugin into `.claude/deploy.config.json`.
Set `GATE="${CLAUDE_PLUGIN_ROOT}/hooks/architect-review-gate.sh"` (fallback:
`find ~/.claude -name architect-review-gate.sh 2>/dev/null | head -1`).

All commands run from the repo root.

## Phase 1: Pick what ships

1. `git status --short`, `git diff`, `git diff --cached`, and
   `git log origin/<productionBranch>..HEAD --oneline` (local commits not yet
   pushed — they ship too; list them in the report).
2. Nothing changed and nothing unpushed → "Nothing to deploy" and stop.
3. Decide which files belong to **this** change (from the conversation and
   `$ARGUMENTS`). The working tree may hold other sessions' unfinished work —
   **never stage files you can't attribute to this change**. If you can't tell,
   stop and list the ambiguous files.
4. A file mixing this change with unrelated edits: never stage hunks with
   `git diff -U0` + `git apply --unidiff-zero` (it misplaces lines). Rebuild the
   file from HEAD with only this change applied, then stage it.
5. Never stage `.env*`, secrets, `node_modules/`, `.next*/`, build output,
   `test-results/`, `playwright-report/`, or any temp build dir.

## Phase 2: Commit (local only)

Stage with explicit paths (never `git add -A` / `git add .`) and commit:

```
<type>(<area>): <summary under 72 chars>

<what changed and why, wrapped at 72>

<commit.attribution>
```

`<type>` ∈ `commit.types`. Use `$ARGUMENTS` as the basis for the message.

## Phase 2b: Architect review — GATE

Run the `/architect-review` skill. It decides from `"$GATE" status` whether a
review is due (always for `gate.riskyPaths`; otherwise once `gate.lineThreshold`
counted lines have accumulated) and, if so, reviews the whole unreviewed range.

- Skipped (below threshold) or **PASS** → continue. Note the result for the
  changelog.
- **BLOCK → stop.** Do not push. Report the blockers and their fixes. The push
  in Phase 5 is blocked by the hook until this passes, so don't skip it.

## Phase 3: Test — GATE

Prefer the project's own `/test` skill if one exists; otherwise run
`test.command` (and `test.e2eCommand` for affected areas). Run it in a subagent
(Agent tool, general-purpose) so its output doesn't flood this conversation.
Honor `--full-e2e` / `--no-e2e` from `$ARGUMENTS`. Tests run against a non-prod
database/branch — never production.

- New or updated test files → stage by path and commit `test: <what was
  covered>` with the attribution line.
- **Verdict FAIL → stop.** Only failures new compared with `test.baseline` fail
  the gate; pre-existing failures and known-flaky tests don't (list them anyway).

## Phase 4: Build the committed tree — GATE

The working tree may contain unshipped work, so build exactly what will be
pushed:

```bash
rm -rf .tmp-head && mkdir .tmp-head
git archive HEAD | tar -x -C .tmp-head
# if build.envFile is set, copy it in as .env.local for a production-faithful build:
cp <build.envFile> .tmp-head/.env.local 2>/dev/null || true
(cd .tmp-head && <build.command>)
# (run Phase 4b's production migration here, inside .tmp-head, if applicable)
rm -rf .tmp-head        # it may hold a copy of secrets
```

Run the build in a subshell so the shell isn't left inside `.tmp-head`. Don't
link the real `node_modules` into it — `.tmp-head` sits inside the repo so
imports resolve from the parent. **Build fails → stop.**

## Phase 4b: Database migrations — GATE

Only if `migrate` is configured AND the commits touch `migrate.schemaPaths`.
Production must have the schema change **before** the code goes live.

1. A schema change with no new migration file → stop and report.
2. If `migrate.requireAdditive`, each new migration must be additive
   (`CREATE … IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`). Anything that drops,
   renames or rewrites data → stop and ask.
3. e2e/staging first: `migrate.e2eCommand`.
4. Production, **from the committed tree** (`.tmp-head`, so the SQL matches what
   ships): `migrate.command`. Only once the user has approved production
   migrations for this deploy (ask once if not; "run it at deploy" counts).
5. `migrate.statusCommand` on both → `pending: 0` and no "edited after applying"
   lines. Run it on every deploy, even without schema changes: it catches
   migrations someone else added but never applied.

## Phase 5: Push

`git push origin <productionBranch>`. Never force-push.
- Rejected because the remote moved → stop and report; don't rebase or merge
  without the user.
- Auth failure → report and stop.

## Phase 6: Confirm the deploy

If `deploy.provider` is `vercel`: use the Vercel MCP tools with
`deploy.vercelProjectId` / `deploy.vercelTeamId`. `list_deployments` filtered by
the pushed SHA, then `get_deployment` until `READY` or `ERROR` (builds take a
few minutes; wait with a background `sleep`, not a foreground loop).
- `READY` → note the production aliases / `deploy.productionUrl`.
- `ERROR` → pull the build logs, report the error. Production keeps serving the
  previous deployment; ask before rolling back or pushing a fix.

(Other providers: run the project's documented confirm step, or report the
pushed SHA and let the user confirm.)

## Phase 7: Changelog

If `changelog.path` is set, append to the end of that file:

```markdown
### <YYYY-MM-DD>
- **Commit**: `<7-char hash>` — <summary>
- **Changes**: <1–2 sentences>
- **Tests**: <suites + counts>
- **Architect review**: <PASS | skipped (N lines) | override — reason>
- **Files**: <changed files>
```

Same date already present → `### <date> (2)`. Commit `docs: changelog for
<summary>` (attribution line) and push. Docs-only; no test or build gate.

## Completion

Report: commits shipped (hash + subject, including earlier unpushed ones); the
test table; build result; deploy state + URL; files deliberately left
uncommitted (other work in the tree).
