# agents-fyi upgrader

A client of the **agents-fyi** service that moves a Rails application one minor release
forward, and records what that cost: the patch, every command with its exit code, the
suite's own verdict before and after, and every change the move carried that no machine
may apply.

The ladder lives in the service, not here. This tool reads an application's own
`Gemfile.lock`, asks `GET /rails/upgrade` what the move crosses, and applies only what
the service says is mechanical. It never invents a fix, and it keeps no copy of Rails'
release order — a second copy of that rule is how two answers to one question start
disagreeing, which is the failure this project has paid for more than once.

## Modes

| Mode | What it does | Writes |
|---|---|---|
| `plan` | resolves the application, reads its Rails release, and prints the steps and the split between mechanical and manual changes | nothing |
| `preflight` | makes an old Gemfile installable at all — the `git://` protocol GitHub stopped accepting in 2022, a fork that has been deleted, a pin that cannot sit beside the framework — from the service's gem-migrations digest, on a working copy this tool owns | a copy this tool owns, and `preflight.json` where `--record` says |
| `step` | runs the *first* release of that move end to end on a working copy this tool owns, and prints the record | a patch and the record, where `--record` says — and nothing to the corpus |
| `serve` | the service: a durable ledger, the service's queue, one step per repository per cycle — or, with `--walk`, rungs chained inside a cycle up to `--rungs` | the run record and, for a failure, a report |
| `serve --walk --publish` | the unattended walk: an empty `--to` reads as the top of the service's ladder, and every passed rung becomes a branch and a pull request chained to the rung before it | the corpus, the branches and the pull requests |
| `prune` | removes what finished and killed runs left behind — the step container of a killed run, and the bundle a run installed (per-run by design, ~150 MB each, and the bind mount every step's container is given) — the same pass `step` and `serve` run before starting one | nothing: it removes only what belongs to a process that is gone |

The default is `plan`, on the miner's reasoning: a tool whose first run writes into a
shared corpus is a tool that discovers its mistakes in the corpus.

`preflight` is the half of a walk that cannot be established by installing anything: an
application whose sources are dead fails its install for a reason no interpreter matrix
can fix, and the digest it reads (`GET /gems/migrations`) is the *documented* half of gem
upgrades — each entry a claim about an index and a repository, naming where it was read
from. `step` runs the same preflight as its first move, before it chooses an interpreter,
because the choice *is* a `bundle install`.

```console
$ ./bin/agents-fyi-upgrader plan  --repo https://github.com/owner/application.git --to 7.1.0
$ ./bin/agents-fyi-upgrader preflight --repo https://github.com/owner/application.git --record ./out
$ ./bin/agents-fyi-upgrader step  --repo https://github.com/owner/application.git --to 7.1.0 --record ./out
$ ./bin/agents-fyi-upgrader serve --repos owner/application@main --to 7.1.0 --interval 600
$ AGENTS_FYI_URL=http://localhost:8001 ./bin/agents-fyi-upgrader plan --repo . --to 5.0.0
```

| Flag | Meaning |
|---|---|
| `--repo PATH\|URL` | the application: a local directory (read where it is, never written to) or a git URL |
| `--ref REF` | the branch, tag or commit to read — URLs only |
| `--to VERSION` | the Rails release the move ends at, e.g. `7.1.0`. Optional in `plan` and `step` — without it the target is the top of the service's ladder (`GET /rails/ladder`), because "to what?" is a question the service answers better than this tool. `serve` requires it deliberately: a deployment that has not decided where it is going must not start walking somebody's application |
| `--api URL` | the service to ask; defaults to `$AGENTS_FYI_URL`, then to the public deployment |
| `--record DIR` | where `step` writes the patch and the JSON record |
| `--work DIR` | where `step` puts its working copy; defaults to `$UPGRADER_HOME` |
| `--home DIR` | this client's own directory: working copies and the ledger |
| `--repos OWNER/NAME[@REF]` | a repository for `serve` to walk; repeatable. Empty means the service's queue is asked |
| `--heartbeat FILE` | the file `serve` touches every cycle |
| `--interval SECONDS` | how long `serve` waits between cycles |
| `--walk` | `serve` only: chain rungs inside a cycle, and read an empty `--to` as the top of the service's ladder |
| `--rungs N` | `serve --walk` only: how many rungs one cycle chains (default 3 — one rung is a bundle install and a suite, and a cycle that never returned would leave the heartbeat untouched for a day) |
| `UPGRADER_DEFAULT_STEPS` | how many new framework defaults one step may try: each is the application's own suite run (`Defaults`). Empty or 0 is off — a deployment decides whether a rung may cost that |
| `UPGRADER_REPAIR_ATTEMPTS` | the repair budget, and the only setting here that spends money. Empty or 0 is off (the library's default); a deployment turns it on with a number, and an agent working in the step's tree gets that many attempts. It needs an authenticated model — the agent uses opencode's own configuration (`UPGRADER_REPAIR_MODEL` pins which model is asked) |
| `--suite-env FILE` | `step`/`serve`: `KEY=VALUE` lines merged into every command that runs *the application* (the suite, the database preparation, the update, the boot) — for a repository whose secrets are not in it, which is the ordinary case: a git-ignored `config/application.yml`, a `.env` |
| `--publish` | `step`/`serve`: a passed rung becomes a branch and a pull request chained to the rung before it. Needs `UPGRADER_GITHUB_TOKEN` (a token with `contents: write` and `pull_requests: write`); the token is never written down, and every message on the way out has it replaced |
| `UPGRADER_RUNTIME` | which machine a step executes on: `docker` (the era's container — the default, and the answer for an old application on a modern host), `rvm` (the host's own interpreter for the era, through rvm, with one services container for the whole walk), or anything else — including nothing — for this process's own Ruby |
| `UPGRADER_RVM_ROOT` | where rvm lives, for `rvm` mode; defaults to `~/.rvm` |
| `UPGRADER_RVM_GEMSET` | the rvm gemset the eras are installed in, for `rvm` mode; defaults to `agents-fyi-upgrader`, because a walk must not install its gems into the gemset a developer uses for their own work |
| `--step-timeout SECONDS` | how long one suite may run |
| `--cycles N` | stop `serve` after N cycles; the default is never |

There is no `--log-level`. This client has no logging framework — its output is the
report and one line per cycle — and the flag that pretended otherwise was a bug worth
the sentence: `entrypoint.sh` passed it to a CLI that never accepted it, so the
container exited 2 with a usage refusal while its compose block, healthcheck and
`start_period` all described a loop that was running.

A URL is cloned once, shallow (`--depth 1`), into `$UPGRADER_HOME`
(`~/.cache/agents-fyi-upgrader`) and reused: a plan is asked for repeatedly while a move
is worked out, and re-cloning per question is slower and less honest about what was read.

**`step` never edits what `plan` read**, and the three cases are worth stating because
"it does not write to your repository" is the claim an operator is entitled to check:

* a **URL** gets a fresh shallow clone per run (`work/<digest>/run-<id>`) — a step leaves
a tree in a state nobody wants to resume from: half a bundle, a rewritten `Gemfile`,
`app:update`'s added files;
* a **local git working tree** gets its own `git worktree add --detach`, which shares the
object database and leaves the caller's tree, index and `HEAD` exactly as they were — so
the promise holds for the files *and* for git's own state;
* **anything else** — an export, a copy with no `.git` — is refused by name, because there
is no copy this tool could make that could not be confused with the caller's own files,
and inventing one is how a tool edits the tree it promised not to touch.

### Exit status

| Code | Meaning |
|---|---|
| `0` | a plan was printed, a step ran and did not fail the suite, or the loop stopped cleanly |
| `2` | a refusal — the ladder will not plan this move, or the tool will not guess a target. The sentence says which. |
| `1` | a real failure — no `Gemfile.lock`, an unreachable service, `git`, or a step whose suite was green before it and failed after |

Two and one are kept apart on purpose. A refusal is a fact about the *move* (this
service reads forward upgrades; it has no chapter for the release after 8.1), and a
failure is a fact about the *repository* or the machine. Collapsing them is how a
refusal gets read as a crash — and a caller that retries a refusal retries it forever.

`unverified` is a **success** for the exit status: the step ran, and nothing was able to
check it — no suite in the application, or a suite that could not run. A caller that
only reads the exit code cannot be told a nuance it did not ask for, and one that reads
the recorded JSON gets all of it. The verdict is in the record, and the sentence beside
it says which of the four it is and why.

`--to` is required in every mode, and the refusal that says so explains why: a default
target needs the top of the ladder, and this tool would rather refuse than hold a second
copy of Rails' release order. A default arrives when the service exposes the ladder
itself.

## What one step does

The pipeline has three stages that make the rest mean anything:

1. **inspect** — the Rails release from the application's own `Gemfile.lock`, the
   declared Ruby floor, the test command, and whether there is a suite at all.
2. **preflight** — the Gemfile made installable where a machine may: a `git://` remote
   rewritten in both the Gemfile *and* the lockfile (Bundler reads the protocol out of the
   lockfile's own `remote:` lines), and the service's gem-migrations digest applied —
   a dead fork replaced by its release, a gem that cannot sit beside the framework
   removed. A declaration it cannot rewrite in full (a comment, several lines, a
   `require:` that changes behaviour) is skipped *with the reason*, and a digest entry for
   a gem the application does not declare becomes a decision rather than an edit.
3. **machine** — which interpreter executes the application. An application old enough to
   be interesting cannot be installed on the Ruby running this tool, so the step chooses:
   the era container for the step's floor when `UPGRADER_RUNTIME=docker`, this process
   when it is not and its interpreter meets the floor, and a recorded `unverified` verdict
   naming the floor when neither can. The choice *is* the install: `bundle install` is run
   through each candidate in turn (`Interpreters`, `Machine`) and the first interpreter
   that can install the application's bundle is the one that can run its suite.
4. **baseline** — the suite on the copy as it arrived, before anything the *move* writes.
   Without it, "the upgrade broke the suite" and "the suite was already red" are one
   sentence, and the second files a report blaming a release for a pre-existing
   breakage. The preflight's repairs happened before this and are in the record under
   their own stage: they are a precondition of measuring, not a change the move is judged
   for.
5. **services**, **database** — PostgreSQL and Redis started inside the step's container
   from the application's own `database.yml` (`images/services.sh`), then the schema the
   suite needs (`db:create db:test:prepare`, best-effort and named beside a suite failure
   rather than being one).
6. **plan**, **apply** — the service's `POST /rails/scan` per step, then the mechanical
   edits, each with its line re-checked against the text the scan read. An edit whose
   line has moved is a refusal, not an edit. **Then this tool's own rules**
   (`lib/agents_fyi/upgrader/rewrites.rb`): the scan locates a call site and deliberately
   stops — its contract is a statement about the ladder — and a rule that edits code is
   this tool's, applied to what the scan located, through the same line-checked write.
   A change a rule applies stops being a decision, and the record says which rules did
   it — with the change's own note, because the decision a rule withdrew carried the
   ladder's caveat. Rules are *instances of families* (`name_moved`, `option_wrapped`,
   `line_removed`, `call_replaced`, `finder_moved`, `find_conditions`, `option_added`,
   `argument_wrapped`, `block_value`, `value_moved`, `line_replaced`,
   `query_materialised`, `superclass_moved`, `setting_removed`, `call_inverted`,
   `option_renamed`, `call_unwrapped`, `parameter_added`, `block_captured`), so the next lighthouse
   writes an instance of
   an existing family, and every change no rule covers carries a **gap** saying what
   would close it — the residue is a queue with reasons, not a list. A change whose fix
   is a *judgement* rather than an edit gets a **survey** instead: it reads the
   application and names the lines the decision is about (which callers of a
   `default_scope` read differently, which lines assign to a `has_many_attached`
   collection, which aliases shadow a method the file defines, and — through
   `survey_calls` — the call sites a decision can only show one of), and the evidence travels
   in the decision, so "none found" is a sentence a reader gets rather than silence.
   A rule may also need
   a **file** to exist (a model cannot inherit from `ApplicationRecord` before that class
   does), and the step writes it before the suite runs. A change whose note's own replacement
   is a **gem** is handled by a declaration rather than by an edit — the call sites keep
   working — and the gem goes inside the block that names its group, because a test-only gem
   declared at the top level is installed in production; such a *bridge* is selected by what
   the scan located, by the rung itself when `app:update` is what will write the evidence
   (`bootsnap`), or by a file in the tree (`sprockets-rails`) — and a change whose answer is a
   *version* rather than a presence is the same table's `floor` (`Spring` becomes
   `gem "spring", ">= 3.0.0"`). `docs/upgrades.md` has the policy.
7. **gems**, **research** — `POST /releases/route` with the lockfile, the interpreter
   the step executes on and the Rails release it moves to, then the `move` verdicts
   applied as Gemfile rewrites with their reasons. A pin the routing could not answer
   about is *researched* first — this client can reach `index.rubygems.org` and the
   service cannot — and the routing is asked again. `replace`/`remove` are the
   preflight's; `blocked` and `unknown` are decisions, never a silent pass.
8. **pin** — the Rails pin in the `Gemfile` is rewritten and `bundle update rails
   --conservative` runs: the locked version of every gem the resolution does not have to
   change is kept, because a rung moves Rails and not the world. The lighthouse proved the
   cost of the alternative — an unconstrained resolve pulled rake 12.3.3 beside Rails 4.1
   (railties asks only `rake >= 0.8.7`), and `rails:update` died on
   `Rake::Application#last_comment`, which rake 11 removed. The gem moves applied just
   before are honoured, since their requirements are what the resolve must satisfy.
   Only the meta-gem is rewritten: an application that pins the framework as components
   has a different line for each one, and choosing which of them move together is a
   decision. That repository is refused, with a sentence saying what to do instead.
9. **rails** — `bin/rails app:update` (or `bundle exec rake rails:update` on an
   application old enough to have a `Rakefile` and no `bin/rails`). Added files are
   adopted; a file the application
   already owns keeps the application's version and the conflict is recorded.
   `config.load_defaults` is therefore never flipped *by `app:update`*, and that falls out of
   the rule rather than being a special case — the pass below flips it deliberately, one
   default at a time.
10. **boot**, **tests** — `bin/rails runner 'puts Rails.version'`, then the suite again,
    under `RAILS_ENV=test`, with `--step-timeout` as the ceiling. Then, *off unless
    `UPGRADER_DEFAULT_STEPS` says otherwise*, the **new defaults are stepped**: one toggle from
    `config/initializers/new_framework_defaults_*.rb` enabled, the suite run, kept if green and
    put back if not. When every toggle passes, the file is dropped and
    `config.load_defaults <minor>` is written into `config/application.rb` — both files saved
    first, so the one more suite run that proves the surviving state can be reverted exactly.
11. **repair** *(off unless `UPGRADER_REPAIR_ATTEMPTS` says otherwise)* — in **two** places,
    in this order. Before the move, when the **baseline** is red: nothing has been changed yet,
    the failure is the application's own, and a red baseline makes everything after it
    unmeasurable — which is how applications old enough to need this walk usually arrive (the
    first real one's suite was 133 examples red on a Rails 4.0.0.rc1-era config). And after the
    move, when the suite went red with a green baseline beneath it. Both are the same budget
    and the same agent: it may read and edit and nothing else, because the application executes
    on an era interpreter inside a container and a shell in its hand cannot run what it reasons
    about. **The verdict is still the suite's** — a repaired step passes because the suite says
    so afterwards, never because a model said it fixed something — and every attempt is a
    stage: the command, its exit code, the agent's closing words and the files it touched. A
    repaired baseline is named in the verdict, because "the suite was green before this step"
    is false without that clause.

`step` leaves a patch and a record, and it never writes to `--repo`: the working copy is
its own.

## The machine a step runs on

**A Rails move is a sequence of Rubies.** Rails 4.2 wants 1.9.3, 5.0 wants 2.2.2, 6.0
wants 2.5, 7.0 wants 2.7, 8.0 wants 3.2 — and this tool runs on one interpreter, chosen
for reading lockfiles and asking the service questions. A step, though, installs a real
application's bundle and boots it, and `json 1.7.7` does not compile on Ruby 3. So each
era is its own container, described by a matrix rather than by code:

* `lib/agents_fyi/upgrader/data/interpreters.json` is the matrix — one row per era, each
  base pinned by digest, with the era's own Ruby version, its Bundler, and how its Debian
  release is reached (jessie, stretch and buster have moved to `archive.debian.org`).
* `images/Dockerfile` builds every era from one recipe, parameterised by the matrix; the
  `scripts/upgrader-images.sh build` script (also `./scripts/dev.sh ruby-images`) turns
  each row into an image and prints its digest. `UPGRADER_INTERPRETER_IMAGES` pins those
  digests, so a rebuilt image is a deliberate change rather than a quiet one.
* Each image carries what a Rails suite of its era needs beyond the interpreter:
  PostgreSQL and Redis **inside the container** (a 2013 `database.yml` says `localhost`,
  and a service on a Docker network is not localhost — so nothing about the application's
  configuration has to be edited to make its suite run), a compiler and the usual `-dev`
  headers for native gems, ImageMagick, Node for `execjs`, and a fresh CA bundle.

**Selection is probed, not declared.** `Interpreters.candidates` orders the eras that meet
the step's floor — starting from the interpreter the application's own `ruby` line or
`RUBY VERSION` names, preferring the era a previous attempt actually used — and the step
runs `bundle install` in them in that order. The first one that can install the bundle is
the machine; every attempt, with its reason, travels in the record. No candidate at all is
`unverified` with the floor named, never a silent fallback.

**What the container is.** One `docker run -d … sleep infinity` per step, with commands
sent in by `docker exec` — one container per *step* and not one per command, because the
services the suite needs live inside it and would die with a per-command container. The
walker's home is mounted at `/agents-fyi`; a containerised walker joins the same *named
volume* it is itself on (discovered from the daemon; `UPGRADER_DOCKER_VOLUME` overrides),
because a bind mount written from inside a container names a host path the daemon would
create empty. Containerised commands run as the walker's uid — named by `images/start.sh`,
since `initdb` and libpq's default username both resolve through a passwd entry a bare uid
does not have — and the container itself is removed when the step is done with it. **A
walker that is *killed* rather than ended runs no cleanup at all**, and `--rm` does not save
it: the process inside the container is a keepalive that never exits, so the container keeps
running with its Postgres and its Redis until something looks. Every container therefore
carries the pid of the walker that owns it, `step` and `serve` remove what a dead owner left
behind before they start their own, and `prune` is that same pass by hand. The same rule applies
to the bundle a run installs: it is per-run on purpose (a killed step must not leave a
half-installed gemset for the next to trust), so a finished run's is dead weight in the home
every step mounts — 21 of them and 2.0 GB here, which took one `docker run` from twenty seconds
to five minutes.

A step executed this way needs Docker at runtime. A deployment that runs the loop in a
container (see `docker-compose.yml`) mounts `/var/run/docker.sock` and sets
`UPGRADER_DOCKER_GID` to the socket's group; a hand-run `step` on a host needs neither, and
can instead run natively on an interpreter that suits the application.

**`UPGRADER_RUNTIME=rvm` is the third machine, and it is the fast one.** The application's
commands run in this process's own namespace — no container to start, which was the slowest
thing a walk did (twenty seconds healthy, ninety when the daemon degraded, paid once per
interpreter candidate) — and the interpreter is the *era's*, resolved through rvm's wrappers:
`~/.rvm/wrappers/<ruby>@<gemset>/bundle` is a real executable that sets `GEM_HOME`, `GEM_PATH`
and the interpreter before exec'ing, so a command is an argv with one bin directory in front of
`PATH`. `scripts/upgrader-rubies.sh install` sets a host up (interpreter, gemset, the era's
bundler, the wrappers) and `check` says which eras are missing.

Its services are a **sibling container with published ports**, kept for the whole walk rather
than started per step: an application running on the host reaches `localhost`, which is what a
2013 `database.yml` says — so `127.0.0.1:5432` is the era image's own PostgreSQL, the roles and
databases in the application's `database.yml` are created by the same script the container
machine runs, and the file is never edited for the machine's convenience. It is the *era's*
image (an old suite may need that era's PostgreSQL) and it is replaced when a step's era changes,
not restarted per step. The application's own ports are used when they are free; when they are
not, a free port is chosen and `PGHOST`/`PGPORT` carry it.

**What `rvm` mode trades away is the digest.** A container's identity is its image's content id,
which is what makes a rebuilt era a *different* machine to the ledger; a host interpreter's
identity is its version, its gemset and its bundler, and a gem or a system library that changed
under those versions is not noticed. The stamp says exactly that and no more. It is also why
`docker` remains the default: the era images carry the era's **C libraries** (ImageMagick 6 for
rmagick 2.x, libpq, the era's PostgreSQL), which a modern host does not have and which is the
part rvm cannot give you.

## What a run writes, and when

`contribute` decides whether a run goes into the shared corpus, and the split is the
difference between this class and a person running one step:

* **`serve` has it on.** The loop owns an operator's account and the decision to walk
  somebody's application at all, so a run made by the container is the one that is
  recorded: `POST /upgrades/runs` with the verdict, the commands and their exit codes,
  the patch, and every refusal — which is what the queue's order and the coverage figure
  are computed from.
* **A hand-run `step` leaves it off.** A person who asked what a move costs is not
  asking to write into a corpus other operators read. `--record DIR` is how they keep the
  evidence.

A step that **failed** also files a report, through `POST /reports/precheck` first, so
that duplicates are the corpus's decision rather than this client's. What it files is
what the run established: the move being made, the command that failed with its exit
code, and that command's output. It does **not** name a gem from the traceback — that
would be this tool deciding which of the application's dependencies is at fault — so a
filed report says `library: "rails"` with `version` set to the release it was moving to.
A `refused` step files nothing: a refusal is a fact about the ladder's coverage, its home
is the run's refusal list, and filing it would report this tool's own gap as somebody's
breakage.

## The queue

The **service** owns which repositories to walk and in what order, and `GET
/upgrades/targets` is where the loop gets them (whoever can reach the network fetches,
the service decides what it means). Every row carries the reasons for
its place — never attempted before attempted, the oldest pinned Rails first inside that,
and the source of the row — so an operator can read the order and argue with it.

`UPGRADER_REPOS` still exists and wins when it is non-empty: a deployment that named its
repositories meant it. Leave it empty and the loop asks the service, which is the shape
the queue exists for.

Two things about the queue are worth stating because both cost work rather than lines:

* **A stale row costs the deployment.** A target naming a repository that has been
  renamed or deleted is walked, fails to clone, and is attempted again next cycle — work
  attempted and failed for ever, against a queue the service believes is good. Removing
  a repository from the world means removing it from the queue.
* **A failed queue read is never an empty queue.** An unreachable service logs the reason
  and walks nothing this cycle; an empty queue says it is empty. "There is no work" and
  "I could not ask" want opposite responses, and a fallback that caught both is a trap
  this project has already paid for.

## The ledger

`ledger.json`, on the `upgrader_cache` volume, keyed
`(repo, commit, from_version, to_version)` → verdict. It is **state, not a cache**:

* **The startup line is the only thing that shows a lost volume.** `serve` names how many
  moves are settled before it does anything, and a deployment that dropped the volume
  looks completely healthy while re-deriving every step it ever ran.
* **A verdict is stamped with the machine that produced it.** `ruby 3.3.12
  (agents-fyi-upgrader:latest)` — the interpreter and the image, because they decide
  whether a refusal is a fact about the repository or about the machine. A record whose
  stamp no longer matches this one is re-opened rather than trusted.
* **A refusal and a failure settle differently.** `passed`, `unverified` and `refused`
  are settled on arrival — re-deriving a refusal reaches the same refusal — while
  `failed` is retried up to `MAX_ATTEMPTS` (3), because the usual cause is a release that
  was briefly unreachable and giving up on the first attempt abandons work that would
  have succeeded.
* **An unreadable file is set aside, never guessed at.** A partially understood ledger
  either redoes settled work or, worse, reports it settled; the file is renamed beside the
  original with the reason kept, and the ledger starts empty.

A cycle is hours long — a bundle resolve, an `app:update`, the application's own suite —
so a step that is interrupted settled nothing and is simply retried. That falls out of the
ledger rather than needing code: only a finished step is recorded.

## An execution by the author of a finding is not independent reproduction

This tool files findings, and therefore it cannot verify them. It runs the application's
own suite on its own working copy, so what it records is a real execution — and it is
still the execution *the finding came from*, which is why the service's `verifier` and
`verifier-independent` accounts exist: the corpus promotes a report to
`resolved_verified` only on the word of operators other than its author.

**And there is a limit to write down rather than paper over.** Those verifiers check a
report by re-deriving an executable claim from it — for a gem, `verifying._ruby_claim`
reads a `change_kind` of `symbol_removed`, `symbol_renamed` or `symbol_moved` and the
reference the report names, then probes the two releases. A report this tool files has no
`change_kind` and names no call site, so there is nothing for that method to derive and
the check returns **no vote** — the verifier's third answer, which is the honest one for a
probe that cannot be made. An application-level failure is therefore application-level
evidence: real, recorded, and confirmed by nobody today. Closing that gap means the
verifiers gaining a Rails-shaped method of their own, which is a phase, not a switch.

## Serving

`docker compose` runs this image as the `upgrader` service, with `entrypoint.sh` in front
of the loop: it waits up to five minutes for `/health`, then starts anyway, because an API
that is down is something a loop waits out rather than a reason not to start.

* **The heartbeat** is a file the loop touches every cycle, and it is what the
  healthcheck reads (`< 5400s` old, three cycle intervals). The process being up says
  nothing about it working, and a loop whose corpus went away looks exactly like one that
  is thinking — for hours.
* **SIGTERM stops the loop between steps**, not inside one. The wait is a flag checked
  every half second rather than a queue a trap handler pushes to, because a trap handler
  runs where some thread primitives are off limits and the failure that gets wrong is a
  container that cannot be stopped at all. The `stop_grace_period` is 60s: it has to
  cover one step's tail, not a whole cycle, because the ledger checkpoints after each
  step.
* **One bad repository is not the loop's bad minute.** A clone that fails, a corpus that
  will not answer, an application whose lockfile cannot be read: logged, and the next
  repository is walked. The heartbeat still moves.
* **The key is an operator's, and never `ADMIN_TOKEN`.** `AGENTS_FYI_KEY` inside the
  container (from `UPGRADER_API_KEY` outside) is what lets it read the queue, record a
  run and file a report. Empty is a working configuration: the anonymous half of this
  client — the ladder, and the scan of the caller's own source — needs no account at all,
  and a write without a key is refused by the service with its own sentence.
* **`upgrader_cache` is state and `upgrader_gems` is not.** A `.gem` is an artifact the
  index published a hash for, so a copy of it is not a claim about anything and it may be
  shared with the verifiers. The bundle is what the gems are *executed* from, which makes
  it evidence, so it is built inside each working copy on `upgrader_cache` and shared with
  nobody.
* **The image is chosen by the step, not by an operator.** Every step of the ladder
  carries `requires_ruby`, so the interpreter is a fact about the move, and a step whose
  floor no image meets is a *recorded refusal* naming the interpreter rather than a crash.
  A step whose floor no image meets is a *recorded refusal* naming the interpreter, not a
  crash.

## Why this has no dependencies

No Gemfile, no `bundle install`, no gem cache for the tool itself — the image needs
`ruby`, `git` and nothing else. That is not thrift for its own sake: a dependency here is
a version to pin, a lockfile to update, and one more thing that can be the reason an
upgrade run did not happen. The one thing this tool does need from the ecosystem, it gets
from the interpreter itself: `Bundler::LockfileParser` is a default gem, and it is the
*only* correct reader of a `Gemfile.lock` — the file has a grammar (an
indentation-significant `specs:` tree, a `RUBY VERSION` section, platform variants) and a
regex over it is a bug waiting for the first application that is formatted unusually. The
service reads the same file its own way, because it must read a `Gemfile.lock` without
Ruby; that is one reader more than this project likes, and it is why this side adds no
third.

Ruby 3.3 or newer, which is the interpreter `components/upgrader/Dockerfile` pins by digest — the
same one every refusal message these modules read was captured on.

## Tests

```console
$ cd upgrader && ruby -Ilib -Itest test/all_test.rb
```

No network and no Rails application: the corpus client is stubbed at the transport, the
shell is a stub that records what it was asked to run, and what does need to be real is a
throwaway `git` repository in a temporary directory — the pin rewrite, `git status`
against a working copy and the patch are all things a fake repository would let this suite
be wrong about. The decisions are what is asserted: the verdict and the sentence beside
it, which files `app:update` may keep, the order the baseline runs in relative to the
tools that wait on it, and what a run does and does not write to the corpus.

`AGENTS.md` carries the invariants a change here has to keep, and
[`docs/api.md`](../docs/api.md#a-rails-upgrade-step-by-step) carries the ladder itself — the
steps, their changes and the refusals they can produce.
