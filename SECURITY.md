# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x | yes |
| older | no |

The client is early. A security fix lands on the latest released minor and is not backported
unless the maintainer says otherwise in the advisory.

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub's private vulnerability reporting for this repository
if it is enabled (Security → Advisories → Report a vulnerability). If it is not, contact
**@shoutsid** through the private contact methods on their GitHub profile and say that the report
is a security matter.

Please include:

- the version (`agents-upgrader --version` or the image tag);
- the operating system and Ruby version;
- the command, mode and relevant flags;
- what an attacker can do, and what they need to start with;
- a minimal reproduction, with keys, tokens and private source redacted.

You will get an acknowledgement as soon as the maintainer sees the report. There is no bug bounty
and no guaranteed response time; this is a small proprietary project.

## Scope

This tool **executes code by design**. It clones repositories, installs their bundles, runs their
test suites and, in `docker` mode, starts containers from era images. A report that "a malicious
repository can run code" is a description of the product, not a vulnerability, unless the code
escapes the boundary the deployment chose.

The boundaries worth reporting a break of:

- **The service credential.** The client holds an operator key, never `ADMIN_TOKEN`. A path that
  reads, logs or transmits the key, or that lets a walked repository reach the service's admin
  surface, is in scope.
- **The GitHub token.** `step --publish` reads `UPGRADER_GITHUB_TOKEN`, and the loop receives a
  short-lived credential from the service. Neither may be written into a record, a report or a
  log line. A leak is in scope.
- **The Docker socket.** `UPGRADER_RUNTIME=docker` mounts the host's socket, which is
  root-equivalent. A walked repository reaching the socket *through the client* — rather than
  being able to run Docker because the deployment gave it a socket — is in scope. The trust
  decision itself is documented in [Deployment](docs/deployment.md#security-posture); a deployment
  that cannot accept it should use `native`.
- **The record and the report.** A record keeps command output; a report may quote it. A path that
  writes the client's own key, token or suite environment values into either is in scope. An
  application printing its own secret is the application's leak, not this client's, but a
  redaction failure in the client is.
- **Path handling.** A cloned repository must not be able to make the client read or write outside
  its working copy through a crafted path or symlink. The applier is line-checked and refuses a
  line that moved; a bypass is in scope.
- **The container posture.** The image runs as uid `10003` with a read-only root. A path that
  writes outside the declared volumes, or that gains privileges, is in scope.

Out of scope:

- a repository's own build scripts doing what build scripts do;
- a deployment that mounts the Docker socket and then runs untrusted repositories, where the
  escape is the socket the operator mounted;
- a leaked key that was placed in the environment, a record or an image by the operator;
- denial of service from a step that is slow, unless it defeats the declared deadline.

## Safe harbour

Do not test against a deployment you do not own, and do not use a real operator key or GitHub
token in a report. A proof of concept against a local service and a disposable repository is
enough.
