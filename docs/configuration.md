# Configuration

Everything here is read from the process environment, a project declaration, or a command
line flag. The precedence is:

1. a command-line flag;
2. a project declaration, for the repository, ref or target the caller did not set;
3. the environment variable that seeds the flag (`AGENTS_FYI_URL`, `UPGRADER_HOME`,
   `UPGRADER_PROJECT`);
4. the default named below.

The tool has no configuration file of its own, no `~/.upgraderrc`, and no default service.
A setting that is not present is a setting the caller did not make.

## Environment variables

### The client

| Variable | Default | Meaning |
|---|---|---|
| `AGENTS_FYI_URL` | none | the service base URL. `--api` overrides it. A mode that needs the service and has neither refuses to run. |
| `AGENTS_FYI_KEY` | empty | the operator key, sent as `X-API-Key`. Empty means anonymous reads only. |
| `UPGRADER_HOME` | `~/.cache/agents-fyi-upgrader` | worktrees, the ledger, per-run bundles, `state/` and the repair agent's config. `--home` overrides it. |
| `UPGRADER_PROJECT` | empty | the project declaration walked when `--project` is not named. |
| `UPGRADER_PROJECTS_DIR` | none | a directory of declarations read **before** the built-in ones. A file here shadows a built-in of the same slug. |
| `UPGRADER_PUBLIC_URL` | empty | the public base a review brief links reports to. Empty names reports rather than linking them. |
| `UPGRADER_IMAGE` | empty | an optional stamp appended to the machine identity in the ledger, for example `agents-fyi-upgrader:0.1.0`. |
| `UPGRADER_COMMAND_TIMEOUT` | `900` | seconds one pipeline command may run before its process group is killed. |
| `UPGRADER_DEFAULT_STEPS` | empty / `0` | how many new framework defaults a step may try. Each toggle is a suite run. |
| `UPGRADER_GITHUB_TOKEN` | empty | the token `step --publish` uses. `serve --publish` asks the service for a connected account's credential instead. It is read and never written into a record. |

### Choosing a machine

| Variable | Default | Meaning |
|---|---|---|
| `UPGRADER_RUNTIME` | empty (native) | `docker` runs the application in an era container; `rvm` (or `host`) runs it on the host through rvm; anything else, including empty, runs it on this process's Ruby. |
| `UPGRADER_INTERPRETER_IMAGES` | empty | digest pins for era images, as `2.2=sha256:…,2.5=sha256:…`; a bare digest inherits the matrix image's repository. Empty uses the tags the matrix carries. |
| `UPGRADER_DOCKER_VOLUME` | discovered | the named volume the walker's home is mounted from, so an era container can mount the same worktree. Set only when discovery cannot answer. |
| `UPGRADER_RVM_ROOT` | `~/.rvm` | rvm's directory, for `UPGRADER_RUNTIME=rvm`. |
| `UPGRADER_RVM_GEMSET` | `agents-fyi-upgrader` | the gemset this tool keeps its eras in, so it does not install into the developer's default. |

### The repair loop

| Variable | Default | Meaning |
|---|---|---|
| `UPGRADER_REPAIR_ATTEMPTS` | `0` (off) | attempts a repair agent gets when a suite is red — the baseline before the move, or the suite after it. |
| `UPGRADER_REPAIR_TIMEOUT` | `600` | seconds one repair attempt may run. A timeout is a kill, not a wait. |
| `UPGRADER_REPAIR_MODEL` | empty | the model the agent is asked to use. Empty uses the agent's own configuration. |
| `UPGRADER_REPAIR_AGENT` | `repair` | the agent name in the generated config. |
| `UPGRADER_REPAIR_BINARY` | `opencode` | the agent binary, for an installation that names it differently. |

Repair is off by default because it is the only setting here that spends money. Turning it on
also needs an authenticated model in the agent's own configuration; the deployment's home volume
is the place for that credential, never the image.

### The service loop's entrypoint

These are read by `entrypoint.sh`, not by the Ruby client. They exist so a container can be
configured without changing its command.

| Variable | Default | Meaning |
|---|---|---|
| `API_BASE_URL` | `http://service:8001` | the service the loop calls. The entrypoint passes it as `--api`. |
| `UPGRADER_TO` | empty | the deployment-wide Rails release every move ends at. Empty uses each account project's own `to`; `UPGRADER_WALK` reads empty as the ladder top. A row with no destination is skipped. |
| `UPGRADER_INTERVAL` | `600` | seconds between cycles when there is nothing to do. |
| `UPGRADER_STEP_TIMEOUT` | `3600` | the ceiling for one application suite; a step runs several commands and may outlive it. |
| `UPGRADER_WALK` | empty | set to any non-empty value to pass `--walk`. |
| `UPGRADER_RUNGS` | empty / `3` | rungs `--walk` may chain in one cycle. |
| `UPGRADER_PUBLISH` | empty | set to any non-empty value to pass `--publish`. |
| `UPGRADER_FORCE` | empty | set to any non-empty value to pass `--force`. |
| `UPGRADER_CYCLES` | empty | stop after this many cycles. Useful for a proof run. |
| `UPGRADER_RECORD` | empty | the directory each step writes its record and patch into. |
| `UPGRADER_SUITE_ENV` | empty | `KEY=VALUE` lines, written into the container's own home and handed to the CLI as a file. |
| `UPGRADER_SUITE_ENV_FILE` | empty | a path to a suite environment file already inside the container. |
| `UPGRADER_PROJECT` | empty | the declaration to walk, passed through as `--project`. |
| `UPGRADER_PROJECTS_DIR` | none | read by the client itself; set here so the container sees the operator's declarations. |
| `UPGRADER_API_KEY` and `UPGRADER_API_BASE_URL` | none | not read by this client. A deployment wrapper may use these names and map them to `AGENTS_FYI_KEY` and `API_BASE_URL`. |

`UPGRADER_REPOS` is **retired**. The service's queue is the deployment's source of work; a
second list in the environment would override the order the service computes, silently.
`--repos` remains for a one-off manual `serve`.

There is deliberately no `UPGRADER_LOG_LEVEL`. This client has no logging framework: its output
is the CLI's report and one line per cycle. A level flag that filtered none of it would be a
setting that lies.

## Project declarations

A project is an application the walk can be pointed at, declared as JSON rather than coded into
the tool. It supplies the facts that belong to one application: where it lives, which ref the
walk starts from, which releases it moves between, how its suite runs, which services it needs,
which environment **names** its suite reads, which interpreters it may use, and where a passed
rung is delivered.

Declarations are read from:

1. an explicit directory passed to `Project.find(..., dir:)`; the CLI does not expose one, and it
   exists for tests and embedders;
2. `UPGRADER_PROJECTS_DIR`, the operator's directory;
3. `lib/agents_fyi/upgrader/data/projects/`, the built-ins shipped in the image.

A file in an earlier directory shadows one of the same slug later. A named project that cannot
be read is a refusal at startup, naming the directories it looked in; one bad file does not hide
the others from a catalogue listing.

### Required fields

| Field | Meaning |
|---|---|
| `slug` | the name `--project` and `UPGRADER_PROJECT` use |
| `repo` | `owner/name` or a full git URL; normalised to one clone URL |
| `from` | the Rails release the walk starts at, for example `7.2.0` |
| `to` | the Rails release the walk ends at, for example `8.0.0` |

### Optional fields

| Field | Default | Meaning |
|---|---|---|
| `base_ref` | the repository's default branch | the branch or tag the walk starts from |
| `stack` | `rails` | the stack pack. `rails` is the only pack this build carries. |
| `suite` | `{"kind":"none"}` | `kind` is `rspec`, `minitest` or `none`; `command` is required unless `kind` is `none`. |
| `services` | `[]` | names of services the application needs, for example `postgres`, `redis`. |
| `env_names` | `[]` | environment **names** the suite reads, for example `RAILS_SECRET_TOKEN`. A value here is rejected. |
| `eras` | `"auto"` | `"auto"` or a list of era names the walk may use. |
| `delivery` | `{"provider":"none","chain":false}` when absent | where a passed rung goes: `provider` is `github` or `none`; `branch` defaults to `agents-fyi/upgrade-<release>` for GitHub; inside an object, `chain` defaults to `true`. |
| `source_roots` | `[]` (the whole repository) | relative directories a rule may scan, for example `app`, `lib`, `components`, `engines`. An absolute path or one containing `..` is rejected. |
| `checks` | `[]` | the rest of the application's gate, beside the suite. |
| `toolchain` | none | build facts, carried and quoted; the overlay image that spends them is a later phase. |
| `style` | none | a formatter and the check that verifies it. |
| `app_update` | see below | what `app:update` may adopt and whether framework defaults are stepped. |
| `decisions` | `[]` | accepted decisions, with effects the walk applies on every run. |

**An unknown key is an error, not a comment.** A typo is a setting that silently does nothing,
and a walk that ignores a setting its operator believes is in force is the failure the
declaration exists to prevent.

### A complete example

```json
{
  "slug": "storefront",
  "repo": "acme/storefront",
  "base_ref": "main",
  "from": "7.2.0",
  "to": "8.0.0",
  "stack": "rails",
  "suite": {
    "kind": "rspec",
    "command": "bundle exec rspec"
  },
  "services": ["postgres", "redis"],
  "env_names": ["RAILS_SECRET_TOKEN"],
  "eras": "auto",
  "source_roots": ["app", "lib", "config", "components", "engines"],
  "delivery": {
    "provider": "github",
    "branch": "agents-fyi/upgrade-<release>",
    "chain": true
  },
  "checks": [
    {
      "id": "rubocop",
      "kind": "lint",
      "command": "bundle exec rubocop",
      "required": true
    },
    {
      "id": "packwerk",
      "kind": "static",
      "command": "bundle exec packwerk check",
      "required": true
    },
    {
      "id": "assets",
      "kind": "build",
      "command": "bin/rails assets:precompile",
      "required": false
    },
    {
      "id": "browser",
      "kind": "external",
      "external": true,
      "environment": "ci",
      "reason": "runs in the application's GitHub Actions job; this walker has no browser"
    }
  ],
  "toolchain": {
    "ruby": "3.2.2",
    "node": "20",
    "postgres": "16",
    "extensions": ["pg", "nokogiri"],
    "apt": ["libvips42"],
    "native": ["libvips"]
  },
  "style": {
    "format": "bundle exec rubocop -A",
    "check": "bundle exec rubocop"
  },
  "app_update": {
    "adopt": "added_only",
    "skip": ["config/credentials.yml.enc", "config/master.key"],
    "skip_unused_engines": true,
    "framework_defaults": "off"
  },
  "decisions": []
}
```

### What the fields decide

**`suite`** is the test check and is always required in the record. `kind: "none"` is a real
answer: an application without a suite is measured by its boot, and a declaration that says so
is not one typo away from a declaration that forgot.

**`env_names`** names environment variables; the values live in the deployment (`UPGRADER_SUITE_ENV`
or `UPGRADER_SUITE_ENV_FILE`) and never in the declaration. A value in a declaration would be a
secret written into an image and into every record that prints the declaration.

**`checks`** is what the suite alone was hiding. A green `bundle exec rspec` is only the test
check; an application's CI may also run a linter, a static analyser, a build and a browser job. A
check that is not declared is not therefore green — the record and the pull request say which
checks were not run. `kind` is one of `test`, `lint`, `static`, `build`, `prepare`, `external`.
An `external` check must carry a `reason` saying where it runs; `environment: "ci"` is only valid
alongside `external`, because this walker cannot reproduce the application's CI environment.

**`toolchain`** is carried, quoted and validated, but the overlay image that spends it is not in
this build. It is still worth declaring: it is a fact a reviewer can check against the
application's CI, and it is what the later phase reads.

**`style`** adds the declared `check` to the gate. `format` may write; `check` asks the same
question without writing.

**`app_update`** defaults to `adopt: "added_only"`, `skip: []`, `skip_unused_engines: true`,
`framework_defaults: "off"`. `added_only` is the only adoption rule this build implements: a file
the application already owns keeps the application's version and the conflict is recorded,
because overwriting it is a decision and not a safeguard. `framework_defaults: "step"` lets
`UPGRADER_DEFAULT_STEPS` spend a suite run per toggle; `off` leaves `config.load_defaults` alone.

**`decisions`** is the operator's accepted answers, with effects the walk applies. They are data
so a decision is a first-class object rather than a note in a pull request body. The shape is
checked at load; the meaning of an effect belongs to the code that applies it.

A `rule` effect's payload names the `change_key` it is about, the `kind` of mechanism, and a
nested `payload` with that mechanism's own fields. `skip` leaves that change out of the scan and
the residue, `expect` accepts a known failure so it is not filed as a new report, and `rewrite`,
`insert` and `config` are tree edits through the same line-checked applier as every other effect.
`rewrite` carries `old`/`new`, `insert` carries `path`/`after`/`text`, and `config` carries
`key`/`file`/`value` (or the `path`/`find`/`replace` a config effect already uses).
`applies_when` scopes any rule to a rung, and a condition this build does not know refuses rather
than applying everywhere.

## Choosing a machine

A step executes the application's commands somewhere. The three answers are deliberately
different, and none is a fallback for another:

- **`native`** (the default when `UPGRADER_RUNTIME` is empty or unrecognised) runs the suite on the
  interpreter this process runs on. It is the right choice for a modern application and a person's
  laptop. It cannot install a 2013 application's bundle, and it should not try.
- **`docker`** starts one era container per step, from the image the ladder says the rung's Ruby
  requires, and sends every application command in with `docker exec`. It needs a Docker daemon,
  the `docker` client in the image, the socket mounted, and a named volume the era container can
  mount for the worktree. `entrypoint.sh` sets nothing about this; the deployment does.
- **`rvm`** (or `host`) runs the era's Ruby from an rvm installation on the host, with a services
  container beside it publishing ports. It is faster than a container per step and weaker as
  evidence: the machine identity is the interpreter, the gemset and bundler, not an image digest.

The machine is written into the ledger and the record. A verdict is stamped with the interpreter
and, when `UPGRADER_IMAGE` names one, the image, because a native extension may build in one and
not the other. A stamp that named only the interpreter was how a fact about a machine outlived
the machine.

## Working copies

`step` and `preflight` never write to `--repo`.

- A **git repository** handed to `step` or `preflight` is opened as a detached `git worktree`;
  the caller's files, index and `HEAD` are left exactly as they were. `plan` reads a local path
  in place.
- A **URL** for `plan` is cloned once into `$UPGRADER_HOME` and reused, because a plan is asked
  for repeatedly while a move is worked out. `preflight` and `step` make a fresh clone for each
  run: a step leaves a tree with a moved pin, an installed bundle and `app:update`'s added files,
  and a copy nobody wants to resume from.
- A **directory with no `.git`** given to `step` or `preflight` is refused by name. Copying it
  would produce a tree that looks like the caller's but is not, and a patch against it would be a
  claim about a repository the tool never read. `plan` can read such a directory's lockfile
  because it writes nothing.

`--work` moves a step's working copy, and the per-run bundle that goes with it, away from
`$UPGRADER_HOME`; the ledger stays under the real home. `--record` puts the patch and the JSON
record somewhere the caller can find them. The bundle lives outside the working tree and is
deliberately not shared: it is what gems are unpacked into and executed from, so it is evidence,
not an artifact. `prune` removes a run's bundle only when no live run is using it, and it only
knows `$UPGRADER_HOME`: a tree or bundle placed with `--work` is outside its inventory.

## The ledger

`$UPGRADER_HOME/ledger.json` remembers settled `(repository, commit, from, to)` moves, the
verdict and the machine that produced it. It is **state, not a cache**. A deployment that drops
the volume looks healthy while re-deriving every step it ever ran; the loop's startup line naming
how many moves are settled is the only thing that shows it.

`--force` sets a settled entry aside for one run. The ledger is a memory, not a lock: a reset
target or a corrected declaration may legitimately need the same rung again.

`state/` is a separate feed, written to be read by a site admin or an operator: what the loop is
doing, the deliveries it has made and the projects it can see. It is not the ledger and nothing
else writes it.

## Publishing

The delivery credential depends on the mode:

- **`step --publish`** reads `UPGRADER_GITHUB_TOKEN`, which needs `contents: write` and
  `pull_requests: write` on the repository.
- **`serve --publish`** asks the service for a short-lived credential for the repository's
  connected GitHub App installation. A repository with no installation publishes nothing, and
  the cycle says so. There is deliberately no deployment-wide customer credential to fall back
  to; the account admin surface is where the connection is repaired.

Each passed rung becomes a branch named by the declaration (`agents-fyi/upgrade-<release>` by
default), and with `chain: true` each pull request targets the rung before it rather than the
base branch. A step that did not pass is never published: a branch is a claim that the rung
works.

A delivery that fails is recorded, and `serve` retries it on its next cycle from the stored
record. `republish` is the separate maintenance pass for an **already-delivered** request whose
body should be re-rendered; it does not move a branch, and it does not retry a missing push.

## The application's environment

A repository whose secrets are git-ignored — a `config/application.yml`, a `.env` — cannot boot
its own suite from a fresh clone. `--suite-env FILE` merges `KEY=VALUE` lines into every command
that runs **the application**: the suite, database preparation, `app:update` and the boot. It is
never merged into this tool's own commands.

In a container, the ordinary way is `UPGRADER_SUITE_ENV`, a value rather than a mounted file. The
entrypoint writes it to `$UPGRADER_HOME/suite.env` (mode 600, on a volume, rewritten each boot)
and hands the path to the CLI. A bind mount is a dependency on the host's file sharing; with that
off, the setting names a path the container cannot see, and the repository's suite can never boot
while the container reports healthy. `UPGRADER_SUITE_ENV_FILE` remains for a deployment that
already has a file inside the container.

### What a fresh clone is missing

A clone is the repository, not a working application. A file the repository git-ignores — a Rails
application's `config/database.yml`, a fork's own settings file, a `.env` — and ships a tracked
`<name>.example` or `<name>.sample` beside is local configuration the repository's own README tells
a person to create. The walker copies the missing target before it reads anything, and records the
copy as a `bootstrap` stage; an existing target is never overwritten, a file git does not ignore is
not local configuration, and an example the repository does not track is not the repository's
statement. `config/database.yml` is the one that matters most: the services stage reads it to
decide which server to start, so a walk that skipped this measured a suite about a database nobody
had provided.

**The bundle's groups are read from the application, not declared here.** A gem in an
`optional: true` group is installed only when `BUNDLE_WITH` names that group; a gem in the
`development` group is not installed at all under the walk's `BUNDLE_WITHOUT`. The walker reads
the Gemfile through Bundler's own DSL and adds the group that carries a gem it actually needs:the gem behind the adapter the application's `database.yml` names (the suite will load it), or the
executable a project command runs (`bundle exec rubocop`). `pg` declared in
`group :postgresql, optional: true` beside `adapter: postgresql` is the measured case — without
it the baseline failed on a gem the application had declared all along — and a declared formatter
whose gem is development-only left every rung `unverified` rather than measured. A Gemfile the
DSL refuses falls back to the environment every walk had before this rule existed.

## Repair

A step whose baseline is red, or whose post-move suite goes red, can ask an agent for help. The
agent works in the step's own tree; every attempt is followed by the suite again. The verdict is
always the suite's, never the model's. The record carries the failure, the attempts, the files
the repair changed and the diff, so a repair nobody can audit is not accepted as a change.

The loop is off unless `UPGRADER_REPAIR_ATTEMPTS` is a positive integer. One attempt is a model
call with a tool loop in it, and a timeout is a kill rather than a wait: an agent that hangs must
not hold a walk for ever. The generated config names the `repair` agent explicitly, because an
unknown agent name makes `opencode run` fall back to `build`, which has a shell — the one
capability this loop removes.
