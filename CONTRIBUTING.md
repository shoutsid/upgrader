# Contributing

This repository is **proprietary**. It is public so operators and reviewers can read the client,
not because it is open source. See [LICENSE](LICENSE).

## Before you write code

Open an issue first and describe the change. Contributions are accepted only by prior
arrangement with the copyright holder. Do not send a pull request that adds a feature, a
dependency or a large refactor without that conversation; it may be declined for reasons that
have nothing to do with the quality of the code.

Opening an issue or a pull request does not grant a licence to use the repository, and does not
transfer ownership of your contribution. Any contribution that is accepted is subject to a
separate written agreement with the copyright holder.

## What is welcome

- A reproducible bug report with the command, the version, the operating system and a redacted
  record.
- A correction to documentation that is wrong about the current behaviour.
- A test that demonstrates a real failure, with the smallest reproduction you can find.
- A focused fix, discussed first.

## Development

You need Ruby 3.3 or newer and `git`. There is no Gemfile and no `bundle install`.

```bash
git clone https://github.com/shoutsid/upgrader.git
cd upgrader
ruby -Ilib -Itest test/all_test.rb
```

A single file:

```bash
ruby -Ilib -Itest test/rewrites_test.rb
```

The suite needs no network, no Rails application, no Docker daemon and no service. If your change
needs one of those to test, it likely belongs in the service's cross-repository contract suite,
not here. [Development](docs/development.md) explains the split.

## Design rules

- **No new runtime dependencies.** A default gem is acceptable when it is the right tool; a new
  gem is a design change, not a convenience.
- **The ladder is the service's.** Do not add a copy of Rails' release order, a default service
  URL, or a default target to the client.
- **A refusal is not a crash.** Keep the three exit codes (`0`, `1`, `2`) and the four verdicts
  (`passed`, `failed`, `refused`, `unverified`) distinct.
- **The record is evidence.** A change that makes a step pass without recording what was run,
  what was refused and what was not measured is not finished.
- **Do not skip a test to make the suite green.** If an agreement needs both repositories, move it
  to the service's contract suite; if it can be stated here, state it here.

## Style

- Two-space indentation, frozen string literals, no trailing whitespace.
- Comments explain **why**, not what the code already says.
- Errors say what the caller should do next, with the count or the limit named.
- Tests are named as sentences and a test that documents a deliberate refusal says so.

The service's RuboCop run scans this tree when it is checked out as a submodule. In standalone CI
the checks are `ruby -c` over every Ruby file and `bash -n` over the shell scripts.

## Pull requests

- One concern per change.
- Add or update a test that would fail without the change.
- Update the docs when a flag, default, refusal or record field changes.
- Do not add a secret, a token or an application's private source to a fixture.
- Describe how you tested it, including the Ruby version and whether Docker was involved.

## Security

Do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

## Conduct

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
