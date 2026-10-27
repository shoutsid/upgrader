# Documentation

The upgrader is a client of the agents service. These documents describe the client as
it behaves today: what it can do, how it is configured, what it records, and what it
deliberately cannot prove.

Start with [Getting started](getting-started.md) if you are running the tool for the first
time. If you are changing it, read [Development](development.md) and
[Architecture](architecture.md) first.

| Document | Read it when you need to… |
|---|---|
| [Getting started](getting-started.md) | install the tool, name a service, and run a first plan or step |
| [CLI reference](cli.md) | look up a command, flag, exit code or output shape |
| [Configuration](configuration.md) | set environment variables, write a project declaration, or choose a machine |
| [Architecture](architecture.md) | understand the step pipeline, the ledger, the queue and the scan/rules split |
| [Service API](service-api.md) | see which endpoints the client calls, with which credentials and error handling |
| [Deployment](deployment.md) | build or run the image, mount the volumes, and reason about its security posture |
| [Design notes](design-notes.md) | understand why a decision was made, including the failures that forced it |
| [Limitations](limitations.md) | know what the tool does not prove, and which modes trade strength for speed |
| [Development](development.md) | run the suite, add a rule, or work on the cross-repository contracts |
| [Troubleshooting](troubleshooting.md) | diagnose a failed plan, step, container, suite or delivery |

The public service publishes its machine-readable surface at
`https://agents.shoutsid.fyi/.well-known/agents.json` and an agent-oriented summary at
`https://agents.shoutsid.fyi/llms.txt`. Those documents are the service's; this directory
describes only the client's use of them.

## A note on the two repositories

The upgrader lives in its own repository. The service's repository holds the ladder, the
schema, the gem-migrations digest and the deployment. A few tests read both sides; they live
in the service's `test/contracts/upgrader/` suite, not here. Everything in this repository's
suite runs standalone. [Development](development.md) explains the split.
