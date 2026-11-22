# deploy-discipline

A review-gated deploy workflow for **Next.js / Vercel / Neon / Drizzle**
projects, packaged as a Claude Code plugin. It's the JerseyOps deploy machinery
— `/deploy`, `/architect-review`, and the push gate — generalized so every
project-specific value lives in one config file instead of being baked into the
skills.

This repo is a **plugin marketplace**: one marketplace manifest plus the plugin
itself under `plugins/deploy-discipline/`.

## What you get

- **`/deploy`** — autonomous: commit → architect-review gate → test gate → build
  the committed tree → migration gate → push → confirm the Vercel deploy →
  changelog. Stops at the first gate that fails; unpushed commits stay local.
- **`/architect-review`** — spawns a fresh "Grumpy Platform Architect" subagent
  that reviews the unreviewed range against your project's rulebook plus a set of
  universal blockers, returns PASS/BLOCK, and stamps a git ref on PASS.
- **Push gate** — a `PreToolUse` hook that blocks `git push <production branch>`
  until the change since the last review has passed `/architect-review`, *once
  it's big or risky enough*. Small changes accumulate; risky paths always
  review. Fails closed.

## The two-layer design

The plugin is the **engine**; your project supplies the **content** via
`.claude/deploy.config.json`. The engine never contains a project's thresholds,
paths, provider IDs, or architecture rules — it reads them. That's what makes it
portable.

The one thing that doesn't travel is your **architecture rulebook** (the hard
rules the architect blocks on). The plugin ships the review *discipline*
(fresh subagent, verdict-first, evidence-required, blockers vs. grumbles) and a
slot — `review.rulebook` — pointing at the file that holds your project's laws
(your `CLAUDE.md`). Each project brings its own rules.

## Install

```bash
# from the Claude Code CLI, after pushing this repo to GitHub:
/plugin marketplace add <your-org>/joshking-plugins
/plugin install deploy-discipline@joshking-plugins
```

Then, in each project you want it on:

```bash
mkdir -p .claude
cp "$(find ~/.claude -name deploy.config.example.json | head -1)" .claude/deploy.config.json
# edit .claude/deploy.config.json for this project
```

Requires `jq`, `git`, and (for the Vercel confirm step) the Vercel MCP server.

## Configure

See `plugins/deploy-discipline/deploy.config.example.json` — it's a fully
worked JerseyOps example with a `$comment` on every block. The shape:

| Block | What it controls |
|---|---|
| `gate` | `lineThreshold`, `riskyPaths[]`, `riskyPatterns[]`, `uncounted[]`, `defaultRiskyPaths`, `defaultRiskyPatterns` — the push gate |
| `commit` | commit `types[]`, `attribution` line |
| `review` | `rulebook` — the file the architect treats as law |
| `test` | `command`, `e2eCommand`, `baseline` |
| `build` | `command`, `envFile` (copied in for a prod-faithful build) |
| `migrate` | migration commands + `schemaPaths[]`; omit the block entirely if you have no migrations |
| `deploy` | `productionBranch`, `provider`, Vercel IDs, `productionUrl` |
| `changelog` | `path`; omit to skip the changelog phase |

Omit any key to fall back to the engine's built-in default (defined in
`hooks/architect-review-gate.sh` for `gate`, and described in the skills for the
rest). `riskyPaths` and `uncounted` are POSIX-ERE regex fragments; the engine
anchors them (`^(...)` and `(...)` respectively).

## How the gate decides

On every `git push` touching the production branch, the hook computes the range
since the last reviewed commit (`refs/architect-review/reviewed`, or the merge
base with `origin/<productionBranch>`), then requires a review when any of these
is true:

- a changed file matches an **always-review path**: the built-in list (request
  handlers under `api/`, `routes/`, `controllers/`; the data layer under `db/`,
  `models/`, `queries/`; migrations; schema files; middleware; any file or folder
  named for auth, sessions, roles, tenants, payments, billing, pricing, refunds,
  webhooks, secrets or tokens; CI, `.claude/`, `package.json`, `.env*`, build
  config) plus anything in `gate.riskyPaths`;
- an **added line** matches an always-review pattern: the built-in list (`sql.raw`,
  `eval`/`exec`/`child_process`, `dangerouslySetInnerHTML`, live API keys and
  private keys, `it.skip`/`.only`, `DROP`/`TRUNCATE`, `eslint-disable`,
  `@ts-ignore`, `--no-verify`) plus anything in `gate.riskyPatterns`. Test files
  count here, so a skipped test can't slip through as "uncounted";
- counted lines (added+deleted, excluding `gate.uncounted`) reach
  `gate.lineThreshold`.

Otherwise the push is allowed. Project config adds to the built-in lists; set
`gate.defaultRiskyPaths` or `gate.defaultRiskyPatterns` to `false` to drop one.
`bash plugins/deploy-discipline/tests/gate.test.sh` checks the decisions.

A PASS stamps the ref to HEAD; the next push only reviews what's new since. Every
decision is logged to `.git/architect-review.log`.

## Not included / known limits (v0.2)

- **Stack-flavored, not stack-agnostic.** Build/test/migrate are shell commands
  in config, so other stacks mostly work, but Phase 6 confirmation assumes
  Vercel. Non-Vercel providers fall back to "report the SHA, user confirms."
- The architect's universal blockers are a floor, not your full rulebook. Since
  v0.2 that floor includes any correctness bug the reviewer can show with a
  concrete triggering input. The
  real enforcement is whatever `review.rulebook` points at.
- The gate only stops pushes Claude runs (it's a Claude Code hook). A `git push`
  you type, or one from CI, isn't gated. Add a required CI check for that.
- `${CLAUDE_PLUGIN_ROOT}` is used to locate the gate script from the skills; if
  your shell doesn't have it set, the skills fall back to a `find` under
  `~/.claude`.
