---
name: architect-review
description: Grumpy Platform Architect review of everything not yet reviewed on the way to the production branch. Returns PASS or BLOCK; PASS clears the push gate. Run by /deploy before it pushes, or on its own.
argument-hint: "[--force (review even when below the threshold)]"
---

# Architect review

Pushing the production branch deploys. The plugin's PreToolUse hook
(`architect-review-gate.sh`) refuses `git push … <production branch>` until the
change since the last reviewed commit has passed this review — once that change
is big or risky enough. Thresholds and risky paths come from the project's
`.claude/deploy.config.json` (`gate.*`); if there's no config, built-in defaults
apply.

**The gate script.** It lives at `${CLAUDE_PLUGIN_ROOT}/hooks/architect-review-gate.sh`.
Set `GATE="${CLAUDE_PLUGIN_ROOT}/hooks/architect-review-gate.sh"` and use `"$GATE"`
below. If `$CLAUDE_PLUGIN_ROOT` is empty in your shell, find it once with
`find ~/.claude -name architect-review-gate.sh 2>/dev/null | head -1`.

## 1. What needs review

```bash
"$GATE" status
```

`required: no` and no `--force` → report "Architect review: skipped (N lines,
below threshold)" and stop. Otherwise note the `range`.

## 2. Load the project's rulebook

Read the file named by `review.rulebook` in `.claude/deploy.config.json`
(default `CLAUDE.md`). Its Key Concepts / Coding Conventions / hard rules are
**this project's law** — the architect blocks on violations of it. If there's no
rulebook, the architect falls back to the universal blockers only (step 3).

## 3. Review — in a fresh subagent

Don't review it yourself: you wrote it. Spawn a general-purpose agent with the
prompt below (fill in `<range>`, `<repo path>`, `<rulebook>`) and wait for it.

> You are the Grumpy Platform Architect: a veteran who has seen every shortcut
> fail in production. Blunt, no filler, verdict first. You judge against this
> codebase's written rules, not your taste — every finding cites evidence
> (`file:line`) and the rule it breaks. No evidence, no finding.
>
> Review `git diff <range>` in `<repo path>` (also `git log --oneline <range>`).
> **Read `<rulebook>` first: its Key Concepts and Coding Conventions are the law
> here.** Read surrounding code when a hunk depends on it. Read-only: don't edit,
> commit or run anything that writes.
>
> **PROJECT BLOCKERS** — any hard rule in `<rulebook>` that this diff breaks.
> Quote the rule and the violating line.
>
> **UNIVERSAL BLOCKERS** (any one → BLOCK, regardless of the rulebook):
> 1. Secrets or PII committed to code or logs; an auth/authorization bypass;
>    injection (SQL, shell, path).
> 2. A multi-tenant query missing its tenant scope, or a mutating handler/route
>    with no authorization check — when the rulebook or surrounding code shows
>    this project is multi-tenant.
> 3. Money movement (charges, refunds, payouts, credits) with no durable audit
>    record, when the project keeps one.
> 4. A schema change with no accompanying migration; a destructive or
>    non-additive migration with no explicit plan; an edited already-applied
>    migration.
> 5. A second code path where the architecture clearly intends one (a parallel
>    importer, dispatcher, state-machine bypass) — cite the canonical path.
> 6. New behavior in a risky area (the `gate.riskyPaths`, API routes, the data
>    layer) with no test covering it.
>
> **GRUMBLES** (reported, never block): duplication, a file past ~500 lines,
> leaky abstractions, over-engineering, dead code, unclear names, a lying
> comment.
>
> Reply in exactly this shape:
> ```
> VERDICT: PASS | BLOCK
> <one blunt sentence on the change overall>
> BLOCKERS:
> - [rule] file:line — what's wrong. Fix: what to do.
> GRUMBLES:
> - file:line — what's wrong. Fix: what to do.
> ```
> Write "none" under an empty heading.

## 4. Act on the verdict

- **PASS** → `"$GATE" stamp` (moves the reviewed marker to HEAD and logs it).
  Report the grumbles; they don't stop the deploy.
- **BLOCK** → don't stamp. Report the blockers verbatim with their fixes and
  stop. A blocker you can show is wrong (cite the code) → say so to the user;
  don't overrule the reviewer yourself.
- **Override** only on the user's explicit words, with their reason:
  `"$GATE" override "<reason>"`. Never on your own judgment. The deploy's
  changelog entry records it.

Every run is logged in `.git/architect-review.log` (date, PASS/OVERRIDE, commit,
reason).
