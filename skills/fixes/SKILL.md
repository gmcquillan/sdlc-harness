---
name: fixes
description: Use when an SDLC pull request has open review comments (inline, review-summary, or conversation) that need to be triaged and either fixed or refuted — fetches and normalizes every thread via GraphQL (skipping already-resolved threads) and REST, filters bot noise, gates on a triage table, fixes accepted comments in subagents with TDD, then replies to every thread without ever resolving one. Never creates a PR, never merges. Invoke as sdlc:fixes <PR#>.
---

# SDLC Fixes: PR review comments → accept/refute → land

Reuses `sdlc:implement`'s execution engine (worktree → subagent fixes with
TDD → verify → lint → push), but works from a PR's open comment threads
instead of a ticket's acceptance criteria. It never creates a new PR and
never merges — and it never resolves a GitHub review thread on either
outcome; replying is this skill's job, resolving is always left to the
human reviewer, so a reviewer's concern never silently disappears from
their queue. Create a todo per checklist item.

## Checklist

1. **Preconditions.** `<PR#>` is a required argument — comments are
   PR-scoped, so there is no "pick one for me" fallback. Run `gh auth
   status` (must succeed) and `gh pr view <PR#> --json state` (must be
   `OPEN`, not merged/closed/draft) — stop and report otherwise.
2. **Gather metadata (main loop, small):** `gh pr view <PR#> --json
   number,title,headRefName,baseRefName,url` only — same discipline as
   `sdlc:review` step 1. Do NOT fetch the diff or comments into this
   context.
3. **Fetch + normalize comments in a subagent.** One subagent call
   fetches:
   - Inline review comments via GraphQL, skipping already-resolved
     threads (the REST comments endpoint has no resolution field, so
     without this cross-reference a re-run would resurface feedback a
     human already closed out):

     ```bash
     gh api graphql -f query='
       query($owner:String!,$repo:String!,$pr:Int!) {
         repository(owner:$owner, name:$repo) {
           pullRequest(number:$pr) {
             reviewThreads(first:100) {
               nodes {
                 isResolved
                 comments(first:50) {
                   nodes { databaseId author { login } path line body }
                 }
               }
             }
           }
         }
       }' -f owner=<owner> -f repo=<repo> -F pr=<PR#> \
       --jq '.data.repository.pullRequest.reviewThreads.nodes
             | map(select(.isResolved == false))'
     ```
   - Review summary bodies and general conversation comments via
     `gh pr view <PR#> --json reviews,comments`. A review with a bare
     state and no body carries nothing to act on — skip it.
   - **Bot filtering:** drop every comment/review whose author is
     `*[bot]` before triage — there's no accept/refute semantics for a CI
     status update, and nobody reads a reply posted back to a bot. Count
     the drops; the count is reported in step 11, so filtering stays
     visible, not silent.
   The subagent returns ONLY a condensed list of `{id, kind, author,
   location, body, thread_root_id}` — never the raw API payload.
4. **Isolate.** Check whether a worktree already tracks the PR's
   `headRefName` (`git worktree list --porcelain`) — the common case,
   left over from the `sdlc:implement` run that produced this PR. Found
   → operate there. Not found → create one directly:
   `git worktree add .worktrees/<headRefName> <headRefName>`. Do NOT
   invoke `superpowers:using-git-worktrees` here — that skill's flow
   always creates a *new* branch via `-b`, which is wrong when the PR's
   branch already exists on the remote.
5. **Triage each comment in subagents**, fanned out per
   `fable-harness:fan-out` — one subagent per comment (batch several
   comments landing on the same lines together). Each subagent reads the
   surrounding code itself and returns exactly one of:
   - **Accept** — a real, in-scope defect or reasonable request; include
     a one-line fix plan.
   - **Refute** — the comment's premise doesn't hold against the current
     code, is out of scope, or is a stylistic disagreement not worth
     changing; include the one-line rationale that becomes the reply.
6. **Gate.** Present the triage table (comment id, author, location,
   accept/refute, one-line reasoning/fix-plan) and WAIT for an explicit
   go-ahead — the same human gate as `sdlc:ticket`'s dry-run and
   `sdlc:review`'s Tier A/B/C. Nothing is posted, resolved, or edited
   before the yes. The user may override any individual verdict here.
7. **Act on accepted comments only**, after the gate. One fresh subagent
   per fix (or a small batched set), running
   `superpowers:receiving-code-review` +
   `superpowers:test-driven-development`. The main loop supervises only —
   it never edits files itself, matching `sdlc:review`'s existing rule.
8. **Verify.** `superpowers:verification-before-completion` in a
   subagent; every accepted comment needs evidence its fix actually
   addresses it.
9. **Lint.** Run the project's linter/formatter and fix every finding —
   same gate as `sdlc:implement` step 10.
10. **Reply and push.** Push once, after all accepted fixes land (`git
    push`). Reply to each accepted inline thread as a native threaded
    reply:

    ```bash
    gh api repos/<owner>/<repo>/pulls/<PR#>/comments \
      -F in_reply_to=<id> -f body="<reply text>"
    ```
    Reply to summary/conversation comments via
    `gh pr comment <PR#> --body "<reply text, referencing which
    comment/review it addresses>"` (no native reply mechanism for those).
    Refuted comments get the same reply treatment with the rationale from
    step 5 — no code change, and **no thread resolution, ever**, for
    either outcome.
11. **Report.** Accepted comments (fix + reply link), refuted comments
    (rationale + reply link), the bot-noise count dropped in step 3, and
    the PR URL. Never merge; suggest `/sdlc:review <PR#>` if the changes
    were substantial enough to warrant a fresh look.

## Red flags

- Resolving a GitHub review thread for any reason, on accept or refute →
  that is always the human reviewer's call, never this skill's.
- Posting a reply, pushing, or fixing anything before the step 6 gate →
  the go-ahead is required, exactly like sdlc:ticket's dry-run.
- Invoking `superpowers:using-git-worktrees` in step 4 → it always
  creates a new branch; the PR's branch already exists remotely.
- Fetching resolved threads, or skipping the GraphQL cross-reference
  entirely → every re-run resurfaces feedback a human already closed.
- Editing files from the main loop → every fix runs in a sub-agent, no
  matter how small.
- Silently dropping bot comments without reporting the count → filtering
  must stay visible.
