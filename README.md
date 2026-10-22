# agents-fyi upgrader

A Ruby client that moves a Rails application one minor release at a time, and records what
the move cost: the patch, every command with its exit code, the suite's verdict before and
after, and every change the move carried that no machine may apply.

The tool is a client of the **agents-fyi** service. The ladder — what each Rails release
changed, and which of those changes a machine may make — lives in the service, not here.
The upgrader reads an application's own `Gemfile.lock`, asks the service what a move
crosses, and applies only what the service calls mechanical. It never invents a fix, and it
keeps no copy of Rails' release order: a second copy of that rule is how two answers to one
question start disagreeing.

The repository is **proprietary**. See [LICENSE](LICENSE). It is public so that operators
and reviewers can read the client, not because it is open source.

## What it gives you

- **`plan`** — what a move crosses, split into mechanical changes and decisions for a person.
- **`preflight`** — makes an old Gemfile installable at all: dead git protocols, deleted
  forks, pins that cannot sit beside the framework.
- **`step`** — executes the first release of a move on a working copy the tool owns: baseline,
  mechanical edits, the pin, `app:update`, a boot, and the suite again.
- **`serve`** — a durable loop over the service's queue, with a ledger, a heartbeat and,
  optionally, rungs chained inside a cycle.
- **`preview`** — renders the review brief a stored step record would publish, without a
  checkout, a token or a push.
- **`prune`** / **`republish`** — housekeeping for containers, per-run bundles and the bodies of
  pull requests that were already delivered.

The record is the product. A pass is not "the tool finished"; it is a suite that was green
before the move and green after it, a named verdict, and the evidence behind both.

## Requirements

- **Ruby 3.3 or newer** (the image pins 3.3.12).
- **git**.
- **Docker** if a step executes on an era interpreter (`UPGRADER_RUNTIME=docker`, the
  deployment's runtime). A hand-run `step` can use the host's Ruby instead.
- Network access to the service, to `index.rubygems.org` for research, and to the
  application's repository.

There is no Gemfile and no `bundle install`. The tool deliberately has no runtime gem
dependencies; `Bundler::LockfileParser`, a default gem, is the only lockfile reader it uses.

## Quick start

```bash
git clone https://github.com/shoutsid/upgrader.git
cd upgrader
./bin/agents-fyi-upgrader --help
```

Point it at the service. There is **no default service**: the deployment or the caller must
name one. The public deployment is `https://agents.shoutsid.fyi`.

```bash
export AGENTS_FYI_URL=https://agents.shoutsid.fyi
./bin/agents-fyi-upgrader plan --repo /path/to/a/rails/app --to 7.1.0
```

`--to` is optional for `plan` and `step`: without it, the target is the top of the service's
ladder. `serve` reads the service's queue each cycle; an account project's `to` is its destination,
`--to` is the deployment-wide fallback, and `--walk` reads an empty target as the top of the
ladder. A row with no destination is skipped and named — a deployment that has not decided where
a repository is going must not start walking it.

A write or a queue read needs an operator key:

```bash
export AGENTS_FYI_KEY=your-operator-key
```

Anonymous reads — the ladder, a plan, and a scan of source you send — need no account. The key
is sent as `X-API-Key`; the tool never accepts an admin token for these operations.

A first step writes nothing to your repository:

```bash
./bin/agents-fyi-upgrader step \
  --repo https://github.com/owner/application.git \
  --to 7.1.0 \
  --record ./out
```

`step` clones a working copy, or adds a detached `git worktree` for a local repository. Your
files, index and `HEAD` are left exactly as they were. An export with no `.git` is refused by
name rather than copied into something that could be confused with your own tree.

## Modes at a glance

| Mode | What it does | Writes |
|---|---|---|
| `plan` | reads the lockfile, asks the service what the move crosses, prints the plan | nothing |
| `preflight` | repairs an old Gemfile so it can be installed | a working copy the tool owns, and `preflight.json` with `--record` |
| `step` | runs the first release of the move end to end | a patch and a record with `--record`; nothing to the corpus |
| `serve` | one step per repository per cycle, over a durable ledger | run records with `--record`, and reports for failures |
| `serve --walk --publish` | chains rungs, and delivers each pass as a branch and a pull request | the corpus, branches and pull requests |
| `preview` | renders a stored record as a review brief | nothing |
| `republish` | re-renders and updates the bodies of already-delivered pull requests from their records | the pull-request body |
| `prune` | removes containers and bundles left by finished or killed runs | nothing that belongs to a live run |

Exit status is part of the contract:

| Code | Meaning |
|---|---|
| `0` | a plan was printed, a step passed, or the loop stopped cleanly |
| `2` | a refusal — a fact about the move, such as a backwards or unplannable upgrade |
| `1` | a failure — a fact about the repository, the service or the machine; includes an `unverified` step |

`unverified` is **not** success: nothing established that the move worked, so the step exits
`1` and the record says why.

## Documentation

- [Getting started](docs/getting-started.md) — install, authenticate and run a first plan.
- [CLI reference](docs/cli.md) — every command, flag and exit code.
- [Configuration](docs/configuration.md) — environment variables, project declarations and
  working-copy policy.
- [Architecture](docs/architecture.md) — what a step does, stage by stage.
- [Service API](docs/service-api.md) — the endpoints this client calls.
- [Deployment](docs/deployment.md) — the image, the volumes, the loop and its security posture.
- [Design notes](docs/design-notes.md) — why the tool is shaped this way, including the
  measured failures that changed it.
- [Limitations](docs/limitations.md) — what this version does not prove.
- [Development](docs/development.md) — tests, layout and the cross-repository contracts.
- [Troubleshooting](docs/troubleshooting.md) — the failures operators actually hit.
- [Changelog](CHANGELOG.md).

## Development

```bash
cd upgrader
ruby -Ilib -Itest test/all_test.rb
```

The standalone suite needs no network and no Rails application. The client's agreements
with the service — its ladder, schema, gem digest, frozen scan recording and deployment —
live in the service's own contract suite, because only a checkout that holds both sides can
test them. See [Development](docs/development.md).

## Contributing

This is a proprietary repository. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening an issue or a pull request; contributions are accepted only by prior arrangement.
Security reports go through [SECURITY.md](SECURITY.md), not a public issue.

## License

Copyright (c) 2026 James Summerill. All rights reserved. No use, copying, modification,
publication, distribution, sublicensing or sale is permitted without prior written
permission from the copyright holder. See [LICENSE](LICENSE).
