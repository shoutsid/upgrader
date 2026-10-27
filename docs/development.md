# Development

## Run the suite

```bash
cd upgrader
ruby -Ilib -Itest test/all_test.rb
```

There is no Gemfile, no `bundle install` and no rake task. The tool has no runtime gem
dependencies, so its tests need none either; a suite that required a bundle to check a program
that requires nothing would be the wrong shape. The tests use Minitest, which is a default gem.

One file:

```bash
ruby -Ilib -Itest test/rewrites_test.rb
```

One test:

```bash
ruby -Ilib -Itest test/rewrites_test.rb -n test_the_removal_rule_takes_a_whole_line_and_leaves_every_other_shape_alone
```

The suite runs on Ruby 3.3.12 in CI and on whatever Ruby 3.3+ is on your machine. It needs no
network, no Rails application, no Docker daemon and no service: every external seam is injected.
`test/all_test.rb` also counts `def test_` declarations against Minitest's runnables. A test
method written outside its class is invisible to Minitest and would leave a green suite with no
evidence; the count makes that a failure.

## Layout

```text
bin/agents-upgrader          the one entry point
lib/agents/upgrader.rb       the loader
lib/agents/upgrader/          the client
  cli.rb                          modes, flags and exit status
  step.rb                         the pipeline
  serve.rb                        the loop
  source.rb                       clones and worktrees
  machine.rb                      native, docker and rvm execution
  corpus.rb                       the service client
  record.rb                       verdicts and the JSON record
  rewrites.rb                     this tool's own code rules
  project.rb                      project declarations
  data/interpreters.json          the era matrix
  data/projects/*.json            built-in declarations
images/                           one era image, built per matrix row
scripts/upgrader-images.sh        build/list/prune the era images
scripts/upgrader-rubies.sh        install/list/check the rvm interpreters
test/                             the standalone suite
Dockerfile                        the image, with build arguments for a step
entrypoint.sh                     the loop's waiter and flag assembly
```

The client has no database driver and no database route. If a change would add one, the design
has gone wrong: the client talks to the service over HTTP with an operator key.

## Cross-repository contracts

A few tests are about the **service** as much as the client. They live in the service's repository,
under `test/contracts/upgrader/`, because only a checkout that holds both sides can run them:

| Contract | Why it cannot live here |
|---|---|
| the ladder's step and change counts, and its top release | the ladder is `data/rails_ladder.json` in the service; copying it here would be the second copy the design forbids |
| the service's schema vocabulary | the schema of record is the service's `db/structure.sql`; the client reads it as an oracle, not as a copy |
| the gem-migrations digest's companions | the digest and its data are the service's |
| the preflight question bound | the digest's contract is the service's |
| the frozen scan recording's idempotence | the recording and the projection belong to the service |
| the production compose file's image arguments, mounts and security posture | the compose file is the service's deployment |

Run them from the service's checkout:

```bash
RAILS_ENV=test bin/rails test test/contracts/upgrader
```

The standalone suite must not read a parent directory. A test here that reaches into the
service's `data/` is a test that cannot run in this repository's CI, which is the whole point of
the split. If an agreement needs both sides, it belongs in the service's contract suite; if it
can be stated about this repository alone, it belongs here.

The artifact test (`test/artifact_test.rb`) is the local half of the deployment agreement: it
compiles the entrypoint's health probe, reads the Dockerfile's user and environment, and checks
every flag the entrypoint passes against the CLI's usage text. The service's deployment contract
is the other half.

## Adding a code rule

`Rewrites` is where a change that needs the file's own context goes. A rule declares:

- the change it answers (the ladder's subject);
- a pattern that matches the **old** form;
- the edit, or a survey of the residue;
- an idempotence guard for the new form.

The rule must be safe to apply twice, must not rewrite a line it did not read, and must leave a
change it cannot decide as a decision rather than a partial edit. `test/rewrites_test.rb` drives
the rules; `test/applier_test.rb` drives the writer's refusal cases. A rule for a rung the
application has already crossed must find nothing, which is what makes the wider scan window
safe.

## Adding a project declaration

Put a JSON file in `lib/agents/upgrader/data/projects/<slug>.json`. The image copies `lib/`, so
a declaration there is present in the deployment; a file in the repository root would be absent
from the image and present everywhere else. An operator can shadow it with a file in
`UPGRADER_PROJECTS_DIR`.

`test/project_test.rb` validates the shape, including unknown keys. Add a case there for a new
field or a new refusal. A declaration carries environment **names**, never values.

## Adding an era

Add a row to `lib/agents/upgrader/data/interpreters.json`, then:

```bash
scripts/upgrader-images.sh build <name>
scripts/upgrader-images.sh list
```

The image is built from `images/Dockerfile` with the row's base, bundler and Ruby. The client
chooses the oldest era that meets a rung's `requires_ruby`; it probes a candidate by installing
the application's own bundle, so a row that cannot install is discovered rather than assumed.
`test/interpreters_test.rb` drives the matrix and the scripts.

The era images are not part of the release workflow. They are deployment material, built on the
daemon the walker talks to.

## Style

The client is Ruby with the service's house style: two-space indentation, frozen string literals,
comments that explain **why** rather than what, and errors that say what to do next. There is no
RuboCop configuration in this repository; the service's RuboCop run scans this tree when it is
checked out as a submodule, and its guide is the one to follow. In standalone CI the checks are
`ruby -c` over every Ruby file and `bash -n` over the shell scripts.

Do not add a runtime dependency. A default gem is acceptable when it is the right tool
(`Bundler::LockfileParser`), but a new gem is a design change, not a convenience.

## The release process

1. Update `lib/agents/upgrader/version.rb` and `CHANGELOG.md`.
2. Run `ruby -Ilib -Itest test/all_test.rb`.
3. Run the service's contract suite if this checkout is the submodule.
4. Commit, tag `vX.Y.Z`, push the tag. The release workflow builds the tool image and publishes it
   to GHCR; the era images remain local and are built with `scripts/upgrader-images.sh`.

The release image is built with the step arguments (compiler and Docker client). The one-shot
`plan` image is the default build. The repair agent stays off unless a deployment deliberately
builds it in.

## Pull requests

- Keep a change to one concern.
- Add or update a test that would fail without it.
- Update the docs if a flag, a default or a refusal changes.
- Do not skip a test to make the suite green. If an agreement needs the service, move it to the
  service's contract suite; if it can be stated here, state it here.
- Do not add a secret, a token or an application's private source to a fixture. A fixture is a
  recording; treat it like a record.
