---
name: review
description: Use when an SDLC pull request needs review against its issue's acceptance criteria — fans out spec-compliance, correctness, and test-quality reviewers, skeptic-verifies findings, and posts a gh pr review. Never merges. Invoke as sdlc:review <PR#>.
---

# SDLC Review: PR → Verdict

The diff is reviewed by subagents; this session holds only metadata,
verdicts, and judgment. Create a todo per checklist item.

## Checklist

1. **Gather metadata (main loop, small):**
   `gh pr view <PR#> --json title,body,headRefName,files` — extract the
   linked issue from `Closes #<n>`, then
   `gh issue view <n> --json body` for the acceptance criteria and spec
   pointer. Do NOT fetch the diff into this context.
2. **Fan out reviewers** per `fable-harness:fan-out` — three subagents,
   ALL dispatched in a single message, each given the PR number, the
   acceptance criteria, and ONE dimension:
   - **Spec compliance:** does the diff satisfy every acceptance
     criterion? Anything out-of-scope smuggled in?
   - **Correctness:** logic, edge cases, error handling, concurrency.
   - **Test quality:** do tests exercise the criteria for real, or are
     they mocked facades that would pass against a stub?
   Each returns findings as `file:line — claim — severity`.
3. **Skeptic-verify significant findings:** every finding a reviewer
   rates important enough to block approval goes to a
   `fable-harness:skeptic` subagent (one finding each, dispatched in a
   single message) that tries to REFUTE it against the actual code.
   Refuted findings are dropped. No plausible-but-wrong comments reach
   the PR.
4. **Post the verdict** — comment or approve, NEVER merge:

   ```bash
   # criteria unmet or confirmed findings:
   gh pr review <PR#> --request-changes --body "<verified findings,
   grouped by dimension, each with file:line and the failure scenario>"
   # everything satisfied:
   gh pr review <PR#> --approve --body "All acceptance criteria verified:
   <one line of evidence per criterion>"
   ```

   Approval ends with: "Ready for your merge decision." The merge is
   always the human's.
5. **Fix mode (ONLY if the user asked you to fix, not just review):**
   check out the PR branch (`gh pr checkout <PR#>`), invoke
   `superpowers:receiving-code-review` on the verified findings —
   technically verify each before implementing, push fixes to the
   branch, then re-run this checklist from step 2.

## Red flags

- Pulling the full diff into the main loop "for a quick look" → that is
  the reviewers' context to spend, not yours.
- Posting reviewer findings nobody tried to refute → skeptic step is not
  optional for blocking findings.
- Merging an approved PR "to save a step" → human gate violated.
