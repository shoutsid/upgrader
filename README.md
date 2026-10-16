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
| `step` | runs the *first* release of that move end to end on a working copy this tool owns, and prints the record | a patch and the record, where `--record` says — and nothing to the corpus |
| `serve` | the service: a durable ledger, the service's queue, one step per repository per cycle | the run record and, for a failure, a report |

The default is `plan`, on the miner's reasoning: a tool whose first run writes into a
shared corpus is a tool that discovers its mistakes in the corpus.

```console
$ ./bin/agents-fyi-upgrader plan  --repo https://github.com/owner/application.git --to 7.1.0
$ ./bin/agents-fyi-upgrader step  --repo https://github.com/owner/application.git --to 7.1.0 --record ./out
$ ./bin/agents-fyi-upgrader serve --repos owner/application@main --to 7.1.0 --interval 600
$ AGENTS_FYI_URL=http://localhost:8001 ./bin/agents-fyi-upgrader plan --repo . --to 5.0.0
```

| Flag | Meaning |
|---|---|
| `--repo PATH\|URL` | the application: a local directory (read where it is, never written to) or a git URL |
| `--ref REF` | the branch, tag or commit to read — URLs only |
| `--to VERSION` | the Rails release the move ends at, e.g. `7.1.0`. Required, in every mode |
| `--api URL` | the service to ask; defaults to `$AGENTS_FYI_URL`, then to the public deployment |
| `--record DIR` | where `step` writes the patch and the JSON record |
| `--work DIR` | where `step` puts its working copy; defaults to `$UPGRADER_HOME` |
| `--home DIR` | this client's own directory: working copies and the ledger |
| `--repos OWNER/NAME[@REF]` | a repository for `serve` to walk; repeatable. Empty means the service's queue is asked |
| `--heartbeat FILE` | the file `serve` touches every cycle |
| `--interval SECONDS` | how long `serve` waits between cycles |
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

The pipeline has two stages that make the rest mean anything:

1. **inspect** — the Rails release from the application's own `Gemfile.lock`, the
   declared Ruby floor, the test command, and whether there is a suite at all.
2. **baseline** — the suite on the **unmodified** copy, before anything is written.
   Without it, "the upgrade broke the suite" and "the suite was already red" are one
   sentence, and the second files a report blaming a release for a pre-existing
   breakage.
3. **plan**, **apply** — the service's `POST /rails/scan` per step, then the mechanical
   edits, each with its line re-checked against the text the scan read. An edit whose
   line has moved is a refusal, not an edit.
4. **pin** — the Rails pin in the `Gemfile` is rewritten and `bundle update rails` runs.
   Only the meta-gem: an application that pins the framework as components has a
   different line for each one, and choosing which of them move together is a decision.
   That repository is refused, with a sentence saying what to do instead.
5. **rails** — `bin/rails app:update` (or `bundle exec rake rails:update` on an
   application old enough to have a `Rakefile` and no `bin/rails`). Added files are
   adopted; a file the application
   already owns keeps the application's version and the conflict is recorded.
   `config.load_defaults` is therefore never flipped, and that falls out of the rule
   rather than being a special case.
6. **boot**, **tests** — `bin/rails runner 'puts Rails.version'`, then the suite again,
   under `RAILS_ENV=test`, with `--step-timeout` as the ceiling.

`step` leaves a patch and a record, and it never writes to `--repo`: the working copy is
its own.

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
