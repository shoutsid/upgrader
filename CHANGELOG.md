# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows semantic
versioning for its command-line surface and record format.

## [Unreleased]

### Added

- `--version`, so an issue can name the client build without reading the source.

### Fixed

- `--work` is honored: a step places its working copy and per-run bundle there instead of
  silently leaving them under `$UPGRADER_HOME`.
- `UPGRADER_RVM_ROOT` and `UPGRADER_RVM_GEMSET` reach the rvm machine instead of being read only
  by the setup script.
- A bare `sha256:…` in `UPGRADER_INTERPRETER_IMAGES` inherits the matrix image's repository.
- Record names are readable (`owner-application-7.0.0-7.1.0.json`) rather than the sanitized raw
  URL; `republish` still finds a record written under the old name.

## [0.1.0] - 2026-10-21

### Added

- `plan`, which reads an application's `Gemfile.lock`, asks the service what a Rails move crosses,
  and prints the mechanical changes, the decisions and the refusals without writing anything.
- `preflight`, which repairs a Gemfile that cannot be installed at all: dead `git://` remotes,
  deleted forks and pins that cannot sit beside the framework.
- `step`, which executes the first release of a move on a working copy the tool owns: preflight,
  machine selection, bundle install, services and database, baseline, scan and rules, gem moves,
  the Rails pin, `app:update`, boot, the post-move suite, optional framework defaults, optional
  repair, and the declared checks.
- `serve`, the durable loop over the service's queue, with a ledger, a heartbeat, per-rung backoff,
  chained rungs (`--walk`) and pull-request delivery (`--publish`).
- `preview`, which renders the review brief from a stored record without a checkout, a token or a
  push.
- `republish` and `prune`, for already-delivered pull-request bodies and for what killed runs
  leave behind. Failed deliveries are retried by `serve`, not by `republish`.
- Project declarations: the repository, base ref, releases, suite, services, environment names,
  eras, delivery, source roots, checks, toolchain, style and `app:update` policy as data.
- The era matrix and the local builders for the interpreter images and the rvm interpreters.
- A standalone test suite that needs no network, no Rails application and no service, plus
  cross-repository contracts in the service's own suite for the ladder, schema, digest, frozen
  recording and deployment.
- The container image, with build arguments for the step toolchain, the Docker client and the
  optional repair agent.
- Documentation for the CLI, configuration, architecture, service API, deployment, design notes,
  limitations, development and troubleshooting.

### Security

- The client holds an operator key, never an admin token. It has no database driver and no route
  to the service's database.
- The repair loop is off by default and bounded; the model never supplies the verdict.
