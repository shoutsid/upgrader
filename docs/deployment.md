# Deployment

The image has one entrypoint — the CLI — so a one-shot `plan` or `step` and a long-running loop
are the same image with different commands. The loop is a service that opts into
`/app/entrypoint.sh`; a `docker run <image> plan …` is unchanged.

## Build the image

The default image is for `plan`, `preview`, `prune` and a native `step` whose application needs
no compiler:

```bash
docker build -t agents-fyi-upgrader:0.1.0 .
```

A step that installs a real application's bundle needs a compiler, and a step that runs an era
container needs the Docker client. Both are build arguments rather than a second Dockerfile:

```bash
docker build \
  --build-arg WITH_BUILD_TOOLS=1 \
  --build-arg WITH_DOCKER_CLIENT=1 \
  -t agents-fyi-upgrader:step .
```

The repair loop is a third argument and the only one that adds a model client and a Node runtime:

```bash
docker build \
  --build-arg WITH_BUILD_TOOLS=1 \
  --build-arg WITH_DOCKER_CLIENT=1 \
  --build-arg WITH_REPAIR_AGENT=1 \
  -t agents-fyi-upgrader:step .
```

The defaults must stay off for the one-shot image. `plan` builds no native extension and starts
no container, and a service that cannot compile a native gem fails in the quietest way there is:
it runs, reports healthy and completes no step. The deployment's build sets what its job needs.

## Run one command

```bash
docker run --rm \
  -e AGENTS_FYI_URL=https://agents.shoutsid.fyi \
  -v "$PWD:/work" \
  -w /work \
  agents-fyi-upgrader:0.1.0 \
  plan --repo . --to 7.1.0
```

The image's entrypoint is the CLI, so the arguments after the image name are the CLI's.

## Run the loop

```bash
docker run --rm \
  -e API_BASE_URL=http://service:8001 \
  -e AGENTS_FYI_KEY=… \
  -e UPGRADER_TO=7.1.0 \
  -e UPGRADER_RUNTIME=docker \
  -e UPGRADER_PUBLIC_URL=https://agents.shoutsid.fyi \
  -v upgrader_cache:/home/upgrader/.cache/agents-fyi-upgrader \
  -v upgrader_gems:/home/upgrader/.gem \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c '%g' /var/run/docker.sock)" \
  --read-only \
  --tmpfs /tmp:size=1g \
  --security-opt no-new-privileges:true \
  --memory 2g \
  --stop-timeout 60 \
  agents-fyi-upgrader:step \
  /app/entrypoint.sh
```

`entrypoint.sh` waits up to five minutes for `GET /api/health`, then starts anyway: an API that
is down is something a loop waits out rather than a reason not to start. It then passes the
deployment's settings to `serve`. The variables it reads are in
[Configuration](configuration.md#the-service-loops-entrypoint).

## Volumes

| Path | What it holds | May it be lost? |
|---|---|---|
| `/home/upgrader/.cache/agents-fyi-upgrader` | the ledger, working copies, per-run bundles, `state/`, `records/`, the repair agent's config | **No.** The ledger is state. Losing it re-derives every settled move while the container looks healthy. |
| `/home/upgrader/.gem` | `GEM_HOME`; the gems an install downloaded | Yes, with a re-download. A `.gem` is an artifact the index published a hash for. |
| `/home/upgrader/.cache/agents-fyi-upgrader/state` | the progress and delivery feed a site admin reads | It is a feed, not the ledger. Losing it loses history, not knowledge. |
| the directory named by `UPGRADER_PROJECTS_DIR` | project declarations written by an operator | No; it is configuration, not state. |

The **bundle** is deliberately not a volume of its own. A bundle is what gems are unpacked into
and executed from, so it is evidence, not an artifact; it lives under the cache volume, outside
the working tree, and cannot be shared by accident. `prune` removes a bundle only when no live run
is using it.

The image creates every mounted directory before `USER upgrader`, because a named volume mounted
at a path the image did not create is owned by root. That is the difference between a gem cache
that works and one that is silently unused, and between a ledger that is written and a service
that settles nothing.

## Machines

### Native

`UPGRADER_RUNTIME` empty or `native` runs the application on this image's Ruby 3.3. It is the
right choice for a modern application and the wrong one for an old one: a Rails 4 bundle does not
install on 3.3, and the step is `unverified` with a sentence saying to use an era container.

### Docker era containers

`UPGRADER_RUNTIME=docker` starts one container per step from the image the rung's `requires_ruby`
names. The application's own services (PostgreSQL, Redis) run inside that container; the worktree
is mounted from the walker's home volume, which is why the volume must be **named** and visible to
the same daemon. The walker discovers the volume from its own container; `UPGRADER_DOCKER_VOLUME`
is the escape hatch when discovery cannot answer.

The era images are not published by the release workflow. They are built locally for the matrix
the client ships:

```bash
cd upgrader
scripts/upgrader-images.sh list
scripts/upgrader-images.sh build
scripts/upgrader-images.sh build 2.2 2.5
scripts/upgrader-images.sh prune
```

`build` reads `lib/agents_fyi/upgrader/data/interpreters.json` and builds each era from the one
`images/Dockerfile`; adding an era is a row in the matrix, not a new Dockerfile. The client needs
the images on the same daemon it talks to. A rung whose floor no image meets is refused by name
rather than attempted.

`UPGRADER_INTERPRETER_IMAGES` pins an image by digest (`2.2=sha256:…,2.5=sha256:…`), which makes
a rebuild a deliberate change rather than a rebuild that quietly re-runs verdicts against
different bytes.

### rvm

`UPGRADER_RUNTIME=rvm` runs the era's Ruby from an rvm installation on the host, with a sibling
services container publishing ports. It is the fastest mode because it starts no container per
step, and the weakest as evidence: the machine stamp is the interpreter, the gemset and bundler,
not an image digest.

```bash
scripts/upgrader-rubies.sh list
scripts/upgrader-rubies.sh install
scripts/upgrader-rubies.sh check
```

The script respects rvm's `autolibs` rather than running package installs behind your back. It
uses `UPGRADER_RVM_GEMSET` (default `agents-fyi-upgrader`) so a walk never installs into the
developer's default gemset.

## Healthcheck

The image ships no `HEALTHCHECK` on purpose: a check in the image would be a check on the wrong
thing for a one-shot `plan`. The loop's liveness is the age of a heartbeat file it touches once a
cycle:

```yaml
healthcheck:
  test: ["CMD", "ruby", "-e", "p='/home/upgrader/.cache/agents-fyi-upgrader/heartbeat'; exit(0 if File.exist?(p) && (Time.now - File.mtime(p)) < 5400 else 1)"]
  interval: 5m
  timeout: 15s
  start_period: 15m
  retries: 3
```

The process being up says nothing about whether it is working. A loop whose corpus went away
looks exactly like one that is thinking, for hours; a heartbeat older than ninety minutes is a
stall worth acting on rather than a slow cycle worth restarting.

## A compose example

This is illustrative rather than a file the repository ships. It assumes a service reachable on
the compose network and a host Docker socket.

```yaml
services:
  upgrader:
    build:
      context: .
      args:
        WITH_BUILD_TOOLS: "1"
        WITH_DOCKER_CLIENT: "1"
        WITH_REPAIR_AGENT: "0"
    image: agents-fyi-upgrader:step
    restart: unless-stopped
    entrypoint: ["/app/entrypoint.sh"]
    environment:
      API_BASE_URL: http://service:8001
      AGENTS_FYI_KEY: ${AGENTS_FYI_KEY:?an operator key is required for the queue}
      UPGRADER_TO: 7.1.0
      UPGRADER_RUNTIME: docker
      UPGRADER_PUBLIC_URL: https://agents.shoutsid.fyi
      UPGRADER_INTERVAL: "600"
      UPGRADER_STEP_TIMEOUT: "3600"
      UPGRADER_RECORD: /home/upgrader/.cache/agents-fyi-upgrader/records
    volumes:
      - upgrader_cache:/home/upgrader/.cache/agents-fyi-upgrader
      - upgrader_gems:/home/upgrader/.gem
      - /var/run/docker.sock:/var/run/docker.sock
    group_add:
      - "${UPGRADER_DOCKER_GID:-999}"
    read_only: true
    tmpfs:
      - /tmp:size=1g
    security_opt:
      - no-new-privileges:true
    mem_limit: 2g
    stop_grace_period: 60s

volumes:
  upgrader_cache:
  upgrader_gems:
```

A deployment that does not want the Docker socket sets `UPGRADER_RUNTIME: native`, drops the
socket, and walks nothing old. That is a real choice, not a degraded one: it is the posture for a
modern application.

## Security posture

The loop executes code from repositories it is asked to walk. That is its job, and the deployment
makes the trust explicit rather than pretending the container is a sandbox:

- **It runs as a non-root user** (uid `10003`, `upgrader`).
- **The root filesystem is read-only**, with a small tmpfs at `/tmp`. Gem and bundle scratch goes
  to `TMPDIR` on the cache volume, so the tmpfs is a bound for whatever ignores it, not the place
  a bundle is unpacked. A tmpfs with pip's scratch in it cost one project 4.1 GB in thirty-five
  minutes and installs failing with an empty message; the same rule applies here.
- **No database driver, no route to the database, no `DB_PASSWORD`.** The client's record write is
  an HTTP request with its operator key.
- **No `ADMIN_TOKEN`.** Filing a report is the whole of what a walk needs. A container that
  clones and executes other people's applications is the last place to put the moderation
  surface.
- **The Docker socket is root-equivalent on the host.** Mounting it widens "code in this
  container" to "code on this host". What keeps it defensible is that this container already
  executes arbitrary code by design — a bundle's build scripts, an application's test suite — and
  that the era containers it starts mount one directory, run no privileged command and are
  removed at the end of the step. If that trade is not acceptable, use `native` and do not mount
  the socket.
- **`no-new-privileges` is set**, so a process cannot gain privileges through setuid binaries.
- **A step is killed at its deadline**, and the grace period before the runtime sends `SIGKILL`
  is long enough to finish one step's tail. A step killed halfway records nothing; the loop
  checkpoints after each step, so a restart resumes rather than starting over.

The operator key is a client's key. Rotating it is the same operation as rotating any operator's
key in the service; the container needs a restart to read the new value.

## Logs and stopping

The container's output is the CLI's report and one line per cycle. There is no logging framework
and no log-level flag. `docker compose logs -f upgrader` is the whole interface.

`SIGTERM` stops the loop **between steps**, not in the middle of one. The ledger is saved and the
container exits; whatever was in flight is retried at the next start. `stop_grace_period` should
cover one step's tail, not a whole cycle.

## Backups and upgrades

Back up the cache volume, not only the image. The ledger, the working copies and the repair
agent's authenticated config live there, and losing the ledger is the one loss that makes a
healthy container start from "nothing examined" without saying so. The image is disposable; the
volume is not.

Upgrading the client is replacing the image and restarting the service. The ledger's format is
read for compatibility with what is on the volume; a record that cannot be read is set aside by
the ledger rather than crashing the loop, and the startup line still names what is settled.
