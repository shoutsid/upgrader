# Limitations

This page is the honest half of the documentation. Each item is a limit of this version, not a
bug waiting to be reported.

## The walker is not a verifier

A step that passes says the application's suite was green before the move and green after it, on
the machine the step ran on. It does not say the move is correct for every caller, and it is not
independent verification. The service promotes a report to `resolved_verified` only through
operators other than its author; a report filed by this walker is evidence, not that promotion.

A weak suite produces weak evidence. The tool measures the gate the application declares; it does
not invent tests, and a `suite.kind: "none"` declaration is measured by its boot.

## A style gate is only judged on a tree that arrived formatted

The style pair (`format`, `check`) is an autocorrect and its verifier, so "did this rung leave the
tree formatted" is a question about a change, and the base commit is what it is a change from.
The check half is therefore run once on the untouched tree. A red answer means the tree arrived
unformatted: the formatter does not run (formatting it is a rewrite of the application, not the
move) and the check is carried as `preexisting` — not green, not a failure of the rung, and named
in the record with the base commit's exit code. This matters for the projects whose own lint job is
diff-scoped (`pronto` over a pull request's changed lines), where a whole-tree run is red by
design: measured on diaspora, 444 offences on a clean `develop`.

The formatter the tool *suggests* is `rubocop -a`, never `-A`: RuboCop's unsafe corrections include
`Style/ClassAndModuleChildren`, whose rewrite of `module User::Querying` into `module User` over a
class is `User is not a module` at boot. A project may still declare `-A` itself; the tool runs what
it is given.

## `unverified` means nothing was established

No interpreter installed the bundle, the suite could not run, the baseline was red, or a required
check did not run. The step exits `1` and the record says which. It is not a pass with a caveat,
and it is not a statement that the move is broken either — it is the absence of a measurement.

## The ladder is a documented set of changes, not every change

The service's ladder carries the changes its authors documented. A rung can pass while a change
the ladder does not know about breaks an application. The scan also only finds what a pattern can
find: an `inert` change is one the ladder documents and no pattern on either side can locate. It
is named in the record rather than silently dropped, but naming it is not fixing it.

The ladder reads forward. A backwards move is a refusal, not a downgrade operation. The top of
the ladder is the newest release it carries; the tool does not know about a release the service
has not published.

## Rails is the only stack

`stack: "rails"` is the only pack this build carries. The project declaration and the engine are
shaped for another stack — the pack would own what a release changes and how a command is spelled —
but a second pack is not implemented. A non-Rails application is not walkable today.

## The toolchain is partly spent

`toolchain` is validated, quoted and recorded. **`apt` is installed**: the packages a repository's
own build declares (`apt-get install` in a workflow, a `Dockerfile`, `.travis.yml` or
`.gitlab-ci.yml`) are installed in the era container before `bundle install`, because a native gem
that needs a header the image does not carry fails the rung for a reason the repository already
stated. That is the whole of what is spent: `ruby`, `node`, `postgres`, `extensions` and `native`
are still carried rather than reproduced, and the overlay image that would use them is a later
phase. A package the repository does not declare, and the image does not carry, is still a bundle
failure rather than a reproduced environment — and a native or rvm walk installs none of it, so a
missing header there is a failure a container walk would not have.

## `app:update` adopts only added files

`app_update.adopt` accepts `added_only`. A file the application already owns keeps the
application's version and the conflict is recorded. There is no three-way merge and no policy
that overwrites. A conflict is a decision for the reviewer.

## The rvm machine is weaker evidence

A container's identity is its image's content id, which is what makes a rebuilt era a different
machine to the ledger. An rvm machine's identity is its interpreter, gemset and bundler; a gem or
a system library that changed under those same versions is not noticed. The stamp says exactly
that much and no more. Use `docker` when the machine identity matters.

## The Docker socket is a trust decision

`UPGRADER_RUNTIME=docker` needs the host's Docker socket, which is root-equivalent on the host.
Era containers mount one directory, run no privileged command and are removed at the end of the
step, but the socket still widens what a compromised step can reach. A deployment that cannot
accept that trade uses `native` and walks no old application.

## A record can contain application output

The record keeps the tail of every command's output, and a failure report can quote the evidence
the step recorded. An application that prints a secret in its test output will put that secret in
the record and possibly in a report. The tool never writes `AGENTS_FYI_KEY`, `UPGRADER_GITHUB_TOKEN`
or a suite environment value into a record, but it cannot redact what the application itself
prints. Review a record before sharing it, and treat the record's directory as sensitive.

The service's corpus is public. A report filed by the walker is a public report; the client does
not file the whole source, but it may quote a failure's output.

## The scan is bounded

The scan sends at most `MAX_SCAN_FILES` files and `MAX_SCAN_BYTES` bytes. A `413` is reported as
the service's answer rather than retried smaller. A repository bigger than the bound is not
fully scanned, and the record says how many files were sent; "nothing found" is about those
files, not about the repository.

## The queue is the service's

`serve` walks what the service's queue offers. A queue row with a repository nobody declared
still walks with the stack's defaults, but it has less to go on: no suite command, no services,
no environment names. A declaration is how an application gets its own facts.

An empty queue and a paused queue are different answers; the client raises on the paused one
rather than treating it as empty. A queue that is merely stale is not distinguishable from one
that is finished from inside the loop; the cycle names its reasons and the ledger names its
settled count.

## A step is one rung

`step` moves the application across the first release of the move. It does not chain. `serve
--walk` chains rungs, up to `--rungs` per cycle (three by default); a walk from 4.0 to 8.1 is
therefore several cycles by design. The bound is a budget: one rung is a bundle install and a
suite, and a cycle that never returned would leave the heartbeat untouched for a day.

## Publishing is a branch and a pull request, not a merge

`--publish` pushes a branch and opens (or updates) a pull request. It never merges, never forces
a branch, and never publishes a step that did not pass. A passed rung whose delivery failed is
debt: the next cycle retries the delivery rather than re-walking the rung. `serve --publish`
needs a connected GitHub App installation for the repository; without one it publishes nothing
and says so. There is no deployment-wide customer credential to fall back to.

## No online service means no plan

`plan`, `preflight`, `step` and `serve` need the service. There is no offline ladder, no bundled
copy of Rails' release order, and no default service. `preview` and `prune` work offline from what
is already on the volume; `republish` needs GitHub but not the agents-fyi service.

## The image is Linux and the era matrix is finite

The tool runs in a Linux container. The era images are built for the interpreters the matrix
carries; a release whose floor no image meets is refused by name rather than attempted. A
native extension with no prebuilt binary needs a compiler in the step image (`WITH_BUILD_TOOLS=1`),
and an era container needs the Docker client (`WITH_DOCKER_CLIENT=1`). The default image has
neither, because `plan` needs neither.

## No quota, and several walkers share a key

The client imposes no write limit on itself, and the service is the authority on limits. A
deployment that runs several walkers shares the operator key and the queue; the loop's interval
is a schedule, not a rate limiter. Treat the service's response as the statement about limits.

## The license is proprietary

This repository is public but not open source. No use, copying, modification, publication,
distribution, sublicensing or sale is permitted without prior written permission. See
[LICENSE](../LICENSE). "Public" here means readable, not licensed for reuse.
