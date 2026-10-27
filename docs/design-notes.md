# Design notes

These are the decisions behind the shape, including the ones that changed after a real walk.
They are kept because the alternative is a future change re-learning the same failure.

## The ladder is the service's, and a default is a second copy

A tool that chose `--to` for you would need Rails' release order. The first version had a default
target and a `no_target` refusal explaining that "a default arrives when the service exposes the
top of its ladder". That is now true: `plan` and `step` read `top` from the service when no target
is named. `serve` still idles without a target unless `--walk` is set or the project declaration
supplies one, because a deployment that has not decided where it is going must not start walking
somebody's application.

The same reasoning gives the client **no default service**. A walker that quietly talked to the
deployment its author ran would answer from a corpus its caller did not choose. `AGENTS_URL`
or `--api` names it, and a mode that needs one and has neither refuses.

## The engine is stack-agnostic, and the project is the adapter

The first complete walk measured the engine knowing one application: it named `bin/rails`,
`bundle exec rspec`, `agents-services`, `RAILS_SECRET_TOKEN`, the era image prefix and the
GitHub target. None of those is a fact about walking Rails; all of them are facts about the
application that was walked first. A second project measured by that engine would not crash — it
would quietly be measured with the first project's knowledge, which is worse.

So a **project declaration** carries the application's facts: where it lives, the ref to start
from, the releases to move between, the suite command, the services it needs, the *names* of the
environment variables its suite reads (never their values), the interpreters it may use, the
source roots a rule may scan, its checks, its style and update policy, its delivery provider and
any decisions already accepted. A **stack pack** — `rails` today — carries what a release changed
and how a command is spelled for that stack. The engine asks the pack and reads the project; it
names no repository, command, secret or volume of its own.

The declaration is validated before it is walked, by name, so a typo is refused at startup rather
than becoming a setting that silently does nothing. This is also why `UPGRADER_PROJECT` and
`UPGRADER_PROJECTS_DIR` exist: a deployment can point the same engine at a different application
without rebuilding it, and the built-in declarations are a fallback rather than the definition of
what the tool can walk.

## A decision is a first-class object

Some changes cannot be made by a rule: a view has to choose between two resources, a configuration
line has to name a value only the application knows, or a change is correct for one rung and wrong
after it. The first walk made several of these by hand and left them in a note. That is not a
mechanism, and the next walk would have to make the same decisions again.

An accepted decision therefore has a question, the evidence that produced it, the options, the
answer, who accepted it, and a list of **effects** — edits with the same shape the walk's own
edits have. The effects are applied on every later walk, in a declared order, before the baseline
is measured. That ordering is the point: a decision is part of how the application *is*, so a red
suite after the move remains attributable to the move. An effect whose text does not occur exactly
once is a refusal, not a silent no-op, and an effect scoped to a rung does not leak into the rungs
after it. A declaration is a file and can carry anything, so `accepted_by` is checked here as well
as in the service; an unaccepted proposal is a note, not machinery.

## Recall happens before the walk acts

The corpus is useful at the moment a rung is about to be planned, not after it has failed. The
client asks the service, with the move's gems and versions, for what other walks observed: the
reports filed against that move, the fixes that resolved them, and how those fixes were verified.
The answer is a **brief**, and it travels in the record and in the review body rather than staying
in a log. A brief that lived only in the log was the failure the first walk kept paying for: the
operator who reviews the pull request could not see what the walk knew before it decided.

## Settled is not delivered

A passed rung and a delivered pull request are two facts, and the loop used to conflate them. A
rung whose branch push or pull-request call failed was marked settled and never retried, so the
work existed only on a machine that had already moved on. Delivery now has its own queue: the
ledger records what was settled, and a settled rung with an unfinished delivery is retried before
new work is planned. The same distinction applies at the end of a walk: a target at its top
release is **done**, and asking the ladder to move it again is a refusal, not a new run. Recording
that refusal every cycle is how a finished walk grew a queue while learning nothing.

## A refusal is an output, not a crash

Exit status is three values:

- `0` — a plan, a passed step, or a clean stop;
- `2` — a refusal: a fact about the **move**;
- `1` — a failure: a fact about the **repository**, the **service** or the **machine**.

Collapsing `2` into `1` reads "the ladder will not plan this" as "the tool crashed". A caller then
retries a refusal forever, or treats a real failure as a known answer. The service's own sentence
travels with the refusal so the caller knows which direction the ladder reads or which release has
no chapter.

## `unverified` is not a pass

The first build treated `unverified` as success: the step ran, so it exited `0`. A real walk
found the failure — an interpreter could not reach GitHub, so every era failed to install, and
every step exited `0` while measuring nothing. `unverified` means no interpreter installed the
bundle, the suite could not run, the baseline was red, or a required check did not run. It exits
`1`, because a caller that reads only the exit code has to be told that nothing was established.

The record still distinguishes `failed` from `unverified`. One is a result; the other is the
absence of one, and the two want different responses.

## The baseline is the measurement's precondition

A suite that was red before the move cannot say anything about the move. For an application from
2013 this is ordinary: the first application walked had 133 examples red on a `secret_key_base`
error a 4.0.0.rc1-era generator had written the old way. The step repairs the baseline first, with
the same bounded repair budget it uses after the move, and the record says "the suite was red;
this made it green; then the move". A verdict that said "the suite was green before this step"
for a tree that was repaired first would describe an application measured before it was fixed.

## The scan looks below the rung, and a rule matches the old form

An application can declare Rails 4.0 and still call code that release's rung asked it to change.
The first walk did: it called `find(:all, conditions: …)`, a change documented for the rung that
arrives at 4.0, and it kept working until 4.1 because `activerecord-deprecated-finders` was still
a dependency. At 4.1 the gem is gone, and the suite failed on a change no step had been asked
about.

So the scan window starts at the ladder's `earliest`, not at the application's version. A rule
matches the **old** form, so a rule for a rung already crossed finds nothing, and one that was
missed finds the line its note describes. An entry carries the rung that named it, so a decision
for an earlier rung says so rather than pretending it belongs to this one.

A rule whose own idempotence guard matches a line has **read** the application and found nothing
to do. That is an answer, not a refusal. The first real walk's residue said three decisions were
owed for `link_to … confirm:` lines that already carried `data: { confirm: … }`; the fix was to
separate "already reads the new way" from "nobody can read this line" and name the first rather
than asking a person to look at it.

## The preflight has no rung, and says what it deferred

`preflight`'s subject is the Gemfile an old application cannot install at all, not a rung's
changes. It does not take `--to` for that reason. A gem-migrations entry whose condition needs the
rung is therefore **deferred**, and the record says which half was skipped. The alternative —
guessing a rung — would apply a change that belongs to a release the caller did not ask about.

The general repairs are facts about a protocol or a repository: `git://` was stopped by GitHub in
2022, a fork may be deleted, a pin may not sit beside the framework. Those hold whatever rung is
being walked.

## A declaration carries names, never values

A project declaration that carried `RAILS_SECRET_TOKEN=abc` would be a secret in an image and in
every record that prints the declaration. `env_names` accepts the shape of a name and rejects
anything else. The value belongs in the deployment — `UPGRADER_SUITE_ENV` or
`UPGRADER_SUITE_ENV_FILE` — and is merged only into commands that run the application.

The suite environment arrived as a **value** rather than a mounted file after a real failure: a
bind mount is a dependency on the host's file sharing, and with that off the setting named a path
the container could not see. The repository's suite could never boot, and the container reported
healthy the whole time. The entrypoint writes the value into the container's own home (a volume,
mode 600, rewritten each boot) and hands the CLI the path.

## `app:update` adopts only what it adds

A file the application already owns keeps the application's version, and the conflict is
recorded. Overwriting it is a decision, not a safeguard. `added_only` is the only adoption rule
this build implements; a policy that claimed to merge files it did not understand would be worse
than the explicit conflict.

New framework defaults are a separate decision from adopting generated files. `app_update.framework_defaults`
defaults to `off`; `step` lets `UPGRADER_DEFAULT_STEPS` spend a suite run per toggle. The order is
load-bearing: defaults are stepped only after the move's own suite passed, so a red run is about
the toggle and not about the move.

## The suite is one check, not the gate

A green `bundle exec rspec` is the test check. An application's CI may also run a linter, a static
analyser, a build and a browser job. Treating the suite as the whole gate was measured on the
first walks. A check is declared with a kind and, for a local check, a command. An external check
must say **where** it runs; `environment: "ci"` is only valid alongside `external`, because this
walker cannot reproduce the application's CI environment.

A failed required check makes the rung `failed`. A required check that did not run makes it
`unverified`. A check that is not declared is not therefore green: the record and the brief say
which checks were not run.

## The repair agent is bounded, and the suite is the verdict

Repair is off by default because it is the only setting that spends money. A step whose baseline
was green and whose post-move suite went red gets a bounded number of attempts by a model in the
step's own tree, each followed by the suite again. The model's word never passes a rung; the
suite does.

Three failures shaped the loop:

- **A timeout is a kill, not a wait.** One attempt is a model call with a tool loop in it. An
  agent that hangs must not hold a walk for ever.
- **`ran` and `timed_out` are separate facts.** An agent that could not be started never touched
  the tree, so asking again asks the same nothing. One killed at the deadline spent the whole
  budget and may have left a patch behind; the first live attempt ran fifteen minutes and was
  recorded as "did not run", which stopped the loop before the suite ever looked at what it had
  changed.
- **The config lives outside the worktree.** `opencode run` resolves the project root from the
  repository the worktree points at, so a config written beside the application was never read
  and the agent answered `Agent not found: "repair"` in 1.3 seconds. `OPENCODE_CONFIG` names the
  file outright, and it lives in this client's home: no file in the application's tree, and none
  to clean up.

The generated config names the `repair` agent explicitly. An unknown agent name makes
`opencode run` fall back to `build`, which has a shell — the one capability this loop removes.

## A bundle is evidence; a gem is an artifact

A `.gem` is a file the index published a hash for, so a copy of it is not a claim about anything
and two readers cannot disagree about it. A **bundle** is what those gems are unpacked into and
executed from; sharing one between runs would mean a verdict was produced in a tree another run
had changed. Bundles are per-run and live inside the working copy, which is on the state volume.
`prune` removes a bundle only when no live run is using it.

The same split, one ecosystem over, is why the gem cache may be shared and the bundle may not.

## Scratch is on the volume, not in a tmpfs

A tmpfs is a memory leak with a filesystem API. `/tmp` in a container is RAM, and every
`gem install`/`bundle install` unpacks each gem and each native build into `TMPDIR`. One measured
run accumulated **4.1 GB within thirty-five minutes**, hundreds of unpack directories, the
container pinned against its memory limit — and the failure was not a memory error. Installs
began failing with an empty message, then the process died mid-cycle with no traceback.

`TMPDIR` is on the cache volume in the image, and `/tmp` is a small bounded tmpfs for whatever
ignores it. A subprocess that fails with no output at all never ran; that points at resources,
not at the command.

## A container is a step's, and a killed process runs no `ensure`

`docker run --rm` removes a container whose own process exits. The era container is a keepalive
that never exits, so `--rm` alone leaves it running. The step's `ensure` stops it on every path,
including the ones that raise.

A process that is **killed** runs no `ensure` at all. Eight containers had accumulated before the
first `docker ps` looked. `Machine::Container.reap!` is the answer: `prune` runs it, and every
step and loop runs the same pass before starting one of its own.

## Every daemon call is bounded

A `docker` CLI call can block while the daemon's containerd path is held, and it does not fail —
it waits. Measured on one deployment three times in an afternoon, with every metadata call still
answering in milliseconds: `docker rm --force` after a passed rung, `docker run` twice before an
era container existed, and `docker rm -f` on the container that started it, still `Up` twenty-two
minutes later. The wedge was containerd's, but an unbounded call is not a slow step; it is a walk
that stops. Every daemon call has a deadline, and a teardown has a shorter one than a start.

## The era is the oldest the floor allows

The machine selection reads the rung's `requires_ruby` and chooses the **oldest** era that
satisfies it, not the newest available and not the ledger's last machine. The ledger is keyed per
repository, so a walk that climbs keeps a hint at or below the next rung's floor and never changes
the answer; a walk re-entered from below inherits the era of the rungs above it. That is how the
6.0 rung came to run on Ruby 2.7 for a floor of 2.5 and be `unverified` on a red baseline.

The application's own facts — a `ruby` line, a `RUBY VERSION` — are where the selection starts.
An environment that exists is not an environment that is finished: `rvm` creates an interpreter
before it installs anything, and a build killed halfway leaves a directory that looks usable. The
client probes by **installing the application's own bundle**; the interpreter that can install it
is the one that can run its suite. Every candidate's attempt, and the reason it was rejected,
travels in the record.

## The ledger is state, not a cache

The ledger remembers settled `(repository, commit, from, to)` moves, the verdict and the machine.
It is consulted before anything runs, because a step costs a bundle resolve and a suite. Losing it
does not produce an error; it produces a healthy container that re-derives every step it ever ran.
The startup line naming how many moves are settled is the only thing that shows it.

A settled entry is checked against the machine this step would get. A verdict produced on a
machine that is no longer the one available is re-opened rather than trusted: a fact about a
machine must not outlive the machine.

`--force` is the operator's answer when the ledger says no and the operator knows better. The
ledger is a memory, not a lock.

## The working tree is reset to its checkpoint

A clean tree is not proof that the last step finished. Concern commits move `HEAD`, so a process
killed after one leaves a clean tree sitting on a half-move. The next cycle would plan from a
`Gemfile.lock` the interrupted step had already rewritten, and report a skipped rung as a step
that passed. The checkpoint marker is the commit the rung started from, and a tree at any other
commit is put back before a lockfile is read.

## A paused queue is not an empty queue

An empty queue means wait. A queue the service is not serving means the index is not collecting,
and retrying will not help. The client raises on the second rather than returning `[]`, because
the two want opposite responses. This is the mining queue's lesson one ecosystem over: a paused
list read as an empty one made a service's own queue go unused while the log said everything was
fine.

The loop asks for a bounded slice (`100`) and comes back after doing the work. A client that asks
for more than the service will serve gets a refusal, and a refusal read as "no queue" is the same
failure in a different spelling.

## Empty and finished look identical from outside

A loop that has walked everything and a loop that is stuck both print `0` work and wait. The
cycle therefore names its reasons, and the ledger's settled count is printed at startup. A
scheduling decision that cannot say why it did nothing is indistinguishable from a broken one.

## The entrypoint's flags are checked against the CLI

`entrypoint.sh` once passed `--log-level` to a CLI that accepts no such flag. `OptionParser`
raised, `serve` exited `2` with a usage refusal, and the container never started — while the
compose service, its `start_period` and its healthcheck all described a working loop. The suite
was green throughout.

There is no logging framework to level, so the flag was removed rather than implemented. The
artifact test now compiles the entrypoint's health probe and checks every flag the script passes
against the CLI's own usage text. A flag added to one side and not the other is a red suite, not a
five-minute boot that ends in a refusal.

## The record is the product

A patch alone says what changed, not whether it worked or what was refused. The record carries
the baseline, the post-move suite, every command and exit code, the refusals with their reasons,
the decisions in force and the machine. `preview` renders the review brief from the record alone,
and `serve` stores the rendered brief beside the delivery.

The body is rendered once and stored, so a retry does not re-render it and a site admin reads the
bytes the pull request carried rather than reimplementing the body in another language.

## An execution is not a verification

A report filed by the walker is evidence, not independent verification. The service promotes a
report to `resolved_verified` only through operators other than its author, and a walker that
files a failure has done the mining half, not the verification half. This tool does not claim
otherwise; see [Limitations](limitations.md).

## What the walk will not infer

The tool reads and executes an application, and the temptation to fill a gap with a plausible
answer is the failure mode behind several of the rules above. Four of them are worth stating on
their own:

- **A probe that could not be made is not evidence about anything.** A timeout, a wheel that did
  not install, a container with no interpreter: those are `unverified`, not "the change is
  fine" and not "the change is broken". The third answer is a distinct value all the way out to
  the verdict.
- **A field that means two things gets read as the wrong one.** A refusal's `kind` is the kind of
  *change*, not this tool's reason for refusing. A candidate repair is not the same field as a
  repair that was executed. When two questions share a field, one of the answers is already
  wrong.
- **Character similarity is not evidence of a rename.** The closest string in a release is not
  the successor of a removed name; a rename keeps the name's words. A fix the corpus cannot
  support is worse than the removal it can.
- **A stage that quietly does less than its name says is a lie by omission.** A scan that sent
  fewer files, a bridge that did not run, or a `to_s` the tests never called with a real run's
  input all look healthy from the outside. The record names what was skipped and why; a count
  with no reason is not an answer.
