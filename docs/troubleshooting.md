# Troubleshooting

Start with the exit status. `2` is a refusal about the move; `1` is a failure about the
repository, the service or the machine. The sentence beside it usually names the next action.

## The tool refuses to start

### `plan` needs the service: pass --api URL or set AGENTS_FYI_URL

There is no default service. Set `AGENTS_FYI_URL` or pass `--api`. A self-hosted service is named
the same way; the public deployment is a convenience, not a default.

### `the project declaration is not usable: …`

The declaration is JSON and is validated before anything runs. The message names the unknown key,
the missing field or the invalid value. Common causes:

- an unknown key (a typo is rejected on purpose, so a setting cannot silently do nothing);
- `env_names` carrying `NAME=value` instead of `NAME`;
- `suite.kind` not one of `rspec`, `minitest`, `none`;
- a `check` with an `external` kind and no `reason`;
- `source_roots` with an absolute path or `..`;
- `delivery.provider` not `github` or `none`.

A declaration with no `slug` has no name, and a declaration with no `repo`, `from` or `to` has no
move. Those are required.

### `no project named "…" in …`

The slug has no file in the directories the message lists. Put it in
`lib/agents_fyi/upgrader/data/projects/<slug>.json`, or in `UPGRADER_PROJECTS_DIR`. A written
declaration shadows a built-in of the same slug; a malformed written one is refused by name
rather than falling back silently.

## The plan refuses

### `the ladder will not plan this move`

The service's sentence is kept whole. The common cases:

- **A backwards move.** This ladder reads forward. A downgrade is not a step.
- **An unknown or unchaptered release.** The ladder has no rung for one side. Check the top with
  `GET /api/rails/ladder`; `plan` without `--to` uses `top`.
- **The same release on both sides.** There is no rung to walk. `step` prints "already at …" and
  returns `nil` (exit `0`); a queue row at its target is idle, not a refusal to re-record every
  cycle.

A refusal is not retried by the loop. Retrying it reaches the same sentence.

### `the service returned no step for …`

The service answered but its plan had no step. The `next_step` field is quoted. This is usually a
window with no rung or an application pinned to a release the ladder does not start from.

## The step is unverified

`unverified` exits `1`. The record's `why` names the cause; these are the usual ones.

### `requires Ruby … and this interpreter is …`

The native interpreter does not meet the rung's floor. Run the step in an era container:

```bash
UPGRADER_RUNTIME=docker ./bin/agents-fyi-upgrader step --repo … --to …
```

The era images must exist on the daemon. See [Deployment](deployment.md#docker-era-containers).

### The bundle did not install

- **No compiler.** A gem with no prebuilt binary needs `build-essential` and the headers in the
  step image. Build with `WITH_BUILD_TOOLS=1`; the era image also needs its own toolchain.
- **A missing system library.** The error names the header or package. The image installs a
  bounded set (`libsqlite3-dev`, `libyaml-dev`, `pkg-config`) and leaves the rest to the era
  image. Add it to the image rather than to the host.
- **The wrong bundler.** A Rails 4-era lockfile may require bundler < 2. The era image pins the
  bundler the matrix names. A native step uses the host's; install the era's bundler or use an
  era image.
- **A dead git source.** A `git://` remote or a deleted fork. Run `preflight`; it rewrites what
  the digest knows and reports what it will not.
- **The network.** `bundle install` reaches the index and GitHub. A container without egress
  fails here; the error is the install's, not the ladder's.

### The suite did not run

The suite command is the declaration's `suite.command` (or the stack default). Check:

- the command exists in the bundle (`bundle exec rspec` may need the gem group installed);
- the application's services are up and its database is prepared;
- the suite environment has the names it reads. `--suite-env FILE` or `UPGRADER_SUITE_ENV` is
  merged into the application's commands, not into the tool's.

### The baseline was red

A red baseline makes the step unmeasurable. If `UPGRADER_REPAIR_ATTEMPTS` is off, the record
quotes the failure and the step is `unverified`. Turn repair on (and authenticate the model), or
fix the baseline on a branch and start the walk from there. The record's baseline stage has the
command and the output tail.

### A required check did not run

The suite passed, but a declared required check was absent or could not run. `unverified` means
the application's gate was not measured. Install the check's tool, fix its command, or declare it
`external` with a reason if this walker genuinely cannot run it.

## The step failed

### `the suite was green before this step and failed after it`

The move broke something. The record's post-move suite has the output tail; the decisions and
refusals name what the walk would not apply. If repair is enabled, the attempts and the files
they changed are in the record.

Do not "fix" this by turning off a check or by pinning back a release the ladder moved. Read the
failure and the refused changes first.

### `app:update` conflicts

A file the application already owns keeps the application's version and the conflict is recorded.
That is deliberate. Review the conflict and decide; `app_update.skip` can exclude a path the
application owns on purpose.

### The style formatter failed

A formatter that ran and failed makes the rung fail. A formatter that is not installed makes it
`unverified` rather than blaming the application. Install it, fix the command, or remove the
`style` declaration if the application has no formatter.

### A check failed

A required local check failed. The record names the check and its exit code. A non-required check
is reported but does not block the rung.

## Docker and era containers

### `docker: executable file not found`

The image was built without the Docker client. Rebuild with `WITH_DOCKER_CLIENT=1`.

### `permission denied` on `/var/run/docker.sock`

The container's user is not in the socket's group. Pass the host's group id:

```bash
--group-add "$(stat -c '%g' /var/run/docker.sock)"
```

The compose example uses `UPGRADER_DOCKER_GID` for the same value. A wrong id is loud in the
record: every step says the daemon could not be reached.

### The daemon call hangs

Every daemon call has a deadline (`DOCKER_SECONDS`, `TEARDOWN_SECONDS`). A wedged containerd can
still make a step slow; the deadline turns it into a failed or unverified step rather than a walk
that never returns. A restart of the Docker engine is the usual cure. The record's stage says
which call timed out.

### `Could not locate Gemfile` in the era container

The era container cannot see the worktree. The walker's home must be a **named volume** the same
daemon can mount. If discovery cannot answer, set `UPGRADER_DOCKER_VOLUME` to the name
`docker volume ls` prints. A wrong name creates an empty volume and every step fails loudly.

### A container is still running after a killed step

A process that is killed runs no `ensure`. Run:

```bash
./bin/agents-fyi-upgrader prune --home …
```

`prune` also reclaims a per-run bundle no live run is using. The next step runs the same pass
before starting its own container.

### `no image for …` / a floor no era meets

The rung requires a Ruby the era matrix does not carry, or the image was not built. Check:

```bash
scripts/upgrader-images.sh list
scripts/upgrader-images.sh build <era>
```

A floor no image meets is refused by name rather than attempted; that is a fact about the
matrix, not a transient failure.

## The loop does nothing

### `serve: no target, so this loop will not walk anything`

`serve` idles without `--to` unless `--walk` is set. Set `UPGRADER_TO` to the release the move
ends at, or set `UPGRADER_WALK=1` to walk each repository to the top of the ladder. This is
deliberate: a deployment that has not decided where it is going must not start walking somebody's
application.

### `the upgrade queue is not being served`

The service's queue is paused. The sentence names the reason and the next step. Retrying will not
help until the index is collecting again. This is different from an empty queue: an empty queue
means wait; a paused one means stop asking.

### The queue is empty, but the repository is not at its target

A target stops being offered once a run has been recorded against it. If the target is stale or
was reset, the ledger may still say the move is settled. `--force` (or `UPGRADER_FORCE=1`) sets
one settled entry aside. Check the startup line's settled count; if it is zero after a restart,
the ledger volume was lost and the loop is re-deriving everything.

### The loop is healthy but no step runs

The heartbeat's age is the health signal, not the process being up. Check:

- the queue is not paused (above);
- `UPGRADER_TO`/`UPGRADER_WALK` is set;
- the loop is not waiting on a backoff after a failed rung;
- the service is reachable from the container (`API_BASE_URL`, not the public hostname, on a
  compose network).

## Service errors

### `401` / `403`

The operator key is missing, wrong, or lacks the scope. Set `AGENTS_FYI_KEY`; do not use
`ADMIN_TOKEN`. Anonymous reads (the ladder, the scan, a plan) work without a key, so a plan can
succeed while a queue read or a run write fails.

### `409` on a report

The corpus already has this report. The service returns a `409`, and the client normalises the
conflict to `{"duplicate": true, "detail": "…"}`; that is an answer, not a failure. The precheck
is what tells you before writing.

### A body is not JSON

A proxy's login page or a block notice can arrive with a 2xx. The client treats a non-object body
as an unreachable service rather than as "no changes", because the latter would tell a caller the
ladder has nothing for a move nobody answered. Check the base URL and any proxy in front of it.

### The scan answers `413`

The source sent exceeded the service's bound. The client already bounds `MAX_SCAN_FILES` and
`MAX_SCAN_BYTES`; a `413` means the service's bound is lower than the client's or a single file
is too large. It is reported rather than retried smaller, because scanning fewer files silently
would make "nothing found" a claim about files nobody read.

## Publishing

### `--publish` does nothing

`step --publish` needs `UPGRADER_GITHUB_TOKEN`, and the token needs `contents: write` and
`pull_requests: write` on the repository. `serve --publish` gets a short-lived credential from
the service for the repository's connected GitHub App installation; a repository with no
installation publishes nothing, and there is no deployment-wide customer credential to fall back
to. A publish failure does not un-pass the rung; it is recorded as delivery debt and retried on
the next cycle.

### The pull request targets the wrong branch

With `delivery.chain: true` (the default), a rung's pull request targets the rung before it, not
the base branch. That is deliberate: it is one reviewable series. Set `chain: false` if you want
each request against the base.

### `republish` cannot find a delivery

`republish` reads the ledger's delivered entries and the stored record. A delivery that predates
the record store, or whose volume was lost, cannot be rebuilt. It does not move a branch; it
rebuilds the body from the record and publishes again.

## Records and secrets

### No record was written

`--record DIR` is required for a step's patch and JSON; `preflight` writes `preflight.json` with
`--record DIR`. In a container, the directory must be writable by uid `10003`. `UPGRADER_RECORD`
is the entrypoint's optional path; when it is empty, the loop writes no record file.

### A record contains a secret

The tool does not write its own key, token or suite environment values into a record, but it
keeps the tail of every command's output. An application that prints a secret in its suite
output will put it in the record, and a failure report may quote it. Review a record before
sharing it; the corpus is public.

### A record cannot be read by `preview`

`preview --from FILE` expects the JSON `step --record` wrote. A missing file, a truncated write or
a record from another version is a usage refusal (`2`) with the parser's message, not a crash.

## Repair

### `Agent not found: "repair"`

The generated config names the `repair` agent and sets `OPENCODE_CONFIG` to a file in the
client's home. If the binary cannot read that file, it falls back to `build` (which has a shell)
or reports the agent missing. Check that `opencode` is installed (`WITH_REPAIR_AGENT=1`) and that
`UPGRADER_HOME` is writable.

### Repair attempts fail immediately

The agent needs an authenticated model in its own configuration. In a container, authenticate it
once in the home volume:

```bash
docker compose exec upgrader opencode auth login
```

The credential survives a restart because it is on the volume, not in the image. A model name in
`UPGRADER_REPAIR_MODEL` that the agent cannot use fails the same way.

### The repair timed out

A timeout is a kill, not a wait. The attempt is recorded as timed out, and its changes (if any)
are still measured by the suite. Raise `UPGRADER_REPAIR_TIMEOUT` only if the model genuinely needs
longer; the loop's job is not to wait for ever.

## Getting more information

- Re-run with `--record ./out` and read the JSON: `stages` has every command and exit code.
- `preview --from ./out/<record>.json` renders the review brief without a checkout or a token.
- The service's discovery document (`/.well-known/agents-fyi.json`) is the authority on routes
  and credentials.
- For a bug in this client, open an issue with the version, the command, the operating system and
  the redacted record. Do not paste a key, a token or an application's private source.
