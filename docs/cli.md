# CLI reference

```text
agents-fyi-upgrader <mode> [options]
```

A mode is required; no command is a usage refusal (exit `2`). A leading `--help` prints the same
usage text the binary carries.

## Modes

| Mode | Service? | What it does |
|---|---|---|
| `plan` | yes | reads the application's `Gemfile.lock`, asks the service what the move crosses, and prints it |
| `preflight` | yes | repairs an old Gemfile so it can be installed at all, on a working copy the tool owns |
| `step` | yes | runs the first release of a move end to end on a working copy the tool owns |
| `serve` | yes | the durable loop: the service's queue, a ledger, a heartbeat, one step per repository per cycle |
| `preview` | no | renders the review brief a stored record would publish |
| `republish` | no | re-renders and updates already-delivered pull-request bodies from their records |
| `prune` | no | removes containers and bundles left by finished or killed runs |

`serve --walk` chains rungs inside a cycle. `serve --publish` (or `step --publish`) delivers a
passed rung as a branch and a pull request.

## Service selection

**There is no default service.** `plan`, `preflight`, `step` and `serve` need one named with
`--api URL` or `AGENTS_FYI_URL`. A mode that needs the service and has neither is a usage
refusal (exit `2`), not a failed request: there is nowhere to send it.

`preview`, `republish` and `prune` do not contact the service.

## Flags

### Common

| Flag | Meaning |
|---|---|
| `--api URL` | the service to ask. Default: `$AGENTS_FYI_URL`. No built-in default. |
| `--repo PATH\|URL` | the application: a local directory, or a git URL. A local directory is read where it is and never written to. |
| `--ref REF` | the branch or tag to read. A URL is cloned at that ref; for a local path, `plan` reads its current `HEAD` while `step` and `preflight` use the ref for their worktree. |
| `--to VERSION` | the Rails release the move ends at, for example `7.1.0`. Optional in `plan` and `step`; without it the target is the top of the service's ladder. `serve` uses an account project's own `to` first; `--to` is the deployment-wide fallback, and a row with no destination is skipped. |
| `--project SLUG` | a declared application (see [Configuration](configuration.md#project-declarations)). Default: `$UPGRADER_PROJECT`. A declaration supplies the repository, base ref and target; an explicit flag still wins. |
| `--record DIR` | where `step` writes its patch and JSON record, and `preflight` writes `preflight.json`. |
| `--home DIR` | this client's own directory: working copies and the ledger. Default: `$UPGRADER_HOME`, then `~/.cache/agents-fyi-upgrader`. |
| `--work DIR` | where `step` puts its working copy and per-run bundle. Default: `$UPGRADER_HOME`. |
| `--suite-env FILE` | `KEY=VALUE` lines merged into every command that runs **the application** — its suite, database preparation, `app:update` and boot. Never into this tool's own environment. |
| `--version` | print the client version and exit `0`. |
| `-h`, `--help` | print usage and exit `0`. |

### `plan`

`plan` needs `--repo` (or a project declaration that supplies it). It writes nothing.

```bash
agents-fyi-upgrader plan --repo . --to 7.1.0
agents-fyi-upgrader plan --repo https://github.com/owner/app.git --ref main
```

### `preflight`

`preflight` needs `--repo`. It does not take `--to`: its subject is the Gemfile an old
application cannot install at all, not a rung's changes. A digest entry whose condition needs
the rung is therefore deferred, and the record says so.

```bash
agents-fyi-upgrader preflight --repo . --record ./out
```

### `step`

| Flag | Meaning |
|---|---|
| `--force` | walk a move even though the ledger has settled it. The ledger is a memory, not a lock. |
| `--publish` | push a branch and open (or update) a pull request for a passed step. Needs `UPGRADER_GITHUB_TOKEN`. |
| `--suite-env FILE` | as above. |

```bash
agents-fyi-upgrader step --repo . --to 7.1.0 --record ./out
```

### `serve`

| Flag | Meaning |
|---|---|
| `--repos OWNER/NAME[@REF]` | a repository to walk. Repeatable; a comma-separated list is also accepted. Empty means the service's queue is asked. |
| `--heartbeat FILE` | the file `serve` touches every cycle; a healthcheck reads its age. |
| `--interval SECONDS` | how long the loop waits when there is nothing to do. Default: `600`; a project queued from the service wakes it early, and this is the fallback. |
| `--step-timeout SECONDS` | the ceiling for one application suite. Default: the step's own. |
| `--cycles N` | stop after `N` cycles. The default is never. |
| `--walk` | chain rungs within a cycle, and read an empty `--to` as the top of the ladder. |
| `--rungs N` | how many rungs `--walk` chains in one cycle. Default: `3`. |
| `--force` | ignore a settled ledger entry for this run. |
| `--publish` | deliver each passed rung as a branch and a pull request. A chained rung also joins the one below it as a GitHub stack. |
| `--record DIR` | write one record per move (`<repository>-<from>-<to>.json`), plus its patch. The repository part is readable: a URL such as `https://github.com/owner/application.git` becomes `owner-application`, and a local path uses its basename. |
| `--suite-env FILE` | as above. |

```bash
agents-fyi-upgrader serve --to 7.1.0 --interval 600
agents-fyi-upgrader serve --walk --publish --to 8.1.0
```

`serve` deliberately idles without a target unless `--walk` is set or the named project
declaration supplies one: a deployment that has not decided where it is going must not start
walking somebody's application. `UPGRADER_REPOS` is retired; the service's queue is the
deployment's source of work. `--repos` remains for a one-off manual run.

`serve --publish` asks the service for the repository's connected GitHub App credential; a
repository with no installation publishes nothing. `UPGRADER_GITHUB_TOKEN` is the token
`step --publish` uses, not the loop's; there is no deployment-wide customer credential to fall
back to.

### `preview`

| Flag | Meaning |
|---|---|
| `--from FILE` | the step record to render. Required. |
| `--base-ref REF` | the chain base the brief names. Default: the repository's own. |
| `--report-base URL` | the public service the brief links reports to. Default: `$UPGRADER_PUBLIC_URL`; empty names reports rather than linking them. |

```bash
agents-fyi-upgrader preview --from ./out/owner-application-7.0.0-7.1.0.json
```

### `republish` and `prune`

Both are local and take only `--home`:

```bash
agents-fyi-upgrader republish --home ~/.cache/agents-fyi-upgrader
agents-fyi-upgrader prune --home ~/.cache/agents-fyi-upgrader
```

`republish` rewrites the title, body and base of a pull request that was **already delivered**,
using the record the step wrote. It does not retry a failed push or open a missing request:
`serve` retries failed delivery on its next cycle, before asking the queue for work.

`prune` removes only what belongs to a process that is gone: a step container whose owning
walker died, or a per-run bundle no live run is using. It never touches a live run's bundle or
the kept tree under `targets/`.

## Exit status

| Code | Meaning |
|---|---|
| `0` | a plan was printed, a step ran and passed, or the loop stopped cleanly. |
| `2` | a refusal — the ladder will not plan this move, a backwards move was asked for, or the tool will not guess a target or a service. The sentence says which. |
| `1` | a real failure — no `Gemfile.lock`, an unreachable service, a git failure, or a step whose suite failed after a green baseline. **An `unverified` step is also `1`.** |

The split between `1` and `2` is the contract. A refusal is a fact about the **move**; a
failure is a fact about the **repository**, the **service** or the **machine**. A caller that
retries a refusal retries it forever.

`unverified` means nothing was established: no interpreter installed the bundle, the suite
could not run, or a required check did not run. It is not success, and the record says which
of the four verdicts it is and why.

## The record

`--record` writes:

- `<repository>-<from>-<to>.json` — the record;
- `<repository>-<from>-<to>.patch` — the patch, where there is one;
- `preflight.json` for `preflight`.

The repository part is a readable name, not the raw argument: `https://github.com/owner/application.git`
writes `owner-application-7.0.0-7.1.0.json`, and a local path uses its basename. A record written
by an older build under the sanitized raw name is still found by `republish`.

The record carries the repository and commit, the move, the machine, the verdict and its
sentence, the baseline and post-move suite, the stages with every command and exit code, the
edits applied, the changes refused and why, the decisions in force, the committed concern
series, and `wrote_nothing_to_the_repository: true`. The patch is the diff; the record is the
explanation.

`preview` renders the same body a pull request would carry from a stored record. `serve`
stores the rendered brief in its delivery record, so a retry does not re-render it.

## Environment variables

The full list, with defaults and scopes, is in [Configuration](configuration.md#environment-variables).
The ones that change the command line's behaviour are:

| Variable | Effect |
|---|---|
| `AGENTS_FYI_URL` | the service, when `--api` is not given |
| `AGENTS_FYI_KEY` | the operator key, sent as `X-API-Key` |
| `UPGRADER_PROJECT` | the project walked when `--project` is not given |
| `UPGRADER_HOME` | the client's home, when `--home` is not given |
| `UPGRADER_TO` | the target a deployment sets for `serve` |
| `UPGRADER_PUBLIC_URL` | the public base a brief links reports to |

`UPGRADER_LOG_LEVEL` does not exist. There is no logging framework to level: the output is
the CLI's report and one line per cycle.
