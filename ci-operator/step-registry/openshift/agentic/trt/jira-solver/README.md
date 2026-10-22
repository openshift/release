# Serial Jira solver and review responder

The `openshift-agentic-trt-runtime-policy` pre-step writes a shared helper to
`SHARED_DIR/trt-runtime-policy.sh`. The solver and responder source it to generate
per-session settings and hooks; the guard implementation lives only in that
step's commands script, not in individual agent images. All four production/eval
workflows include the step, and the solve-eval dispatcher copies the helper into
each case's `SHARED_DIR`.

Both modes merge `Agent` into `permissions.deny`, preserving hooks and other
settings. The initial solve, timeout continuation, responder's direct Claude
gate, review worker, and CI-fix worker all receive those settings, even when
`ALLOWED_TOOLS` includes `Agent`. The responder retains its existing credential
denials. The shared skills remain unchanged.

The parent owns implementation, review, validation, and local commits. CI policy
is appended after skill and repository guidance so instructions to delegate or
publish do not override it. Neither mode permits agent pushes. Solver mode also
blocks `gh`; review mode allows it for reading reviews/CI and posting authorized
replies. The gate remains read-only; the shared policy does not grant it write
permission or change its required output format.

Only the pipeline publishes a committed feature branch and opens the solver PR.
Solver publication fails for missing commits, commits with no net changes from the
starting tree, leftover tracked changes, or untracked files outside `artifacts/`.
A timeout remains a failed solve even if continuation successfully preserves
work in a local commit. Evaluation renames its local
branch before publication; it does not delete remote branches or fall back to
pushing upstream. The responder retains its existing pipeline push/target checks
and no-change behavior; it does not inherit the solver's empty-solution gate.

Each solve has a separate temporary hook/settings directory, including concurrent
evaluation cases; this does not enable delegation within a solve. The
`guard-command.sh` Bash hook recognizes quoted arguments, literal quoted heredoc
commit messages (including tab-stripped `<<-'EOF'`), inline Node code, common
wrappers, Git global options, and explicit shell `-c` code. It rejects publication
commands, persistent and transient Git alias configuration, `BASH_ENV`/`ENV`
assignments, stdin-fed shells, shell script arguments/input redirects, and
unsupported active shell expansions. `exec`, `xargs`, and `find` are deliberately
denied rather than interpreting their execution options. Use direct commands or
Grep/Glob tools instead. A shell in a later pipeline stage is denied even with
`-c`. Function/coproc bodies are inspected as commands, not ignored as arguments.
The guard never executes commands to inspect their result. It is **not a sandbox**
against arbitrary interpreter code, scripts, or deliberate modification of the
guard itself.

## Setup and validation

Repository setup must establish and verify its own test prerequisites before
returning success. In particular, Sippy requires the pip/pytest checks from
[sippy#4139](https://github.com/openshift/sippy/pull/4139); system pip is not a
substitute for pip in the actual MCP virtualenv. A failing setup stops the solver
before agent launch. Origin and ship-status-dash retain their own setup contracts.

The generated `run-check.sh <command> [args...]` captures the full check output,
prints its last 80 lines only after completion, records the exact command and
exit status in `artifacts/check.*.json`, and returns that status. For compound
checks use `bash -o pipefail -c '...'`. Do not pipe checks to `head`/`tail`, ignore
their exit codes, or describe a component pass as a passing full target. These
records describe only the commands actually run, not full validation coverage.

`artifacts/solver-settings.json`/`solver-versions.txt` and
`review-settings.json`/`review-versions.txt` record each mode's supplied settings
and installed versions, not all merged Claude settings. Session logs and check
logs remain artifacts. Do not include credentials in commands or captured output.

## Rehearsal verification

Verify this change using rehearsals of `openshift-agentic-trt-eval` and
`openshift-agentic-trt-review-responder-eval` on the release PR. They build the
shared agentic-dev image containing the PR's scripts. The solver rehearsal needs
the actual deployed `agentic-ci` wrapper, Claude version, solver settings, and
updated Sippy environment. The responder rehearsal must verify policy enforcement
on the gate and both worker paths, not just shared-image compatibility.

1. Exercise the initial solve. Ask the parent to attempt the `Agent` tool, then
   edit a fixture, run a passing check, and commit locally. Confirm delegation is
   denied and no subagent/session was launched. A textual refusal alone is not
   proof: retain tool events and session logs.
2. Force an initial timeout after a session exists and exercise `--continue`.
   Repeat the delegation attempt, local edit, validation, and commit. Confirm the
   same settings are applied, no child runs, and the solve still reports timeout
   failure without publication.
3. On both paths attempt direct and wrapped pushes to a **disposable local bare
   remote**, plus `gh` use. Confirm tool denial and unchanged remote refs. Verify
   the actual audited commit and Node command strings succeed without guard
   workarounds, using the audit artifacts to recover the exact commands.
   Also verify piped/file-fed shells, shell startup environment variables,
   `exec -a`, function/coproc bodies, xargs/find execution, and persistent Git
   alias configuration are denied. Include a tab-stripped heredoc commit as a
   legitimate command that must succeed.
4. Exercise the success path's pipeline-owned push and PR creation using a
   dedicated test fork. Verify only the intended feature ref is published. Check
   evaluation naming too. Never use a real upstream branch as the test target.
   Confirm empty commits and commit/revert pairs with no net changes do not
   publish a PR.
5. Inject a failing full check after a passing component check. Confirm the check
   record retains the failure, full logs are available, and the final report does
   not call the full target passing. Confirm the actual MCP virtualenv Python,
   pip, and pytest work before implementation.
6. In responder rehearsal, verify delegation and direct/wrapped pushes are denied
   on the gate, review, and CI-fix paths, while required `gh` reads and authorized
   replies still work. Preserve the gate's read-only behavior and output contract.
   A legitimate no-change review round must not fail the solver's publication gate.

Record the rehearsal URLs, image identity, installed versions, initial and
continuation tool events, child-session inspection, remote refs, and check
outcomes. A passing ordinary solve alone does not verify delegation denial or
the timeout continuation path; explicitly exercise and inspect both.

## Parallelism remains disabled

Re-enabling delegation requires a separately scoped design for read-only helpers
or isolated implementation workers. Implementation workers need separate
checkouts/dependencies or equivalent exclusive ownership, bounded concurrency,
runtime-confirmed completion/termination before reassignment or integration,
quiescent dependency recovery, and one owner for shared Git operations, broad
validation, and publication. Regression tests must cover delayed workers and
conflicting file/dependency/Git operations before delegation is re-enabled.
Model benchmarking and setup-performance tuning are outside this mitigation.
