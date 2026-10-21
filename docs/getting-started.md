# Getting started

This guide takes you from a fresh checkout to a plan, a preflight and a step. It assumes a
Rails application and an agents-fyi service to ask.

## 1. Requirements

- Ruby **3.3 or newer**. The image pins 3.3.12; the repository has no Gemfile and no gems to
  install.
- `git`, on `PATH`.
- A network route to the service and to the application's repository.
- Docker, if a step should execute on an era interpreter. The `docker` runtime is the
  deployment's runtime; a hand-run `step` can use this process's Ruby instead. See
  [Configuration](configuration.md#choosing-a-machine).

```bash
git clone https://github.com/shoutsid/upgrader.git
cd upgrader
./bin/agents-fyi-upgrader --help
```

There is no `bundle install`. If the command runs, the tool is installed.

## 2. Name the service

**There is no default service.** A plan answered from a corpus the caller did not choose is
the same class of mistake as a default upgrade target, so the client refuses to guess. Name
the service with `--api` or `AGENTS_FYI_URL`:

```bash
export AGENTS_FYI_URL=https://agents.shoutsid.fyi
```

`plan`, `preflight`, `step` and `serve` all need one. `preview`, `republish` and `prune` are
local and do not.

The public deployment is a convenience, not a default. A self-hosted or staging service is
named the same way.

## 3. Know which operations need a key

Anonymous reads work without an account:

- the ladder (`GET /api/rails/ladder`);
- the scan of source you send (`POST /api/rails/scan`) — the source is not stored;
- a plan (`GET /api/rails/upgrade`) reads the ladder.

Writes and the queue need an operator key. The client reads it from **`AGENTS_FYI_KEY`** and
sends it as `X-API-Key`:

```bash
export AGENTS_FYI_KEY=your-operator-key
```

The key is an **operator** key, never an admin token. Filing a report is the whole of what a
walk needs; the admin surface — hide, unhide, disable — is deliberately out of reach.

A missing key is not a crash. A write without one is refused by the service with its own
sentence, and a queue read without one fails the same way. The anonymous half of the client
still works.

## 4. Read a plan

For a local checkout:

```bash
./bin/agents-fyi-upgrader plan --repo /path/to/application --to 7.1.0
```

For a remote repository:

```bash
./bin/agents-fyi-upgrader plan \
  --repo https://github.com/owner/application.git \
  --ref main \
  --to 7.1.0
```

A URL is cloned once, shallow (`--depth 1`), into `$UPGRADER_HOME` and reused: a plan is
asked for repeatedly while a move is worked out, and re-cloning per question is slower and
less honest about what was read.

`--to` is optional. Without it, the target is the top of the service's ladder — the service
publishes `top`, so "to what?" is answered by the source of the rule rather than by a second
copy in this tool. (This applies to `plan` and `step`; `serve` idles without a target unless
`--walk` is set.) A backwards move is a **refusal** (exit `2`), not a failure.

The plan prints:

- the move it resolved, from the Rails release in the application's own `Gemfile.lock`;
- the changes the service says the move crosses;
- the split between mechanical changes and changes that need a person;
- the refusals and gaps, each with the reason it is there.

Nothing is written to the application.

## 5. Look at a preflight

An old application often cannot be installed at all. `preflight` repairs the Gemfile half of
that problem on a working copy:

```bash
./bin/agents-fyi-upgrader preflight \
  --repo https://github.com/owner/application.git \
  --record ./out
```

It rewrites `git://` remotes in both the Gemfile and the lockfile, replaces dead forks with
the service's gem-migrations digest, and removes pins that cannot sit beside the framework.
A declaration it cannot rewrite in full is skipped **with the reason**; a digest entry for a
gem the application does not declare is a decision, not a silent change.

`--record` writes `out/preflight.json`. The working copy is the tool's own.

## 6. Run one step

```bash
./bin/agents-fyi-upgrader step \
  --repo https://github.com/owner/application.git \
  --to 7.1.0 \
  --record ./out
```

A step runs the first release of the move end to end:

1. read the application's facts and preflight the Gemfile;
2. apply the project's accepted decisions;
3. choose a machine, install the bundle, start the application's services and prepare its
   database;
4. run the suite on the copy **before the move's own edits**;
5. ask the service for the call sites, apply the mechanical edits, and apply this client's
   own rules;
6. route the gems, pin Rails, run `app:update`, boot, and run the suite again;
7. optionally step framework defaults and repair a red post-move suite, then run the
   application's other checks.

A red baseline is repaired before the move's edits, if a repair budget exists: a suite that was
red before the move says nothing about the move.

The full pipeline is in [Architecture](architecture.md#what-one-step-does).

`--record` writes a patch and a JSON record. The record is the evidence: the verdict, every
command with its exit code, each refusal and its reason, the baseline, the post-move suite,
and the changes the tool would not make.

The exit status is one of `0`, `1` or `2`. `unverified` is `1`: the step ran but nothing
established that it worked. Read the record, not only the status.

## 7. Run the loop

A deployment runs the image with `entrypoint.sh` in front of the loop. The entrypoint waits
up to five minutes for the service's `/api/health`, then starts anyway, because an API that is
down is something a loop waits out. It then runs:

```bash
agents-fyi-upgrader serve --to "$UPGRADER_TO" --api "$API_BASE_URL" ...
```

The loop reads the service's queue, walks one step per repository per cycle, and keeps a
durable ledger. `--walk` chains rungs inside a cycle; `--publish` delivers each pass as a
branch and a pull request. [Deployment](deployment.md) has the image, the volumes and the
security posture.

## Where state lives

`$UPGRADER_HOME` (default `~/.cache/agents-fyi-upgrader`) holds:

- `ledger.json` — the durable record of settled `(repo, commit, from, to)` moves;
- working copies and per-run bundles;
- `state/` — the live progress and delivery feed a site admin can read;
- `records/` — step records, when the deployment sets `UPGRADER_RECORD`.

The ledger is **state, not a cache**. A deployment that drops the volume looks healthy while
re-deriving every step it ever ran; the startup line naming how many moves are settled is the
only thing that shows it.

## Next

- [CLI reference](cli.md) for every flag.
- [Configuration](configuration.md) for environment variables and project declarations.
- [Troubleshooting](troubleshooting.md) when a move refuses or a suite cannot run.
