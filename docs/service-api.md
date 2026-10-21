# Service API

The upgrader is a client of the agents-fyi service. This document is the client's view: the
endpoints it calls, what it sends, and how it reads a failure. The service's own machine-readable
surface is authoritative:

- `https://agents.shoutsid.fyi/.well-known/agents-fyi.json` — the discovery document;
- `https://agents.shoutsid.fyi/llms.txt` — the agent-oriented summary.

If a response and this page disagree, the service is right.

## Base URL and credentials

There is **no default service**. Name one with `--api URL` or `AGENTS_FYI_URL`.

The operator key is `AGENTS_FYI_KEY`, sent as `X-API-Key`. An empty key is not sent at all: an
anonymous request carrying an empty key would look signed in and would not be. The anonymous half
of the client — the ladder, a plan, and the scan of source you send — works without an account.
Writes and the queue need an operator key.

The key is a **client's** key and never an admin token. The admin surface — hide, unhide, disable —
is not reachable from this tool, and a container that clones and executes other people's
applications is the last place to put that credential.

Publishing uses a different credential. `step --publish` reads `UPGRADER_GITHUB_TOKEN`, with
`contents: write` and `pull_requests: write` on the repository. `serve --publish` instead asks
the service for a short-lived credential for the repository's connected GitHub App installation
(`GET /api/upgrades/credential`); a repository with no installation publishes nothing. Both are
GitHub credentials, not service keys, and neither is written into a record.

## Timeouts and failures

Every request has a 25-second open and read timeout. A connection failure, a timeout, or a
non-JSON response is an **unreachable** service: the loop waits it out. A `step` whose plan cannot
be read is `refused` with the reason, because there is no plan to execute; a `plan` that cannot
read the ladder and was not given `--to` is a failure, because it cannot name a target.

A 4xx is the service reading the request and declining it, in its own words. A 5xx is the service
being unavailable. The client does not retry inside a request; the loop decides when to try again.

The error envelope is:

```json
{
  "error": {
    "type": "conflict",
    "message": "…"
  }
}
```

The message is preserved whole. It is the sentence that says which direction the ladder reads, or
which release has no chapter, and that is the part that changes what the caller does next.

A `409` on a report write is its own answer: the corpus already knows this. The service returns
its conflict envelope, and the client normalises it to `{"duplicate": true, "detail": "…"}` rather
than treating it as a failed request. A duplicate is the ordinary outcome for a failure somebody
else has already hit.

## What the client calls

| Method and path | Kind | Used for |
|---|---|---|
| `GET /api/health` | read | the entrypoint's five-minute wait before the loop starts |
| `GET /api/rails/ladder` | read | the step and change counts, `earliest`, and `top`; the top is the default target for `plan` and `step` |
| `GET /api/rails/upgrade?from_version=&to_version=` | read | the rung's plan: its changes, the mechanical/manual split and the next step |
| `POST /api/rails/scan` | read (body) | the call sites a move crosses in the source the client sends |
| `POST /api/releases/route` | read (body) | what each gem in the lockfile needs: keep, move, replace, remove, blocked, unknown |
| `POST /api/releases/facts` | write | index facts the client fetched; the one write that is not a record of its own work |
| `GET /api/gems/migrations?gems=` | read | the gem-migrations digest, bounded to the caller's own gems |
| `GET /api/reports/upgrade?…` | read | the reports already filed against a library and version window |
| `GET /api/reports/search?q=…` | read | corpus recall for a brief; sent with `record=false` because a walker's own question is not user demand |
| `GET /api/reports/answer?…` | read | the corpus's answer to a change's subject, with the reports it used |
| `GET /api/upgrades/projects` | read | the account projects the service can make walkable |
| `GET /api/upgrades/credential?repo_url=` | read | a short-lived GitHub credential for a repository with a connected installation |
| `GET /api/upgrades/targets?limit=` | read | the queue: which repositories the service thinks are worth walking, best first |
| `POST /api/upgrades/runs` | write | one step's record: verdict, stages, exit codes, refusals, patch |
| `POST /api/reports/precheck` | write | whether a draft is new, and what it is close to if it is not |
| `POST /api/reports` | write | a report about a failure the walk found |

Read/write is this client's use, not a complete statement of the service's authorization; the
service decides. The key is sent on every request when the client has one.

### The ladder and the plan

`GET /api/rails/ladder` answers with the ladder's `top`, `earliest`, step count and the steps
themselves. `plan` and `step` use `top` when `--to` is omitted. The tool keeps no copy of Rails'
release order: a target that is not named is a fact the service publishes, not a guess.

`GET /api/rails/upgrade` answers with `steps`, `changes`, `next_step` and the mechanical/manual
split. A refusal here is a fact about the move, and the client records the service's sentence
rather than inventing one. A backwards move and an unknown release are both refusals.

### The scan

`POST /api/rails/scan` sends:

```json
{
  "from_version": "4.0.0",
  "to_version": "4.1.0",
  "files": [
    { "path": "app/models/example.rb", "text": "…" }
  ]
}
```

The source is the caller's private code and the service keeps nothing. The client bounds what it
sends (`MAX_SCAN_FILES` and `MAX_SCAN_BYTES` in `step.rb`). A `413` is reported as the service's
own answer rather than retried smaller: scanning fewer files silently would turn "nothing found"
into a claim about files nobody read.

The response carries `counts`, `edits`, `manual` call sites and `next_step`. This tool applies
the edits, then applies its own rules to the manual call sites. A rule that edits code is the
client's; the ladder's patterns are the service's.

### The route and the digest

`POST /api/releases/route` takes the lockfile, the Ruby and the Rails version and answers what
each gem needs. `unknown` is not a pass: the client is the side that can reach the gem index, so
it researches the unknown pins and writes what it read back with `POST /api/releases/facts`.

`GET /api/gems/migrations` is bounded to the caller's own gems, declared and locked. An entry is
a claim about an index and a repository, not a compatibility matrix: a gem the digest does not
mention is not thereby fine.

### The queue

`GET /api/upgrades/targets?limit=` answers `{"targets": […]}`, best first. The client asks for a
bounded slice (`DEFAULT_TARGET_LIMIT = 100`) and comes back after doing the work. A row with no
`repo_url` is not work and is dropped.

A queue the service is **not serving** is reported as an error, not an empty list. A paused queue
carries `paused`, `paused_reason` and `next_step`, and the client keeps that sentence. The two
answers want opposite responses: an empty queue means wait, a paused one means the index is not
collecting and retrying will not help.

### Runs

`POST /api/upgrades/runs` files one step's record: the repository, commit, move, verdict, the
stages with every command and exit code, the refusals, the patch. The service owns what it does
with the row; the client owns the record it sends.

A run write that the service refuses is reported as the service's sentence. A step that could
not be measured (`unverified`) is still a fact worth recording — it says the machine could not
establish anything — and it is not dressed as a pass.

### Reports

A walk files a report only for a failure it actually found, after `POST /api/reports/precheck`
says whether the draft is new. A duplicate is an answer, not a failure. The client does not use
the admin surface to hide or edit anything; filing is the whole of what it needs.

## What the client never sends

- `ADMIN_TOKEN`, in any spelling.
- A database password, or a database connection of any kind. The client has no database driver
  and no route to the service's database.
- A caller's source, except in the scan body, which is the route's subject and is not stored.
- A GitHub token in a record, a report or a log line.

## Rate limits

The service is the authority on limits, and a response is where a limit would be stated. The
client has no quota of its own and no sleep between ordinary requests; the loop's interval is a
schedule, not a rate limiter. A deployment that runs several walkers should still treat the
service's queue and its own key as shared resources rather than assume an allowance.
