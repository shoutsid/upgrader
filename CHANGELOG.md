# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows semantic
versioning for its command-line surface and record format.

## [Unreleased]

### Changed

- The project is **Agents**. The client is `agents-upgrader`, the namespace is
  `Agents::Upgrader`, the environment variables use the `AGENTS_` prefix, the state directory is
  `~/.cache/agents-upgrader`, and the image tags use `agents-upgrader`. The old names are not read
  or accepted; this is a breaking rename, so the client is `0.2.0`.

### Added

- A browser suite runs in the era container without an edit to the application: the machine
  writes Chromium's `/etc/chromium.d` drop-in (no sandbox, no `/dev/shm`) and seeds
  `webdrivers`' cache from the driver Debian builds with the browser, so the gem's retired
  storage endpoint is never asked. Both are recorded as a `browser` stage.
- **A live-Debian era ships a pinned Chrome for Testing beside the distribution's Chromium, and
  the project says whether its suite drives a browser and which one** (`toolchain.chrome`:
  `pinned` or `distro`, and the key's absence means no browser at all, so a project without `:js`
  examples pays nothing). The distribution's browser moves under a test stack that does not:
  measured on `ohana-api`, 19 `:js` examples failed on bookworm's Chromium 156 and 1,557 examples
  passed with 0 failures on 120, same tree and same bundle. An archived era's image carries no
  browser, so the step installs its frozen package; a Firefox suite is the one browser package
  that stays in `toolchain.apt`, because no era image carries Firefox.
- A red suite's template route failures are repaired from the application's own router — the
  declared helper for a controller and action, with the variables its controller reads from
  `params` — and a repair that made the suite green is filed to the corpus as a report with the
  derived edit as its fix, so the next walk reads the failure and its answer instead of
  re-deriving them.
- A serialized column the release refuses to load is repaired from the class the failure names:
  the release's own `config.active_record.yaml_column_permitted_classes` line is written into
  `config/application.rb`, once, before any component initializer reads a row.
- A spec that asserted a response's MIME type reads it through `response.media_type` when 6.1's
  `content_type` returns the header whole (charset included) — the release's own accessor for the
  value the assertion was written against.
- 7.0's moved translation setting is repaired from the removed setter the suite names:
  `config.action_view.raise_on_missing_translations` moves to
  `config.i18n.raise_on_missing_translations` in every environment file that carries it, value
  unchanged.
- A spec that identifies a link by a translation key the application never defines keeps the
  `href:` it already names: 7.1 raises on a missing translation wherever `I18n.t` is called, and
  the label half of the assertion could never have been a link's text. The failure parser also
  reads a class ending in `Data` (`I18n::MissingTranslationData`) and keeps the exception's own
  message when a source excerpt is printed above it.
- 7.0's removed `ActiveModel::Errors#keys` is repaired from the NoMethodError that names the class:
  the failing line reads `attribute_names`, the reader that answers the same list.
- `--version`, so an issue can name the client build without reading the source.
- A project queued from the service wakes a sleeping `serve` loop instead of waiting out the
  poll interval; the interval remains the fallback when the projects volume is not mounted.

### Fixed

- A pin that does not resolve ends the rung: `app:update`, the boot and the suite no longer run
  against a bundle that still names the release the move left, so one unresolvable gem is one
  question rather than four.
- `app:update` no longer gates a rung. Its refusal is recorded beside the run and named in a
  passing verdict, while boot and the suite decide the move — Rails 8's `active_storage:update`
  refused on an application with no Active Storage tables whose suite was green.
- A stopped rung posts one root-cause question. `app:update` conflicts and the plan's manual
  changes after an earlier failure are recorded but no longer posted as separate questions, and a
  red baseline is retried rather than parked behind a question nobody can answer.
- A passed rung that was never published is delivered from its own record. `step` publishes only
  with `--publish`, so a rung walked by hand while the loop was not publishing settled with no
  delivery at all — nothing revisits a settled rung, so the chain kept a hole for ever (measured:
  ohana 7.1.6 passed by hand at 19:17, and 7.2.4 was being measured on top of a checkpoint whose
  branch had never been pushed). The loop now reads that rung's record — its last concern commit
  and its tree — and publishes it without walking it again; a rung whose record is gone is stated
  and its repository blocked rather than guessed at from the patch.
- A patch checkpoint records the release its lockfile pins as the move's `from`, so a walk that
  starts at `4.1.16` chains each request on the branch below it instead of basing every one on
  the default branch.
- A chained rung is associated with GitHub's stacked-pull-request object: the second request
  creates the stack and each later one is appended, so the layers show as one stack and can
  merge together. A refused association is logged and leaves the branch and its request intact.
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
