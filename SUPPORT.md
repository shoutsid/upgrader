# Support

This is a small, proprietary project. There is no support contract, no service-level agreement
and no guaranteed response time. The documentation is the first line of support, and the issue
tracker is the second.

## Before opening an issue

1. Read [Getting started](docs/getting-started.md) and [Configuration](docs/configuration.md).
2. Read [Troubleshooting](docs/troubleshooting.md); it covers the common refusals, unverified
   steps, Docker failures and queue problems.
3. Search the existing issues.
4. Re-run the command with `--record ./out` and read the JSON `stages`. The record usually names
   the failure more precisely than the terminal output.

## What to include

- the version and the image tag;
- the operating system and Ruby version;
- the exact command and flags;
- the service URL, **never the operator key**;
- the exit code and the record, with secrets and private source redacted;
- whether the runtime was `native`, `docker` or `rvm`.

## What is not supported

- a deployment's own compose file, proxy or secret store;
- a modified image or a fork;
- a repository whose suite cannot run for reasons outside the client;
- a request for a licence, a redistribution right or a support contract.

Licensing questions go to the copyright holder; see [LICENSE](LICENSE). Security reports go
through [SECURITY.md](SECURITY.md), not the issue tracker.
