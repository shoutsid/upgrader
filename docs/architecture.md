# Architecture

The upgrader is a client, not a service. It reads an application, asks the agents-fyi service
what a Rails release changed, applies the changes the service calls mechanical, and measures the
result with the application's own suite. It has no database, no ladder of its own and no admin
credential. The worst it can do to the corpus is what any operator with the same key can do, and
it can be stopped while the service carries on.

That shape is deliberate. The rule this product is built on — what each Rails release changed,
and which of those changes a machine may make — is the service's. A tool that knew "the next
release after 4.2 is 5.0" would be a second copy of the ladder, and a second copy is how two
answers to one question start disagreeing. The tool asks the source of the rule instead.

## The ladder and the two halves of a move

A move crosses documented changes. The service splits them into:

- **mechanical** — a change with a pattern a machine can locate and a fix it can apply. The scan
  returns call sites, and the tool applies them.
- **manual** — a change that needs a person's judgement. It travels in the record and the review
  brief as a decision, with the reason and the evidence.
- **inert** — a change the ladder documents that no pattern on either side can find. It is not
  silently dropped; the record says the change exists and that nothing could look for it.

The scan runs from the ladder's own `earliest` release, not from the application's pinned
version. An application can declare Rails 4.0 and still call code that release's rung asked it to
change, because a dependency kept the old path working until the next release removed it. A rule
matches the **old** form, so a rule for a rung the application has already crossed finds nothing
to rewrite, and one it missed finds exactly the line its note describes. A change that is found
already in the new form is named as satisfied rather than counted as a decision.

The scan reads only the caller's source, sends a bounded amount of it (`MAX_SCAN_FILES` and
`MAX_SCAN_BYTES` in `step.rb`), and the service keeps nothing. A `413` is reported as the
service's own answer rather than retried smaller: silently scanning less would turn "nothing
found" into a claim about files nobody read.

## What one step does

`step` moves the application across the **first** release of the requested move. A move from 4.0
to 8.1 is not one step; it is a walk, and `serve --walk` chains the rungs.

```text
prepare a working copy
  -> read Gemfile.lock and the pinned Rails release
  -> ask the service for the rung's plan
  -> consult the ledger: is this move settled for this machine?
  -> preflight the Gemfile
  -> apply the project's accepted decisions
  -> choose a machine and install the bundle
  -> start services, prepare the database, build JavaScript/assets
  -> run the application's prepare checks
  -> run the suite before the move's own edits     (the baseline)
  -> if the baseline is red, repair it first
  -> run the scan, apply the service's edits and this tool's rules
  -> move the gems the route says must move
  -> rewrite the Rails pin
  -> run app:update
  -> re-prepare the database if the update added a migration
  -> format the application, if declared
  -> boot the application
  -> run the suite again                           (the post-move suite)
  -> step new framework defaults, if budgeted
  -> repair a red post-move suite, if budgeted
  -> run the rest of the application's declared checks
  -> write the verdict, the patch and the record
```

The order is the argument:

- **The baseline comes before the move's edits.** The preflight and accepted decisions are
  preconditions of measuring, not changes the rung is judged for; both are in the record under
  their own stages. A suite that was red before the move makes everything after it unmeasurable,
  so the baseline is repaired first if a repair budget exists. A reviewer then reads "the suite
  was red; this made it green; then the move", in that order.
- **The pin is rewritten after the gem moves.** The route's `move` verdicts are what a
  `bundle update rails` cannot work out for itself; applying them first makes a pin failure be
  about Rails rather than about a gem the route already named.
- **`app:update` adopts only what it adds.** A file the application already owns keeps the
  application's version and the conflict is recorded. Overwriting it is a decision, not a
  safeguard.
- **The new defaults are stepped only after the move's own suite passed.** A red run then
  belongs to the toggle and not to the move, which makes "revert this one" the right answer
  rather than a guess. Every toggle is a suite run, so `UPGRADER_DEFAULT_STEPS` is a budget.
- **The rest of the gate runs after the suite and its repairs.** A lint or static check that ran
  before a repair would judge a tree the suite never saw. A red check makes the rung fail; a
  required check that did not run makes it `unverified`, because the application's gate was not
  measured.

No application suite is invented. A declaration with `suite.kind: "none"` is measured by its
boot, and the record says so.

## Verdicts

Four words, and they are not interchangeable:

| Verdict | Meaning |
|---|---|
| `passed` | the suite was green before the step and green after it, and no required check failed or went missing |
| `failed` | a stage failed, a required check failed, or the suite was green before the move and red after it |
| `refused` | the ladder will not plan this move — a backwards move, an unknown release, or no rung for it |
| `unverified` | nothing was established: no interpreter installed the bundle, the suite could not run, the baseline was red, or a required check did not run |

`unverified` is a failure for the process's exit status (`1`), not a pass. A caller that reads
only the exit code has to be told that a step which measured nothing did not succeed; a caller
that reads the record gets the sentence saying which of the four it is and why.

The three exit codes are the contract:

- `0` — a plan was printed, a step passed, or the loop stopped cleanly;
- `2` — a refusal: a fact about the **move**, not the machine or the repository;
- `1` — a failure: a fact about the **repository**, the **service** or the **machine**.

A caller that retries a refusal retries it forever.

## The scan and this tool's rules

Two implementations meet at the scan:

- **The service locates call sites.** It owns the ladder's patterns, the version window and the
  edits it can describe.
- **This tool applies the changes that are edits to code.** `Rewrites` holds the rules that need
  the file's own context, a survey of a residue, or a scaffold the service cannot create. They go
  through the same line-checked writer as the service's edits: the scan's `text` is what the
  applier compares against, so a line that moved between the read and the write is refused
  rather than half-rewritten.

A rule that knows a change and would not touch a line is the most specific fact downstream can
have. It is kept, not counted: the repair agent's brief carries it. A rule whose own idempotence
guard matches a line has **read** the application and found nothing to do; that is an answer, and
the decision is removed rather than asking a person to look at a line that already reads the new
way.

The record names what happened, not just how many rules ran: applied, refused, already
satisfied, a gem declared for a change whose fix is a gem, a file created because a rule depends
on it, and any rule whose file glob was truncated. A rule that read a slice and found nothing
looks exactly like a rule with nothing to find, and only one of those is trustworthy.

## The machine

A step executes the application's commands somewhere. The chosen machine is part of the
evidence, because a gem with no prebuilt binary may build on one and not another:

- **native** — this process's Ruby. It is checked against the rung's `requires_ruby` before a
  bundle is spent. If the floor is not met, the step is `unverified` with a sentence saying to
  run it in an era container.
- **docker** — one era container per step, from the image the rung's Ruby requires. The
  application's services run inside that container; the worktree is mounted from the walker's
  named volume. A container is a step's, and the step's `ensure` stops it. A process that is
  killed runs no `ensure`, so `prune` and the next step's own pass reap what a killed run left.
- **rvm** — the era's Ruby from an rvm installation on the host, with a sibling services
  container publishing ports. It is faster and weaker as evidence: the stamp is the interpreter,
  the gemset and bundler, not an image digest.

The machine is written into the ledger and the record. A verdict recorded on a machine that is
no longer the one this step would get is re-opened rather than trusted: a fact about a machine
must not outlive the machine.

## Working copies and checkpoints

`step` and `preflight` never write to `--repo`.

- A git repository handed to `step` or `preflight` is opened as a detached `git worktree`, so the
  caller's files, index and `HEAD` are untouched. `plan` reads a local path in place.
- A URL for a plan is cloned once into `$UPGRADER_HOME` and reused; a plan is asked for
  repeatedly while a move is worked out. `preflight` and `step` make a fresh clone per run,
  because a step leaves a tree nobody wants to resume from.
- A directory with no `.git` given to `step` or `preflight` is refused by name. Copying it would
  produce a tree that looks like the caller's but is not, and a patch against it would be a claim
  about a repository the tool never read. `plan` can read one because it writes nothing.

A kept tree is reset to its checkpoint before the next step reads a lockfile. A clean tree is not
proof that the last step finished: concern commits move `HEAD`, so a process killed after one
leaves a clean tree sitting on a half-move. The checkpoint marker is the commit the rung started
from, and a tree at any other commit is put back. An interrupted step settled nothing, so the
tree it was measured in holds nothing worth keeping.

Each step's bundle lives under the step's home, outside the working copy and outside the tree a
checkpoint commits. It is deliberately not shared: a bundle is what gems are unpacked into and
executed from, so it is evidence rather than an artifact. `prune` removes one only when no live
run is using it.

## The ledger

`$UPGRADER_HOME/ledger.json` is a durable record of settled `(repository, commit, from, to)`
moves, the verdict and the machine that produced it. It is checked **before** anything runs: a
step costs a bundle resolve and a suite, and a loop that runs for weeks must not re-derive what
it already settled.

It is **state, not a cache**. A container that lost it would look healthy while re-deriving every
step it ever ran, which is why the loop names how many moves are settled at startup. `--force`
sets an entry aside for one run; the ledger is a memory, not a lock.

A queue row that is already at its target is not a run at all. The loop reports it idle rather
than recording a refusal every ten minutes, because a finished walk is finished.

## The queue and the loop

`serve` asks the service for a bounded slice of the queue (`GET /api/upgrades/targets`). The
service owns the order; the client asks for a slice and comes back after doing the work, which is
also how it avoids asking for more than the service will serve. An empty list is a real answer —
nothing is queued. A queue the service is **not serving** is an error, not an empty list: a paused
list read as an empty one is how the service's own mining queue went unused, and the two want
opposite responses from a loop.

For each row, the repository is the service's fact and the declaration is the application's:

- a row with a ref walks that ref;
- a row with no ref starts where the declaration's `base_ref` says;
- a row whose repository has a declaration uses that declaration's suite, services, environment
  names and delivery;
- a row with no declaration uses the stack's defaults. That is not an error: the engine can walk
  a repository nobody declared, it just has less to go on.

The loop's smallest unit is one step. `--walk` chains passed rungs in a cycle, up to `--rungs`
(three by default). The bound is a budget, not a preference: one rung is a bundle install and a
suite, and a cycle that never returned would leave the heartbeat untouched for a day.

Three behaviours make a long-running loop survivable:

- **The heartbeat is touched once a cycle**, and the container's healthcheck reads its age. A
  process that is up and stuck is the failure a healthcheck exists to catch.
- **A signal stops the loop between steps**, not in the middle of one. The ledger is saved and
  the container exits; whatever was in flight is retried at the next start.
- **A failed delivery is debt, not a failed rung.** A passed rung whose branch or pull request
  never arrived is already paid for; the next cycle retries the delivery before asking for work,
  because re-walking it would spend the rung again.

A rung that does not pass is retried on a backoff (30 seconds, doubling while the same rung keeps
failing, capped at the cycle interval). The usual reason a rung does not pass is a change
somebody has just made, and ten minutes of waiting is a window in which nobody can tell whether
the change worked.

## The record and the review brief

The record is the product. `--record` writes a JSON file and a patch. The JSON carries:

- the repository, commit and worktree;
- the move, the rung, the required Ruby, the interpreter, the image and the machine stamp;
- the verdict and its sentence;
- the baseline and post-move suite;
- every stage, every command, its exit code and the tail of its output;
- the edits applied and the edits refused with their reasons;
- the decisions in force, the checks, the repairs and the commits;
- `wrote_nothing_to_the_repository: true`.

The patch is the diff; the record is the explanation. A reviewer who has only the record can
see what was run, what was refused and what was not measured. `preview` renders the same body a
pull request would carry from a stored record, without a checkout, a token or a push. `serve`
stores the rendered brief beside the delivery, so a retry does not re-render it and a site admin
reads the bytes the pull request carried rather than reimplementing the body in Rails.

## Why no dependencies

The default image is Ruby and `git`. The tool reads a `Gemfile.lock` with
`Bundler::LockfileParser`, a **default gem**, and speaks HTTP with `Net::HTTP`. There is no
Gemfile, no `bundle install`, and no `bundle exec` in front of a tool that has no dependencies.

The reasons are practical rather than ideological:

- A dependency would need its own install in an image whose job is to install *somebody else's*
  dependencies, and the failure modes would be hard to tell apart.
- The tool must run on the interpreter of the era it is walking. A gem with a native extension
  would tie the client to one Ruby, which is the one thing this client must not be.
- A small dependency surface is easier to audit in a container that executes untrusted
  application code and holds a Docker socket.

The steps the tool executes do install gems; that is the application's bundle, not the tool's.

## Where the tests live

The standalone suite (`ruby -Ilib -Itest test/all_test.rb`) drives the client with injected
seams: a fake corpus, a fake machine, a fake step class, a temporary git repository. It needs no
network, no Rails application and no service.

A few agreements cannot be tested from this repository alone, because they are about the service's
own data and deployment:

- the ladder's step and change counts, and the release the ladder tops out at;
- the service's schema, which is the vocabulary a client reads;
- the gem-migrations digest's companions;
- the service's preflight question bound;
- the frozen scan recording's idempotence;
- the production compose file's image arguments, mounts and security posture.

Those live in the service's own `test/contracts/upgrader/` suite, where a checkout holds both
sides. The alternative — copying the service's data into this repository — would be a second
copy of the ladder, which is the thing the whole design avoids. See
[Development](development.md#cross-repository-contracts).
