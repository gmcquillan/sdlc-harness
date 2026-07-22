# PR comment fixes: `sdlc:fixes`

Date: 2026-07-22

A new pipeline skill, `sdlc:fixes <PR#>`, that closes the loop `sdlc:review`
leaves open: once a PR is out and a human (or another tool) leaves review
comments on it, something needs to accept or refute each one and land the
accepted fixes. `sdlc:review`'s own step 5 only acts on findings *it*
generated in the same run; it has no path for comments that arrive later,
from a real reviewer, in a separate session. `sdlc:fixes` reuses
`sdlc:implement`'s execution engine (worktree → subagent fixes with TDD →
verify → lint → push) but the "spec" it works from is the PR's open comment
threads instead of a ticket's acceptance criteria.

It never creates a new PR (one already exists) and never merges. It also
never resolves a GitHub review thread — replying is this skill's job;
resolving is always left to the human reviewer, on both accepted and
refuted comments, so the tool can never make a reviewer's concern silently
disappear from their queue.

## Scope of comments

Three GitHub comment surfaces are triaged, chosen deliberately broad because
review feedback shows up in all three depending on the reviewer/tool:

- **Inline review comments** — tied to a diff line, fetched with resolution
  state so an already-resolved thread is never re-litigated on a re-run.
- **Review summary bodies** — the free text a reviewer writes when
  submitting APPROVED/CHANGES_REQUESTED/COMMENTED (a bare state with no body
  carries nothing to act on and is skipped).
- **General PR conversation comments** — includes CI bots and other
  automated chatter, so a filtering step is required (see below).

**Bot filtering.** Comments/reviews from any `*[bot]` author are dropped
before triage — there's no accept/refute semantics for a CI status update,
and nobody reads a reply posted back to a bot. The dropped count is still
reported in the final summary so filtering stays visible, not silent.

**Resolved-thread filtering.** Inline comments are fetched via GraphQL
(`reviewThreads { isResolved comments { databaseId author path line body } }`)
specifically because the REST comments endpoint has no resolution field —
without the GraphQL cross-reference, every re-run of `sdlc:fixes` on the same
PR would resurface feedback that was already addressed and closed out by a
human.

## Execution flow

Context discipline mirrors `sdlc:review`: raw comment JSON and file contents
never land in the main loop. A subagent fetches and normalizes comments into
a condensed list (`{id, kind, author, location, body, thread_root_id}`);
subagents judge each comment; subagents implement each accepted fix. The
main loop holds only the condensed triage table, the gate, and the final
report.

1. **Preconditions.** `<PR#>` is a required argument (no ticket-style
   "pick one for me" fallback — comments are PR-scoped, so there's nothing
   to select among). `gh auth status` succeeds and the PR is `OPEN` (not
   merged/closed/draft).
2. **Gather metadata** (main loop, small): number/title/headRefName/
   baseRefName/url only — same discipline as `sdlc:review` step 1.
3. **Fetch + normalize comments in a subagent.** One subagent call: the
   GraphQL `reviewThreads` query (skip `isResolved: true`), plus
   `gh pr view --json reviews,comments` for summaries and conversation.
   Drop `*[bot]` authors. Return only the condensed list above — never the
   raw API payload.
4. **Isolate.** Check whether a worktree already tracks the PR's
   `headRefName` (common case: left over from the `sdlc:implement` run that
   produced this PR). If found, operate there. If not, create one directly
   — `git worktree add .worktrees/<headRefName> <headRefName>` — rather
   than invoking `superpowers:using-git-worktrees`, whose flow always
   creates a **new** branch (`-b`); this branch already exists on the
   remote, so that skill's assumptions don't fit.
5. **Triage each comment in subagents**, fanned out per
   `fable-harness:fan-out` (one subagent per comment, batched by file when
   several comments land on the same lines). Each subagent reads the
   surrounding code itself and returns exactly one of:
   - **Accept** — a real, in-scope defect or reasonable request; include a
     one-line fix plan.
   - **Refute** — the comment's premise doesn't hold against the current
     code, is out of scope, or is a stylistic disagreement not worth
     changing; include the one-line rationale that becomes the reply.
6. **Gate.** Present the triage table (comment id, author, location,
   accept/refute, one-line reasoning/fix-plan) and wait for an explicit
   go-ahead — the same human gate as `sdlc:ticket`'s dry-run and
   `sdlc:review`'s Tier A/B/C. Nothing is posted, resolved, or edited before
   the yes. The user may override any individual verdict here.
7. **Act on accepted comments only**, after the gate. One fresh subagent per
   fix (or a small batched set), running
   `superpowers:receiving-code-review` + `superpowers:test-driven-development`.
   The main loop supervises only — it never edits files itself, matching
   `sdlc:review`'s existing rule.
8. **Verify.** `superpowers:verification-before-completion` in a subagent;
   every accepted comment needs evidence its fix actually addresses it.
9. **Lint.** Run the project's linter/formatter and fix every finding — same
   gate as `sdlc:implement` step 10.
10. **Reply and push.** Push once, after all accepted fixes land
    (`git push`). Reply to each accepted inline thread via
    `gh api repos/<owner>/<repo>/pulls/<PR#>/comments -F in_reply_to=<id>`
    (native threaded reply); reply to summary/conversation comments via
    `gh pr comment <PR#>` (no native reply mechanism for those, so the reply
    text references which comment/review it addresses). Refuted comments
    get the same reply treatment with the rationale from step 5 — no code
    change, and **no thread resolution, ever**, for either outcome.
11. **Report.** Accepted comments (fix + reply link), refuted comments
    (rationale + reply link), the bot-noise count dropped in step 3, and the
    PR URL. Never merge; suggest `/sdlc:review <PR#>` if the changes were
    substantial enough to warrant a fresh look.

## Why no ticket-backend resolution (step 0)

`sdlc:ticket`/`next`/`implement`/`review` all start with
`sdlc-backend.sh resolve` because they read or write the *ticket* system,
which is configurably GitHub Issues or JIRA. PR comments are GitHub-native
regardless of which ticket backend is bound — there is no JIRA equivalent
in this pipeline's scope — so `sdlc:fixes` skips step 0 entirely and is
excluded from `validate-skills.sh`'s backend-resolution check list.

## Files touched

- `skills/fixes/SKILL.md` — new skill (frontmatter `name: fixes`,
  description beginning "Use when").
- `tests/validate-skills.sh` — add `fixes` to the `expected` skill list;
  do NOT add it to the `pipeline` (backend-resolution) list.
- `README.md` — add `sdlc:fixes` to the documented command list.

## Out of scope

- No change to `sdlc:review`'s own step 5 (findings it generates itself in
  the same run) — that path is unchanged and independent of this skill.
- No new ticket/issue creation path (no Tier B/C equivalent) — every comment
  resolves to exactly accept-and-fix or refute-and-explain, matching what
  was asked for. A comment that's really a large new feature request is
  handled as a refute with a rationale pointing at `sdlc:ticket` instead.
- No thread-resolution automation of any kind, for either outcome.
- No merge/push-to-main automation — the human integration gate stays
  absolute, as in every other pipeline skill.
